import CoreGraphics

/// The four visual states of the island.
enum IslandState: String, CaseIterable, Equatable {
    /// Nothing to show: island matches the hardware notch (hidden on displays without one).
    case idle
    /// Music is loaded: small wings on either side of the notch.
    case compact
    /// Full player with artwork, scrubber and controls.
    case expanded
    /// A notification banner temporarily drops out of the notch.
    case peek
    /// Mac charging / unplugged / fully charged / low battery.
    case powerPeek
    /// Bluetooth audio device (AirPods) connected or disconnected.
    case airpodsPeek

    var isPeek: Bool {
        switch self {
        case .peek, .powerPeek, .airpodsPeek: return true
        case .idle, .compact, .expanded: return false
        }
    }

    var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .compact: return "Compact"
        case .expanded: return "Expanded"
        case .peek: return "Notification Peek"
        case .powerPeek: return "Power Peek"
        case .airpodsPeek: return "AirPods Peek"
        }
    }
}

/// Geometry of the notch on the screen the island is attached to.
struct NotchMetrics: Equatable {
    /// Size of the hardware notch, or of the simulated notch on displays without one.
    var notchSize: CGSize
    /// Whether the screen has a real camera housing.
    var hasNotch: Bool

    static let fallback = NotchMetrics(notchSize: CGSize(width: 200, height: 32), hasNotch: false)
}

/// Pure size calculations for each state, shared by the SwiftUI view and the
/// window controller's hit testing so both always agree.
enum IslandLayout {
    static let compactWingWidth: CGFloat = 76
    static let peekExtraHeight: CGFloat = 64
    /// Music block (~152) plus the Devices row.
    static let expandedContentHeight: CGFloat = 186
    static let powerPeekExtraHeight: CGFloat = 48
    static let airpodsPeekExtraHeight: CGFloat = 92
    static let expandedMinWidth: CGFloat = 460
    static let peekMinWidth: CGFloat = 400
    /// Room around the island inside the panel for the drop shadow.
    static let shadowMargin: CGFloat = 24

    static func size(for state: IslandState, metrics: NotchMetrics) -> CGSize {
        let notch = metrics.notchSize
        switch state {
        case .idle:
            return metrics.hasNotch ? notch : CGSize(width: notch.width, height: 0)
        case .compact:
            return CGSize(width: notch.width + compactWingWidth * 2, height: notch.height)
        case .peek:
            return CGSize(
                width: max(peekMinWidth, notch.width + 160),
                height: notch.height + peekExtraHeight
            )
        case .expanded:
            return CGSize(
                width: max(expandedMinWidth, notch.width + 200),
                height: notch.height + expandedContentHeight
            )
        case .powerPeek:
            return CGSize(
                width: max(340, notch.width + 160),
                height: notch.height + powerPeekExtraHeight
            )
        case .airpodsPeek:
            return CGSize(
                width: max(400, notch.width + 200),
                height: notch.height + airpodsPeekExtraHeight
            )
        }
    }

    /// Size of the transparent panel: big enough for the largest state plus shadow.
    static func panelSize(metrics: NotchMetrics) -> CGSize {
        let largest = IslandState.allCases
            .map { size(for: $0, metrics: metrics) }
            .reduce(CGSize.zero) { CGSize(width: max($0.width, $1.width), height: max($0.height, $1.height)) }
        return CGSize(width: largest.width + shadowMargin * 2, height: largest.height + shadowMargin)
    }

    /// Bottom corner radius per state.
    static func bottomRadius(for state: IslandState, metrics: NotchMetrics) -> CGFloat {
        switch state {
        case .idle, .compact: return min(10, metrics.notchSize.height / 2)
        case .peek, .powerPeek, .airpodsPeek: return 22
        case .expanded: return 30
        }
    }

    /// Outward flare at the top corners that blends the island into the menu bar edge.
    static func topRadius(for state: IslandState) -> CGFloat {
        switch state {
        case .idle, .compact: return 6
        case .peek, .powerPeek, .airpodsPeek, .expanded: return 12
        }
    }
}
