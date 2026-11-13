import SwiftUI

/// Horizontal battery with a fill level and an optional charging bolt.
struct BatteryGlyph: View {
    let percent: Int
    let isCharging: Bool
    var width: CGFloat = 26
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var height: CGFloat { width * 0.48 }

    /// Plugging in: the bolt pops in with a small spring. Unplugging: it shrinks away with a
    /// short ease-out (no bounce). Reduce Motion: a plain fade both ways.
    private var boltAnimation: Animation {
        if reduceMotion { return .easeInOut(duration: 0.25) }
        return isCharging ? .spring(response: 0.45, dampingFraction: 0.6) : .easeOut(duration: 0.28)
    }

    static func color(percent: Int, isCharging: Bool) -> Color {
        if isCharging { return .green }
        if percent <= 10 { return .red }
        if percent <= 20 { return .orange }
        return .white
    }

    var body: some View {
        let fraction = CGFloat(min(max(percent, 0), 100)) / 100
        let color = Self.color(percent: percent, isCharging: isCharging)
        HStack(spacing: width * 0.04) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height * 0.3, style: .continuous)
                    .stroke(Color.white.opacity(0.45), lineWidth: max(1, width * 0.05))
                RoundedRectangle(cornerRadius: height * 0.2, style: .continuous)
                    .fill(color)
                    .padding(width * 0.07)
                    .frame(width: max(width * 0.16, width * fraction))
                    .animation(.easeInOut(duration: 0.4), value: color)
                    .animation(.easeInOut(duration: 0.6), value: fraction)
                // Always in the hierarchy and animated by scale/opacity, so it never pops
                // while the surrounding peek is itself animating in or out.
                Image(systemName: "bolt.fill")
                    .font(.system(size: height * 0.72, weight: .heavy))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 1)
                    .frame(maxWidth: .infinity)
                    .scaleEffect(isCharging || reduceMotion ? 1 : 0.3)
                    .opacity(isCharging ? 1 : 0)
                    .animation(boltAnimation, value: isCharging)
            }
            .frame(width: width, height: height)
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.white.opacity(0.45))
                .frame(width: max(1.5, width * 0.06), height: height * 0.35)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(percent) percent\(isCharging ? ", charging" : "")")
    }
}

/// Circular battery ring with a label underneath; shows "--" when unknown.
struct BatteryRing: View {
    let label: String
    let value: Int?
    var diameter: CGFloat = 38

    var body: some View {
        let fraction = CGFloat(value ?? 0) / 100
        let color = BatteryGlyph.color(percent: value ?? 100, isCharging: false)
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.15), lineWidth: 3.5)
                Circle()
                    .trim(from: 0, to: value == nil ? 0 : fraction)
                    .stroke(value == nil ? Color.clear : (color == .white ? Color.green : color),
                            style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(value.map { "\($0)" } ?? "--")
                    .font(.system(size: diameter * 0.3, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            .frame(width: diameter, height: diameter)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) battery \(value.map { "\($0) percent" } ?? "unknown")")
    }
}

/// Compact "Devices" line for the expanded island: Mac battery and connected audio devices.
struct DevicesRowView: View {
    let power: PowerSnapshot?
    let devices: [AudioDevice]

    var body: some View {
        HStack(spacing: 14) {
            if let power {
                HStack(spacing: 6) {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                    BatteryGlyph(percent: power.percent, isCharging: power.showsChargingStyle, width: 22)
                    Text("\(power.percent)%")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.8))
                }
                .help(power.statusText)
            }
            ForEach(devices) { device in
                HStack(spacing: 5) {
                    Image(systemName: device.kind.symbolName)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(Self.batterySummary(device.battery))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
                .help(device.name)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 18)
    }

    static func batterySummary(_ battery: BatteryLevels?) -> String {
        guard let battery, !battery.isEmpty else { return "--" }
        if battery.left != nil || battery.right != nil {
            var parts = ["L \(BatteryLevels.text(battery.left))", "R \(BatteryLevels.text(battery.right))"]
            if let caseLevel = battery.caseLevel {
                parts.append("Case \(caseLevel)%")
            }
            return parts.joined(separator: "  ")
        }
        return BatteryLevels.text(battery.main)
    }
}
