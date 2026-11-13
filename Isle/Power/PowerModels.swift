import Foundation

/// Battery state of the Mac's internal battery.
struct PowerSnapshot: Equatable {
    var percent: Int
    var isCharging: Bool
    var isPluggedIn: Bool
    var isCharged: Bool
    /// nil while macOS is still calculating, or when not charging.
    var minutesToFull: Int?
    /// nil while calculating, or when on AC power.
    var minutesToEmpty: Int?
    /// The charger was just connected and macOS hasn't switched to "charging" yet (it takes a
    /// few seconds). Shown as "Charging…" instead of "not charging".
    var isStartingToCharge = false

    /// Draw the battery as charging (green + bolt) as soon as the charger is connected, like
    /// the macOS menu bar. macOS reports "plugged in" at once but "charging" only a few
    /// seconds later (and never while charging is paused or limited).
    var showsChargingStyle: Bool { isPluggedIn }

    /// ", charging" / ", plugged in" / "" for accessibility labels.
    var chargeDescription: String {
        isCharging || isStartingToCharge ? ", charging" : (isPluggedIn ? ", plugged in" : "")
    }

    /// "Charging, 1h 20m to full", "Fully charged", "Unplugged", …
    var statusText: String {
        if isPluggedIn {
            if isCharged || percent >= 100 { return "Fully charged" }
            if isCharging {
                if let minutes = minutesToFull, minutes > 0 {
                    return "Charging, \(Self.duration(minutes)) to full"
                }
                return "Charging"
            }
            if isStartingToCharge { return "Charging…" }
            return "Plugged in, not charging"
        }
        if let minutes = minutesToEmpty, minutes > 0 {
            return "On battery, \(Self.duration(minutes)) left"
        }
        return "On battery"
    }

    static func duration(_ minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        if hours > 0 && mins > 0 { return "\(hours)h \(mins)m" }
        if hours > 0 { return "\(hours)h" }
        return "\(mins)m"
    }
}

enum PowerEvent: Equatable {
    case pluggedIn
    case unplugged
    case fullyCharged
    /// Crossed 20 % or 10 % while unplugged.
    case lowBattery(threshold: Int)

    var title: String {
        switch self {
        case .pluggedIn: return "Charging"
        case .unplugged: return "Unplugged"
        case .fullyCharged: return "Fully Charged"
        case .lowBattery: return "Low Battery"
        }
    }

    var isCritical: Bool {
        if case .lowBattery(let threshold) = self { return threshold <= 10 }
        return false
    }
}
