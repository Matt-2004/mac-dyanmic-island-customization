import Foundation
import IOKit.ps
import Observation

/// Watches the Mac's internal battery through IOKit power sources.
///
/// `IOPSNotificationCreateRunLoopSource` fires on every power-source change;
/// the description is then read on a utility queue (IOKit IPC, kept off the
/// main thread) and published here. Transitions become `PowerEvent`s:
/// plugged in, unplugged, fully charged, and low battery at 20 % / 10 %
/// (only while unplugged, once per discharge).
@Observable
@MainActor
final class PowerService {
    private(set) var hasBattery = false
    private(set) var percent = 0
    private(set) var isCharging = false
    private(set) var isPluggedIn = false
    private(set) var isCharged = false
    private(set) var minutesToFull: Int?
    private(set) var minutesToEmpty: Int?

    var snapshot: PowerSnapshot? {
        guard hasBattery else { return nil }
        return PowerSnapshot(
            percent: percent,
            isCharging: isCharging,
            isPluggedIn: isPluggedIn,
            isCharged: isCharged,
            minutesToFull: minutesToFull,
            minutesToEmpty: minutesToEmpty
        )
    }

    /// Called on the main thread with every new reading.
    @ObservationIgnored var onChange: ((PowerSnapshot?) -> Void)?
    /// Called on the main thread for each detected transition.
    @ObservationIgnored var onEvent: ((PowerEvent, PowerSnapshot) -> Void)?

    @ObservationIgnored private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private let readQueue = DispatchQueue(label: "com.wai.Isle.power", qos: .utility)
    @ObservationIgnored private var previous: PowerSnapshot?
    @ObservationIgnored private var warnedAt20 = false
    @ObservationIgnored private var warnedAt10 = false
    @ObservationIgnored private var announcedFull = false

    func start() {
        guard runLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let service = Unmanaged<PowerService>.fromOpaque(context).takeUnretainedValue()
            // IOKit delivers on the run loop the source was added to (main).
            MainActor.assumeIsolated { service.refresh() }
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else {
            FileLog.write("power: IOPSNotificationCreateRunLoopSource failed")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source
        refresh()
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        runLoopSource = nil
    }

    func refresh() {
        readQueue.async { [weak self] in
            let reading = Self.readInternalBattery()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(reading) }
            }
        }
    }

    // MARK: Private

    /// Applies a reading and emits transitions. Internal so tests can feed readings.
    func apply(_ reading: PowerSnapshot?) {
        guard let reading else {
            hasBattery = false
            previous = nil
            onChange?(nil)
            return
        }
        hasBattery = true
        percent = reading.percent
        isCharging = reading.isCharging
        isPluggedIn = reading.isPluggedIn
        isCharged = reading.isCharged
        minutesToFull = reading.minutesToFull
        minutesToEmpty = reading.minutesToEmpty
        onChange?(reading)

        defer { previous = reading }
        guard let previous else {
            // First reading: establish baselines without announcing anything.
            announcedFull = reading.isPluggedIn && (reading.isCharged || reading.percent >= 100)
            warnedAt20 = !reading.isPluggedIn && reading.percent <= 20
            warnedAt10 = !reading.isPluggedIn && reading.percent <= 10
            return
        }
        detectTransitions(from: previous, to: reading)
    }

    private func detectTransitions(from old: PowerSnapshot, to new: PowerSnapshot) {
        if !old.isPluggedIn && new.isPluggedIn {
            warnedAt20 = false
            warnedAt10 = false
            announcedFull = new.isCharged || new.percent >= 100
            emit(.pluggedIn, new)
        } else if old.isPluggedIn && !new.isPluggedIn {
            announcedFull = false
            emit(.unplugged, new)
        }

        if new.isPluggedIn, !announcedFull, new.isCharged || new.percent >= 100 {
            announcedFull = true
            emit(.fullyCharged, new)
        }

        if !new.isPluggedIn {
            if new.percent <= 10, !warnedAt10 {
                warnedAt10 = true
                warnedAt20 = true
                emit(.lowBattery(threshold: 10), new)
            } else if new.percent <= 20, !warnedAt20 {
                warnedAt20 = true
                emit(.lowBattery(threshold: 20), new)
            }
        }
        // Re-arm warnings once the battery is comfortably above the thresholds again.
        if new.percent > 22 { warnedAt20 = false }
        if new.percent > 12 { warnedAt10 = false }
    }

    private func emit(_ event: PowerEvent, _ snapshot: PowerSnapshot) {
        FileLog.write("power: \(event) at \(snapshot.percent)%")
        onEvent?(event, snapshot)
    }

    /// Reads the internal battery. Runs on `readQueue`.
    nonisolated private static func readInternalBattery() -> PowerSnapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let percent = maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : current
            let state = description[kIOPSPowerSourceStateKey] as? String
            let toFull = description[kIOPSTimeToFullChargeKey] as? Int ?? -1
            let toEmpty = description[kIOPSTimeToEmptyKey] as? Int ?? -1
            return PowerSnapshot(
                percent: min(max(percent, 0), 100),
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                isPluggedIn: state == kIOPSACPowerValue,
                isCharged: description[kIOPSIsChargedKey] as? Bool ?? false,
                minutesToFull: toFull > 0 ? toFull : nil,
                minutesToEmpty: toEmpty > 0 ? toEmpty : nil
            )
        }
        return nil
    }
}
