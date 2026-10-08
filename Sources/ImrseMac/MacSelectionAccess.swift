#if os(macOS)
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import ImrseCore

@MainActor
public final class MacSelectionAccess: SelectionAccess {
    private typealias TextRange = ImrseCore.TextRange

    private static let axMessagingTimeout: Float = 0.1
    private static let captureBudget = Duration.seconds(1)
    private static let focusRetryDelayMilliseconds: Int64 = 10
    private static let manualAccessibilityAttribute = "AXManualAccessibility"
    private static let protectedContentAttribute = "AXProtectedContent"

    private struct TargetHandle {
        let id: UUID
        let applicationID: String
        let processID: Int32
        let role: String
        let application: AXUIElement
        let element: AXUIElement
    }

    private struct CapturedTarget {
        let snapshot: SelectionSnapshot
        let handle: TargetHandle
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
    }

    public var clipboardFallbackEnabled: Bool
    public private(set) var capturedScreen: NSScreen?
    private let prepareForClipboardPaste: ClipboardPastePreparation?
    private let clock = ContinuousClock()
    private var capturedTarget: CapturedTarget?
    private var observerRegistration: ObserverRegistration?
    private var workspaceObserver: NSObjectProtocol?
    private var captureDeadline: ContinuousClock.Instant?
    private var undoTarget: UndoTarget?

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
        clearCapture()
        captureDeadline = clock.now.advanced(by: Self.captureBudget)
        defer { captureDeadline = nil }
        guard Self.accessibilityPermissionGranted else { throw ImrseError.permissionRequired }
        guard !IsSecureEventInputEnabled() else { throw ImrseError.secureInput }
        guard let runningApplication = NSWorkspace.shared.frontmostApplication else {
            throw ImrseError.noSelection
        }

        let processID = runningApplication.processIdentifier
        guard processID != ProcessInfo.processInfo.processIdentifier else { throw ImrseError.noSelection }
        let application = AXUIElementCreateApplication(processID)
        try configureAXMessaging(application)
        guard let element = try AccessibilityFocusAcquisition.acquire(
            requestManualAccessibility: { try self.requestManualAccessibility(on: application) },
            hasTimeForRetry: { self.hasCaptureTimeForFocusRetry() },
            readFocusedElement: {
                try self.elementAttribute(application, kAXFocusedUIElementAttribute, failure: .noSelection)
            },
            validate: { element in
                guard try !self.isSecure(element, in: application) else { throw ImrseError.secureInput }
            },
            waitBeforeRetry: {
                Thread.sleep(forTimeInterval: Double(Self.focusRetryDelayMilliseconds) / 1_000.0)
            }
        ) else {
            throw ImrseError.noSelection
        }
        guard let role = try stringAttribute(element, kAXRoleAttribute, failure: .noSelection) else {
            throw ImrseError.noSelection
        }
        let canReadValue = supportsPlainTextValueReplacement(element, role: role)
        guard let range = try rangeAttribute(element, kAXSelectedTextRangeAttribute, failure: .noSelection),
              isValidRangeArithmetic(range),
              range.length > 0,
              let text = try selectedText(
                element,
                range: range,
                failure: .noSelection,
                allowValueFallback: canReadValue
              ),
              !text.isEmpty,
              text.utf16.count == range.length
        else {
            throw ImrseError.noSelection
        }

        let applicationID = runningApplication.bundleIdentifier ?? "pid:\(processID)"
        let snapshot = SelectionSnapshot(
            applicationID: applicationID,
            processID: processID,
            role: role,
            text: text,
            range: range,
            isSecure: false
        )
        let handle = TargetHandle(
            id: snapshot.id,
            applicationID: applicationID,
            processID: processID,
            role: role,
            application: application,
            element: element
        )
        try requireTargetForeground(handle)
        capturedTarget = CapturedTarget(snapshot: snapshot, handle: handle)
        observerRegistration = makeObserver(for: handle)
        installWorkspaceObserver(for: handle)
        do {
            try requireTargetForeground(handle)
            guard sameSelection(
                try currentSelection(handle),
                NativeSelection(text: text, range: range)
            ) else {
                throw ImrseError.noSelection
            }
            capturedScreen = sourceScreen(for: element)
        } catch {
            invalidateCapture(snapshot.id)
            throw error
        }
        return snapshot
    }

    public func validate(_ target: SelectionSnapshot) throws {
        guard let captured = capturedTarget, captured.snapshot.id == target.id else {
            throw ImrseError.targetLost
        }
        guard sameSnapshot(target, captured.snapshot) else {
            invalidateCapture(target.id)
            throw ImrseError.staleSelection
        }

        do {
            try requireSafeForeground(captured.handle)
            let selection = try currentSelection(captured.handle)
            guard let range = target.range,
                  sameSelection(selection, NativeSelection(text: target.text, range: range))
            else {
                throw ImrseError.staleSelection
            }
        } catch {
            invalidateCapture(target.id)
            throw error
        }
    }

    public func replace(_ target: SelectionSnapshot, with text: String) async throws -> ReplacementReceipt {
        try validate(target)
        guard let captured = capturedTarget, captured.snapshot.id == target.id else {
            throw ImrseError.targetLost
        }
        guard let range = target.range else { throw ImrseError.staleSelection }
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
                focusedSelection: before
            )
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
            focusedSelection: applied.focusedSelection
        )
        return receipt
    }

    public func undo(_ receipt: ReplacementReceipt) async throws {
        guard let undoTarget, sameReceipt(receipt, undoTarget.receipt) else {
            throw ImrseError.undoUnavailable
        }
        do {
            let current = try currentSelection(undoTarget.handle, allowingEmpty: true)
            guard sameSelection(current, undoTarget.focusedSelection) else {
                throw ImrseError.undoUnavailable
            }
            if supportsPlainTextValueReplacement(undoTarget.handle.element, role: undoTarget.handle.role) {
                try undoPlainTextField(undoTarget, receipt: receipt, currentSelection: current)
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
        } catch let error as ImrseError {
            if error == .staleSelection || error == .secureInput || error == .targetLost || error == .undoUnavailable {
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
    ) throws {
        let target = undoTarget.handle
        guard let currentValue = try wholeValue(target.element, failure: .undoUnavailable),
              let restoredValue = PlainTextUndoValidation.restoredValue(
                currentValue: currentValue,
                receipt: receipt,
                replacementRange: undoTarget.replacementRange,
                currentSelection: UndoSelectionProof(text: currentSelection.text, range: currentSelection.range),
                receiptSelection: UndoSelectionProof(
                    text: undoTarget.focusedSelection.text,
                    range: undoTarget.focusedSelection.range
                )
              )
        else {
            throw ImrseError.undoUnavailable
        }

        let selectedReplacement = currentSelection.range == undoTarget.replacementRange
            && sameText(currentSelection.text, receipt.replacement)
        let canWriteSelectedText = (try? attributeIsSettable(target.element, kAXSelectedTextAttribute)) == true
        if selectedReplacement, canWriteSelectedText {
            let beforeWrite = try self.currentSelection(target, allowingEmpty: true)
            guard sameSelection(beforeWrite, currentSelection),
                  let valueBeforeWrite = try wholeValue(target.element, failure: .undoUnavailable),
                  sameText(valueBeforeWrite, currentValue)
            else {
                throw ImrseError.undoUnavailable
            }
            let status = try setAttribute(target.element, kAXSelectedTextAttribute, value: receipt.target.text as CFString)
            guard status == .success else {
                invalidateAfterUnverifiedWrite(target.id)
                throw ImrseError.undoUnavailable
            }
        } else {
            guard (try? attributeIsSettable(target.element, kAXValueAttribute)) == true else {
                throw ImrseError.undoUnavailable
            }
            let beforeWrite = try self.currentSelection(target, allowingEmpty: true)
            guard sameSelection(beforeWrite, currentSelection),
                  let valueBeforeWrite = try wholeValue(target.element, failure: .undoUnavailable),
                  sameText(valueBeforeWrite, currentValue)
            else {
                throw ImrseError.undoUnavailable
            }
            let status = try setAttribute(target.element, kAXValueAttribute, value: restoredValue as CFString)
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
            _ = try self.currentSelection(target, allowingEmpty: true)
        } catch {
            invalidateAfterUnverifiedWrite(target.id)
            throw ImrseError.undoUnavailable
        }
    }

    public func discard(_ target: SelectionSnapshot) {
        invalidateCapture(target.id)
        if undoTarget?.receipt.target.id == target.id { undoTarget = nil }
    }

    private static let observerCallback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let context = Unmanaged<ObserverContext>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated {
            context.owner?.observedChange(for: context.targetID)
        }
    }

    private func makeObserver(for target: TargetHandle) -> ObserverRegistration? {
        var observer: AXObserver?
        guard AXObserverCreate(target.processID, Self.observerCallback, &observer) == .success,
              let observer else { return nil }
        let context = ObserverContext(owner: self, targetID: target.id)
        let refcon = Unmanaged.passUnretained(context).toOpaque()
        let notifications: [(AXUIElement, CFString)] = [
            (target.application, kAXFocusedUIElementChangedNotification as CFString),
            (target.element, kAXSelectedTextChangedNotification as CFString),
            (target.element, kAXValueChangedNotification as CFString)
        ]
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
        guard let processID = activatedProcessID else {
            invalidateCapture(targetID)
            return
        }
        guard processID == targetProcessID || processID == ProcessInfo.processInfo.processIdentifier else {
            invalidateCapture(targetID)
            return
        }
    }

    private func removeWorkspaceObserver() {
        guard let workspaceObserver else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        self.workspaceObserver = nil
    }

    private func observedChange(for targetID: UUID) {
        invalidateCapture(targetID)
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

    private func invalidateCapture(_ targetID: UUID) {
        clearCapture(for: targetID)
        if undoTarget?.receipt.target.id == targetID { undoTarget = nil }
    }

    private func requireSafeForeground(_ target: TargetHandle) throws {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            throw ImrseError.staleSelection
        }
        let processID = frontmostApplication.processIdentifier
        guard processID == ProcessInfo.processInfo.processIdentifier
                || (processID == target.processID && (frontmostApplication.bundleIdentifier ?? "pid:\(processID)") == target.applicationID)
        else { throw ImrseError.staleSelection }
    }

    private func requireTargetForeground(_ target: TargetHandle) throws {
        guard target.processID != ProcessInfo.processInfo.processIdentifier,
              let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              frontmostApplication.processIdentifier == target.processID,
              (frontmostApplication.bundleIdentifier ?? "pid:\(target.processID)") == target.applicationID
        else {
            throw ImrseError.staleSelection
        }
    }

    private func currentSelection(_ target: TargetHandle, allowingEmpty: Bool = false) throws -> NativeSelection {
        try validateSelectionTarget(target)
        guard let selection = try readSelection(target, allowingEmpty: allowingEmpty) else {
            throw ImrseError.staleSelection
        }
        return selection
    }

    private func validateSelectionTarget(_ target: TargetHandle) throws {
        guard Self.accessibilityPermissionGranted else { throw ImrseError.permissionRequired }
        guard !IsSecureEventInputEnabled(), try !isSecure(target.element, in: target.application) else {
            throw ImrseError.secureInput
        }
        try requireSafeForeground(target)
        guard let focused = try elementAttribute(target.application, kAXFocusedUIElementAttribute, failure: .targetLost),
              sameElement(focused, target.element)
        else {
            throw ImrseError.staleSelection
        }
        guard try stringAttribute(target.element, kAXRoleAttribute, failure: .targetLost) == target.role else {
            throw ImrseError.staleSelection
        }
    }

    private func readSelection(_ target: TargetHandle, allowingEmpty: Bool) throws -> NativeSelection? {
        guard let range = try rangeAttribute(target.element, kAXSelectedTextRangeAttribute, failure: .targetLost),
              isValidRangeArithmetic(range),
              (allowingEmpty || range.length > 0),
              let text = try selectedText(
                target.element,
                range: range,
                failure: .targetLost,
                allowingEmpty: allowingEmpty,
                allowValueFallback: supportsPlainTextValueReplacement(target.element, role: target.role)
              ),
              text.utf16.count == range.length
        else {
            return nil
        }
        return NativeSelection(text: text, range: range)
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
        focusedSelection: NativeSelection
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

        var selectedTextFallbackBaseline: String?
        var selectedTextNoOpValidated = false
        if before.range == range, sameText(before.text, expectedText),
           try attributeIsSettable(target.element, kAXSelectedTextAttribute) {
            let current = try currentSelection(target, allowingEmpty: true)
            guard sameSelection(current, before) else {
                throw ImrseError.staleSelection
            }
            if let oldValue {
                guard let currentValue = try wholeValue(target.element, failure: .replacementFailed),
                      sameText(currentValue, oldValue)
                else {
                    throw ImrseError.staleSelection
                }
            }
            if clipboardFallbackEnabled {
                selectedTextFallbackBaseline = ClipboardFallbackNoOpValidation.baseline(
                    value: oldValue ?? (try? wholeValue(target.element, failure: .replacementFailed)),
                    range: range,
                    selectedText: expectedText
                )
            }
            let status = try setAttribute(target.element, kAXSelectedTextAttribute, value: replacement as CFString)
            guard status == .success else {
                invalidateAfterUnverifiedWrite(target.id)
                throw ImrseError.replacementFailed
            }
            let after: NativeSelection
            let afterValue: String?
            do {
                after = try currentSelection(target, allowingEmpty: true)
                if clipboardFallbackEnabled, selectedTextFallbackBaseline != nil {
                    afterValue = try? wholeValue(target.element, failure: .replacementFailed)
                } else if !clipboardFallbackEnabled, allowsWholeValueWrite {
                    afterValue = try wholeValue(target.element, failure: .replacementFailed)
                } else {
                    afterValue = nil
                }
            } catch {
                invalidateAfterUnverifiedWrite(target.id)
                throw ImrseError.replacementFailed
            }
            if SelectedTextReplacementValidation.confirms(
                afterValue: afterValue,
                expectedValue: expectedValue,
                afterRange: after.range,
                afterText: after.text,
                replacementRange: replacementRange,
                replacement: replacement
            ) {
                return AppliedReplacement(strategy: .selectedText, focusedSelection: after)
            }
            if UTF16SelectionRange.isCollapsedCaret(
                after.range,
                selectedText: after.text,
                atEndOf: replacementRange
            ) {
                do {
                    guard let rangeText = try stringForRange(
                        target.element,
                        range: replacementRange,
                        failure: .replacementFailed
                    ), sameText(rangeText, replacement) else {
                        throw ImrseError.replacementFailed
                    }
                    let verifiedSelection = try currentSelection(target, allowingEmpty: true)
                    guard sameSelection(verifiedSelection, after) else {
                        throw ImrseError.replacementFailed
                    }
                    return AppliedReplacement(strategy: .selectedText, focusedSelection: verifiedSelection)
                } catch {
                    invalidateAfterUnverifiedWrite(target.id)
                    throw ImrseError.replacementFailed
                }
            }
            if clipboardFallbackEnabled,
               let selectedTextFallbackBaseline,
               let afterValue,
               after.range == before.range,
               sameText(after.text, before.text),
               sameText(afterValue, selectedTextFallbackBaseline) {
                do {
                    try requireTargetForeground(target)
                    let recheckedSelection = try currentSelection(target, allowingEmpty: true)
                    guard let recheckedValue = try wholeValue(target.element, failure: .replacementFailed),
                          ClipboardFallbackNoOpValidation.permits(
                            enabled: clipboardFallbackEnabled,
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
                    selectedTextNoOpValidated = true
                } catch {
                    invalidateAfterUnverifiedWrite(target.id)
                    throw ImrseError.replacementFailed
                }
            } else {
                invalidateAfterUnverifiedWrite(target.id)
                throw ImrseError.replacementFailed
            }
        }

        if !selectedTextNoOpValidated,
           allowsWholeValueWrite,
           let oldValue,
           let expectedValue,
           try attributeIsSettable(target.element, kAXValueAttribute) {
            let stillCurrent = try currentSelection(target, allowingEmpty: true)
            guard sameSelection(stillCurrent, before),
                  let currentValue = try wholeValue(target.element, failure: .replacementFailed),
                  sameText(currentValue, oldValue)
            else {
                throw ImrseError.staleSelection
            }
            let status = try setAttribute(target.element, kAXValueAttribute, value: expectedValue as CFString)
            guard status == .success else {
                invalidateAfterUnverifiedWrite(target.id)
                throw ImrseError.replacementFailed
            }
            let afterValue: String
            do {
                guard let value = try wholeValue(target.element, failure: .replacementFailed) else {
                    throw ImrseError.replacementFailed
                }
                afterValue = value
            } catch {
                invalidateAfterUnverifiedWrite(target.id)
                throw ImrseError.replacementFailed
            }
            if sameText(afterValue, expectedValue) {
                let after: NativeSelection
                do {
                    after = try currentSelection(target, allowingEmpty: true)
                } catch {
                    invalidateAfterUnverifiedWrite(target.id)
                    throw ImrseError.replacementFailed
                }
                return AppliedReplacement(strategy: .valueRange, focusedSelection: after)
            }
            invalidateAfterUnverifiedWrite(target.id)
            throw ImrseError.replacementFailed
        }

        guard clipboardFallbackEnabled, before.range == range, sameText(before.text, expectedText) else {
            throw ImrseError.replacementFailed
        }
        guard let prepareForClipboardPaste else { throw ImrseError.clipboardFailed }
        try requireTargetForeground(target)
        guard clipboardFallbackTargetIsEligible(target) else { throw ImrseError.replacementFailed }
        do {
            try await prepareForClipboardPaste()
        } catch {
            throw ImrseError.clipboardFailed
        }
        let clipboardValue: String
        do {
            try requireTargetForeground(target)
            guard clipboardFallbackTargetIsEligible(target) else { throw ImrseError.staleSelection }
            let afterPreparation = try currentSelection(target, allowingEmpty: true)
            guard sameSelection(afterPreparation, before),
                  let value = try wholeValue(target.element, failure: .staleSelection),
                  (selectedTextFallbackBaseline ?? oldValue).map({ sameText(value, $0) }) ?? true,
                  let clipboardText = substring(value, range: range),
                  sameText(clipboardText, expectedText)
            else {
                throw ImrseError.staleSelection
            }
            clipboardValue = value
        } catch {
            if selectedTextNoOpValidated { invalidateAfterUnverifiedWrite(target.id) }
            throw error
        }
        guard let clipboardExpectedValue = replacing(clipboardValue, range: range, with: replacement) else {
            throw ImrseError.staleSelection
        }
        let afterPaste = try await paste(
            replacement,
            to: target,
            replacing: expectedText,
            at: range,
            expectedSelection: before,
            oldValue: clipboardValue,
            expectedValue: clipboardExpectedValue
        )
        return AppliedReplacement(strategy: .clipboard, focusedSelection: afterPaste)
    }

    private func invalidateAfterUnverifiedWrite(_ targetID: UUID) {
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
        expectedValue: String
    ) async throws -> NativeSelection {
        guard Self.eventPostingPermissionGranted else { throw ImrseError.permissionRequired }
        try requireTargetForeground(target)
        guard clipboardFallbackTargetIsEligible(target) else { throw ImrseError.staleSelection }
        let pasteboard = NSPasteboard.general
        var transaction = try ClipboardPasteboardTransaction.capture(from: pasteboard)
        do {
            try requireTargetForeground(target)
            guard clipboardFallbackTargetIsEligible(target) else { throw ImrseError.staleSelection }
            try transaction.stage(text, on: pasteboard)
            guard transaction.stillOwns(pasteboard) else { throw ImrseError.clipboardFailed }

            try requireTargetForeground(target)
            guard clipboardFallbackTargetIsEligible(target) else { throw ImrseError.staleSelection }
            let current = try currentSelection(target)
            guard current.range == range,
                  sameText(current.text, expectedText),
                  let currentValue = try wholeValue(target.element, failure: .staleSelection),
                  sameText(currentValue, oldValue),
                  transaction.stillOwns(pasteboard)
            else {
                throw ImrseError.staleSelection
            }

            guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
            else {
                throw ImrseError.clipboardFailed
            }
            try requireTargetForeground(target)
            guard clipboardFallbackTargetIsEligible(target) else { throw ImrseError.staleSelection }
            let beforePost = try currentSelection(target)
            guard beforePost.range == range,
                  sameText(beforePost.text, expectedText),
                  let valueBeforePost = try wholeValue(target.element, failure: .staleSelection),
                  sameText(valueBeforePost, oldValue)
            else {
                throw ImrseError.staleSelection
            }
            guard transaction.stillOwns(pasteboard) else { throw ImrseError.clipboardFailed }
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            keyDown.postToPid(target.processID)
            keyUp.postToPid(target.processID)

            guard try await waitForValue(expectedValue, in: target.element) else {
                throw ImrseError.replacementFailed
            }
            let after = try currentSelection(target, allowingEmpty: true)
            _ = try transaction.restoreIfOwned(on: pasteboard)
            return after
        } catch {
            do {
                _ = try transaction.restoreIfOwned(on: pasteboard)
            } catch {
                invalidateAfterUnverifiedWrite(target.id)
                throw ImrseError.clipboardFailed
            }
            throw error
        }
    }

    private func waitForValue(_ expectedValue: String, in element: AXUIElement) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(500))
        while true {
            guard let current = try wholeValue(element, failure: .replacementFailed) else {
                throw ImrseError.replacementFailed
            }
            if sameText(current, expectedValue) { return true }
            guard clock.now < deadline else { return false }
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

    private func clipboardFallbackTargetIsEligible(_ target: TargetHandle) -> Bool {
        ClipboardTargetStructureValidation.permits(
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

    private func elementChildren(_ element: AXUIElement, failure: ImrseError) throws -> [AXUIElement] {
        try configureAXMessaging(element)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        guard status == .success,
              let value,
              CFGetTypeID(value) == CFArrayGetTypeID(),
              CFArrayGetCount(unsafeDowncast(value, to: CFArray.self)) <= 1,
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
        guard status == .success else { throw ImrseError.replacementFailed }
        return settable.boolValue
    }

    private func setAttribute(_ element: AXUIElement, _ attribute: String, value: CFTypeRef) throws -> AXError {
        try configureAXMessaging(element)
        return AXUIElementSetAttributeValue(element, attribute as CFString, value)
    }

    private func configureAXMessaging(_ element: AXUIElement) throws {
        if let captureDeadline, clock.now >= captureDeadline { throw ImrseError.targetLost }
        guard AXUIElementSetMessagingTimeout(element, Self.axMessagingTimeout) == .success else {
            throw ImrseError.targetLost
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
        guard status == .success, let value, let result = value as? String else { throw failure }
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
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { throw failure }
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
        guard status == .success, let value, let result = value as? String else { throw failure }
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
        guard status == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { throw failure }
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
        guard status == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { throw failure }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { throw failure }
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
        guard status == .success,
              let value,
              CFGetTypeID(value) == CFBooleanGetTypeID(),
              let result = value as? Bool
        else {
            throw failure
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

    private func substring(_ value: String, range: TextRange) -> String? {
        UTF16SelectionRange.substring(value, range: range)
    }

    private func replacing(_ value: String, range: TextRange, with replacement: String) -> String? {
        UTF16SelectionRange.replacing(value, range: range, with: replacement)
    }
}
#endif
