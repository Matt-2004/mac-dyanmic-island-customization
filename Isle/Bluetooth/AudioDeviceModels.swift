import Foundation

/// Battery levels reported by system_profiler; any field can be missing.
struct BatteryLevels: Equatable {
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    /// Single-battery devices (AirPods Max, most headphones/speakers).
    var main: Int?

    var isEmpty: Bool {
        left == nil && right == nil && caseLevel == nil && main == nil
    }

    /// Keeps previous values for fields missing from a newer reading
    /// (the case level disappears when the case is closed).
    func merged(over older: BatteryLevels?) -> BatteryLevels {
        guard let older else { return self }
        return BatteryLevels(
            left: left ?? older.left,
            right: right ?? older.right,
            caseLevel: caseLevel ?? older.caseLevel,
            main: main ?? older.main
        )
    }

    static func text(_ value: Int?) -> String {
        value.map { "\($0)%" } ?? "--"
    }
}

enum AudioDeviceKind: Equatable {
    case airpods
    case airpodsPro
    case airpodsMax
    case beats
    case headphones
    case speaker

    var symbolName: String {
        switch self {
        case .airpods: return "airpods"
        case .airpodsPro: return "airpodspro"
        case .airpodsMax: return "airpodsmax"
        case .beats: return "beats.headphones"
        case .headphones: return "headphones"
        case .speaker: return "hifispeaker.fill"
        }
    }

    var isAirPods: Bool {
        switch self {
        case .airpods, .airpodsPro, .airpodsMax: return true
        case .beats, .headphones, .speaker: return false
        }
    }

    static func classify(name: String, minorType: String?, vendorID: String?) -> AudioDeviceKind {
        let lower = name.lowercased()
        let isApple = vendorID?.uppercased() == "0X004C"
        if lower.contains("airpods max") { return .airpodsMax }
        if lower.contains("airpods pro") { return .airpodsPro }
        if lower.contains("airpods") { return .airpods }
        if lower.contains("beats") || lower.contains("powerbeats") { return .beats }
        let minor = minorType?.lowercased() ?? ""
        if isApple && minor == "headphones" { return .airpods }
        if minor.contains("speaker") || minor.contains("hifi") || minor.contains("portable audio") {
            return .speaker
        }
        return .headphones
    }
}

struct AudioDevice: Identifiable, Equatable {
    /// Normalised Bluetooth address (uppercase hex, no separators).
    let id: String
    var name: String
    var kind: AudioDeviceKind
    var battery: BatteryLevels?
    var isConnected: Bool
}

struct AirPodsPeekInfo: Equatable {
    var device: AudioDevice
    var connected: Bool
}

enum BluetoothScope: String, CaseIterable, Identifiable {
    case airpodsOnly
    case allAudio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .airpodsOnly: return "AirPods only"
        case .allAudio: return "All audio devices"
        }
    }
}

enum BluetoothAddress {
    static func normalize(_ address: String) -> String {
        address.uppercased().filter { $0.isHexDigit }
    }
}
