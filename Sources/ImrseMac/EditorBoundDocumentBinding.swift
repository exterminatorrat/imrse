import ImrseCore

enum EditorBoundDocumentBinding {
    struct Binding<Element> {
        let editor: Element
        let webArea: Element
        let url: DocumentBindingProbe.Value
    }

    enum WindowDocumentState: Equatable {
        case empty
        case populated
        case unavailable
        case refused
        case readFailed
    }

    static func isEligible(documentFailure: DocumentContextFailure?) -> Bool {
        documentFailure == .emptyValue
    }

    static func windowDocumentState(
        read: SelectionTargetContextValidation.DocumentRead,
        failure: DocumentContextFailure?
    ) -> WindowDocumentState {
        switch read {
        case .context(.unavailable):
            return .unavailable
        case .context(.value):
            return .populated
        case .context(.malformed):
            return .refused
        case .failed(.documentContextUnavailable):
            return failure == .emptyValue ? .empty : .refused
        case .failed:
            return .readFailed
        }
    }

    static func captureResolution<Element>(
        intent: SelectionEditIntent,
        documentFailure: DocumentContextFailure?,
        resolve: () -> Binding<Element>?,
        observe: () -> Void
    ) -> Binding<Element>? {
        guard intent == .replaceSelection,
              isEligible(documentFailure: documentFailure),
              let binding = resolve()
        else {
            observe()
            return nil
        }
        return binding
    }

    static func resolve<Element>(
        editor: Element,
        window: Element,
        intent: SelectionEditIntent,
        hasTimeForProbe: () -> Bool,
        isSameProcess: (Element) -> Bool,
        readParent: (Element) throws -> Element?,
        readRole: (Element) throws -> String?,
        readWindow: (Element) throws -> Element?,
        readURL: (Element) -> DocumentBindingProbe.URLSample,
        sameElement: (Element, Element) -> Bool
    ) -> Binding<Element>? {
        guard intent == .replaceSelection else { return nil }
        let observation = DocumentBindingProbe.nearestWebAreaAncestor(
            from: editor,
            window: window,
            hasTimeForProbe: hasTimeForProbe,
            isSameProcess: isSameProcess,
            readParent: readParent,
            readRole: readRole,
            readWindow: readWindow,
            sameElement: sameElement
        )
        guard observation.result == .foundWebArea,
              let webArea = observation.candidate,
              let url = readURL(webArea).value
        else { return nil }
        return Binding(editor: editor, webArea: webArea, url: url)
    }

    static func failureReason<Element>(
        binding: Binding<Element>,
        currentEditor: Element,
        capturedWindow: Element,
        currentWindow: Element?,
        intent: SelectionEditIntent,
        sameElement: (Element, Element) -> Bool,
        isValidWindow: (Element) throws -> Bool,
        readWindowDocumentState: () -> WindowDocumentState,
        hasTimeForProbe: () -> Bool,
        isSameProcess: (Element) -> Bool,
        readParent: (Element) throws -> Element?,
        readRole: (Element) throws -> String?,
        readWindow: (Element) throws -> Element?,
        readURL: (Element) -> DocumentBindingProbe.URLSample
    ) throws -> SelectionFailureReason? {
        guard intent == .replaceSelection else { return .caretProofUnavailable }
        guard sameElement(currentEditor, binding.editor) else { return .documentContextChanged }
        guard let currentWindow else { return .windowContextUnavailable }
        guard sameElement(capturedWindow, currentWindow), try isValidWindow(currentWindow) else {
            return .windowContextChanged
        }
        switch readWindowDocumentState() {
        case .empty:
            break
        case .populated:
            return .documentContextChanged
        case .unavailable, .refused, .readFailed:
            return .documentContextUnavailable
        }
        let observation = DocumentBindingProbe.nearestWebAreaAncestor(
            from: binding.editor,
            window: capturedWindow,
            hasTimeForProbe: hasTimeForProbe,
            isSameProcess: isSameProcess,
            readParent: readParent,
            readRole: readRole,
            readWindow: readWindow,
            sameElement: sameElement
        )
        guard observation.result == .foundWebArea else { return .documentContextUnavailable }
        guard let webArea = observation.candidate, sameElement(webArea, binding.webArea) else {
            return .documentContextChanged
        }
        guard let url = readURL(webArea).value else { return .documentContextUnavailable }
        guard url == binding.url else { return .documentContextChanged }
        return nil
    }
}
