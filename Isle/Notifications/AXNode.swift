import ApplicationServices
import CoreGraphics

/// Plain-value snapshot of an accessibility element and its subtree.
///
/// The banner parser works on snapshots instead of live `AXUIElement`s so it can be
/// unit-tested with fixtures built from `ax-dump.txt`, and so each scan reads every
/// attribute exactly once.
struct AXNode {
    var role: String?
    var subrole: String?
    var identifier: String?
    var title: String?
    var descriptionText: String?
    var value: String?
    var frame: CGRect?
    var actions: [String]
    var children: [AXNode]
    /// The live element (nil in tests). Used only to perform actions such as closing a banner.
    var element: AXUIElement?

    init(
        role: String? = nil,
        subrole: String? = nil,
        identifier: String? = nil,
        title: String? = nil,
        descriptionText: String? = nil,
        value: String? = nil,
        frame: CGRect? = nil,
        actions: [String] = [],
        children: [AXNode] = [],
        element: AXUIElement? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.title = title
        self.descriptionText = descriptionText
        self.value = value
        self.frame = frame
        self.actions = actions
        self.children = children
        self.element = element
    }

    /// Reads `element` and its descendants (bounded by depth and node count).
    static func capture(_ element: AXUIElement, maxDepth: Int = 16, maxNodes: Int = 1500) -> AXNode {
        var budget = maxNodes
        return capture(element, depth: 0, maxDepth: maxDepth, budget: &budget)
    }

    private static func capture(_ element: AXUIElement, depth: Int, maxDepth: Int, budget: inout Int) -> AXNode {
        budget -= 1
        var node = AXNode(
            role: AX.role(element),
            subrole: AX.subrole(element),
            identifier: AX.identifier(element),
            title: AX.string(element, kAXTitleAttribute),
            descriptionText: AX.string(element, kAXDescriptionAttribute),
            value: AX.string(element, kAXValueAttribute),
            frame: AX.frame(element),
            actions: [],
            children: [],
            element: element
        )
        // Actions are only needed on banners (to close them); reading them everywhere is wasted IPC.
        if let subrole = node.subrole, subrole.hasPrefix("AXNotificationCenter") {
            node.actions = AX.actions(element)
        }
        guard depth < maxDepth else { return node }
        for child in AX.children(element) {
            guard budget > 0 else { break }
            node.children.append(capture(child, depth: depth + 1, maxDepth: maxDepth, budget: &budget))
        }
        return node
    }

    /// Depth-first search.
    func first(where predicate: (AXNode) -> Bool) -> AXNode? {
        for child in children {
            if predicate(child) { return child }
            if let found = child.first(where: predicate) { return found }
        }
        return nil
    }
}
