#if os(macOS)
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import ImrseCore

enum SelectionTargetContextValidation {
    enum Document: Equatable {
        case unavailable
        case value([UInt16])
        case malformed
    }

    enum DocumentRead: Equatable {
        case context(Document)
        case failed(SelectionFailureReason)
    }

    static let maximumDocumentUTF16Length = 4_096

    static func documentRead(status: AXError, value: CFTypeRef?) -> DocumentRead {
        if status == .noValue {
            return value == nil ? .context(.unavailable) : .failed(.documentContextUnavailable)
        }
        guard status == .success else {
            return .failed(status == .attributeUnsupported ? .documentContextUnavailable : .axReadFailure)
        }
        guard let value, let document = value as? String else {
            return .failed(.documentContextUnavailable)
        }
        let context = self.document(document)
        guard context != .malformed else { return .failed(.documentContextUnavailable) }
        return .context(context)
    }

    static func document(_ value: String) -> Document {
        var utf16: [UInt16] = []
        for unit in value.utf16 {
            guard utf16.count < maximumDocumentUTF16Length else { return .malformed }
            utf16.append(unit)
        }
        guard !utf16.isEmpty else { return .malformed }
        return .value(utf16)
    }

    static func failureReason<Window>(
        capturedWindow: Window,
        capturedDocument: Document,
        currentWindow: Window?,
        intent: SelectionEditIntent,
        sameWindow: (Window, Window) -> Bool,
        isValidWindow: (Window) throws -> Bool,
        readDocument: (Window) throws -> Document
    ) throws -> SelectionFailureReason? {
        guard let currentWindow else {
            return intent == .insertAtCaret ? .caretProofUnavailable : .windowContextUnavailable
        }
        guard sameWindow(capturedWindow, currentWindow), try isValidWindow(currentWindow) else {
            return intent == .insertAtCaret ? .caretProofUnavailable : .windowContextChanged
        }
        let currentDocument = try readDocument(currentWindow)
        switch (capturedDocument, currentDocument) {
        case (.malformed, _), (_, .malformed):
            return .documentContextUnavailable
        case (.unavailable, .unavailable):
            return nil
        case let (.value(captured), .value(current)) where captured.elementsEqual(current):
            return nil
        default:
            return .documentContextChanged
        }
    }
}

@MainActor
public final class MacSelectionAccess: SelectionAccess {
    private typealias TextRange = ImrseCore.TextRange

    private static let axMessagingTimeout: Float = 0.1
    private static let captureBudget = Duration.seconds(1)
    private static let focusRetryDelayMilliseconds: Int64 = 10
    private static let captureSetupAXCallReserve: Int64 = 8
    private static let manualAccessibilityAttribute = "AXManualAccessibility"
    private static let protectedContentAttribute = "AXProtectedContent"
    private static let editableAncestorAttribute = "AXEditableAncestor"
    private static let highestEditableAncestorAttribute = "AXHighestEditableAncestor"
    private static let markedTextRangeAttribute = "AXTextInputMarkedTextMarkerRange"

    private struct TargetHandle {
        let id: UUID
        let applicationID: String
        let processID: Int32
        let role: String
        let intent: SelectionEditIntent
        let window: AXUIElement
        let document: SelectionTargetContextValidation.Document
        let application: AXUIElement
        let anchor: AXUIElement
        let anchorRole: String
        let element: AXUIElement
    }

    private struct EditableHostBinding {
        let element: AXUIElement
        let role: String
        let selection: NativeSelection
    }

    private struct SelectionEvidence<Value> {
        let availability: CaptureSelectionFallback.Availability
        let value: Value?
        let reason: SelectionFailureReason?
    }

    private struct CapturedTarget {
        let snapshot: SelectionSnapshot
        let handle: TargetHandle
        let insertionProof: CaretInsertionProof?
    }

    private struct NativeSelection {
        let text: String
        let range: TextRange
    }

    private struct UndoTarget {
        let receipt: ReplacementReceipt
        let handle: TargetHandle
        let replacementRange: TextRange
        let focusedSelection: NativeSelection
        let styleProof: ContenteditableClipboardProof?
        let insertionProof: CaretInsertionProof?
    }

    private final class ObserverContext: @unchecked Sendable {
        weak var owner: MacSelectionAccess?
        let targetID: UUID

        init(owner: MacSelectionAccess, targetID: UUID) {
            self.owner = owner
            self.targetID = targetID
        }
    }

    private struct ObserverRegistration {
        let observer: AXObserver
        let source: CFRunLoopSource
        let context: ObserverContext
        let notifications: [(AXUIElement, CFString)]
    }

    private struct AppliedReplacement {
        let strategy: ReplacementStrategy
        let focusedSelection: NativeSelection
        let styleProof: ContenteditableClipboardProof?
    }

    private struct ClipboardDestination {
        let target: TargetHandle
        let application: NSRunningApplication
        let identity: ClipboardDestinationIdentity
        let expectedValue: String
        let replacement: String
        let replacementRange: TextRange
    }

    public var clipboardFallbackEnabled: Bool
    public private(set) var capturedScreen: NSScreen?
    public private(set) var lastFailureReason: SelectionFailureReason?
    private let prepareForClipboardPaste: ClipboardPastePreparation?
    private let clock = ContinuousClock()
    private var capturedTarget: CapturedTarget?
    private var observerRegistration: ObserverRegistration?
    private var workspaceObserver: NSObjectProtocol?
    private var captureDeadline: ContinuousClock.Instant?
    private var undoTarget: UndoTarget?
    private let clipboardRecovery = ClipboardPasteRecovery<ClipboardPasteboardTransaction, ClipboardDestination>()

    public static var accessibilityPermissionGranted: Bool {
        AXIsProcessTrusted()
    }

    public static var eventPostingPermissionGranted: Bool {
        CGPreflightPostEventAccess()
    }

    public init(
        clipboardFallbackEnabled: Bool = false,
        prepareForClipboardPaste: ClipboardPastePreparation? = nil
    ) {
        self.clipboardFallbackEnabled = clipboardFallbackEnabled
        self.prepareForClipboardPaste = prepareForClipboardPaste
    }

    public func capture() throws -> SelectionSnapshot {
        try capture(intent: .replaceSelection)
    }

    public func capture(intent: SelectionEditIntent) throws -> SelectionSnapshot {
        clearCapture()
        lastFailureReason = nil
        captureDeadline = clock.now.advanced(by: Self.captureBudget)
        defer { captureDeadline = nil }
        guard Self.accessibilityPermissionGranted else { throw ImrseError.permissionRequired }
        guard !IsSecureEventInputEnabled() else { throw failure(.protectedTarget, .secureInput) }
        guard let runningApplication = NSWorkspace.shared.frontmostApplication else {
            throw failure(.frontmostApplicationUnavailable, .noSelection)
        }

        let processID = runningApplication.processIdentifier
        guard processID != ProcessInfo.processInfo.processIdentifier else {
            throw failure(.ownApplicationFocused, .noSelection)
        }
        let application = AXUIElementCreateApplication(processID)
        try configureAXMessaging(application)
        guard let element = try AccessibilityFocusAcquisition.acquire(
            readApplicationRole: {
                _ = try self.stringAttribute(application, kAXRoleAttribute, failure: .noSelection)
            },
            requestManualAccessibility: { try self.requestManualAccessibility(on: application) },
            hasTimeForRetry: { self.hasCaptureTimeForFocusRetry() },
            readFocusedElement: {
                try self.elementAttribute(application, kAXFocusedUIElementAttribute, failure: .noSelection)
            },
            validate: { element in
                guard try !self.isSecure(element, in: application) else {
                    throw self.failure(.protectedTarget, .secureInput)
                }
            },
            waitBeforeRetry: {
                Thread.sleep(forTimeInterval: Double(Self.focusRetryDelayMilliseconds) / 1_000.0)
            }
        ) else {
            throw failure(.focusedElementUnavailable, .noSelection)
        }
        guard let role = try stringAttribute(element, kAXRoleAttribute, failure: .noSelection) else {
            throw failure(.roleUnavailable, .noSelection)
        }
        let canReadValue = supportsPlainTextValueReplacement(element, role: role)
        let inserting = intent == .insertAtCaret
        let selection: NativeSelection
        let hostBinding: EditableHostBinding?
        let insertionProof: CaretInsertionProof?
        if inserting {
            let selectedRange = try rangeAttribute(element, kAXSelectedTextRangeAttribute, failure: .insertionUnavailable)
            if let reason = SelectionReadValidation.rangeFailure(selectedRange, allowingEmpty: true) {
                throw failure(reason, .insertionUnavailable)
            }
            guard let range = selectedRange else { throw failure(.selectedRangeUnavailable, .insertionUnavailable) }
            let selected = try stringAttribute(element, kAXSelectedTextAttribute, failure: .insertionUnavailable)
            if let reason = SelectionReadValidation.textFailure(selected, range: range, allowingEmpty: true) {
                throw failure(reason, .insertionUnavailable)
            }
            guard let text = selected else { throw failure(.selectedTextUnavailable, .insertionUnavailable) }
            guard canReadValue, range.length == 0, text.isEmpty else {
                throw failure(.caretProofUnavailable, .insertionUnavailable)
            }
            let composition = try caretCompositionState(element)
            guard composition == .unmarked else {
                throw failure(
                    composition == .marked ? .markedTextActive : .compositionStateUnavailable,
                    .insertionUnavailable
                )
            }
            guard let proof = CaretInsertionProof(
                value: try wholeValue(element, failure: .insertionUnavailable),
                range: range,
                selectedText: selected,
                permitsPlainTextValueWrite: canReadValue,
                composition: composition
            ) else { throw failure(.caretProofUnavailable, .insertionUnavailable) }
            insertionProof = proof
            hostBinding = nil
            selection = NativeSelection(text: text, range: range)
        } else {
            let rangeProbe = rangeAvailability(element, allowingEmpty: false)
            if let reason = rangeProbe.reason {
                throw failure(reason, .noSelection)
            }
            let textProbe: SelectionEvidence<String>
            if let range = rangeProbe.value {
                textProbe = textAvailability(element, range: range, allowingEmpty: false, canReadValue: canReadValue)
            } else {
                textProbe = unrangedTextAvailability(element)
            }
            if let reason = textProbe.reason {
                throw failure(reason, .noSelection)
            }
            switch CaptureSelectionFallback.route(
                range: rangeProbe.availability,
                text: textProbe.availability
            ) {
            case .refuse:
                throw ImrseError.noSelection
            case .captured:
                guard let range = rangeProbe.value, let text = textProbe.value else {
                    throw ImrseError.noSelection
                }
                insertionProof = nil
                hostBinding = nil
                selection = NativeSelection(text: text, range: range)
            case .resolveHost:
                guard let binding = fallbackEditableHostBinding(
                    anchor: element,
                    processID: processID,
                    intent: intent,
                    anchorRange: rangeProbe.value,
                    anchorText: textProbe.value
                ) else {
                    throw failure(
                        rangeProbe.value == nil ? .selectedRangeUnavailable : .selectedTextUnavailable,
                        .noSelection
                    )
                }
                insertionProof = nil
                hostBinding = binding
                selection = binding.selection
            }
        }
        let windowContext = try captureWindowContext(for: element, processID: processID, intent: intent)
        let targetRole = hostBinding?.role ?? role
        let targetElement = hostBinding?.element ?? element

        let applicationID = runningApplication.bundleIdentifier ?? "pid:\(processID)"
        let snapshot = SelectionSnapshot(
            applicationID: applicationID,
            processID: processID,
            role: targetRole,
            text: selection.text,
            range: selection.range,
            isSecure: false,
            intent: intent
        )
        let handle = TargetHandle(
            id: snapshot.id,
            applicationID: applicationID,
            processID: processID,
            role: targetRole,
            intent: intent,
            window: windowContext.window,
            document: windowContext.document,
            application: application,
            anchor: element,
            anchorRole: role,
            element: targetElement
        )
        try requireTargetForeground(handle)
        capturedTarget = CapturedTarget(snapshot: snapshot, handle: handle, insertionProof: insertionProof)
        observerRegistration = makeObserver(for: handle)
        installWorkspaceObserver(for: handle)
        do {
            try requireTargetForeground(handle)
            guard sameSelection(try currentSelection(handle), selection) else {
                throw failure(.captureChangedDuringSetup, .noSelection)
            }
            try validateInsertionProof(insertionProof, on: handle)
            capturedScreen = sourceScreen(for: element)
        } catch {
            invalidateCapture(snapshot.id)
            throw error
        }
        lastFailureReason = nil
        return snapshot
    }

    public func validate(_ target: SelectionSnapshot) throws {
        guard let captured = capturedTarget, captured.snapshot.id == target.id else {
            throw failure(lastFailureReason ?? .captureInvalidated, .targetLost)
        }
        lastFailureReason = nil
        guard sameSnapshot(target, captured.snapshot) else {
            lastFailureReason = .snapshotMismatch
            invalidateCapture(target.id)
            throw ImrseError.staleSelection
        }

        do {
            try requireSafeForeground(captured.handle)
            let selection = try currentSelection(captured.handle)
            guard selection.range == target.range else {
                throw failure(.rangeChanged, .staleSelection)
            }
            guard sameText(selection.text, target.text) else {
                throw failure(.textChanged, .staleSelection)
            }
            try validateInsertionProof(captured.insertionProof, on: captured.handle)
            lastFailureReason = nil
        } catch {
            invalidateCapture(target.id)
            throw error
        }
    }

    public func replace(_ target: SelectionSnapshot, with text: String) async throws -> ReplacementReceipt {
        try recoverPendingClipboard()
        try validate(target)
        guard let captured = capturedTarget, captured.snapshot.id == target.id else {
            throw ImrseError.targetLost
        }
        guard let range = target.range else { throw ImrseError.staleSelection }
        let insertionValue: String?
        if let proof = captured.insertionProof {
            guard !text.isEmpty else { throw ImrseError.emptyOutput }
            guard let value = proof.inserting(text) else { throw ImrseError.outputTooLarge }
            insertionValue = value
        } else {
            insertionValue = nil
        }
        if sameText(target.text, text) {
            return ReplacementReceipt(target: target, replacement: text, strategy: .selectedText)
        }
        guard let replacementRange = validatedRange(at: range.location, length: text.utf16.count),
              isWithinSupportedRange(replacementRange) else {
            throw ImrseError.outputTooLarge
        }

        let before = try currentSelection(captured.handle)
        stopObservingCapturedTarget(target.id)
        let applied: AppliedReplacement
        do {
            applied = try await applyReplacement(
                to: captured.handle,
                replacing: target.text,
                at: range,
                with: text,
                focusedSelection: before,
                requiredOriginalValue: captured.insertionProof?.value
            )
            if let insertionValue {
                guard let value = try wholeValue(captured.handle.element, failure: .replacementFailed),
                      sameText(value, insertionValue),
                      sameSelection(try currentSelection(captured.handle, allowingEmpty: true), applied.focusedSelection)
                else {
                    invalidateAfterUnverifiedWrite(target.id)
                    throw ImrseError.replacementFailed
                }
            }
        } catch {
            invalidateCapture(target.id)
            throw error
        }

        let receipt = ReplacementReceipt(target: target, replacement: text, strategy: applied.strategy)
        clearCapture(for: target.id)
        undoTarget = UndoTarget(
            receipt: receipt,
            handle: captured.handle,
            replacementRange: replacementRange,
            focusedSelection: applied.focusedSelection,
            styleProof: applied.styleProof,
            insertionProof: captured.insertionProof
        )
        lastFailureReason = nil
        return receipt
    }

    public func undo(_ receipt: ReplacementReceipt) async throws {
        lastFailureReason = nil
        try recoverPendingClipboard()
        guard let undoTarget, sameReceipt(receipt, undoTarget.receipt) else {
            throw ImrseError.undoUnavailable
        }
        do {
            let current = try currentSelection(undoTarget.handle, allowingEmpty: true)
            guard sameSelection(current, undoTarget.focusedSelection) else {
                throw failure(current.range == undoTarget.focusedSelection.range ? .textChanged : .rangeChanged, .undoUnavailable)
            }
            if let proof = undoTarget.insertionProof {
                guard proof.confirmsApplied(
                    value: try wholeValue(undoTarget.handle.element, failure: .undoUnavailable),
                    inserting: receipt.replacement
                )
                else { throw ImrseError.undoUnavailable }
            }
            if let styleProof = undoTarget.styleProof {
                try await undoContenteditable(
                    undoTarget,
                    receipt: receipt,
                    currentSelection: current,
                    styleProof: styleProof
                )
            } else if supportsPlainTextValueReplacement(undoTarget.handle.element, role: undoTarget.handle.role) {
                try await undoPlainTextField(undoTarget, receipt: receipt, currentSelection: current)
            } else {
                let target = undoTarget.handle
                let replacementSelection: NativeSelection
                if current.range == undoTarget.replacementRange,
                   sameText(current.text, receipt.replacement) {
                    replacementSelection = current
                } else {
                    guard UTF16SelectionRange.isCollapsedCaret(
                        current.range,
                        selectedText: current.text,
                        atEndOf: undoTarget.replacementRange
                    ), let replacementText = try stringForRange(
                        target.element,
                        range: undoTarget.replacementRange,
                        failure: .undoUnavailable
                    ), sameText(replacementText, receipt.replacement),
                    (try? attributeIsSettable(target.element, kAXSelectedTextRangeAttribute)) == true
                    else {
                        throw ImrseError.undoUnavailable
                    }
                    let beforeSelection = try currentSelection(target, allowingEmpty: true)
                    guard sameSelection(beforeSelection, undoTarget.focusedSelection) else {
                        throw ImrseError.undoUnavailable
                    }
                    let selectedRange = try axRangeValue(undoTarget.replacementRange, failure: .undoUnavailable)
                    guard try setAttribute(target.element, kAXSelectedTextRangeAttribute, value: selectedRange) == .success else {
                        throw ImrseError.undoUnavailable
                    }
                    replacementSelection = try await selection(
                        afterSetting: undoTarget.replacementRange,
                        text: receipt.replacement,
                        on: target
                    )
                }
                _ = try await applyReplacement(
                    to: target,
                    replacing: receipt.replacement,
                    at: undoTarget.replacementRange,
                    with: receipt.target.text,
                    focusedSelection: replacementSelection
                )
            }
            self.undoTarget = nil
            lastFailureReason = nil
        } catch let error as ImrseError {
            if error == .staleSelection || error == .secureInput || error == .targetLost
                || error == .undoUnavailable || error == .insertionUnavailable {
                self.undoTarget = nil
                throw ImrseError.undoUnavailable
            }
            throw error
        } catch {
            self.undoTarget = nil
            throw ImrseError.undoUnavailable
        }
    }

    private func undoPlainTextField(
        _ undoTarget: UndoTarget,
        receipt: ReplacementReceipt,
        currentSelection: NativeSelection
    ) async throws {
        let target = undoTarget.handle
        guard let currentValue = try wholeValue(target.element, failure: .undoUnavailable) else {
            throw ImrseError.undoUnavailable
        }
        let currentProof = UndoSelectionProof(text: currentSelection.text, range: currentSelection.range)
        let receiptProof = UndoSelectionProof(
            text: undoTarget.focusedSelection.text,
            range: undoTarget.focusedSelection.range
        )
        let restored: String?
        if let proof = undoTarget.insertionProof {
            guard (try? attributeIsSettable(target.element, kAXSelectedTextRangeAttribute)) == true else {
                throw ImrseError.undoUnavailable
            }
            restored = PlainTextUndoValidation.insertionRestoredValue(
                currentValue: currentValue,
                proof: proof,
                receipt: receipt,
                currentSelection: currentProof,
                receiptSelection: receiptProof
            )
        } else {
            restored = PlainTextUndoValidation.restoredValue(
                currentValue: currentValue,
                receipt: receipt,
                replacementRange: undoTarget.replacementRange,
                currentSelection: currentProof,
                receiptSelection: receiptProof
            )
        }
        guard let restoredValue = restored else {
            throw ImrseError.undoUnavailable
        }

        let selectedReplacement = currentSelection.range == undoTarget.replacementRange
            && sameText(currentSelection.text, receipt.replacement)
        let canWriteSelectedText = (try? attributeIsSettable(target.element, kAXSelectedTextAttribute)) == true
        if selectedReplacement, canWriteSelectedText {
            let status = try VerifiedAction.perform(
                verify: {
                    let beforeWrite = try self.currentSelection(target, allowingEmpty: true)
                    guard self.sameSelection(beforeWrite, currentSelection),
                          let valueBeforeWrite = try self.wholeValue(target.element, failure: .undoUnavailable),
                          self.sameText(valueBeforeWrite, currentValue)
                    else {
                        throw ImrseError.undoUnavailable
                    }
                },
                action: {
                    try self.setAttribute(
                        target.element,
                        kAXSelectedTextAttribute,
                        value: receipt.target.text as CFString
                    )
                }
            )
            guard status == .success else {
                invalidateAfterUnverifiedWrite(target.id)
                throw ImrseError.undoUnavailable
            }
        } else {
            guard (try? attributeIsSettable(target.element, kAXValueAttribute)) == true else {
                throw ImrseError.undoUnavailable
            }
            let status = try VerifiedAction.perform(
                verify: {
                    let beforeWrite = try self.currentSelection(target, allowingEmpty: true)
                    guard self.sameSelection(beforeWrite, currentSelection),
                          let valueBeforeWrite = try self.wholeValue(target.element, failure: .undoUnavailable),
                          self.sameText(valueBeforeWrite, currentValue)
                    else {
                        throw ImrseError.undoUnavailable
                    }
                },
                action: {
                    try self.setAttribute(target.element, kAXValueAttribute, value: restoredValue as CFString)
                }
            )
            guard status == .success else {
                invalidateAfterUnverifiedWrite(target.id)
                throw ImrseError.undoUnavailable
            }
        }

        do {
            guard let valueAfterWrite = try wholeValue(target.element, failure: .undoUnavailable),
                  sameText(valueAfterWrite, restoredValue)
            else {
                throw ImrseError.undoUnavailable
            }
            let after = try self.currentSelection(target, allowingEmpty: true)
            if let proof = undoTarget.insertionProof {
                guard sameText(restoredValue, proof.value) else { throw ImrseError.undoUnavailable }
                if after.range != proof.range || !after.text.isEmpty {
                    guard try attributeIsSettable(target.element, kAXSelectedTextRangeAttribute) else {
                        throw ImrseError.undoUnavailable
                    }
                    let caret = try axRangeValue(proof.range, failure: .undoUnavailable)
                    let status = try VerifiedAction.perform(
                        verify: {
                            guard self.sameSelection(try self.currentSelection(target), after),
                                  let value = try self.wholeValue(target.element, failure: .undoUnavailable),
                                  self.sameText(value, proof.value)
                            else { throw ImrseError.undoUnavailable }
                        },
                        action: { try self.setAttribute(target.element, kAXSelectedTextRangeAttribute, value: caret) }
                    )
                    guard status == .success else { throw ImrseError.undoUnavailable }
                    _ = try await selection(afterSetting: proof.range, text: "", on: target)
                }
                try validateInsertionProof(proof, on: target)
            }
        } catch {
            invalidateAfterUnverifiedWrite(target.id)
            throw ImrseError.undoUnavailable
        }
    }

    private func undoContenteditable(
        _ undoTarget: UndoTarget,
        receipt: ReplacementReceipt,
        currentSelection: NativeSelection,
        styleProof: ContenteditableClipboardProof
    ) async throws {
        let target = undoTarget.handle
        guard let inverseProof = styleProof.inverse(
            selectionRange: undoTarget.replacementRange,
            selectedText: receipt.replacement,
            replacement: receipt.target.text
        ),
        try requireContenteditableStyleState(
            target,
            proof: styleProof,
            confirmsApplied: true
        ) else {
            throw ImrseError.undoUnavailable
        }
        guard let prepareForClipboardPaste else { throw ImrseError.clipboardFailed }
        try requireTargetForeground(target)
        let replacementSelection: NativeSelection
        if currentSelection.range == undoTarget.replacementRange,
           sameText(currentSelection.text, receipt.replacement) {
            replacementSelection = currentSelection
        } else {
            guard UTF16SelectionRange.isCollapsedCaret(
                currentSelection.range,
                selectedText: currentSelection.text,
                atEndOf: undoTarget.replacementRange
            ),
            let replacementText = try stringForRange(
                target.element,
                range: undoTarget.replacementRange,
                failure: .undoUnavailable
            ),
            sameText(replacementText, receipt.replacement),
            (try? attributeIsSettable(target.element, kAXSelectedTextRangeAttribute)) == true
            else {
                throw ImrseError.undoUnavailable
            }
            let beforeSelectionChange = try self.currentSelection(target, allowingEmpty: true)
            guard sameSelection(beforeSelectionChange, currentSelection) else {
                throw ImrseError.undoUnavailable
            }
            let selectedRange = try axRangeValue(undoTarget.replacementRange, failure: .undoUnavailable)
            guard try setAttribute(target.element, kAXSelectedTextRangeAttribute, value: selectedRange) == .success else {
                throw ImrseError.undoUnavailable
            }
            replacementSelection = try await selection(
                afterSetting: undoTarget.replacementRange,
                text: receipt.replacement,
                on: target
            )
        }
        let beforePreparation = try self.currentSelection(target, allowingEmpty: true)
        guard sameSelection(beforePreparation, replacementSelection) else { throw ImrseError.undoUnavailable }
        do {
            try await prepareForClipboardPaste()
        } catch {
            throw ImrseError.clipboardFailed
        }

        let beforePaste = try self.currentSelection(target, allowingEmpty: true)
        guard sameSelection(beforePaste, replacementSelection),
              try requireContenteditableStyleState(
                target,
                proof: inverseProof,
                confirmsApplied: false
              )
        else {
            throw ImrseError.undoUnavailable
        }

        let afterPaste = try await paste(
            receipt.target.text,
            to: target,
            replacing: receipt.replacement,
            at: undoTarget.replacementRange,
            expectedSelection: replacementSelection,
            oldValue: styleProof.expectedText,
            expectedValue: styleProof.originalText,
            styleProof: inverseProof
        )

        do {
            guard try requireContenteditableStyleState(target, proof: styleProof, confirmsApplied: false),
            try requireContenteditableStyleState(target, proof: inverseProof, confirmsApplied: true),
            sameSelection(try self.currentSelection(target, allowingEmpty: true), afterPaste)
            else {
                throw ImrseError.undoUnavailable
            }
        } catch {
            invalidateAfterUnverifiedWrite(target.id)
            throw ImrseError.undoUnavailable
        }
    }

    public func discard(_ target: SelectionSnapshot) {
        invalidateCapture(target.id, reason: .captureDiscarded)
        if undoTarget?.receipt.target.id == target.id { undoTarget = nil }
    }

    private static let observerCallback: AXObserverCallback = { _, _, notification, refcon in
        guard let refcon else { return }
        let context = Unmanaged<ObserverContext>.fromOpaque(refcon).takeUnretainedValue()
        let reason = ObservedCaptureNotification.failureReason(for: notification)
        MainActor.assumeIsolated {
            context.owner?.observedChange(for: context.targetID, reason: reason)
        }
    }

    private func makeObserver(for target: TargetHandle) -> ObserverRegistration? {
        var observer: AXObserver?
        guard AXObserverCreate(target.processID, Self.observerCallback, &observer) == .success,
              let observer else { return nil }
        let context = ObserverContext(owner: self, targetID: target.id)
        let refcon = Unmanaged.passUnretained(context).toOpaque()
        var notifiedElements = [target.anchor]
        if !sameElement(target.anchor, target.element) {
            notifiedElements.append(target.element)
        }
        var notifications: [(AXUIElement, CFString)] = [
            (target.application, kAXFocusedUIElementChangedNotification as CFString)
        ]
        for element in notifiedElements {
            notifications.append((element, kAXSelectedTextChangedNotification as CFString))
            notifications.append((element, kAXValueChangedNotification as CFString))
        }
        var registered: [(AXUIElement, CFString)] = []
        for (element, notification) in notifications {
            do {
                try configureAXMessaging(element)
            } catch {
                continue
            }
            if AXObserverAddNotification(observer, element, notification, refcon) == .success {
                registered.append((element, notification))
            }
        }
        guard !registered.isEmpty else { return nil }
        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return ObserverRegistration(observer: observer, source: source, context: context, notifications: registered)
    }

    private func installWorkspaceObserver(for target: TargetHandle) {
        removeWorkspaceObserver()
        let targetID = target.id
        let capturedProcessID = target.processID
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let activatedProcessID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                self.workspaceApplicationChanged(
                    activatedProcessID,
                    targetID: targetID,
                    targetProcessID: capturedProcessID
                )
            }
        }
    }

    private func workspaceApplicationChanged(
        _ activatedProcessID: Int32?,
        targetID: UUID,
        targetProcessID: Int32
    ) {
        guard capturedTarget?.snapshot.id == targetID else { return }
        guard let processID = activatedProcessID else {
            lastFailureReason = .frontmostApplicationUnavailable
            invalidateCapture(targetID)
            return
        }
        guard processID == targetProcessID || processID == ProcessInfo.processInfo.processIdentifier else {
            lastFailureReason = .foregroundApplicationChanged
            invalidateCapture(targetID)
            return
        }
    }

    private func removeWorkspaceObserver() {
        guard let workspaceObserver else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        self.workspaceObserver = nil
    }

    private func observedChange(for targetID: UUID, reason: SelectionFailureReason) {
        if reason == .captureObservedFocusChange,
           let captured = capturedTarget {
            let previousFailureReason = lastFailureReason
            let preservesCapture = ObservedFocusValidation.preservesCapture(
                observedTargetID: targetID,
                currentTargetID: captured.snapshot.id,
                capturedElement: captured.handle.anchor,
                readFocusedElement: {
                    defer { self.lastFailureReason = previousFailureReason }
                    return try self.elementAttribute(
                        captured.handle.application,
                        kAXFocusedUIElementAttribute,
                        failure: .targetLost
                    )
                },
                sameElement: { self.sameElement($0, $1) }
            )
            if preservesCapture { return }
        }
        invalidateCapture(targetID, reason: reason)
    }

    private func clearCapture() {
        removeObserverRegistration()
        removeWorkspaceObserver()
        capturedTarget = nil
        capturedScreen = nil
    }

    private func stopObservingCapturedTarget(_ targetID: UUID) {
        guard capturedTarget?.snapshot.id == targetID, observerRegistration != nil else { return }
        removeObserverRegistration()
    }

    private func removeObserverRegistration() {
        guard let observerRegistration else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), observerRegistration.source, .commonModes)
        for (element, notification) in observerRegistration.notifications {
            _ = AXObserverRemoveNotification(observerRegistration.observer, element, notification)
        }
        self.observerRegistration = nil
    }

    private func clearCapture(for targetID: UUID) {
        guard capturedTarget?.snapshot.id == targetID else { return }
        clearCapture()
    }

    private func invalidateCapture(
        _ targetID: UUID,
        reason: SelectionFailureReason = .captureInvalidated
    ) {
        if capturedTarget?.snapshot.id == targetID, lastFailureReason == nil {
            lastFailureReason = reason
        }
        clearCapture(for: targetID)
        if undoTarget?.receipt.target.id == targetID { undoTarget = nil }
    }

    private func requireSafeForeground(_ target: TargetHandle) throws {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            throw failure(.frontmostApplicationUnavailable, .staleSelection)
        }
        let processID = frontmostApplication.processIdentifier
        guard processID == ProcessInfo.processInfo.processIdentifier
                || (processID == target.processID && (frontmostApplication.bundleIdentifier ?? "pid:\(processID)") == target.applicationID)
        else { throw failure(.foregroundApplicationChanged, .staleSelection) }
    }

    private func requireTargetForeground(_ target: TargetHandle) throws {
        guard target.processID != ProcessInfo.processInfo.processIdentifier,
              let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              frontmostApplication.processIdentifier == target.processID,
              (frontmostApplication.bundleIdentifier ?? "pid:\(target.processID)") == target.applicationID
        else {
            throw failure(.foregroundApplicationChanged, .staleSelection)
        }
    }

    private func currentSelection(_ target: TargetHandle, allowingEmpty: Bool = false) throws -> NativeSelection {
        try validateSelectionTarget(target)
        guard let selection = try readSelection(target, allowingEmpty: allowingEmpty) else {
            throw ImrseError.staleSelection
        }
        return selection
    }

    private func captureWindowContext(
        for element: AXUIElement,
        processID: Int32,
        intent: SelectionEditIntent
    ) throws -> (window: AXUIElement, document: SelectionTargetContextValidation.Document) {
        let failureReason: SelectionFailureReason = intent == .insertAtCaret
            ? .caretProofUnavailable
            : .windowContextUnavailable
        let error: ImrseError = intent == .insertAtCaret ? .insertionUnavailable : .noSelection
        guard let window = try elementAttribute(element, kAXWindowAttribute, failure: error),
              let windowProcessID = processIdentifier(of: window),
              windowProcessID == processID,
              let role = try stringAttribute(window, kAXRoleAttribute, failure: error),
              role == (kAXWindowRole as String)
        else {
            throw failure(failureReason, error)
        }
        let document = try documentContext(window, failure: error)
        return (window, document)
    }

    private func fallbackEditableHostBinding(
        anchor: AXUIElement,
        processID: Int32,
        intent: SelectionEditIntent,
        anchorRange: TextRange?,
        anchorText: String?
    ) -> EditableHostBinding? {
        let previousFailureReason = lastFailureReason
        defer { lastFailureReason = previousFailureReason }
        guard intent == .replaceSelection,
              let host = resolvedEditableHost(anchor: anchor, processID: processID),
              let hostSelection = try? elementSelection(
                host,
                allowingEmpty: false,
                readingCaretText: false,
                allowValueFallback: false
              ),
              anchorRange.map({ $0 == hostSelection.range }) ?? true,
              anchorText.map({ sameText($0, hostSelection.text) }) ?? true
        else {
            return nil
        }
        return EditableHostBinding(element: host, role: kAXTextAreaRole as String, selection: hostSelection)
    }

    private func rangeAvailability(
        _ element: AXUIElement,
        allowingEmpty: Bool
    ) -> SelectionEvidence<TextRange> {
        do {
            guard let resolved = try rangeAttribute(
                element,
                kAXSelectedTextRangeAttribute,
                failure: .noSelection
            ) else {
                return SelectionEvidence(availability: .absent, value: nil, reason: nil)
            }
            if let reason = SelectionReadValidation.rangeFailure(resolved, allowingEmpty: allowingEmpty) {
                return SelectionEvidence(availability: .present, value: nil, reason: reason)
            }
            return SelectionEvidence(availability: .present, value: resolved, reason: nil)
        } catch {
            return SelectionEvidence(availability: .malformed, value: nil, reason: nil)
        }
    }

    private func textAvailability(
        _ element: AXUIElement,
        range: TextRange,
        allowingEmpty: Bool,
        canReadValue: Bool
    ) -> SelectionEvidence<String> {
        do {
            let selected = try selectedText(
                element,
                range: range,
                failure: .noSelection,
                allowingEmpty: allowingEmpty,
                allowValueFallback: canReadValue
            )
            guard let selected else {
                return SelectionEvidence(availability: .absent, value: nil, reason: nil)
            }
            if let reason = SelectionReadValidation.textFailure(
                selected,
                range: range,
                allowingEmpty: allowingEmpty
            ) {
                return SelectionEvidence(availability: .present, value: nil, reason: reason)
            }
            return SelectionEvidence(availability: .present, value: selected, reason: nil)
        } catch {
            return SelectionEvidence(availability: .malformed, value: nil, reason: nil)
        }
    }

    private func unrangedTextAvailability(_ element: AXUIElement) -> SelectionEvidence<String> {
        do {
            guard let selected = try stringAttribute(element, kAXSelectedTextAttribute, failure: .noSelection) else {
                return SelectionEvidence(availability: .absent, value: nil, reason: nil)
            }
            return SelectionEvidence(availability: .present, value: selected, reason: nil)
        } catch {
            return SelectionEvidence(availability: .malformed, value: nil, reason: nil)
        }
    }

    private func resolvedEditableHost(anchor: AXUIElement, processID: Int32) -> AXUIElement? {
        let previousFailureReason = lastFailureReason
        defer { lastFailureReason = previousFailureReason }
        guard let host = EditableHostResolution.host(
            anchor: anchor,
            hasTimeForProbe: { self.hasCaptureTimeForProbe() },
            isSameProcess: { self.hasProcessID($0, equalTo: processID) },
            readParent: { try self.elementAttribute($0, kAXParentAttribute, failure: .noSelection) },
            readEditableAncestor: {
                try self.elementAttribute($0, Self.editableAncestorAttribute, failure: .noSelection)
            },
            readHighestEditableAncestor: {
                try self.elementAttribute($0, Self.highestEditableAncestorAttribute, failure: .noSelection)
            },
            sameElement: { self.sameElement($0, $1) }
        ),
              (try? booleanAttribute(host, kAXEnabledAttribute as String, failure: .noSelection)) == true,
              (try? stringAttribute(host, kAXRoleAttribute, failure: .noSelection)) == (kAXTextAreaRole as String)
        else {
            return nil
        }
        return host
    }

    private func validateSelectionTarget(_ target: TargetHandle) throws {
        guard Self.accessibilityPermissionGranted else { throw ImrseError.permissionRequired }
        guard !IsSecureEventInputEnabled(), try !isSecure(target.anchor, in: target.application) else {
            throw failure(.protectedTarget, .secureInput)
        }
        try requireSafeForeground(target)
        guard let focused = try elementAttribute(target.application, kAXFocusedUIElementAttribute, failure: .targetLost) else {
            throw failure(.focusedElementUnavailable, .staleSelection)
        }
        guard sameElement(focused, target.anchor) else {
            throw failure(.focusedElementChanged, .staleSelection)
        }
        guard try stringAttribute(target.element, kAXRoleAttribute, failure: .targetLost) == target.role else {
            throw failure(.roleChanged, .staleSelection)
        }
        if !sameElement(target.anchor, target.element) {
            guard try stringAttribute(target.anchor, kAXRoleAttribute, failure: .targetLost) == target.anchorRole else {
                throw failure(.roleChanged, .staleSelection)
            }
            guard let host = resolvedEditableHost(anchor: target.anchor, processID: target.processID),
                  sameElement(host, target.element)
            else {
                throw failure(.focusedElementChanged, .staleSelection)
            }
            guard let hostWindow = try elementAttribute(target.element, kAXWindowAttribute, failure: .staleSelection),
                  sameElement(hostWindow, target.window)
            else {
                throw failure(.windowContextChanged, .staleSelection)
            }
            try requireAnchorHostSelectionAgreement(target)
        }
        let currentWindow = try elementAttribute(target.anchor, kAXWindowAttribute, failure: .staleSelection)
        if let reason = try SelectionTargetContextValidation.failureReason(
            capturedWindow: target.window,
            capturedDocument: target.document,
            currentWindow: currentWindow,
            intent: target.intent,
            sameWindow: { self.sameElement($0, $1) },
            isValidWindow: { window in
                guard self.processIdentifier(of: window) == target.processID else { return false }
                return try self.stringAttribute(window, kAXRoleAttribute, failure: .staleSelection)
                    == (kAXWindowRole as String)
            },
            readDocument: { window in try self.documentContext(window, failure: .staleSelection) }
        ) {
            throw failure(reason, .staleSelection)
        }
        if target.intent == .insertAtCaret {
            guard supportsPlainTextValueReplacement(target.element, role: target.role) else {
                throw failure(.caretProofUnavailable, .insertionUnavailable)
            }
            let composition = try caretCompositionState(target.element)
            guard composition == .unmarked else {
                throw failure(
                    composition == .marked ? .markedTextActive : .compositionStateUnavailable,
                    .insertionUnavailable
                )
            }
        }
    }

    private func documentContext(
        _ window: AXUIElement,
        failure error: ImrseError
    ) throws -> SelectionTargetContextValidation.Document {
        try configureAXMessaging(window)
        var attributes: CFArray?
        let attributesStatus = AXUIElementCopyAttributeNames(window, &attributes)
        guard attributesStatus == .success,
              let attributes = attributes as? [String]
        else {
            throw failure(.axReadFailure, error)
        }
        guard attributes.contains(kAXDocumentAttribute as String) else { return .unavailable }
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &value)
        switch SelectionTargetContextValidation.documentRead(status: status, value: value) {
        case let .context(document):
            return document
        case let .failed(reason):
            throw failure(reason, error)
        }
    }

    private func readSelection(_ target: TargetHandle, allowingEmpty: Bool) throws -> NativeSelection? {
        let allowingEmpty = allowingEmpty || target.intent == .insertAtCaret
        return try elementSelection(
            target.element,
            allowingEmpty: allowingEmpty,
            readingCaretText: target.intent == .insertAtCaret,
            allowValueFallback: supportsPlainTextValueReplacement(target.element, role: target.role)
        )
    }

    private func elementSelection(
        _ element: AXUIElement,
        allowingEmpty: Bool,
        readingCaretText: Bool,
        allowValueFallback: @autoclosure () -> Bool
    ) throws -> NativeSelection? {
        let selectedRange = try rangeAttribute(element, kAXSelectedTextRangeAttribute, failure: .targetLost)
        if let reason = SelectionReadValidation.rangeFailure(selectedRange, allowingEmpty: allowingEmpty) {
            lastFailureReason = reason
            return nil
        }
        guard let range = selectedRange else { return nil }
        let selected: String?
        if readingCaretText && range.length == 0 {
            selected = try stringAttribute(element, kAXSelectedTextAttribute, failure: .targetLost)
        } else {
            selected = try selectedText(
                element,
                range: range,
                failure: .targetLost,
                allowingEmpty: allowingEmpty,
                allowValueFallback: allowValueFallback()
            )
        }
        if let reason = SelectionReadValidation.textFailure(selected, range: range, allowingEmpty: allowingEmpty) {
            lastFailureReason = reason
            return nil
        }
        guard let text = selected else { return nil }
        lastFailureReason = nil
        return NativeSelection(text: text, range: range)
    }

    private func requireAnchorHostSelectionAgreement(_ target: TargetHandle) throws {
        let allowingEmpty = true
        guard let hostSelection = try elementSelection(
            target.element,
            allowingEmpty: allowingEmpty,
            readingCaretText: false,
            allowValueFallback: false
        ) else {
            throw failure(lastFailureReason ?? .selectedRangeUnavailable, .staleSelection)
        }
        let rangeProbe = rangeAvailability(target.anchor, allowingEmpty: allowingEmpty)
        let textProbe: SelectionEvidence<String>
        if let advertisedRange = rangeProbe.value {
            textProbe = textAvailability(
                target.anchor,
                range: advertisedRange,
                allowingEmpty: allowingEmpty,
                canReadValue: false
            )
        } else if rangeProbe.availability == .absent {
            textProbe = unrangedTextAvailability(target.anchor)
        } else {
            textProbe = SelectionEvidence(availability: .absent, value: nil, reason: nil)
        }
        let anchorRange = rangeProbe.reason == nil
            ? rangeProbe.availability
            : CaptureSelectionFallback.Availability.malformed
        let anchorText = textProbe.reason == nil
            ? textProbe.availability
            : CaptureSelectionFallback.Availability.malformed
        switch CaptureSelectionFallback.anchorAgreement(
            anchorRange: anchorRange,
            anchorRangeMatchesHost: anchorRange == .present && rangeProbe.value == hostSelection.range,
            anchorText: anchorText,
            anchorTextMatchesHost: anchorText == .present
                && (textProbe.value.map { sameText($0, hostSelection.text) } ?? false)
        ) {
        case .agrees:
            return
        case .rangeMismatch:
            throw failure(.rangeChanged, .staleSelection)
        case .textMismatch:
            throw failure(.textChanged, .staleSelection)
        case .malformed:
            throw failure(.axReadFailure, .staleSelection)
        }
    }

    private func caretCompositionState(_ element: AXUIElement) throws -> CaretCompositionState {
        try configureAXMessaging(element)
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
              let names = names as? [String],
              names.contains(Self.markedTextRangeAttribute)
        else { return .unavailable }
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, Self.markedTextRangeAttribute as CFString, &value)
        return CaretCompositionState.read(advertised: true, status: status, hasValue: value != nil)
    }

    private func validateInsertionProof(_ proof: CaretInsertionProof?, on target: TargetHandle) throws {
        guard target.intent == .insertAtCaret else { return }
        let selection = try currentSelection(target)
        guard let proof,
              proof.matches(
                value: try wholeValue(target.element, failure: .staleSelection),
                range: selection.range,
                selectedText: selection.text
              )
        else { throw ImrseError.staleSelection }
    }

    private func selection(
        afterSetting expectedRange: TextRange,
        text expectedText: String,
        on target: TargetHandle
    ) async throws -> NativeSelection {
        guard let selected = try await UndoSelectionConsistencyValidation.firstMatching(
            expected: UndoSelectionProof(text: expectedText, range: expectedRange),
            read: {
                try self.validateSelectionTarget(target)
                return try self.readSelection(target, allowingEmpty: false).map {
                    UndoSelectionProof(text: $0.text, range: $0.range)
                }
            },
            wait: { await self.waitForNativeUpdateTurn() }
        ) else {
            throw ImrseError.staleSelection
        }
        return NativeSelection(text: selected.text, range: selected.range)
    }

    private func sourceScreen(for focusedElement: AXUIElement) -> NSScreen? {
        var geometryAvailable = false
        var window: AXUIElement?
        do {
            window = try elementAttribute(focusedElement, kAXWindowAttribute, failure: .targetLost)
        } catch {
            window = nil
        }
        if let window {
            do {
                if let bounds = try axWindowBounds(window) {
                    geometryAvailable = true
                    if let screen = screen(forAXBounds: bounds) { return screen }
                }
            } catch {
            }
        }
        do {
            if let bounds = try axWindowBounds(focusedElement) {
                geometryAvailable = true
                if let screen = screen(forAXBounds: bounds) { return screen }
            }
        } catch {
        }
        return geometryAvailable ? nil : NSScreen.main
    }

    private func axWindowBounds(_ element: AXUIElement) throws -> CGRect? {
        guard let position = try pointAttribute(element, kAXPositionAttribute, failure: .targetLost),
              let size = try sizeAttribute(element, kAXSizeAttribute, failure: .targetLost),
              position.x.isFinite,
              position.y.isFinite,
              size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0
        else {
            return nil
        }
        let bounds = CGRect(origin: position, size: size)
        guard bounds.maxX.isFinite, bounds.maxY.isFinite else { return nil }
        return bounds
    }

    private func screen(forAXBounds bounds: CGRect) -> NSScreen? {
        let candidates: [(screen: NSScreen, overlap: CGFloat)] = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayBounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            let quartzIntersection = bounds.intersection(displayBounds)
            guard !displayBounds.isNull,
                  !quartzIntersection.isNull,
                  !quartzIntersection.isEmpty,
                  let cocoaIntersection = NSScreenCoordinateConversion.cocoaRect(
                    from: quartzIntersection,
                    displayBounds: displayBounds,
                    screenFrame: screen.frame
                  )
            else {
                return nil
            }
            let overlap = cocoaIntersection.intersection(screen.frame)
            guard !overlap.isNull, !overlap.isEmpty else { return nil }
            return (screen, overlap.width * overlap.height)
        }
        return candidates.max { $0.overlap < $1.overlap }?.screen
    }

    private func isSecure(_ element: AXUIElement, in application: AXUIElement) throws -> Bool {
        if IsSecureEventInputEnabled() { return true }
        var ancestor = element
        for _ in 0..<64 {
            let role = try stringAttribute(ancestor, kAXRoleAttribute, failure: .targetLost)
            let subrole = try stringAttribute(ancestor, kAXSubroleAttribute, failure: .targetLost)
            let protected = try booleanAttribute(ancestor, Self.protectedContentAttribute, failure: .targetLost)
            if role == (kAXSecureTextFieldSubrole as String)
                || subrole == (kAXSecureTextFieldSubrole as String)
                || protected == true {
                return true
            }
            if sameElement(ancestor, application) { return false }
            guard let parent = try elementAttribute(ancestor, kAXParentAttribute, failure: .targetLost) else {
                return true
            }
            ancestor = parent
        }
        return true
    }

    private func applyReplacement(
        to target: TargetHandle,
        replacing expectedText: String,
        at range: TextRange,
        with replacement: String,
        focusedSelection: NativeSelection,
        requiredOriginalValue: String? = nil
    ) async throws -> AppliedReplacement {
        guard !replacement.isEmpty else { throw ImrseError.emptyOutput }
        let before = try currentSelection(target, allowingEmpty: true)
        guard let replacementRange = validatedRange(at: range.location, length: replacement.utf16.count),
              isWithinSupportedRange(replacementRange)
        else { throw ImrseError.outputTooLarge }
        guard before.range == range,
              sameText(before.text, expectedText),
              sameSelection(before, focusedSelection),
              isWithinSupportedRange(range)
        else {
            throw ImrseError.staleSelection
        }
        let allowsWholeValueWrite = supportsPlainTextValueReplacement(target.element, role: target.role)
        let oldValue: String?
        if allowsWholeValueWrite {
            oldValue = try wholeValue(target.element, failure: .replacementFailed)
        } else {
            oldValue = nil
        }
        if let requiredOriginalValue {
            guard let oldValue, sameText(oldValue, requiredOriginalValue) else {
                throw ImrseError.staleSelection
            }
        }
        if let oldValue {
            guard let selectedValue = substring(oldValue, range: range),
                  sameText(selectedValue, expectedText)
            else {
                throw ImrseError.staleSelection
            }
        }
        let expectedValue = try oldValue.map { value -> String in
            guard let result = replacing(value, range: range, with: replacement) else {
                throw ImrseError.staleSelection
            }
            return result
        }

        let selectedTextSettable: Bool
        if before.range == range, sameText(before.text, expectedText) {
            selectedTextSettable = try attributeIsSettable(target.element, kAXSelectedTextAttribute)
        } else {
            selectedTextSettable = false
        }
        let capabilities = SelectionWriteCapabilities(
            selectedTextSettable: selectedTextSettable,
            permitsWholeValueWrite: allowsWholeValueWrite,
            clipboardFallbackEnabled: clipboardFallbackEnabled
        )
        var selectedTextFallbackBaseline: String?
        var selectedTextOutcome: SelectionMutationOutcome<AppliedReplacement>?
        if before.range == range, sameText(before.text, expectedText),
           capabilities.canConsider(.selectedText) {
            let status = try VerifiedAction.perform(
                verify: {
                    let current = try self.currentSelection(target, allowingEmpty: true)
                    guard self.sameSelection(current, before) else {
                        throw ImrseError.staleSelection
                    }
                    if let oldValue {
                        guard let currentValue = try self.wholeValue(target.element, failure: .replacementFailed),
                              self.sameText(currentValue, oldValue)
                        else {
                            throw ImrseError.staleSelection
                        }
                    }
                    if self.clipboardFallbackEnabled {
                        selectedTextFallbackBaseline = ClipboardFallbackNoOpValidation.baseline(
                            value: oldValue ?? (try? self.wholeValue(target.element, failure: .replacementFailed)),
                            range: range,
                            selectedText: expectedText
                        )
                    }
                },
                action: {
                    try self.setAttribute(target.element, kAXSelectedTextAttribute, value: replacement as CFString)
                }
            )
            if status != .success {
                selectedTextOutcome = .indeterminate(.replacementWriteRejected)
            } else {
                var failureReason = SelectionFailureReason.replacementReadbackFailed
                do {
                    let after = try currentSelection(target, allowingEmpty: true)
                    let afterValue = try SelectedTextReplacementValidation.readbackValue(
                        expectedValue: expectedValue,
                        fallbackBaseline: selectedTextFallbackBaseline,
                        read: { try self.wholeValue(target.element, failure: .replacementFailed) }
                    )
                    if SelectedTextReplacementValidation.confirms(
                        afterValue: afterValue,
                        expectedValue: expectedValue,
                        afterRange: after.range,
                        afterText: after.text,
                        replacementRange: replacementRange,
                        replacement: replacement
                    ) {
                        selectedTextOutcome = .confirmedApplied(
                            AppliedReplacement(strategy: .selectedText, focusedSelection: after, styleProof: nil)
                        )
                    } else if SelectedTextReplacementValidation.permitsRangeOnlyConfirmation(
                        expectedValue: expectedValue
                    ), UTF16SelectionRange.isCollapsedCaret(
                        after.range,
                        selectedText: after.text,
                        atEndOf: replacementRange
                    ) {
                        guard let rangeText = try self.stringForRange(
                            target.element,
                            range: replacementRange,
                            failure: .replacementFailed
                        ) else {
                            throw ImrseError.replacementFailed
                        }
                        failureReason = .replacementEvidenceMismatch
                        guard self.sameText(rangeText, replacement) else {
                            throw ImrseError.replacementFailed
                        }
                        failureReason = .replacementReadbackFailed
                        let verifiedSelection = try self.currentSelection(target, allowingEmpty: true)
                        failureReason = .replacementEvidenceMismatch
                        guard self.sameSelection(verifiedSelection, after) else {
                            throw ImrseError.replacementFailed
                        }
                        selectedTextOutcome = .confirmedApplied(
                            AppliedReplacement(
                                strategy: .selectedText,
                                focusedSelection: verifiedSelection,
                                styleProof: nil
                            )
                        )
                    } else if self.clipboardFallbackEnabled,
                              let selectedTextFallbackBaseline,
                              let afterValue,
                              after.range == before.range,
                              self.sameText(after.text, before.text),
                              self.sameText(afterValue, selectedTextFallbackBaseline) {
                        failureReason = .replacementVerificationFailed
                        try self.requireTargetForeground(target)
                        let recheckedSelection = try self.currentSelection(target, allowingEmpty: true)
                        guard let recheckedValue = try self.wholeValue(target.element, failure: .replacementFailed),
                              ClipboardFallbackNoOpValidation.permits(
                                enabled: self.clipboardFallbackEnabled,
                                targetIsSafeAndFocused: true,
                                range: range,
                                beforeText: before.text,
                                afterRange: recheckedSelection.range,
                                afterText: recheckedSelection.text,
                                beforeValue: selectedTextFallbackBaseline,
                                afterValue: recheckedValue
                              )
                        else {
                            throw ImrseError.replacementFailed
                        }
                        selectedTextOutcome = .provedNotApplied
                    } else {
                        selectedTextOutcome = .indeterminate(.replacementEvidenceMismatch)
                    }
                } catch {
                    selectedTextOutcome = .indeterminate(failureReason)
                }
            }
        }
        if let selectedTextOutcome {
            switch selectedTextOutcome {
            case .confirmedApplied(let applied):
                return applied
            case .provedNotApplied:
                break
            case .indeterminate(let reason):
                invalidateAfterUnverifiedWrite(target.id, reason: reason)
                throw ImrseError.replacementFailed
            }
        }
        let selectedTextNoOpValidated = selectedTextOutcome?.allowsFallback ?? false

        if !selectedTextNoOpValidated,
           capabilities.canConsider(.valueRange),
           let oldValue,
           let expectedValue,
           try attributeIsSettable(target.element, kAXValueAttribute) {
            let status = try VerifiedAction.perform(
                verify: {
                    let stillCurrent = try self.currentSelection(target, allowingEmpty: true)
                    guard self.sameSelection(stillCurrent, before),
                          let currentValue = try self.wholeValue(target.element, failure: .replacementFailed),
                          self.sameText(currentValue, oldValue)
                    else {
                        throw ImrseError.staleSelection
                    }
                },
                action: {
                    try self.setAttribute(target.element, kAXValueAttribute, value: expectedValue as CFString)
                }
            )
            guard status == .success else {
                invalidateAfterUnverifiedWrite(target.id, reason: .replacementWriteRejected)
                throw ImrseError.replacementFailed
            }
            let afterValue: String
            do {
                guard let value = try wholeValue(target.element, failure: .replacementFailed) else {
                    throw ImrseError.replacementFailed
                }
                afterValue = value
            } catch {
                invalidateAfterUnverifiedWrite(target.id, reason: .replacementReadbackFailed)
                throw ImrseError.replacementFailed
            }
            if sameText(afterValue, expectedValue) {
                let after: NativeSelection
                do {
                    after = try currentSelection(target, allowingEmpty: true)
                } catch {
                    invalidateAfterUnverifiedWrite(target.id, reason: .replacementReadbackFailed)
                    throw ImrseError.replacementFailed
                }
                return AppliedReplacement(strategy: .valueRange, focusedSelection: after, styleProof: nil)
            }
            invalidateAfterUnverifiedWrite(target.id, reason: .replacementEvidenceMismatch)
            throw ImrseError.replacementFailed
        }

        guard (selectedTextOutcome?.allowsFallback ?? true),
              capabilities.canConsider(.clipboard), before.range == range, sameText(before.text, expectedText) else {
            throw ImrseError.replacementFailed
        }
        guard let prepareForClipboardPaste else { throw ImrseError.clipboardFailed }
        try requireTargetForeground(target)
        let styleProof = try preflightClipboardStyleProof(
            target,
            replacing: expectedText,
            at: range,
            with: replacement,
            expectedValue: selectedTextFallbackBaseline ?? oldValue
        )
        guard clipboardFallbackTargetIsEligible(target, styleProof: styleProof) else {
            throw ImrseError.replacementFailed
        }
        do {
            try await prepareForClipboardPaste()
        } catch {
            throw ImrseError.clipboardFailed
        }
        let clipboardValue: String
        do {
            try requireTargetForeground(target)
            guard clipboardFallbackTargetIsEligible(target, styleProof: styleProof) else {
                throw ImrseError.staleSelection
            }
            let afterPreparation = try currentSelection(target, allowingEmpty: true)
            guard sameSelection(afterPreparation, before),
                  let value = try wholeValue(target.element, failure: .staleSelection),
                  (selectedTextFallbackBaseline ?? oldValue).map({ sameText(value, $0) }) ?? true,
                  let displayRange = clipboardDisplayRange(range, proof: styleProof),
                  let clipboardText = substring(value, range: displayRange),
                  sameText(clipboardText, expectedText)
            else {
                throw ImrseError.staleSelection
            }
            clipboardValue = value
        } catch {
            if selectedTextNoOpValidated { invalidateAfterUnverifiedWrite(target.id) }
            throw error
        }
        guard let displayRange = clipboardDisplayRange(range, proof: styleProof),
              let clipboardExpectedValue = replacing(clipboardValue, range: displayRange, with: replacement),
              styleProof.map({ sameText(clipboardExpectedValue, $0.expectedText) }) ?? true
        else {
            throw ImrseError.staleSelection
        }
        let afterPaste = try await paste(
            replacement,
            to: target,
            replacing: expectedText,
            at: range,
            expectedSelection: before,
            oldValue: clipboardValue,
            expectedValue: clipboardExpectedValue,
            styleProof: styleProof
        )
        return AppliedReplacement(strategy: .clipboard, focusedSelection: afterPaste, styleProof: styleProof)
    }

    private func invalidateAfterUnverifiedWrite(
        _ targetID: UUID,
        reason: SelectionFailureReason = .replacementVerificationFailed
    ) {
        lastFailureReason = reason
        invalidateCapture(targetID)
        if undoTarget?.receipt.target.id == targetID { undoTarget = nil }
    }

    /// The pasteboard and event system provide no atomic ownership reservation, so rechecks leave a narrow OS race.
    private func paste(
        _ text: String,
        to target: TargetHandle,
        replacing expectedText: String,
        at range: TextRange,
        expectedSelection: NativeSelection,
        oldValue: String,
        expectedValue: String,
        styleProof: ContenteditableClipboardProof? = nil
    ) async throws -> NativeSelection {
        guard Self.eventPostingPermissionGranted else { throw ImrseError.permissionRequired }
        try requireTargetForeground(target)
        guard clipboardFallbackTargetIsEligible(target, styleProof: styleProof) else {
            throw ImrseError.staleSelection
        }
        guard let application = NSRunningApplication(processIdentifier: target.processID), !application.isTerminated else {
            throw failure(.targetApplicationUnavailable, .clipboardFailed)
        }
        guard let identity = clipboardIdentity(application),
              identity.applicationID == target.applicationID,
              let replacementRange = validatedRange(at: range.location, length: text.utf16.count),
              let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else {
            throw ImrseError.clipboardFailed
        }
        let destination = ClipboardDestination(
            target: target,
            application: application,
            identity: identity,
            expectedValue: expectedValue,
            replacement: text,
            replacementRange: replacementRange
        )
        let pasteboard = NSPasteboard.general
        let afterPaste = try await clipboardRecovery.perform(
            destination: destination,
            capture: { try ClipboardPasteboardTransaction.capture(from: pasteboard) },
            stage: { transaction in
                try self.requireTargetForeground(target)
                let current = try self.currentSelection(target)
                guard self.sameSelection(current, expectedSelection),
                      let value = try self.wholeValue(target.element, failure: .staleSelection),
                      self.sameText(value, oldValue),
                      self.clipboardFallbackTargetIsEligible(target, styleProof: styleProof)
                else { throw ImrseError.staleSelection }
                try transaction.stage(text, on: pasteboard)
            },
            verify: { transaction in
                try self.requireCurrentClipboardDestination(destination)
                try self.requireTargetForeground(target)
                guard self.clipboardFallbackTargetIsEligible(target, styleProof: styleProof) else {
                    throw ImrseError.staleSelection
                }
                let beforePost = try self.currentSelection(target)
                guard beforePost.range == range,
                      self.sameText(beforePost.text, expectedText),
                      self.sameSelection(beforePost, expectedSelection),
                      let valueBeforePost = try self.wholeValue(target.element, failure: .staleSelection),
                      self.sameText(valueBeforePost, oldValue)
                else { throw ImrseError.staleSelection }
                guard transaction.stillOwns(pasteboard) else { throw ImrseError.clipboardFailed }
            },
            post: {
                keyDown.flags = .maskCommand
                keyUp.flags = .maskCommand
                keyDown.postToPid(target.processID)
                keyUp.postToPid(target.processID)
            },
            confirm: {
                guard let after = try await self.waitForClipboardWrite(destination) else {
                    throw ImrseError.replacementFailed
                }
                return after
            },
            hasMutated: { $0.hasMutatedPasteboard },
            restore: { try $0.restoreIfOwned(on: pasteboard) }
        )
        if let styleProof {
            do {
                guard try requireContenteditableStyleState(
                    target,
                    proof: styleProof,
                    confirmsApplied: true
                ),
                sameSelection(try currentSelection(target, allowingEmpty: true), afterPaste)
                else {
                    throw ImrseError.replacementFailed
                }
            } catch {
                invalidateAfterUnverifiedWrite(target.id)
                throw ImrseError.replacementFailed
            }
        }
        return afterPaste
    }

    private func recoverPendingClipboard() throws {
        try clipboardRecovery.recover(
            terminationConfirmed: { destination in
                destination.identity.confirmsTermination(
                    observed: self.clipboardIdentity(destination.application),
                    isTerminated: destination.application.isTerminated
                )
            },
            writeConfirmed: { try self.confirmedClipboardSelection($0) != nil },
            restore: { try $0.restoreIfOwned(on: NSPasteboard.general) }
        )
    }

    private func clipboardIdentity(_ application: NSRunningApplication) -> ClipboardDestinationIdentity? {
        guard let launchDate = application.launchDate,
              let executableURL = application.executableURL
        else { return nil }
        return ClipboardDestinationIdentity(
            processID: application.processIdentifier,
            launchDate: launchDate,
            executableURL: executableURL,
            applicationID: application.bundleIdentifier ?? "pid:\(application.processIdentifier)"
        )
    }

    private func requireCurrentClipboardDestination(_ destination: ClipboardDestination) throws {
        guard !destination.application.isTerminated,
              clipboardIdentity(destination.application) == destination.identity,
              let current = NSRunningApplication(processIdentifier: destination.identity.processID),
              !current.isTerminated,
              clipboardIdentity(current) == destination.identity
        else { throw failure(.targetApplicationUnavailable, .staleSelection) }
    }

    private func confirmedClipboardSelection(_ destination: ClipboardDestination) throws -> NativeSelection? {
        try requireCurrentClipboardDestination(destination)
        let target = destination.target
        try requireTargetForeground(target)
        let selection = try currentSelection(target, allowingEmpty: true)
        guard (selection.range == destination.replacementRange && sameText(selection.text, destination.replacement))
                || UTF16SelectionRange.isCollapsedCaret(
                    selection.range,
                    selectedText: selection.text,
                    atEndOf: destination.replacementRange
                ),
              let value = try wholeValue(target.element, failure: .replacementFailed),
              sameText(value, destination.expectedValue)
        else { return nil }
        let rechecked = try currentSelection(target, allowingEmpty: true)
        guard sameSelection(selection, rechecked) else { throw ImrseError.staleSelection }
        return rechecked
    }

    private func waitForClipboardWrite(_ destination: ClipboardDestination) async throws -> NativeSelection? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(500))
        while true {
            try Task.checkCancellation()
            if let selection = try confirmedClipboardSelection(destination) {
                return selection
            }
            guard clock.now < deadline else { return nil }
            await waitForNativeUpdateTurn()
        }
    }

    private func waitForNativeUpdateTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) {
                continuation.resume()
            }
        }
    }

    private func clipboardFallbackTargetIsEligible(
        _ target: TargetHandle,
        styleProof: ContenteditableClipboardProof? = nil
    ) -> Bool {
        let eligible: Bool
        if let styleProof {
            do {
                eligible = try requireContenteditableStyleState(
                    target,
                    proof: styleProof,
                    confirmsApplied: false
                )
            } catch {
                if lastFailureReason == nil { lastFailureReason = .clipboardTargetIneligible }
                return false
            }
        } else {
            eligible = ClipboardTargetStructureValidation.permits(
                root: target.element,
                readRole: { element in
                    guard let role = try self.stringAttribute(element, kAXRoleAttribute, failure: .staleSelection) else {
                        throw ImrseError.staleSelection
                    }
                    return role
                },
                readChildren: { element in
                    try self.elementChildren(element, failure: .staleSelection)
                },
                sameElement: { self.sameElement($0, $1) }
            )
        }
        if !eligible, lastFailureReason == nil {
            lastFailureReason = .clipboardTargetIneligible
        }
        return eligible
    }

    private func preflightClipboardStyleProof(
        _ target: TargetHandle,
        replacing selectedText: String,
        at range: TextRange,
        with replacement: String,
        expectedValue: String?
    ) throws -> ContenteditableClipboardProof? {
        if clipboardFallbackTargetIsEligible(target) { return nil }
        guard let styleProof = try contenteditableClipboardStyleProof(
            target,
            replacing: selectedText,
            at: range,
            with: replacement,
            expectedValue: expectedValue
        ) else {
            if lastFailureReason == nil { lastFailureReason = .clipboardTargetIneligible }
            throw ImrseError.replacementFailed
        }
        lastFailureReason = nil
        return styleProof
    }

    private func contenteditableClipboardStyleProof(
        _ target: TargetHandle,
        replacing selectedText: String,
        at range: TextRange,
        with replacement: String,
        expectedValue: String?
    ) throws -> ContenteditableClipboardProof? {
        guard let value = try wholeValue(target.element, failure: .replacementFailed),
              expectedValue.map({ sameText(value, $0) }) ?? true
        else { return nil }
        if try contenteditableClipboardTargetIsEligible(target) {
            guard let attributedValue = try attributedWholeValue(
                target.element,
                matching: value,
                failure: .replacementFailed
            ), let proof = ContenteditableTextStyleProof(
                originalValue: attributedValue,
                selectionRange: range,
                selectedText: selectedText,
                replacement: replacement
            ) else { return nil }
            return .uniform(proof)
        }
        guard let snapshot = try structuredContenteditableSnapshot(target, matching: value),
              try structuredSelectionCoordinatesMatch(
                target,
                range: range,
                fieldRange: snapshot.markerRange,
                canonicalLength: snapshot.projection.text.utf16.count
              ),
              let proof = ContenteditableTextStyleProof.Structured(
            originalValue: snapshot.value,
            projection: snapshot.projection,
            selectionRange: range,
            selectedText: selectedText,
            replacement: replacement
        ) else { return nil }
        return .structured(proof)
    }

    private func clipboardDisplayRange(_ range: TextRange, proof: ContenteditableClipboardProof?) -> TextRange? {
        if case .structured(let structured)? = proof {
            return structured.originalProjection.displayRange(for: range)
        }
        return range
    }

    private func requireContenteditableStyleState(
        _ target: TargetHandle,
        proof: ContenteditableClipboardProof,
        confirmsApplied: Bool
    ) throws -> Bool {
        switch proof {
        case .uniform(let uniform):
            guard try contenteditableClipboardTargetIsEligible(target),
                  let actual = try attributedWholeValue(
                    target.element,
                    matching: confirmsApplied ? uniform.expectedText : uniform.originalText,
                    failure: .staleSelection
                  )
            else { return false }
            return confirmsApplied ? uniform.confirmsApplied(actual) : uniform.confirmsOriginal(actual)
        case .structured(let structured):
            let expected = confirmsApplied ? structured.expectedProjection : structured.originalProjection
            guard let actual = try structuredContenteditableSnapshot(target, matching: expected.displayText),
                  actual.projection == expected
            else { return false }
            return confirmsApplied ? structured.confirmsApplied(actual.value) : structured.confirmsOriginal(actual.value)
        }
    }

    private func contenteditableClipboardTargetIsEligible(_ target: TargetHandle) throws -> Bool {
        guard try contenteditableRootIsEligible(target),
              ClipboardDirectStaticTextValidation.permits(
                root: target.element,
                readRole: { element in
                    guard let role = try self.stringAttribute(element, kAXRoleAttribute, failure: .staleSelection) else {
                        throw ImrseError.staleSelection
                    }
                    return role
                },
                readChildren: { element in
                    try self.elementChildren(element, failure: .staleSelection)
                },
                sameElement: { self.sameElement($0, $1) }
              )
        else { return false }
        return true
    }

    private func contenteditableRootIsEligible(_ target: TargetHandle) throws -> Bool {
        guard target.role == "AXTextArea",
              try booleanAttribute(target.element, kAXEnabledAttribute as String, failure: .staleSelection) == true,
              let editableAncestor = try elementAttribute(
                target.element,
                Self.editableAncestorAttribute,
                failure: .staleSelection
              ),
              let highestEditableAncestor = try elementAttribute(
                target.element,
                Self.highestEditableAncestorAttribute,
                failure: .staleSelection
              ),
              sameElement(editableAncestor, target.element),
              sameElement(highestEditableAncestor, target.element),
              hasProcessID(target.element, equalTo: target.processID),
              hasProcessID(editableAncestor, equalTo: target.processID),
              hasProcessID(highestEditableAncestor, equalTo: target.processID)
        else {
            return false
        }
        return true
    }

    private func hasProcessID(_ element: AXUIElement, equalTo expected: Int32) -> Bool {
        processIdentifier(of: element) == expected
    }

    private func processIdentifier(of element: AXUIElement) -> Int32? {
        var processID: pid_t = 0
        guard AXUIElementGetPid(element, &processID) == .success else { return nil }
        return Int32(processID)
    }

    private func structuredContenteditableProjection(
        _ target: TargetHandle,
        matching value: String
    ) throws -> ContenteditableTextProjection? {
        guard value.utf16.count <= ContenteditableTextStyleProof.maximumWholeValueUTF16Length,
              try contenteditableRootIsEligible(target),
              let currentValue = try wholeValue(target.element, failure: .staleSelection),
              sameText(currentValue, value)
        else { return nil }
        return ClipboardStructuredTextValidation.projection(
            root: target.element,
            displayText: value,
            readRole: { element in
                guard let role = try self.stringAttribute(element, kAXRoleAttribute, failure: .staleSelection) else {
                    throw ImrseError.staleSelection
                }
                return role
            },
            readChildren: { element in
                try self.elementChildren(
                    element,
                    failure: .staleSelection,
                    maximumCount: ClipboardStructuredTextValidation.maximumNodes
                )
            },
            readText: { element in
                guard let text = try self.stringAttribute(element, kAXValueAttribute, failure: .staleSelection),
                      text.utf16.count <= ContenteditableTextStyleProof.maximumWholeValueUTF16Length
                else { return nil }
                return text
            },
            readParent: { try self.elementAttribute($0, kAXParentAttribute, failure: .staleSelection) },
            belongsToProcess: { self.hasProcessID($0, equalTo: target.processID) },
            sameElement: { self.sameElement($0, $1) }
        )
    }

    private func structuredContenteditableSnapshot(
        _ target: TargetHandle,
        matching value: String
    ) throws -> (projection: ContenteditableTextProjection, value: NSAttributedString, markerRange: AXTextMarkerRange)? {
        guard let projection = try structuredContenteditableProjection(target, matching: value),
              let markerRange = try parameterizedAttribute(
                target.element,
                "AXTextMarkerRangeForUIElement",
                parameter: target.element,
                failure: .staleSelection
              ),
              CFGetTypeID(markerRange) == AXTextMarkerRangeGetTypeID(),
              let rawValue = try parameterizedAttribute(
                target.element,
                "AXAttributedStringForTextMarkerRange",
                parameter: markerRange,
                failure: .staleSelection
              ),
              CFGetTypeID(rawValue) == CFAttributedStringGetTypeID(),
              let attributedValue = rawValue as? NSAttributedString,
              attributedValue.length == projection.text.utf16.count,
              sameText(attributedValue.string, projection.text),
              try structuredContenteditableProjection(target, matching: value) == projection
        else { return nil }
        return (
            projection,
            NSAttributedString(attributedString: attributedValue),
            unsafeDowncast(markerRange, to: AXTextMarkerRange.self)
        )
    }

    private func structuredSelectionCoordinatesMatch(
        _ target: TargetHandle,
        range: TextRange,
        fieldRange: AXTextMarkerRange,
        canonicalLength: Int
    ) throws -> Bool {
        try configureAXMessaging(target.element)
        var selectedRange: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(target.element, "AXSelectedTextMarkerRange" as CFString, &selectedRange)
        guard status == .success,
              let selectedRange,
              CFGetTypeID(selectedRange) == AXTextMarkerRangeGetTypeID()
        else { return false }
        let selected = unsafeDowncast(selectedRange, to: AXTextMarkerRange.self)
        guard let fieldStart = try textMarkerIndex(AXTextMarkerRangeCopyStartMarker(fieldRange), on: target.element),
              let fieldEnd = try textMarkerIndex(AXTextMarkerRangeCopyEndMarker(fieldRange), on: target.element),
              let selectedStart = try textMarkerIndex(AXTextMarkerRangeCopyStartMarker(selected), on: target.element),
              let selectedEnd = try textMarkerIndex(AXTextMarkerRangeCopyEndMarker(selected), on: target.element),
              fieldEnd >= fieldStart,
              fieldEnd - fieldStart == canonicalLength,
              selectedStart >= fieldStart,
              selectedEnd >= selectedStart,
              selectedEnd <= fieldEnd,
              selectedStart - fieldStart == range.location,
              selectedEnd - selectedStart == range.length
        else { return false }
        return true
    }

    private func textMarkerIndex(_ marker: AXTextMarker, on element: AXUIElement) throws -> Int? {
        guard let value = try parameterizedAttribute(
            element,
            "AXIndexForTextMarker",
            parameter: marker,
            failure: .staleSelection
        ), CFGetTypeID(value) == CFNumberGetTypeID()
        else { return nil }
        var index: Int64 = 0
        guard CFNumberGetValue(unsafeDowncast(value, to: CFNumber.self), .sInt64Type, &index),
              let result = Int(exactly: index), result >= 0
        else { return nil }
        return result
    }

    private func parameterizedAttribute(
        _ element: AXUIElement,
        _ attribute: String,
        parameter: CFTypeRef,
        failure: ImrseError
    ) throws -> CFTypeRef? {
        try configureAXMessaging(element)
        var value: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &value)
        if status == .attributeUnsupported || status == .parameterizedAttributeUnsupported
            || status == .noValue || status == .notImplemented {
            return nil
        }
        guard status == .success, let value else { throw self.failure(.axReadFailure, failure) }
        return value
    }

    private func elementChildren(
        _ element: AXUIElement,
        failure: ImrseError,
        maximumCount: Int = 1
    ) throws -> [AXUIElement] {
        try configureAXMessaging(element)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        guard status == .success,
              let value,
              CFGetTypeID(value) == CFArrayGetTypeID(),
              CFArrayGetCount(unsafeDowncast(value, to: CFArray.self)) <= maximumCount,
              let children = value as? [AXUIElement]
        else {
            throw failure
        }
        return children
    }

    private func attributeIsSettable(_ element: AXUIElement, _ attribute: String) throws -> Bool {
        try configureAXMessaging(element)
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        if status == .attributeUnsupported || status == .noValue || status == .notImplemented { return false }
        guard status == .success else { throw failure(.axReadFailure, .replacementFailed) }
        return settable.boolValue
    }

    private func setAttribute(_ element: AXUIElement, _ attribute: String, value: CFTypeRef) throws -> AXError {
        try configureAXMessaging(element)
        return AXUIElementSetAttributeValue(element, attribute as CFString, value)
    }

    private func configureAXMessaging(_ element: AXUIElement) throws {
        if let captureDeadline, clock.now >= captureDeadline { throw failure(.axMessagingFailure, .targetLost) }
        guard AXUIElementSetMessagingTimeout(element, Self.axMessagingTimeout) == .success else {
            throw failure(.axMessagingFailure, .targetLost)
        }
    }

    private func requestManualAccessibility(on application: AXUIElement) throws {
        guard try attributeIsSettable(application, Self.manualAccessibilityAttribute) else { return }
        _ = try setAttribute(
            application,
            Self.manualAccessibilityAttribute,
            value: kCFBooleanTrue
        )
    }

    private func hasCaptureTimeForFocusRetry() -> Bool {
        guard let captureDeadline else { return true }
        let requiredMilliseconds = Self.focusRetryDelayMilliseconds + Int64(Self.axMessagingTimeout * 1_000)
        return clock.now.advanced(by: .milliseconds(requiredMilliseconds)) < captureDeadline
    }

    private func hasCaptureTimeForProbe() -> Bool {
        guard let captureDeadline else { return true }
        let requiredMilliseconds = Int64(Self.axMessagingTimeout * 1_000) * Self.captureSetupAXCallReserve
        return clock.now.advanced(by: .milliseconds(requiredMilliseconds)) < captureDeadline
    }

    private func supportsPlainTextValueReplacement(_ element: AXUIElement, role: String) -> Bool {
        guard role == (kAXTextFieldRole as String) else { return false }
        do {
            try configureAXMessaging(element)
            var attributeNames: CFArray?
            guard AXUIElementCopyAttributeNames(element, &attributeNames) == .success,
                  let attributeNames = attributeNames as? [String],
                  !attributeNames.contains(kAXDocumentAttribute as String),
                  !attributeNames.contains(kAXSelectedTextRangesAttribute as String)
            else {
                return false
            }

            var parameterizedNames: CFArray?
            let status = AXUIElementCopyParameterizedAttributeNames(element, &parameterizedNames)
            if status == .attributeUnsupported || status == .noValue { return true }
            guard status == .success, let parameterizedNames = parameterizedNames as? [String] else {
                return false
            }
            let structuredAttributes = [
                kAXAttributedStringForRangeParameterizedAttribute as String,
                kAXRTFForRangeParameterizedAttribute as String,
                kAXStyleRangeForIndexParameterizedAttribute as String
            ]
            return !parameterizedNames.contains(where: structuredAttributes.contains)
        } catch {
            return false
        }
    }

    private func wholeValue(_ element: AXUIElement, failure: ImrseError) throws -> String? {
        guard let value = try stringAttribute(element, kAXValueAttribute, failure: failure) else { return nil }
        guard value.utf16.count <= PlainTextUndoValidation.maximumWholeValueUTF16Length else { throw failure }
        return value
    }

    private func attributedWholeValue(
        _ element: AXUIElement,
        matching value: String,
        failure: ImrseError
    ) throws -> NSAttributedString? {
        let length = value.utf16.count
        guard length > 0,
              length <= ContenteditableTextStyleProof.maximumWholeValueUTF16Length,
              let range = validatedRange(at: 0, length: length),
              let attributedValue = try attributedStringForRange(element, range: range, failure: failure),
              attributedValue.length == length,
              sameText(attributedValue.string, value)
        else {
            return nil
        }
        return NSAttributedString(attributedString: attributedValue)
    }

    private func attributedStringForRange(
        _ element: AXUIElement,
        range: TextRange,
        failure: ImrseError
    ) throws -> NSAttributedString? {
        guard isWithinSupportedRange(range) else { throw failure }
        let parameter = try axRangeValue(range, failure: failure)
        try configureAXMessaging(element)
        var value: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXAttributedStringForRangeParameterizedAttribute as CFString,
            parameter,
            &value
        )
        if status == .attributeUnsupported
            || status == .parameterizedAttributeUnsupported
            || status == .noValue
            || status == .notImplemented {
            return nil
        }
        guard status == .success, let value else { throw self.failure(.axReadFailure, failure) }
        guard CFGetTypeID(value) == CFAttributedStringGetTypeID(),
              let attributedValue = value as? NSAttributedString
        else {
            throw self.failure(.axValueTypeMismatch, failure)
        }
        return NSAttributedString(attributedString: attributedValue)
    }

    private func stringForRange(
        _ element: AXUIElement,
        range: TextRange,
        failure: ImrseError
    ) throws -> String? {
        guard isWithinSupportedRange(range) else { throw failure }
        let parameter = try axRangeValue(range, failure: failure)
        try configureAXMessaging(element)
        var value: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            parameter,
            &value
        )
        if status == .attributeUnsupported
            || status == .parameterizedAttributeUnsupported
            || status == .noValue
            || status == .notImplemented {
            return nil
        }
        guard status == .success, let value else { throw self.failure(.axReadFailure, failure) }
        guard let result = value as? String else { throw self.failure(.axValueTypeMismatch, failure) }
        return result
    }

    private func axRangeValue(_ range: TextRange, failure: ImrseError) throws -> AXValue {
        guard isValidRangeArithmetic(range) else { throw failure }
        var nativeRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &nativeRange) else { throw failure }
        return value
    }

    private func isValidRangeArithmetic(_ range: TextRange) -> Bool {
        UTF16SelectionRange.isValid(range)
    }

    private func isWithinSupportedRange(_ range: TextRange) -> Bool {
        UTF16SelectionRange.isWithinSupportedRange(range)
    }

    private func validatedRange(at location: Int, length: Int) -> TextRange? {
        UTF16SelectionRange.make(at: location, length: length)
    }

    private func elementAttribute(
        _ element: AXUIElement,
        _ attribute: String,
        failure: ImrseError
    ) throws -> AXUIElement? {
        try configureAXMessaging(element)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if status == .attributeUnsupported || status == .noValue { return nil }
        guard status == .success, let value else { throw self.failure(.axReadFailure, failure) }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { throw self.failure(.axValueTypeMismatch, failure) }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func stringAttribute(
        _ element: AXUIElement,
        _ attribute: String,
        failure: ImrseError
    ) throws -> String? {
        try configureAXMessaging(element)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if status == .attributeUnsupported || status == .noValue { return nil }
        guard status == .success, let value else { throw self.failure(.axReadFailure, failure) }
        guard let result = value as? String else { throw self.failure(.axValueTypeMismatch, failure) }
        return result
    }

    private func axValueAttribute(
        _ element: AXUIElement,
        _ attribute: String,
        failure: ImrseError
    ) throws -> AXValue? {
        try configureAXMessaging(element)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if status == .attributeUnsupported || status == .noValue { return nil }
        guard status == .success, let value else { throw self.failure(.axReadFailure, failure) }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { throw self.failure(.axValueTypeMismatch, failure) }
        return unsafeDowncast(value, to: AXValue.self)
    }

    private func pointAttribute(
        _ element: AXUIElement,
        _ attribute: String,
        failure: ImrseError
    ) throws -> CGPoint? {
        guard let value = try axValueAttribute(element, attribute, failure: failure) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { throw failure }
        return point
    }

    private func sizeAttribute(
        _ element: AXUIElement,
        _ attribute: String,
        failure: ImrseError
    ) throws -> CGSize? {
        guard let value = try axValueAttribute(element, attribute, failure: failure) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { throw failure }
        return size
    }

    private func rangeAttribute(
        _ element: AXUIElement,
        _ attribute: String,
        failure: ImrseError
    ) throws -> TextRange? {
        try configureAXMessaging(element)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if status == .attributeUnsupported || status == .noValue { return nil }
        guard status == .success, let value else { throw self.failure(.axReadFailure, failure) }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { throw self.failure(.axValueTypeMismatch, failure) }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { throw self.failure(.axValueTypeMismatch, failure) }
        return TextRange(location: range.location, length: range.length)
    }

    private func booleanAttribute(
        _ element: AXUIElement,
        _ attribute: String,
        failure: ImrseError
    ) throws -> Bool? {
        try configureAXMessaging(element)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if status == .attributeUnsupported || status == .noValue { return nil }
        guard status == .success, let value else { throw self.failure(.axReadFailure, failure) }
        guard CFGetTypeID(value) == CFBooleanGetTypeID(),
              let result = value as? Bool
        else {
            throw self.failure(.axValueTypeMismatch, failure)
        }
        return result
    }

    private func selectedText(
        _ element: AXUIElement,
        range: TextRange,
        failure: ImrseError,
        allowingEmpty: Bool = false,
        allowValueFallback: Bool = false
    ) throws -> String? {
        guard isValidRangeArithmetic(range),
              (allowingEmpty || range.length > 0)
        else {
            throw failure
        }
        let directText = try stringAttribute(element, kAXSelectedTextAttribute, failure: failure)
        if allowingEmpty, range.length == 0 { return directText ?? "" }
        if let selected = try SelectedTextRangeFallback.resolve(
            directText: directText,
            range: range,
            failure: failure,
            onTextLengthMismatch: { self.lastFailureReason = .selectedTextLengthMismatch },
            readStringForRange: {
                try stringForRange(element, range: range, failure: failure)
            }
        ) {
            return selected
        }
        guard allowValueFallback,
              let value = try wholeValue(element, failure: failure),
              let selected = substring(value, range: range)
        else {
            return nil
        }
        return selected
    }

    private func sameSnapshot(_ lhs: SelectionSnapshot, _ rhs: SelectionSnapshot) -> Bool {
        lhs.id == rhs.id
            && lhs.applicationID == rhs.applicationID
            && lhs.processID == rhs.processID
            && lhs.role == rhs.role
            && sameText(lhs.text, rhs.text)
            && lhs.range == rhs.range
            && lhs.isSecure == rhs.isSecure
            && lhs.intent == rhs.intent
    }

    private func sameReceipt(_ lhs: ReplacementReceipt, _ rhs: ReplacementReceipt) -> Bool {
        lhs.target.id == rhs.target.id
            && sameSnapshot(lhs.target, rhs.target)
            && sameText(lhs.replacement, rhs.replacement)
            && lhs.strategy == rhs.strategy
    }

    private func sameSelection(_ lhs: NativeSelection, _ rhs: NativeSelection) -> Bool {
        lhs.range == rhs.range && sameText(lhs.text, rhs.text)
    }

    private func sameElement(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        CFEqual(lhs, rhs)
    }

    private func sameText(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
    }

    private func failure(_ reason: SelectionFailureReason, _ error: ImrseError) -> ImrseError {
        lastFailureReason = reason
        return error
    }

    private func substring(_ value: String, range: TextRange) -> String? {
        UTF16SelectionRange.substring(value, range: range)
    }

    private func replacing(_ value: String, range: TextRange, with replacement: String) -> String? {
        UTF16SelectionRange.replacing(value, range: range, with: replacement)
    }
}
#endif
