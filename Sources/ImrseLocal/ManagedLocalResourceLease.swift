import Darwin
import Foundation

/// Cooperative process admission, not authentication against malicious same-user code.
/// All production clients use the same model-store root. Never unlink this lock:
/// replacing its inode would allow two owners to hold different locks simultaneously.
final class ManagedLocalResourceLease: Sendable {
    enum Failure: Error { case busy, unavailable }
    static let filename = ".resource-admission.lock"
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { Darwin.close(descriptor) }

    static func acquire(root: URL) throws -> ManagedLocalResourceLease {
        let directory = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(directory) }
        var directoryInfo = stat()
        guard fstat(directory, &directoryInfo) == 0,
              directoryInfo.st_uid == geteuid(),
              directoryInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              directoryInfo.st_mode & 0o022 == 0
        else { throw Failure.unavailable }

        let fd = openat(directory, filename, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw Failure.unavailable }
        var transferred = false
        defer { if !transferred { Darwin.close(fd) } }
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_mode & 0o077 == 0
        else { throw Failure.unavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN { throw Failure.busy }
            throw Failure.unavailable
        }
        var named = stat()
        guard fstatat(directory, filename, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == info.st_dev, named.st_ino == info.st_ino,
              named.st_nlink == 1
        else { throw Failure.unavailable }
        transferred = true
        return ManagedLocalResourceLease(descriptor: fd)
    }
}
