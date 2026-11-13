import Foundation

/// Paired-device info and battery levels from `system_profiler SPBluetoothDataType -json`.
/// Always runs on a private background queue; results are delivered on the main queue.
final class BluetoothBatteryReader {
    struct DeviceInfo: Equatable {
        var name: String
        var address: String
        var isConnected: Bool
        var minorType: String?
        var vendorID: String?
        var productID: String?
        var battery: BatteryLevels
    }

    private let queue = DispatchQueue(label: "com.wai.Isle.system-profiler", qos: .utility)
    private var running = false
    private var pendingCompletions: [([String: DeviceInfo]) -> Void] = []

    /// Reads all paired devices keyed by normalised address. Concurrent calls share one run.
    func read(completion: @escaping ([String: DeviceInfo]) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingCompletions.append(completion)
            guard !self.running else { return }
            self.running = true
            let result = Self.runSystemProfiler()
            let completions = self.pendingCompletions
            self.pendingCompletions.removeAll()
            self.running = false
            DispatchQueue.main.async {
                completions.forEach { $0(result) }
            }
        }
    }

    private static func runSystemProfiler() -> [String: DeviceInfo] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            FileLog.write("bluetooth: system_profiler failed to start: \(error.localizedDescription)")
            return [:]
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(data)
    }

    /// Tolerates any missing level: the JSON shape is not documented.
    static func parse(_ data: Data) -> [String: DeviceInfo] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [:] }
        var result: [String: DeviceInfo] = [:]
        for controller in controllers {
            for (section, connected) in [("device_connected", true), ("device_not_connected", false)] {
                let entries = controller[section] as? [[String: Any]] ?? []
                for entry in entries {
                    for (name, value) in entry {
                        guard let info = value as? [String: Any],
                              let rawAddress = info["device_address"] as? String else { continue }
                        let address = BluetoothAddress.normalize(rawAddress)
                        let device = DeviceInfo(
                            name: name,
                            address: address,
                            isConnected: connected,
                            minorType: info["device_minorType"] as? String,
                            vendorID: info["device_vendorID"] as? String,
                            productID: info["device_productID"] as? String,
                            battery: BatteryLevels(
                                left: percent(info["device_batteryLevelLeft"]),
                                right: percent(info["device_batteryLevelRight"]),
                                caseLevel: percent(info["device_batteryLevelCase"]),
                                main: percent(info["device_batteryLevelMain"]) ?? percent(info["device_batteryLevel"])
                            )
                        )
                        // A device can appear in both lists briefly; prefer the connected entry.
                        if result[address]?.isConnected != true {
                            result[address] = device
                        }
                    }
                }
            }
        }
        return result
    }

    private static func percent(_ value: Any?) -> Int? {
        if let number = value as? Int { return (0...100).contains(number) ? number : nil }
        guard let string = value as? String else { return nil }
        let digits = string.filter(\.isNumber)
        guard let number = Int(digits), (0...100).contains(number) else { return nil }
        return number
    }
}
