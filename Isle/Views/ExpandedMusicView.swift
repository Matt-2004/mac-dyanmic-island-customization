import SwiftUI

/// Full island: player (artwork, track info, scrubber, transport controls) and a Devices row.
/// Without music (e.g. expanded from the charging indicator) it shows "Not Playing".
struct ExpandedMusicView: View {
    let nowPlaying: NowPlaying?
    let power: PowerSnapshot?
    let devices: [AudioDevice]
    let metrics: NotchMetrics
    let controller: PlaybackControlling?

    var body: some View {
        VStack(spacing: 10) {
            if let nowPlaying {
                player(nowPlaying)
            } else {
                notPlaying
            }
            if power != nil || !devices.isEmpty {
                Divider().overlay(Color.white.opacity(0.12))
                DevicesRowView(power: power, devices: devices)
            }
        }
        .padding(.horizontal, IslandLayout.topRadius(for: .expanded) + 18)
        .padding(.top, metrics.notchSize.height + 4)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func player(_ nowPlaying: NowPlaying) -> some View {
        HStack(spacing: 14) {
            ArtworkView(image: nowPlaying.artwork, size: 60, cornerRadius: 12)
                .shadow(color: nowPlaying.accent.opacity(0.35), radius: 10)
                .onTapGesture { controller?.openPlayerApp() }
            VStack(alignment: .leading, spacing: 3) {
                Text(nowPlaying.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(nowPlaying.artist)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            PlayingIndicator(isPlaying: nowPlaying.isPlaying, color: nowPlaying.accent, height: 18)
        }

        ScrubberView(nowPlaying: nowPlaying) { seconds in
            controller?.seek(to: seconds)
        }

        HStack(spacing: 36) {
            TransportButton(systemName: "backward.fill", size: 18, label: "Previous") {
                controller?.previousTrack()
            }
            TransportButton(systemName: nowPlaying.isPlaying ? "pause.fill" : "play.fill", size: 24,
                            label: nowPlaying.isPlaying ? "Pause" : "Play") {
                controller?.playPause()
            }
            TransportButton(systemName: "forward.fill", size: 18, label: "Next") {
                controller?.nextTrack()
            }
        }
    }

    private var notPlaying: some View {
        HStack(spacing: 14) {
            ArtworkView(image: nil, size: 60, cornerRadius: 12)
            VStack(alignment: .leading, spacing: 3) {
                Text("Not Playing")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                if let power {
                    Text(power.statusText)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button("Open Music") { controller?.openPlayerApp() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.14)))
        }
        .frame(maxHeight: .infinity)
    }
}

private struct TransportButton: View {
    let systemName: String
    let size: CGFloat
    let label: String
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovered ? 1 : 0.85))
                .frame(width: 36, height: 30)
                .contentShape(Rectangle())
                .scaleEffect(isHovered && !reduceMotion ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(label)
    }
}

/// Progress bar that can be dragged to seek. Seeks once on release.
struct ScrubberView: View {
    let nowPlaying: NowPlaying
    let onSeek: (TimeInterval) -> Void
    @State private var dragFraction: Double?
    @State private var isHovered = false

    var body: some View {
        if nowPlaying.duration > 0 {
            scrubber
        } else {
            liveStream
        }
    }

    /// Radio and live streams have no duration, so there is nothing to seek.
    private var liveStream: some View {
        HStack(spacing: 8) {
            Text("LIVE")
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(nowPlaying.accent.opacity(0.3)))
                .foregroundStyle(nowPlaying.accent)
            Capsule().fill(Color.white.opacity(0.18)).frame(height: 5)
        }
        .frame(height: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live stream")
    }

    private var scrubber: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let liveFraction = nowPlaying.progress(at: context.date)
            let fraction = min(max(dragFraction ?? liveFraction, 0), 1)
            let shownTime = dragFraction.map { $0 * nowPlaying.duration } ?? nowPlaying.elapsed(at: context.date)
            HStack(spacing: 8) {
                Text(TimeFormatting.string(from: shownTime))
                    .frame(width: 40, alignment: .trailing)
                GeometryReader { proxy in
                    let barHeight: CGFloat = (isHovered || dragFraction != nil) ? 7 : 5
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule()
                            .fill(nowPlaying.accent)
                            .frame(width: max(barHeight, proxy.size.width * fraction))
                    }
                    .frame(height: barHeight)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard proxy.size.width > 0 else { return }
                                dragFraction = min(max(value.location.x / proxy.size.width, 0), 1)
                            }
                            .onEnded { value in
                                guard proxy.size.width > 0, nowPlaying.duration > 0 else {
                                    dragFraction = nil
                                    return
                                }
                                let final = min(max(value.location.x / proxy.size.width, 0), 1)
                                onSeek(final * nowPlaying.duration)
                                dragFraction = nil
                            }
                    )
                    .animation(.easeOut(duration: 0.15), value: barHeight)
                }
                .frame(height: 16)
                .onHover { isHovered = $0 }
                Text(TimeFormatting.string(from: nowPlaying.duration))
                    .frame(width: 40, alignment: .leading)
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(TimeFormatting.string(from: nowPlaying.elapsed())) of \(TimeFormatting.string(from: nowPlaying.duration))")
    }
}
