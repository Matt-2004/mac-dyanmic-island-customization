import Foundation

/// Sample peeks for the Debug menu. They go through the normal priority queue,
/// so triggering several in a row also exercises queueing and pre-emption.
@MainActor
enum DebugPeeks {
    static func power(_ event: PowerEvent, current: PowerSnapshot?) -> PeekItem {
        var snapshot = current ?? PowerSnapshot(
            percent: 64, isCharging: false, isPluggedIn: false, isCharged: false,
            minutesToFull: nil, minutesToEmpty: 250
        )
        switch event {
        case .pluggedIn:
            snapshot.isPluggedIn = true
            snapshot.isCharging = true
            snapshot.isCharged = false
            snapshot.minutesToFull = snapshot.minutesToFull ?? 80
            snapshot.percent = min(snapshot.percent, 99)
        case .unplugged:
            snapshot.isPluggedIn = false
            snapshot.isCharging = false
            snapshot.minutesToFull = nil
        case .fullyCharged:
            snapshot.isPluggedIn = true
            snapshot.isCharging = false
            snapshot.isCharged = true
            snapshot.percent = 100
            snapshot.minutesToFull = nil
        case .lowBattery(let threshold):
            snapshot.isPluggedIn = false
            snapshot.isCharging = false
            snapshot.percent = threshold
            snapshot.minutesToFull = nil
            snapshot.minutesToEmpty = threshold * 3
        }
        return PeekItem(
            content: .power(event: event, snapshot: snapshot, isLive: false),
            kind: event.isCritical ? .criticalPower : .power,
            duration: event.isCritical ? 5 : 3
        )
    }

    static func airpods(connected: Bool, existing: AudioDevice?) -> PeekItem {
        let device = existing ?? AudioDevice(
            id: "DEBUG",
            name: "Debug AirPods Pro",
            kind: .airpodsPro,
            battery: BatteryLevels(left: 87, right: 92, caseLevel: nil, main: nil),
            isConnected: connected
        )
        return PeekItem(content: .airpods(AirPodsPeekInfo(device: device, connected: connected)), kind: .airpods, duration: connected ? 3 : 2)
    }
}
