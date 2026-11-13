import AppKit
import CoreGraphics

/// The hand signs Isle recognizes, and the app each one opens.
enum HandGesture: String, CaseIterable, Equatable {
    /// ☝️ index finger only.
    case one
    /// ✌️ index + middle finger.
    case two
    /// 🖐️ open hand (all four fingers; the thumb is not required).
    case open

    var emoji: String {
        switch self {
        case .one: return "☝️"
        case .two: return "✌️"
        case .open: return "🖐️"
        }
    }

    var target: GestureTarget {
        switch self {
        case .one: return GestureTarget(name: "VS Code", bundleIdentifiers: ["com.microsoft.VSCode"])
        case .two: return GestureTarget(name: "Terminal", bundleIdentifiers: ["com.apple.Terminal"])
        case .open: return GestureTarget(name: "Teams", bundleIdentifiers: ["com.microsoft.teams2", "com.microsoft.teams"])
        }
    }

    /// A finger counts as extended when its tip is clearly farther from the wrist than its
    /// middle (PIP) joint. A curled finger folds the tip back toward the palm.
    static let extensionRatio: CGFloat = 1.2

    /// Classifies normalized hand points. Arrays are ordered index, middle, ring, little;
    /// nil means Vision wasn't confident about that joint.
    static func classify(wrist: CGPoint?, tips: [CGPoint?], pips: [CGPoint?]) -> HandGesture? {
        guard let wrist, tips.count == 4, pips.count == 4 else { return nil }
        let extended: [Bool?] = (0..<4).map { index in
            guard let tip = tips[index], let pip = pips[index] else { return nil }
            let pipDistance = hypot(pip.x - wrist.x, pip.y - wrist.y)
            guard pipDistance > 0.001 else { return nil }
            return hypot(tip.x - wrist.x, tip.y - wrist.y) / pipDistance > extensionRatio
        }
        let index = extended[0], middle = extended[1], ring = extended[2], little = extended[3]
        if index == true, middle == true, ring == true, little == true {
            return .open
        }
        // Folded fingers are often partly hidden; an unknown ring/little finger counts as folded.
        let ringDown = ring != true, littleDown = little != true
        if index == true, middle == true, ringDown, littleDown {
            return .two
        }
        if index == true, middle == false, ringDown, littleDown {
            return .one
        }
        return nil
    }
}

struct GestureTarget: Equatable {
    let name: String
    let bundleIdentifiers: [String]

    var applicationURL: URL? {
        for identifier in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                return url
            }
        }
        return nil
    }
}
