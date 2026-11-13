import SwiftUI

/// Rounded album art with a neutral fallback when no artwork is available.
struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.25), Color(white: 0.12)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.45, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Animated equalizer bars; static when paused.
struct PlayingIndicator: View {
    let isPlaying: Bool
    let color: Color
    var barCount = 4
    var height: CGFloat = 14
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: !isPlaying || reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: barHeight(index: index, time: time))
                }
            }
            .frame(height: height)
        }
    }

    private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        guard isPlaying else { return height * 0.3 }
        if reduceMotion {
            // Static "levels" so playing is still distinguishable from paused.
            let levels: [CGFloat] = [0.55, 0.9, 0.7, 0.45]
            return height * levels[index % levels.count]
        }
        let speed = 5.0 + Double(index) * 1.3
        let phase = Double(index) * 1.7
        let value = (sin(time * speed + phase) + 1) / 2
        return height * (0.25 + 0.75 * CGFloat(value))
    }
}

extension NowPlaying {
    var accent: Color {
        if let accentColor {
            return Color(nsColor: accentColor)
        }
        return Color.white
    }
}
