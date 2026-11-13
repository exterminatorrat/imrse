import ApplicationServices
import Foundation
import ImrseCore

enum DocumentBindingProbe {
    static let maximumURLValueUTF16Length = 4_096

    enum Value: Equatable {
        case string([UInt16])
        case url([UInt16])
    }

    struct URLSample: Equatable {
        let read: DocumentBindingDiagnostic.URLRead
        let value: Value?

        init(read: DocumentBindingDiagnostic.URLRead, value: Value? = nil) {
            self.read = read
            self.value = value
        }
    }

    struct Observation<Element> {
        let result: DocumentBindingDiagnostic.AncestorResult
        let depth: Int?
        let candidate: Element?

        init(
            result: DocumentBindingDiagnostic.AncestorResult,
            depth: Int? = nil,
            candidate: Element? = nil
        ) {
            self.result = result
            self.depth = depth
            self.candidate = candidate
        }
    }

    struct Snapshot<Element> {
        let processID: Int32
        let window: Element
        let editor: Element
        let webArea: Element?
        let value: Value?
    }

    private enum CandidateInspection<Element> {
        case found(Element)
        case skipped
        case failed(DocumentBindingDiagnostic.AncestorResult)
    }

    static func observe<Element>(
        editor: Element,
        window: Element,
        hasTimeForProbe: () -> Bool,
        isSameProcess: (Element) -> Bool,
        readParent: (Element) throws -> Element?,
        readRole: (Element) throws -> String?,
        readWindow: (Element) throws -> Element?,
        sameElement: (Element, Element) -> Bool
    ) -> Observation<Element> {
        guard hasTimeForProbe() else { return Observation(result: .timeLimitReached) }
        guard isSameProcess(editor) else { return Observation(result: .inconsistentProcess) }
        guard !sameElement(editor, window) else { return Observation(result: .notFound) }

        switch inspection(
            of: editor,
            window: window,
            hasTimeForProbe: hasTimeForProbe,
            isSameProcess: isSameProcess,
            readRole: readRole,
            readWindow: readWindow,
            sameElement: sameElement
        ) {
        case let .found(found):
            return Observation(result: .foundWebArea, depth: 0, candidate: found)
        case let .failed(result):
            return Observation(result: result)
        case .skipped:
            break
        }

        var current = editor
        var visited = [editor]
        var depth = 0
        while depth < DocumentBindingDiagnostic.maximumAncestorDepth {
            guard hasTimeForProbe() else { return Observation(result: .timeLimitReached) }
            let parent: Element?
            do {
                parent = try readParent(current)
            } catch {
                return Observation(result: .readFailed)
            }
            guard let parent else { return Observation(result: .notFound) }
            guard isSameProcess(parent) else { return Observation(result: .inconsistentProcess) }
            guard !visited.contains(where: { sameElement($0, parent) }) else {
                return Observation(result: .cycleDetected)
            }
            visited.append(parent)
            depth += 1
            guard !sameElement(parent, window) else { return Observation(result: .notFound) }
            switch inspection(
                of: parent,
                window: window,
                hasTimeForProbe: hasTimeForProbe,
                isSameProcess: isSameProcess,
                readRole: readRole,
                readWindow: readWindow,
                sameElement: sameElement
            ) {
            case let .found(found):
                return Observation(result: .foundWebArea, depth: depth, candidate: found)
            case let .failed(result):
                return Observation(result: result)
            case .skipped:
                current = parent
            }
        }
        return Observation(result: .depthLimitReached)
    }

    static func urlSample(status: AXError, value: CFTypeRef?) -> URLSample {
        if status == .attributeUnsupported { return URLSample(read: .unsupported) }
        if status == .noValue {
            return URLSample(read: value == nil ? .noValue : .unexpectedNoValuePayload)
        }
        guard status == .success else { return URLSample(read: .readFailed) }
        guard let value else { return URLSample(read: .missingValue) }
        if CFGetTypeID(value) == CFURLGetTypeID() {
            let absolute = (unsafeDowncast(value, to: CFURL.self) as NSURL).absoluteString ?? ""
            guard !absolute.isEmpty else { return URLSample(read: .emptyURL) }
            guard let units = boundedUnits(absolute) else { return URLSample(read: .valueTooLong) }
            return URLSample(read: .nonemptyURL, value: .url(units))
        }
        guard let string = value as? String else { return URLSample(read: .unexpectedType) }
        guard !string.isEmpty else { return URLSample(read: .emptyString) }
        guard let units = boundedUnits(string) else { return URLSample(read: .valueTooLong) }
        return URLSample(read: .nonemptyString, value: .string(units))
    }

    static func comparison<Element>(
        previous: Snapshot<Element>?,
        current: Snapshot<Element>,
        sameElement: (Element, Element) -> Bool
    ) -> DocumentBindingDiagnostic.Comparison? {
        guard let previous, previous.processID == current.processID else { return nil }
        let webAreaUnchanged: Bool?
        if let previousWebArea = previous.webArea, let currentWebArea = current.webArea {
            webAreaUnchanged = sameElement(previousWebArea, currentWebArea)
        } else {
            webAreaUnchanged = nil
        }
        let urlUnchanged: Bool?
        if let previousValue = previous.value, let currentValue = current.value {
            urlUnchanged = previousValue == currentValue
        } else {
            urlUnchanged = nil
        }
        return DocumentBindingDiagnostic.Comparison(
            windowUnchanged: sameElement(previous.window, current.window),
            editorUnchanged: sameElement(previous.editor, current.editor),
            webAreaUnchanged: webAreaUnchanged,
            urlUnchanged: urlUnchanged
        )
    }

    private static func inspection<Element>(
        of element: Element,
        window: Element,
        hasTimeForProbe: () -> Bool,
        isSameProcess: (Element) -> Bool,
        readRole: (Element) throws -> String?,
        readWindow: (Element) throws -> Element?,
        sameElement: (Element, Element) -> Bool
    ) -> CandidateInspection<Element> {
        guard hasTimeForProbe() else { return .failed(.timeLimitReached) }
        let role: String?
        do {
            role = try readRole(element)
        } catch {
            return .failed(.readFailed)
        }
        guard let role else { return .failed(.readFailed) }
        guard role == "AXWebArea" else { return .skipped }
        let ownWindow: Element?
        do {
            ownWindow = try readWindow(element)
        } catch {
            return .failed(.readFailed)
        }
        guard let ownWindow else { return .failed(.inconsistentWindow) }
        guard isSameProcess(ownWindow) else { return .failed(.inconsistentProcess) }
        guard sameElement(ownWindow, window) else { return .failed(.inconsistentWindow) }
        return .found(element)
    }

    static func snapshotAfterCapture<Element>(
        _ previous: Snapshot<Element>?,
        diagnostic: DocumentBindingDiagnostic?
    ) -> Snapshot<Element>? {
        diagnostic == nil ? nil : previous
    }

    private static func boundedUnits(_ value: String) -> [UInt16]? {
        let units = Array(value.utf16.prefix(maximumURLValueUTF16Length + 1))
        guard units.count <= maximumURLValueUTF16Length else { return nil }
        return units
    }
}
