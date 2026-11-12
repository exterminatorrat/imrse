#if os(macOS)
import Testing
@testable import ImrseMac

@Suite
struct EditableHostResolutionTests {
    @Test
    func keepsTheSameElementPathWhenTheAnchorAdvertisesItself() {
        let anchor = Node()

        anchor.advertises(anchor)

        #expect(host(anchor) == nil)
    }

    @Test
    func resolvesOneStrictAncestorTheAnchorAdvertises() {
        let hostNode = Node()
        let group = Node()
        let anchor = Node(parent: group)

        group.parent = hostNode
        anchor.advertises(hostNode)
        hostNode.advertises(hostNode)

        #expect(host(anchor) === hostNode)
    }

    @Test
    func acceptsNestedEditablesThatAdvertiseTheSameHost() {
        let hostNode = Node()
        let intermediate = Node()
        let anchor = Node(parent: intermediate)

        intermediate.parent = hostNode
        anchor.advertises(hostNode)
        intermediate.advertises(hostNode)
        hostNode.advertises(hostNode)

        #expect(host(anchor) === hostNode)
    }

    @Test
    func refusesAnEditableBetweenTheAnchorAndItsHostThatAdvertisesAnotherNode() {
        let hostNode = Node()
        let otherHost = Node()
        let intermediate = Node()
        let anchor = Node(parent: intermediate)

        intermediate.parent = hostNode
        anchor.advertises(hostNode)
        intermediate.advertises(otherHost)
        hostNode.advertises(hostNode)
        otherHost.advertises(otherHost)

        #expect(host(anchor) == nil)
    }

    @Test
    func refusesAdvertisementsThatDisagree() {
        let hostNode = Node()
        let anchor = Node(parent: hostNode)

        anchor.editableAncestor = hostNode
        anchor.highestEditableAncestor = Node()

        #expect(host(anchor) == nil)
    }

    @Test
    func refusesHostsThatDoNotAdvertiseThemselves() {
        let outer = Node()
        let hostNode = Node()
        let anchor = Node(parent: hostNode)

        hostNode.parent = outer
        anchor.advertises(hostNode)
        hostNode.advertises(outer)
        outer.advertises(outer)

        #expect(host(anchor) == nil)
    }

    @Test
    func refusesAdvertisedNodesOutsideTheParentChain() {
        let foreign = Node()
        let anchor = Node(parent: Node())

        anchor.advertises(foreign)
        foreign.advertises(foreign)

        #expect(host(anchor) == nil)
    }

    @Test
    func refusesMissingAdvertisementsAndUnreadableRelationships() {
        let hostNode = Node()
        let anchor = Node(parent: hostNode)

        anchor.advertises(hostNode)
        hostNode.advertises(hostNode)
        #expect(host(anchor) === hostNode)

        let unreadableAnchor = Node(parent: hostNode)
        unreadableAnchor.advertises(hostNode)
        unreadableAnchor.failsAdvertisementRead = true
        #expect(host(unreadableAnchor) == nil)

        let unreadableParent = Node(parent: hostNode)
        unreadableParent.advertises(hostNode)
        unreadableParent.failsParentRead = true
        #expect(host(unreadableParent) == nil)

        let unrelated = Node(parent: hostNode)
        #expect(host(unrelated) == nil)
    }

    @Test
    func terminatesCyclesInsteadOfRepeatingThem() {
        let foreign = Node()
        let first = Node()
        let second = Node(parent: first)
        let anchor = Node(parent: second)

        first.parent = second
        anchor.advertises(foreign)
        foreign.advertises(foreign)

        #expect(host(anchor) == nil)
    }

    @Test
    func refusesAnchorsOutsideTheTargetProcess() {
        let hostNode = Node()
        let anchor = Node(parent: hostNode)

        anchor.advertises(hostNode)
        hostNode.advertises(hostNode)
        anchor.sharesProcess = false

        #expect(host(anchor) == nil)
    }

    @Test
    func refusesForeignNodesInTheParentChain() {
        let hostNode = Node()
        let intermediate = Node()
        let anchor = Node(parent: intermediate)

        intermediate.parent = hostNode
        anchor.advertises(hostNode)
        hostNode.advertises(hostNode)
        intermediate.sharesProcess = false
        #expect(host(anchor) == nil)

        intermediate.sharesProcess = true
        hostNode.sharesProcess = false
        #expect(host(anchor) == nil)
    }

    @Test
    func refusesOneSidedAdvertisements() {
        let hostNode = Node()
        let intermediate = Node()
        let anchor = Node(parent: intermediate)

        intermediate.parent = hostNode
        anchor.advertises(hostNode)
        hostNode.advertises(hostNode)
        intermediate.editableAncestor = hostNode
        #expect(host(anchor) == nil)

        intermediate.editableAncestor = nil
        intermediate.highestEditableAncestor = hostNode
        #expect(host(anchor) == nil)

        intermediate.highestEditableAncestor = nil
        #expect(host(anchor) === hostNode)

        hostNode.highestEditableAncestor = nil
        #expect(host(anchor) == nil)
    }

    @Test
    func refusesWhenNoProbeTimeRemains() {
        let hostNode = Node()
        let anchor = Node(parent: hostNode)

        anchor.advertises(hostNode)
        hostNode.advertises(hostNode)

        #expect(host(anchor, hasTime: false) == nil)
    }

    @Test
    func boundsTheAncestorSearch() {
        let withinBudget = chain(depth: EditableHostResolution.maximumAncestorDepth)
        let anchor = withinBudget.anchor
        anchor.advertises(withinBudget.host)
        withinBudget.host.advertises(withinBudget.host)

        #expect(host(anchor) === withinBudget.host)

        let beyondBudget = chain(depth: EditableHostResolution.maximumAncestorDepth + 1)
        let deepAnchor = beyondBudget.anchor
        deepAnchor.advertises(beyondBudget.host)
        beyondBudget.host.advertises(beyondBudget.host)

        #expect(host(deepAnchor) == nil)
    }

    private func chain(depth: Int) -> (anchor: Node, host: Node) {
        let hostNode = Node()
        var parent = hostNode
        for _ in 1..<depth {
            let node = Node(parent: parent)
            parent = node
        }
        return (Node(parent: parent), hostNode)
    }

    private func host(_ anchor: Node, hasTime: Bool = true) -> Node? {
        EditableHostResolution.host(
            anchor: anchor,
            hasTimeForProbe: { hasTime },
            isSameProcess: { $0.sharesProcess },
            readParent: { node in
                guard !node.failsParentRead else { throw ReadError.unavailable }
                return node.parent
            },
            readEditableAncestor: { node in
                guard !node.failsAdvertisementRead else { throw ReadError.unavailable }
                return node.editableAncestor
            },
            readHighestEditableAncestor: { node in
                guard !node.failsAdvertisementRead else { throw ReadError.unavailable }
                return node.highestEditableAncestor
            },
            sameElement: { $0 === $1 }
        )
    }

    private enum ReadError: Error {
        case unavailable
    }

    private final class Node {
        var parent: Node?
        var editableAncestor: Node?
        var highestEditableAncestor: Node?
        var sharesProcess = true
        var failsParentRead = false
        var failsAdvertisementRead = false

        init(parent: Node? = nil) {
            self.parent = parent
        }

        func advertises(_ host: Node) {
            editableAncestor = host
            highestEditableAncestor = host
        }
    }
}
#endif
