import CoreGraphics

/// The four visual states of the island.
enum IslandState: String, CaseIterable, Equatable {
    /// Nothing to show: island matches the hardware notch (hidden on displays without one).
    case idle
    /// Nothing else to show, but the battery wing sits to the right of the notch.
    case battery
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
    /// Left ⌥ held: the camera is looking for a hand sign.
    case gesture

    var isPeek: Bool {
        switch self {
        case .peek, .powerPeek, .airpodsPeek: return true
        case .idle, .battery, .compact, .expanded, .gesture: return false
        }
    }

    var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .battery: return "Battery"
        case .compact: return "Compact"
        case .expanded: return "Expanded"
        case .peek: return "Notification Peek"
        case .powerPeek: return "Power Peek"
        case .airpodsPeek: return "AirPods Peek"
        case .gesture: return "Hand Gesture"
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
    /// Width of the battery wing to the right of the notch ("100%" + battery icon).
    static let batteryWingWidth: CGFloat = 88
    /// Extra room in the compact right wing when the battery is shown next to the equalizer.
    static let compactBatteryExtra: CGFloat = 46
    static let gestureWingWidth: CGFloat = 96
    static let peekExtraHeight: CGFloat = 64
    /// Music block (~152) plus the Devices row.
    static let expandedContentHeight: CGFloat = 186
    static let powerPeekExtraHeight: CGFloat = 48
    static let airpodsPeekExtraHeight: CGFloat = 92
    static let expandedMinWidth: CGFloat = 460
    static let peekMinWidth: CGFloat = 400
    /// Room around the island inside the panel for the drop shadow.
    static let shadowMargin: CGFloat = 24

    /// `battery`: the battery wing is shown (widens the right side of `.battery` / `.compact`).
    static func size(for state: IslandState, metrics: NotchMetrics, battery: Bool = false) -> CGSize {
        let notch = metrics.notchSize
        switch state {
        case .idle:
            return metrics.hasNotch ? notch : CGSize(width: notch.width, height: 0)
        case .battery:
            return CGSize(width: notch.width + batteryWingWidth, height: notch.height)
        case .compact:
            return CGSize(width: notch.width + compactWingWidth * 2 + (battery ? compactBatteryExtra : 0), height: notch.height)
        case .gesture:
            return CGSize(width: notch.width + gestureWingWidth * 2, height: notch.height)
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

    /// Horizontal shift of the island's center from the notch center. Wings that only grow
    /// to the right (battery) keep the left edge on the notch.
    static func centerOffset(for state: IslandState, metrics: NotchMetrics, battery: Bool = false) -> CGFloat {
        switch state {
        case .battery: return batteryWingWidth / 2
        case .compact: return battery ? compactBatteryExtra / 2 : 0
        case .idle, .expanded, .peek, .powerPeek, .airpodsPeek, .gesture: return 0
        }
    }

    /// Size of the transparent panel: big enough for the largest state (including its
    /// off-center shift) plus shadow.
    static func panelSize(metrics: NotchMetrics) -> CGSize {
        let largest = IslandState.allCases
            .map { state -> CGSize in
                let size = size(for: state, metrics: metrics, battery: true)
                let offset = abs(centerOffset(for: state, metrics: metrics, battery: true))
                return CGSize(width: size.width + offset * 2, height: size.height)
            }
            .reduce(CGSize.zero) { CGSize(width: max($0.width, $1.width), height: max($0.height, $1.height)) }
        return CGSize(width: largest.width + shadowMargin * 2, height: largest.height + shadowMargin)
    }

    /// Bottom corner radius per state.
    static func bottomRadius(for state: IslandState, metrics: NotchMetrics) -> CGFloat {
        switch state {
        case .idle, .battery, .compact, .gesture: return min(10, metrics.notchSize.height / 2)
        case .peek, .powerPeek, .airpodsPeek: return 22
        case .expanded: return 30
        }
    }

    /// Outward flare at the top corners that blends the island into the menu bar edge.
    static func topRadius(for state: IslandState) -> CGFloat {
        switch state {
        case .idle, .battery, .compact, .gesture: return 6
        case .peek, .powerPeek, .airpodsPeek, .expanded: return 12
        }
    }
}
