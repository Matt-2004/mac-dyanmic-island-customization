import SwiftUI

/// Wings on either side of the notch.
/// - Music playing: artwork left, equalizer right (plus a bolt while charging).
/// - Charging without music: battery percent left, battery ring with bolt right.
struct CompactMusicView: View {
    let nowPlaying: NowPlaying?
    let power: PowerSnapshot?
    let showsCharging: Bool
    /// Battery wing on: percent + icon after the equalizer (replaces the charging bolt).
    let showsBattery: Bool
    let metrics: NotchMetrics

    var body: some View {
        let height = metrics.notchSize.height
        let artSize = max(14, min(22, height - 10))
        let inset = IslandLayout.topRadius(for: .compact)
        HStack(spacing: 0) {
            leftWing(artSize: artSize)
                .padding(.leading, inset + 12)
                .frame(width: IslandLayout.compactWingWidth, alignment: .leading)
            Spacer(minLength: metrics.notchSize.width)
            rightWing(artSize: artSize)
                .padding(.trailing, inset + 12)
                .frame(width: IslandLayout.compactWingWidth + (showsBattery ? IslandLayout.compactBatteryExtra : 0),
                       alignment: .trailing)
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private func leftWing(artSize: CGFloat) -> some View {
        if let nowPlaying, nowPlaying.isPlaying || !showsCharging {
            ArtworkView(image: nowPlaying.artwork, size: artSize, cornerRadius: 5)
        } else if let power {
            Text("\(power.percent)%")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private func rightWing(artSize: CGFloat) -> some View {
        let musicPlaying = nowPlaying?.isPlaying ?? false
        HStack(spacing: 8) {
            if showsBattery, let power {
                if let nowPlaying, musicPlaying {
                    PlayingIndicator(isPlaying: true, color: nowPlaying.accent, height: artSize * 0.7)
                }
                BatteryStatusView(snapshot: power)
            } else {
                chargingAndEqualizer(artSize: artSize, musicPlaying: musicPlaying)
            }
        }
    }

    @ViewBuilder
    private func chargingAndEqualizer(artSize: CGFloat, musicPlaying: Bool) -> some View {
        HStack(spacing: 6) {
            if showsCharging {
                if musicPlaying {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.green)
                } else if let power {
                    ChargingRing(percent: power.percent, diameter: artSize)
                }
            }
            if let nowPlaying, musicPlaying {
                PlayingIndicator(isPlaying: true, color: nowPlaying.accent, height: artSize * 0.7)
            }
        }
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if let nowPlaying, nowPlaying.isPlaying {
            parts.append("\(nowPlaying.title) by \(nowPlaying.artist)")
        }
        if showsBattery, let power {
            parts.append("Battery \(power.percent) percent\(power.isCharging ? ", charging" : "")")
        } else if showsCharging, let power {
            parts.append("Charging, \(power.percent) percent")
        }
        return parts.joined(separator: ". ")
    }
}

/// Small green ring with a bolt, for the compact charging indicator.
struct ChargingRing: View {
    let percent: Int
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(Color.green.opacity(0.25), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(percent, 0), 100)) / 100)
                .stroke(Color.green, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "bolt.fill")
                .font(.system(size: diameter * 0.42, weight: .bold))
                .foregroundStyle(.green)
        }
        .frame(width: diameter, height: diameter)
    }
}

/// "87%" plus a battery icon, like the macOS menu bar battery.
struct BatteryStatusView: View {
    let snapshot: PowerSnapshot

    var body: some View {
        HStack(spacing: 5) {
            Text("\(snapshot.percent)%")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(snapshot.percent <= 20 && !snapshot.isCharging
                                 ? BatteryGlyph.color(percent: snapshot.percent, isCharging: false)
                                 : .white.opacity(0.92))
                .animation(.easeInOut(duration: 0.45), value: snapshot.isCharging)
                .contentTransition(.numericText(value: Double(snapshot.percent)))
                .animation(.easeInOut(duration: 0.3), value: snapshot.percent)
                .lineLimit(1)
                .fixedSize()
            BatteryGlyph(percent: snapshot.percent, isCharging: snapshot.isCharging, width: 24)
        }
    }
}

/// The `.battery` state: only a right-hand wing, the left edge stays on the notch.
struct BatteryWingView: View {
    let snapshot: PowerSnapshot?
    let metrics: NotchMetrics

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: metrics.notchSize.width)
            if let snapshot {
                BatteryStatusView(snapshot: snapshot)
                    .padding(.trailing, IslandLayout.topRadius(for: .battery) + 10)
            }
        }
        .frame(height: metrics.notchSize.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.map { "Battery \($0.percent) percent\($0.isCharging ? ", charging" : "")" } ?? "")
    }
}
