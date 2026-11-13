import AppKit
import Combine

/// Connects PowerService and BluetoothService to the island: pushes live state into
/// the store, turns events into peeks according to Settings, and refreshes AirPods
/// batteries when the island expands.
@MainActor
final class DevicesCoordinator {
    let power = PowerService()
    let bluetooth: BluetoothService

    private let store: IslandStateStore
    private let settings: AppSettings
    private var onboarding: BluetoothOnboardingWindowController?
    private var cancellables = Set<AnyCancellable>()

    init(store: IslandStateStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        bluetooth = BluetoothService(scope: settings.bluetoothScope)
    }

    func start() {
        power.onChange = { [weak self] snapshot in
            self?.store.updatePower(snapshot)
        }
        power.onEvent = { [weak self] event, snapshot in
            self?.handlePowerEvent(event, snapshot: snapshot)
        }
        power.start()

        bluetooth.onDevicesChange = { [weak self] devices in
            self?.store.updateAudioDevices(devices)
        }
        bluetooth.onEvent = { [weak self] event in
            self?.handleBluetoothEvent(event)
        }
        bluetooth.onPermissionChange = { [weak self] permission in
            self?.handlePermission(permission)
        }
        bluetooth.start()
        handlePermission(bluetooth.permission)

        settings.$bluetoothScope
            .dropFirst()
            .sink { [weak self] scope in self?.bluetooth.setScope(scope) }
            .store(in: &cancellables)

        // Fresh AirPods batteries whenever the user opens the island.
        store.$state
            .removeDuplicates()
            .filter { $0 == .expanded }
            .sink { [weak self] _ in self?.bluetooth.refreshBatteryIfStale() }
            .store(in: &cancellables)
    }

    func stop() {
        power.stop()
        bluetooth.stop()
    }

    func showBluetoothOnboarding() {
        let controller = onboarding ?? BluetoothOnboardingWindowController(bluetooth: bluetooth, settings: settings)
        onboarding = controller
        controller.show()
    }

    // MARK: Debug

    func debugPowerPeek(_ event: PowerEvent) {
        store.present(DebugPeeks.power(event, current: power.snapshot))
    }

    func debugAirPodsPeek(connected: Bool) {
        store.present(DebugPeeks.airpods(connected: connected, existing: bluetooth.devices.first))
    }

    // MARK: Private

    private func handlePowerEvent(_ event: PowerEvent, snapshot: PowerSnapshot) {
        let item: PeekItem
        switch event {
        case .lowBattery:
            guard settings.lowBatteryAlertsEnabled else { return }
            item = PeekItem(
                content: .power(event: event, snapshot: snapshot, isLive: true),
                kind: event.isCritical ? .criticalPower : .power,
                duration: event.isCritical ? 5 : 3
            )
        case .pluggedIn, .unplugged, .fullyCharged:
            guard settings.chargingPeekEnabled else { return }
            item = PeekItem(content: .power(event: event, snapshot: snapshot, isLive: true), kind: .power, duration: 3)
        }
        store.present(item)
    }

    private func handleBluetoothEvent(_ event: BluetoothService.Event) {
        guard settings.airpodsPeekEnabled else { return }
        switch event {
        case .connected(let device):
            store.present(PeekItem(content: .airpods(AirPodsPeekInfo(device: device, connected: true)), kind: .airpods, duration: 3))
        case .disconnected(let device):
            store.present(PeekItem(content: .airpods(AirPodsPeekInfo(device: device, connected: false)), kind: .airpods, duration: 2))
        }
    }

    private func handlePermission(_ permission: BluetoothService.Permission) {
        guard permission == .denied, settings.airpodsPeekEnabled, !settings.skipBluetoothOnboarding else { return }
        showBluetoothOnboarding()
    }
}
