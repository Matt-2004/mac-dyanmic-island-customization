import AppKit
import IOBluetooth
import CoreBluetooth
import Observation

/// Tracks connected Bluetooth audio devices (AirPods by default) and their batteries.
///
/// - Connection events: `IOBluetoothDevice.register(forConnectNotifications:)`
///   plus a per-device `register(forDisconnectNotification:)`.
/// - Identification: device name, Bluetooth device class, and the paired-device
///   info from system_profiler (vendor 0x004C + Headphones = Apple headphones).
/// - Battery: `system_profiler SPBluetoothDataType -json` on a background queue,
///   once ~2 s after connect, then every 60 s while a device is connected, and
///   on demand when the island expands (throttled). Last values are cached.
/// - Permission: Bluetooth TCC state comes from `CBManager.authorization`.
@Observable
@MainActor
final class BluetoothService: NSObject {
    enum Permission: Equatable {
        case notDetermined
        case allowed
        case denied
    }

    enum Event {
        case connected(AudioDevice)
        case disconnected(AudioDevice)
    }

    private(set) var devices: [AudioDevice] = []
    private(set) var permission: Permission = .notDetermined

    /// Called on main whenever `devices` changes.
    @ObservationIgnored var onDevicesChange: (([AudioDevice]) -> Void)?
    @ObservationIgnored var onEvent: ((Event) -> Void)?
    @ObservationIgnored var onPermissionChange: ((Permission) -> Void)?

    @ObservationIgnored private let reader = BluetoothBatteryReader()
    @ObservationIgnored private var scope: BluetoothScope
    @ObservationIgnored private var connectNotification: IOBluetoothUserNotification?
    @ObservationIgnored private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    @ObservationIgnored private var profilerInfo: [String: BluetoothBatteryReader.DeviceInfo] = [:]
    @ObservationIgnored private var batteryCache: [String: BatteryLevels] = [:]
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var lastBatteryRead: Date?
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var centralManager: CBCentralManager?
    @ObservationIgnored private var started = false

    init(scope: BluetoothScope) {
        self.scope = scope
        super.init()
    }

    // MARK: Lifecycle

    func start() {
        updatePermission()
        switch CBManager.authorization {
        case .notDetermined:
            // Creating a central manager shows the system Bluetooth prompt; the delegate
            // callback continues once the user answers.
            centralManager = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        case .allowedAlways:
            beginMonitoring()
        case .denied, .restricted:
            FileLog.write("bluetooth: permission denied")
        @unknown default:
            beginMonitoring()
        }
    }

    func stop() {
        connectNotification?.unregister()
        connectNotification = nil
        disconnectNotifications.values.forEach { $0.unregister() }
        disconnectNotifications.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
        started = false
    }

    func setScope(_ newScope: BluetoothScope) {
        guard newScope != scope else { return }
        scope = newScope
        guard started else { return }
        rescanConnectedDevices()
    }

    /// Re-reads batteries if the last reading is older than `maxAge` (used when the island expands).
    func refreshBatteryIfStale(maxAge: TimeInterval = 15) {
        guard devices.contains(where: \.isConnected) else { return }
        if let last = lastBatteryRead, Date().timeIntervalSince(last) < maxAge { return }
        readBatteries()
    }

    /// Re-checks permission (e.g. after the user changed it in System Settings) and starts if allowed.
    func recheckPermission() {
        updatePermission()
        if permission == .allowed {
            beginMonitoring()
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Monitoring

    private func beginMonitoring() {
        guard !started else { return }
        started = true
        startedAt = Date()
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:))
        )
        FileLog.write("bluetooth: monitoring started")
        // Learn paired-device info first so already-connected devices are classified correctly.
        reader.read { [weak self] info in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.ingest(info)
                self.rescanConnectedDevices()
            }
        }
    }

    private func rescanConnectedDevices() {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        var updated: [AudioDevice] = []
        for device in paired where device.isConnected() {
            guard let audio = makeAudioDevice(device), isRelevant(device, audio) else { continue }
            watchDisconnect(device)
            updated.append(audio)
        }
        setDevices(updated)
        updatePolling()
        if !updated.isEmpty {
            readBatteries()
        }
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard let address = device.addressString.map(BluetoothAddress.normalize) else { return }
        // The connect notification also fires for devices that were already connected when we registered.
        let isLaunchReplay = Date().timeIntervalSince(startedAt) < 3
        handleConnect(device, address: address, announce: !isLaunchReplay)
    }

    private func handleConnect(_ device: IOBluetoothDevice, address: String, announce: Bool) {
        guard let audio = makeAudioDevice(device) else { return }
        if isRelevant(device, audio) {
            accept(device, audio: audio, announce: announce)
            return
        }
        // Unknown yet (e.g. renamed AirPods): check the paired-device info, then decide.
        guard device.deviceClassMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorAudio) else { return }
        reader.read { [weak self] info in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.ingest(info)
                guard let refreshed = self.makeAudioDevice(device), self.isRelevant(device, refreshed) else { return }
                self.accept(device, audio: refreshed, announce: announce)
            }
        }
    }

    private func accept(_ device: IOBluetoothDevice, audio: AudioDevice, announce: Bool) {
        watchDisconnect(device)
        var list = devices.filter { $0.id != audio.id }
        list.append(audio)
        setDevices(list)
        FileLog.write("bluetooth: connected \(audio.kind)")
        if announce {
            onEvent?(.connected(audio))
        }
        updatePolling()
        // Batteries are usually reported a moment after the link comes up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated { self?.readBatteries() }
        }
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard let address = device.addressString.map(BluetoothAddress.normalize) else { return }
        notification.unregister()
        disconnectNotifications[address] = nil
        guard let known = devices.first(where: { $0.id == address }) else { return }
        setDevices(devices.filter { $0.id != address })
        updatePolling()
        var gone = known
        gone.isConnected = false
        FileLog.write("bluetooth: disconnected \(known.kind)")
        onEvent?(.disconnected(gone))
    }

    private func watchDisconnect(_ device: IOBluetoothDevice) {
        guard let address = device.addressString.map(BluetoothAddress.normalize),
              disconnectNotifications[address] == nil else { return }
        disconnectNotifications[address] = device.register(
            forDisconnectNotification: self,
            selector: #selector(deviceDisconnected(_:device:))
        )
    }

    // MARK: Classification

    private func makeAudioDevice(_ device: IOBluetoothDevice) -> AudioDevice? {
        guard let rawAddress = device.addressString else { return nil }
        let address = BluetoothAddress.normalize(rawAddress)
        let info = profilerInfo[address]
        let name = device.name ?? info?.name ?? "Bluetooth Device"
        return AudioDevice(
            id: address,
            name: name,
            kind: AudioDeviceKind.classify(name: name, minorType: info?.minorType, vendorID: info?.vendorID),
            battery: batteryCache[address],
            isConnected: true
        )
    }

    private func isRelevant(_ device: IOBluetoothDevice, _ audio: AudioDevice) -> Bool {
        switch scope {
        case .airpodsOnly:
            if audio.kind.isAirPods { return true }
            let info = profilerInfo[audio.id]
            return info?.vendorID?.uppercased() == "0X004C" && info?.minorType?.lowercased() == "headphones"
        case .allAudio:
            if device.deviceClassMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorAudio) { return true }
            let minor = profilerInfo[audio.id]?.minorType?.lowercased() ?? ""
            return audio.kind.isAirPods
                || ["headphones", "headset", "speaker", "hifi audio", "portable audio", "loudspeaker", "car audio"]
                    .contains(where: { minor.contains($0) })
        }
    }

    // MARK: Battery

    private func updatePolling() {
        let needsPolling = devices.contains(where: \.isConnected)
        if needsPolling, pollTimer == nil {
            let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.readBatteries() }
            }
            timer.tolerance = 5
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        } else if !needsPolling {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    private func readBatteries() {
        lastBatteryRead = Date()
        reader.read { [weak self] info in
            MainActor.assumeIsolated { self?.ingest(info) }
        }
    }

    private func ingest(_ info: [String: BluetoothBatteryReader.DeviceInfo]) {
        guard !info.isEmpty else { return }
        profilerInfo.merge(info) { _, new in new }
        for (address, device) in info where !device.battery.isEmpty {
            batteryCache[address] = device.battery.merged(over: batteryCache[address])
        }
        let updated = devices.map { existing -> AudioDevice in
            var copy = existing
            copy.battery = batteryCache[existing.id] ?? existing.battery
            if let profiled = info[existing.id] {
                copy.kind = AudioDeviceKind.classify(name: existing.name, minorType: profiled.minorType, vendorID: profiled.vendorID)
            }
            return copy
        }
        setDevices(updated)
    }

    private func setDevices(_ list: [AudioDevice]) {
        guard list != devices else { return }
        devices = list
        onDevicesChange?(list)
    }

    private func updatePermission() {
        let value: Permission
        switch CBManager.authorization {
        case .allowedAlways: value = .allowed
        case .denied, .restricted: value = .denied
        case .notDetermined: value = .notDetermined
        @unknown default: value = .allowed
        }
        guard value != permission else { return }
        permission = value
        onPermissionChange?(value)
    }
}

extension BluetoothService: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            updatePermission()
            if permission == .allowed {
                beginMonitoring()
            }
            centralManager = nil
        }
    }
}
