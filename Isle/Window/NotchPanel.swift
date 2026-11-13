import AppKit

/// Borderless, transparent, non-activating panel that floats above the menu bar.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .mainMenu + 3
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
    }

    // Never take focus away from the frontmost app.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Allow the panel to sit over the menu bar instead of being pushed below it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
