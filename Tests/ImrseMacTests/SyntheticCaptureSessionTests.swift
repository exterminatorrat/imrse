#if os(macOS) && DEBUG
import ApplicationServices
import Foundation
import ImrseCore
import XCTest
@_spi(SyntheticCaptureDiagnostics) @testable import ImrseMac

@MainActor
final class SyntheticCaptureSessionTests: XCTestCase {
    private let processIdentifier: Int32 = 41
    private let launchDate = Date(timeIntervalSince1970: 1_700_000_000)
    private let bundleIdentifier = "org.example.synthetic-editor"
    private let documentURL = URL(fileURLWithPath: "/synthetic/approved.txt")

    func testProcessIncarnationRequiresPositivePIDAndExactLaunchDateAndBundle() {
        XCTAssertTrue(SyntheticCaptureMetadataValidation.processMatches(
            expectedProcessIdentifier: processIdentifier,
            expectedLaunchDate: launchDate,
            expectedBundleIdentifier: bundleIdentifier,
            actualProcessIdentifier: processIdentifier,
            actualLaunchDate: launchDate,
            actualBundleIdentifier: bundleIdentifier
        ))
        XCTAssertFalse(SyntheticCaptureMetadataValidation.processMatches(
            expectedProcessIdentifier: processIdentifier,
            expectedLaunchDate: launchDate,
            expectedBundleIdentifier: bundleIdentifier,
            actualProcessIdentifier: processIdentifier + 1,
            actualLaunchDate: launchDate,
            actualBundleIdentifier: bundleIdentifier
        ))
        XCTAssertFalse(SyntheticCaptureMetadataValidation.processMatches(
            expectedProcessIdentifier: processIdentifier,
            expectedLaunchDate: launchDate,
            expectedBundleIdentifier: bundleIdentifier,
            actualProcessIdentifier: processIdentifier,
            actualLaunchDate: nil,
            actualBundleIdentifier: bundleIdentifier
        ))
        XCTAssertFalse(SyntheticCaptureMetadataValidation.processMatches(
            expectedProcessIdentifier: processIdentifier,
            expectedLaunchDate: launchDate,
            expectedBundleIdentifier: bundleIdentifier,
            actualProcessIdentifier: processIdentifier,
            actualLaunchDate: launchDate.addingTimeInterval(1),
            actualBundleIdentifier: bundleIdentifier
        ))
        XCTAssertFalse(SyntheticCaptureMetadataValidation.processMatches(
            expectedProcessIdentifier: processIdentifier,
            expectedLaunchDate: launchDate,
            expectedBundleIdentifier: bundleIdentifier,
            actualProcessIdentifier: processIdentifier,
            actualLaunchDate: launchDate,
            actualBundleIdentifier: nil
        ))
        XCTAssertFalse(SyntheticCaptureMetadataValidation.processMatches(
            expectedProcessIdentifier: 0,
            expectedLaunchDate: launchDate,
            expectedBundleIdentifier: bundleIdentifier,
            actualProcessIdentifier: 0,
            actualLaunchDate: launchDate,
            actualBundleIdentifier: bundleIdentifier
        ))
        let invalidLaunchDate = Date(timeIntervalSince1970: 0)
        XCTAssertFalse(SyntheticCaptureMetadataValidation.processMatches(
            expectedProcessIdentifier: processIdentifier,
            expectedLaunchDate: invalidLaunchDate,
            expectedBundleIdentifier: bundleIdentifier,
            actualProcessIdentifier: processIdentifier,
            actualLaunchDate: invalidLaunchDate,
            actualBundleIdentifier: bundleIdentifier
        ))
    }

    func testInvalidProcessIncarnationFailsBeforeRetainingNativeIdentity() {
        let session = makeSession(processLaunchDate: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(session.state, .failed)
        XCTAssertFalse(session.retainsNativeIdentity)
    }

    func testWrongProcessStopsBeforeRootFieldAndContentReads() throws {
        let counts = try attempt(actualProcessIdentifier: processIdentifier + 1)

        XCTAssertEqual(counts.rootReads, 0)
        XCTAssertEqual(counts.fieldReads, 0)
        XCTAssertEqual(counts.contentReads, 0)
    }

    func testMatchingRootAndFieldReachContentReadsAfterMetadataValidation() throws {
        let counts = try attempt()

        XCTAssertEqual(counts.rootReads, 5)
        XCTAssertEqual(counts.documentURLReads, 1)
        XCTAssertEqual(counts.fieldReads, 4)
        XCTAssertEqual(counts.contentReads, 1)
    }

    func testSameURLOnDifferentFocusedRootStopsBeforeDocumentAndFieldReads() throws {
        let counts = try attempt(root: RootMetadata(
            documentURL: documentURL,
            focusedRoot: 99,
            parent: 1,
            applicationProcessIdentifier: processIdentifier,
            rootProcessIdentifier: processIdentifier
        ))

        XCTAssertEqual(counts.rootReads, 1)
        XCTAssertEqual(counts.documentURLReads, 0)
        XCTAssertEqual(counts.fieldReads, 0)
        XCTAssertEqual(counts.contentReads, 0)
    }

    func testWrongURLOrParentStopsBeforeFieldAndContentReads() throws {
        let wrongURL = try attempt(root: RootMetadata(
            documentURL: URL(fileURLWithPath: "/synthetic/other.txt"),
            parent: 1,
            applicationProcessIdentifier: processIdentifier,
            rootProcessIdentifier: processIdentifier
        ))
        let wrongParent = try attempt(root: RootMetadata(
            documentURL: documentURL,
            parent: 9,
            applicationProcessIdentifier: processIdentifier,
            rootProcessIdentifier: processIdentifier
        ))
        let wrongRole = try attempt(root: RootMetadata(
            documentURL: documentURL,
            parent: 1,
            applicationProcessIdentifier: processIdentifier,
            rootProcessIdentifier: processIdentifier,
            role: "AXTextField"
        ))

        XCTAssertEqual(wrongURL.documentURLReads, 1)
        XCTAssertEqual(wrongURL.fieldReads, 0)
        XCTAssertEqual(wrongURL.contentReads, 0)
        for counts in [wrongParent, wrongRole] {
            XCTAssertEqual(counts.documentURLReads, 0)
            XCTAssertEqual(counts.fieldReads, 0)
            XCTAssertEqual(counts.contentReads, 0)
        }
    }

    func testMissingRootMetadataFailsClosedBeforeContentReads() throws {
        let missingURL = try attempt(root: RootMetadata(
            documentURL: nil,
            parent: 1,
            applicationProcessIdentifier: processIdentifier,
            rootProcessIdentifier: processIdentifier
        ))
        let missingOwnership = try attempt(root: RootMetadata(
            documentURL: documentURL,
            parent: nil,
            applicationProcessIdentifier: nil,
            rootProcessIdentifier: nil
        ))

        XCTAssertEqual(missingURL.documentURLReads, 1)
        XCTAssertEqual(missingURL.fieldReads, 0)
        XCTAssertEqual(missingURL.contentReads, 0)
        for counts in [missingOwnership] {
            XCTAssertEqual(counts.documentURLReads, 0)
            XCTAssertEqual(counts.fieldReads, 0)
            XCTAssertEqual(counts.contentReads, 0)
        }
    }

    func testWrongFieldOrWindowStopsBeforeContentReads() throws {
        let wrongField = try attempt(field: FieldMetadata(
            acquiredField: 4,
            focusedField: 4,
            window: 2,
            fieldProcessIdentifier: processIdentifier,
            windowProcessIdentifier: processIdentifier
        ))
        let wrongFocus = try attempt(field: FieldMetadata(
            acquiredField: 3,
            focusedField: 4,
            window: 2,
            fieldProcessIdentifier: processIdentifier,
            windowProcessIdentifier: processIdentifier
        ))
        let wrongFieldProcess = try attempt(field: FieldMetadata(
            acquiredField: 3,
            focusedField: 3,
            window: 2,
            fieldProcessIdentifier: processIdentifier + 1,
            windowProcessIdentifier: processIdentifier
        ))
        let wrongWindow = try attempt(field: FieldMetadata(
            acquiredField: 3,
            focusedField: 3,
            window: 7,
            fieldProcessIdentifier: processIdentifier,
            windowProcessIdentifier: processIdentifier
        ))
        let wrongWindowProcess = try attempt(field: FieldMetadata(
            acquiredField: 3,
            focusedField: 3,
            window: 2,
            fieldProcessIdentifier: processIdentifier,
            windowProcessIdentifier: processIdentifier + 1
        ))

        XCTAssertEqual(wrongField.rootReads, 5)
        XCTAssertEqual(wrongField.fieldReads, 0)
        XCTAssertEqual(wrongField.contentReads, 0)
        XCTAssertEqual(wrongFocus.fieldReads, 2)
        XCTAssertEqual(wrongFocus.contentReads, 0)
        XCTAssertEqual(wrongFieldProcess.fieldReads, 1)
        XCTAssertEqual(wrongFieldProcess.contentReads, 0)
        XCTAssertEqual(wrongWindow.rootReads, 5)
        XCTAssertEqual(wrongWindow.fieldReads, 4)
        XCTAssertEqual(wrongWindow.contentReads, 0)
        XCTAssertEqual(wrongWindowProcess.fieldReads, 4)
        XCTAssertEqual(wrongWindowProcess.contentReads, 0)
    }

    func testMissingFieldMetadataFailsClosedBeforeContentReads() throws {
        let counts = try attempt(field: FieldMetadata(
            acquiredField: 3,
            focusedField: nil,
            window: nil,
            fieldProcessIdentifier: processIdentifier,
            windowProcessIdentifier: nil
        ))

        XCTAssertEqual(counts.fieldReads, 2)
        XCTAssertEqual(counts.contentReads, 0)
    }

    func testWrongIntentAndConsumedAttemptCannotBeRearmed() throws {
        let wrongIntent = makeSession()

        XCTAssertThrowsError(try wrongIntent.beginCapture(intent: .replaceSelection))
        XCTAssertEqual(wrongIntent.state, .failed)
        XCTAssertFalse(wrongIntent.retainsNativeIdentity)
        XCTAssertThrowsError(try wrongIntent.beginCapture(intent: .insertAtCaret))

        let consumed = makeSession()
        _ = try consumed.beginCapture(intent: .insertAtCaret)
        XCTAssertTrue(consumed.finishCapture(succeeded: true))
        XCTAssertEqual(consumed.state, .consumed)
        XCTAssertFalse(consumed.retainsNativeIdentity)
        XCTAssertThrowsError(try consumed.beginCapture(intent: .insertAtCaret))
    }

    func testExpiredSessionFailsClosedAndDropsNativeIdentity() {
        var now = ContinuousClock().now
        let session = makeSession(lifetime: .seconds(1), now: { now })
        now = now.advanced(by: .seconds(1))

        XCTAssertThrowsError(try session.beginCapture(intent: .insertAtCaret))
        XCTAssertEqual(session.state, .failed)
        XCTAssertFalse(session.retainsNativeIdentity)
    }

    func testFailureAndCancellationDenyLateCaptureAndReleaseIdentity() throws {
        let failed = makeSession()
        _ = try failed.beginCapture(intent: .insertAtCaret)
        XCTAssertFalse(failed.finishCapture(succeeded: false))
        XCTAssertEqual(failed.state, .failed)
        XCTAssertFalse(failed.retainsNativeIdentity)
        XCTAssertThrowsError(try failed.beginCapture(intent: .insertAtCaret))

        let cancelled = makeSession()
        cancelled.cancel()
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertFalse(cancelled.retainsNativeIdentity)
        XCTAssertThrowsError(try cancelled.beginCapture(intent: .insertAtCaret))
    }

    func testRealCaptureWrongIntentIsRefusedBeforeNativeAccess() {
        let session = makeSession()
        let access = MacSelectionAccess(syntheticCaptureSession: session)

        XCTAssertThrowsError(try access.capture(intent: .replaceSelection))
        XCTAssertEqual(access.syntheticCaptureSessionState, .failed)
        XCTAssertFalse(session.retainsNativeIdentity)
    }

    func testConsumedAndCancelledAccessRejectEveryLaterCaptureIntent() throws {
        let consumedSession = makeSession()
        let consumedAccess = MacSelectionAccess(syntheticCaptureSession: consumedSession)
        _ = try consumedSession.beginCapture(intent: .insertAtCaret)
        XCTAssertTrue(consumedSession.finishCapture(succeeded: true))

        XCTAssertThrowsError(try consumedAccess.capture(intent: .replaceSelection))
        XCTAssertEqual(consumedAccess.syntheticCaptureSessionState, .consumed)

        let cancelledSession = makeSession()
        let cancelledAccess = MacSelectionAccess(syntheticCaptureSession: cancelledSession)
        cancelledSession.cancel()

        XCTAssertThrowsError(try cancelledAccess.capture(intent: .insertAtCaret))
        XCTAssertEqual(cancelledAccess.syntheticCaptureSessionState, .cancelled)
    }

    func testOrdinaryInitializerHasNoSyntheticConstraint() {
        let access = MacSelectionAccess()

        XCTAssertFalse(access.hasSyntheticCaptureSession)
        XCTAssertNil(access.syntheticCaptureSessionState)
    }

    func testRealCaptureWiresAdmissionBeforeNativeAndContentReads() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ImrseMac/MacSelectionAccess.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "    public func capture(intent:"))
        let end = try XCTUnwrap(source.range(
            of: "\n    public func validate(",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])
        func position(_ marker: String, last: Bool = false) throws -> String.Index {
            try XCTUnwrap(body.range(of: marker, options: last ? .backwards : [])).lowerBound
        }

        XCTAssertLessThan(
            try position("syntheticSession.beginCapture(intent: intent)"),
            try position("clearCapture()")
        )
        XCTAssertLessThan(
            try position("SyntheticCaptureMetadataValidation.processMatches("),
            try position("AXUIElementCreateApplication(processID)")
        )
        XCTAssertLessThan(
            try position("try syntheticDocumentRootIsValid("),
            try position("AccessibilityFocusAcquisition.acquire(")
        )
        XCTAssertLessThan(
            try position("try self.syntheticFocusedFieldIsValid("),
            try position("self.isSecure(element, in: application)")
        )
        for marker in ["try syntheticDocumentRootIsValid(", "try syntheticFocusedFieldIsValid("] {
            XCTAssertGreaterThan(try position(marker, last: true), try position("let canReadValue ="))
            XCTAssertLessThan(try position(marker, last: true), try position("let selectedRange ="))
        }

        let rootStart = try XCTUnwrap(source.range(of: "    private func syntheticDocumentRootIsValid("))
        let fieldStart = try XCTUnwrap(source.range(of: "    private func syntheticFocusedFieldIsValid("))
        XCTAssertFalse(source[rootStart.lowerBound..<fieldStart.lowerBound].contains("kAXWindowsAttribute"))
    }

    private func attempt(
        actualProcessIdentifier: Int32? = nil,
        root: RootMetadata? = RootMetadata(
            documentURL: URL(fileURLWithPath: "/synthetic/approved.txt"),
            parent: 1,
            applicationProcessIdentifier: 41,
            rootProcessIdentifier: 41
        ),
        field: FieldMetadata? = FieldMetadata(
            acquiredField: 3,
            focusedField: 3,
            window: 2,
            fieldProcessIdentifier: 41,
            windowProcessIdentifier: 41
        )
    ) throws -> ReadCounts {
        var counts = ReadCounts()
        guard SyntheticCaptureMetadataValidation.processMatches(
            expectedProcessIdentifier: processIdentifier,
            expectedLaunchDate: launchDate,
            expectedBundleIdentifier: bundleIdentifier,
            actualProcessIdentifier: actualProcessIdentifier ?? processIdentifier,
            actualLaunchDate: launchDate,
            actualBundleIdentifier: bundleIdentifier
        ) else { return counts }

        guard let root,
              try SyntheticCaptureMetadataValidation.documentRootIsValid(
                expectedRoot: 2,
                expectedDocumentURL: documentURL,
                application: 1,
                expectedProcessIdentifier: processIdentifier,
                readFocusedRoot: { counts.rootReads += 1; return root.focusedRoot },
                readRootParent: { counts.rootReads += 1; return root.parent },
                readRootRole: { counts.rootReads += 1; return root.role },
                readApplicationProcessIdentifier: {
                    counts.rootReads += 1
                    return root.applicationProcessIdentifier
                },
                readRootProcessIdentifier: {
                    counts.rootReads += 1
                    return root.rootProcessIdentifier
                },
                readDocumentURL: {
                    counts.documentURLReads += 1
                    return root.documentURL
                },
                sameElement: { $0 == $1 }
              ),
              let field,
              try SyntheticCaptureMetadataValidation.focusedFieldIsValid(
                expectedField: 3,
                acquiredField: field.acquiredField,
                expectedRoot: 2,
                expectedProcessIdentifier: processIdentifier,
                readFieldProcessIdentifier: {
                    counts.fieldReads += 1
                    return field.fieldProcessIdentifier
                },
                readCurrentFocusedField: {
                    counts.fieldReads += 1
                    return field.focusedField
                },
                readFieldWindow: {
                    counts.fieldReads += 1
                    return field.window
                },
                readWindowProcessIdentifier: { _ in
                    counts.fieldReads += 1
                    return field.windowProcessIdentifier
                },
                sameElement: { $0 == $1 }
              )
        else { return counts }

        counts.contentReads += 1
        return counts
    }

    private func makeSession(
        processLaunchDate: Date? = nil,
        lifetime: Duration = .seconds(10),
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock().now }
    ) -> SyntheticCaptureSession {
        let anchor = AXUIElementCreateSystemWide()
        let identity = SyntheticCaptureIdentity(
            processIdentifier: processIdentifier,
            processLaunchDate: processLaunchDate ?? launchDate,
            bundleIdentifier: bundleIdentifier,
            documentURL: documentURL,
            documentRoot: anchor,
            focusedField: anchor
        )
        return SyntheticCaptureSession(identity: identity, lifetime: lifetime, now: now)
    }

    private struct RootMetadata {
        let documentURL: URL?
        var focusedRoot: Int? = 2
        let parent: Int?
        let applicationProcessIdentifier: Int32?
        let rootProcessIdentifier: Int32?
        var role: String? = "AXWindow"
    }

    private struct FieldMetadata {
        let acquiredField: Int
        let focusedField: Int?
        let window: Int?
        let fieldProcessIdentifier: Int32?
        let windowProcessIdentifier: Int32?
    }

    private struct ReadCounts {
        var rootReads = 0
        var documentURLReads = 0
        var fieldReads = 0
        var contentReads = 0
    }
}
#endif
