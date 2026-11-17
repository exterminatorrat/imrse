import Darwin
import Foundation
import XCTest
@testable import ImrseLocal

final class ManagedLocalResourceLeaseTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("imrse-lease-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }

    func testIndependentOwnersContendAndDeinitReleasesWithoutUnlink() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        var first: ManagedLocalResourceLease? = try .acquire(root: root)
        try withExtendedLifetime(first) {
            XCTAssertThrowsError(try ManagedLocalResourceLease.acquire(root: root)) {
                guard case ManagedLocalResourceLease.Failure.busy = $0 else { return XCTFail("Expected busy") }
            }
        }
        first = nil
        let second = try ManagedLocalResourceLease.acquire(root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(ManagedLocalResourceLease.filename).path))
        withExtendedLifetime(second) {}
    }

    func testUnsafeLockObjectsFailClosed() throws {
        for kind in ["symlink", "directory", "public", "hardlink", "fifo"] {
            let root = try root()
            defer { try? FileManager.default.removeItem(at: root) }
            let lock = root.appendingPathComponent(ManagedLocalResourceLease.filename)
            let other = root.appendingPathComponent("other")
            try Data().write(to: other)
            switch kind {
            case "symlink": try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: other)
            case "directory": try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
            case "public": try Data().write(to: lock); XCTAssertEqual(chmod(lock.path, 0o644), 0)
            case "hardlink": try FileManager.default.linkItem(at: other, to: lock)
            default: XCTAssertEqual(mkfifo(lock.path, 0o600), 0)
            }
            XCTAssertThrowsError(try ManagedLocalResourceLease.acquire(root: root), kind) {
                guard case ManagedLocalResourceLease.Failure.unavailable = $0 else { return XCTFail("Expected unavailable") }
            }
        }
    }

    func testUnsafeRootFailsClosed() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(chmod(root.path, 0o777), 0)
        XCTAssertThrowsError(try ManagedLocalResourceLease.acquire(root: root))
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        XCTAssertThrowsError(try ManagedLocalResourceLease.acquire(root: alias))
    }

    func testParentAliasSharesSameLockAndThrownOperationReleases() throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = parent.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: false)
        let alias = parent.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: parent)
        enum Expected: Error { case stop }
        do {
            let lease = try ManagedLocalResourceLease.acquire(root: store)
            defer { withExtendedLifetime(lease) {} }
            XCTAssertThrowsError(try ManagedLocalResourceLease.acquire(root: alias.appendingPathComponent("store"))) {
                guard case ManagedLocalResourceLease.Failure.busy = $0 else { return XCTFail("Expected shared lock") }
            }
            throw Expected.stop
        } catch Expected.stop {}
        let available = try ManagedLocalResourceLease.acquire(root: store)
        withExtendedLifetime(available) {}
    }

    func testLiveChildOwnerBlocksParentUntilActualExit() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let process = Process()
        let ready = Pipe()
        let release = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
        import os,fcntl,signal,sys
        signal.alarm(5)
        fd=os.open(sys.argv[1],os.O_CREAT|os.O_RDWR,0o600)
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        os.write(1,b'R')
        os.read(0,1)
        """, root.appendingPathComponent(ManagedLocalResourceLease.filename).path]
        process.standardOutput = ready
        process.standardInput = release
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        XCTAssertEqual(ready.fileHandleForReading.readData(ofLength: 1), Data("R".utf8))
        XCTAssertThrowsError(try ManagedLocalResourceLease.acquire(root: root)) {
            guard case ManagedLocalResourceLease.Failure.busy = $0 else { return XCTFail("Expected busy") }
        }
        try release.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let available = try ManagedLocalResourceLease.acquire(root: root)
        withExtendedLifetime(available) {}
    }

    func testOwnedDescriptorIsCloseOnExecAndClosedOnRelease() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        var lease: ManagedLocalResourceLease? = try .acquire(root: root)
        var named = stat()
        XCTAssertEqual(lstat(root.appendingPathComponent(ManagedLocalResourceLease.filename).path, &named), 0)
        func descriptors() -> [Int32] {
            (0..<getdtablesize()).filter { fd in
                var info = stat()
                return fstat(fd, &info) == 0 && info.st_dev == named.st_dev && info.st_ino == named.st_ino
            }
        }
        withExtendedLifetime(lease) {
            let owned = descriptors()
            XCTAssertEqual(owned.count, 1)
            for fd in owned { XCTAssertNotEqual(fcntl(fd, F_GETFD) & FD_CLOEXEC, 0) }
        }
        lease = nil
        XCTAssertTrue(descriptors().isEmpty)
    }

    func testKilledOwnerReleasesKernelLockWithoutDeletingFile() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
        import os,fcntl,signal,sys
        fd=os.open(sys.argv[1],os.O_CREAT|os.O_RDWR,0o600)
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        os.kill(os.getpid(),signal.SIGKILL)
        """, root.appendingPathComponent(ManagedLocalResourceLease.filename).path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
        let lease = try ManagedLocalResourceLease.acquire(root: root)
        withExtendedLifetime(lease) {}
    }

    func testOtherProcessContendsThenCanAcquireAfterRelease() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = """
        import os,fcntl,sys
        fd=os.open(sys.argv[1],os.O_RDWR)
        try: fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError: sys.exit(73)
        sys.exit(0)
        """
        func child() throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c", script, root.appendingPathComponent(ManagedLocalResourceLease.filename).path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            return process.terminationStatus
        }
        var owner: ManagedLocalResourceLease? = try .acquire(root: root)
        try withExtendedLifetime(owner) { XCTAssertEqual(try child(), 73) }
        owner = nil
        XCTAssertEqual(try child(), 0)
    }
}
