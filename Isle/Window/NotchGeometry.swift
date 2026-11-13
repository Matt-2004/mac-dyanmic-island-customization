import AppKit

/// Reads notch geometry from an `NSScreen`.
enum NotchGeometry {
    /// Picks the screen the island should live on: the first screen with a
    /// camera housing, otherwise the main screen, otherwise any screen.
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first(where: hasNotch) ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func hasNotch(_ screen: NSScreen) -> Bool {
        screen.safeAreaInsets.top > 0
    }

    /// Notch size from `safeAreaInsets` and the auxiliary top areas (the
    /// menu-bar regions left and right of the camera housing). On screens
    /// without a notch, returns a simulated notch the height of the menu bar.
    static func metrics(for screen: NSScreen) -> NotchMetrics {
        let topInset = screen.safeAreaInsets.top
        if topInset > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            if width > 0 {
                return NotchMetrics(notchSize: CGSize(width: width, height: topInset), hasNotch: true)
            }
        }
        if topInset > 0 {
            // Notched screen that did not report auxiliary areas: use the typical MacBook notch width.
            return NotchMetrics(notchSize: CGSize(width: 185, height: topInset), hasNotch: true)
        }
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        let height = menuBarHeight > 0 ? menuBarHeight : NSStatusBar.system.thickness
        return NotchMetrics(notchSize: CGSize(width: 200, height: height), hasNotch: false)
    }

    /// Panel frame pinned to the top-center of the screen (top edge flush with the screen edge).
    static func panelFrame(for screen: NSScreen, metrics: NotchMetrics) -> NSRect {
        let size = IslandLayout.panelSize(metrics: metrics)
        let frame = screen.frame
        return NSRect(
            x: (frame.midX - size.width / 2).rounded(),
            y: frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// Island rect in screen coordinates for hit testing.
    static func islandRect(for state: IslandState, screen: NSScreen, metrics: NotchMetrics, battery: Bool = false) -> NSRect {
        let size = IslandLayout.size(for: state, metrics: metrics, battery: battery)
        let offset = IslandLayout.centerOffset(for: state, metrics: metrics, battery: battery)
        let frame = screen.frame
        return NSRect(
            x: frame.midX + offset - size.width / 2,
            y: frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }
}
