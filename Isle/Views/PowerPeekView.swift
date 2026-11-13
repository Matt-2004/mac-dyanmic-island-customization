import SwiftUI

/// Peek for charger plugged in / unplugged / fully charged / low battery.
struct PowerPeekView: View {
    let event: PowerEvent
    let snapshot: PowerSnapshot
    let metrics: NotchMetrics

    private var headline: String {
        switch event {
        case .lowBattery(let threshold):
            return threshold <= 10 ? "Battery Critically Low" : "Low Battery"
        default:
            return event.title
        }
    }

    private var detail: String {
        switch event {
        case .unplugged:
            return "Unplugged"
        case .lowBattery:
            return snapshot.isPluggedIn ? snapshot.statusText : "Connect your charger soon"
        case .pluggedIn, .fullyCharged:
            return snapshot.statusText
        }
    }

    private var percentColor: Color {
        if case .lowBattery = event {
            return BatteryGlyph.color(percent: snapshot.percent, isCharging: false)
        }
        return snapshot.isCharging || event == .fullyCharged ? .green : .white
    }

    var body: some View {
        HStack(spacing: 12) {
            BatteryGlyph(percent: snapshot.percent, isCharging: snapshot.isCharging, width: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(headline)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("\(snapshot.percent)%")
                .font(.system(size: 20, weight: .semibold).monospacedDigit())
                .foregroundStyle(percentColor)
        }
        .padding(.horizontal, IslandLayout.topRadius(for: .powerPeek) + 16)
        .padding(.top, metrics.notchSize.height + 4)
        .padding(.bottom, 8)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .combine)
    }
}
