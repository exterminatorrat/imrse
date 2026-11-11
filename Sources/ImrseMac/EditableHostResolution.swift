enum EditableHostResolution {
    static let maximumAncestorDepth = 16

    static func host<Element>(
        anchor: Element,
        hasTimeForProbe: () -> Bool,
        isSameProcess: (Element) -> Bool,
        readParent: (Element) throws -> Element?,
        readEditableAncestor: (Element) throws -> Element?,
        readHighestEditableAncestor: (Element) throws -> Element?,
        sameElement: (Element, Element) -> Bool
    ) -> Element? {
        guard hasTimeForProbe(),
              isSameProcess(anchor),
              let advertised = try? readEditableAncestor(anchor),
              let highest = try? readHighestEditableAncestor(anchor),
              isSameProcess(advertised),
              isSameProcess(highest),
              sameElement(advertised, highest),
              !sameElement(advertised, anchor)
        else {
            return nil
        }

        var element = anchor
        var visited = [anchor]
        var depth = 0
        while depth < maximumAncestorDepth {
            guard hasTimeForProbe(),
                  let parent = try? readParent(element),
                  isSameProcess(parent),
                  !visited.contains(where: { sameElement($0, parent) })
            else {
                return nil
            }
            visited.append(parent)
            depth += 1
            let isHost = sameElement(parent, advertised)
            guard advertises(
                parent,
                advertised,
                toleratingAbsence: !isHost,
                readEditableAncestor: readEditableAncestor,
                readHighestEditableAncestor: readHighestEditableAncestor,
                sameElement: sameElement
            ) else {
                return nil
            }
            if isHost { return parent }
            element = parent
        }
        return nil
    }

    private static func advertises<Element>(
        _ element: Element,
        _ host: Element,
        toleratingAbsence: Bool,
        readEditableAncestor: (Element) throws -> Element?,
        readHighestEditableAncestor: (Element) throws -> Element?,
        sameElement: (Element, Element) -> Bool
    ) -> Bool {
        do {
            let advertised = try readEditableAncestor(element)
            let highest = try readHighestEditableAncestor(element)
            guard let advertisedValue = advertised, let highestValue = highest else {
                return advertised == nil && highest == nil && toleratingAbsence
            }
            return sameElement(advertisedValue, host) && sameElement(highestValue, host)
        } catch {
            return false
        }
    }
}

enum CaptureSelectionFallback {
    enum Availability: Equatable {
        case present
        case absent
        case malformed
    }

    enum Route: Equatable {
        case captured
        case resolveHost
        case refuse
    }

    enum Agreement: Equatable {
        case agrees
        case rangeMismatch
        case textMismatch
        case malformed
    }

    static func route(range: Availability, text: Availability) -> Route {
        guard range != .malformed, text != .malformed else { return .refuse }
        guard range == .present, text == .present else { return .resolveHost }
        return .captured
    }

    static func anchorAgreement(
        anchorRange: Availability,
        anchorRangeMatchesHost: Bool,
        anchorText: Availability,
        anchorTextMatchesHost: Bool
    ) -> Agreement {
        guard anchorRange != .malformed, anchorText != .malformed else { return .malformed }
        guard anchorRange == .absent || anchorRangeMatchesHost else { return .rangeMismatch }
        guard anchorText == .absent || anchorTextMatchesHost else { return .textMismatch }
        return .agrees
    }
}
