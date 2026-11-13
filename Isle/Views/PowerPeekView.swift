import SwiftUI

/// Peek for charger plugged in / unplugged / fully charged / low battery.
struct PowerPeekView: View {
    let event: PowerEvent
    let snapshot: PowerSnapshot
    let metrics: NotchMetrics
    /// Plug in / unplug: the icon first shows the previous state, then animates to the new one.
    @State private var glyphCharging: Bool?

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
        let charging = glyphCharging ?? snapshot.showsChargingStyle
        return charging || event == .fullyCharged ? .green : .white
    }

    var body: some View {
        HStack(spacing: 12) {
            BatteryGlyph(percent: snapshot.percent, isCharging: glyphCharging ?? snapshot.showsChargingStyle, width: 34)
                .onAppear(perform: animateChargeChange)
                .onChange(of: snapshot.showsChargingStyle) { _, _ in glyphCharging = nil }
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
                .animation(.easeInOut(duration: 0.4), value: glyphCharging)
        }
        .padding(.horizontal, IslandLayout.topRadius(for: .powerPeek) + 16)
        .padding(.top, metrics.notchSize.height + 4)
        .padding(.bottom, 8)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .combine)
    }

    private func animateChargeChange() {
        switch event {
        case .pluggedIn: glyphCharging = false
        case .unplugged: glyphCharging = true
        case .fullyCharged, .lowBattery: return
        }
        // Wait until the peek has finished dropping open (spring ≈ 0.45 s), then switch to
        // the real state so the change is seen on its own rather than mid-morph.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            glyphCharging = nil
        }
    }
}
