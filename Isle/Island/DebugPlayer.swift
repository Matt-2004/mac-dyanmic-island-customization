import AppKit

/// In-memory player used by the Debug menu so every island state can be
/// exercised without Apple Music. Its controls really change the sample track.
@MainActor
final class DebugPlayer: PlaybackControlling {
    private struct Track {
        let title: String
        let artist: String
        let album: String
        let duration: TimeInterval
        let colors: (NSColor, NSColor)
    }

    private let tracks: [Track] = [
        Track(title: "Harbour Lights", artist: "The Debug Ensemble", album: "Sample Sessions",
              duration: 214, colors: (.systemPink, .systemOrange)),
        Track(title: "Low Tide", artist: "Placeholder Quartet", album: "Island Tests",
              duration: 187, colors: (.systemTeal, .systemBlue)),
        Track(title: "Northern Notch", artist: "Synthetic Signals", album: "Menu Bar Music",
              duration: 251, colors: (.systemPurple, .systemIndigo))
    ]

    private weak var store: IslandStateStore?
    private var index = 0
    private(set) var current: NowPlaying

    init(store: IslandStateStore) {
        self.store = store
        current = NowPlaying(trackID: "", title: "", artist: "", album: "", duration: 0,
                             position: 0, positionTimestamp: Date(), isPlaying: false,
                             artwork: nil, accentColor: nil)
        current = makeNowPlaying(index: 0, position: 42, playing: true)
    }

    func sample() -> NowPlaying {
        current
    }

    func playPause() {
        var next = current
        next.position = current.elapsed()
        next.positionTimestamp = Date()
        next.isPlaying.toggle()
        publish(next)
    }

    func nextTrack() {
        index = (index + 1) % tracks.count
        publish(makeNowPlaying(index: index, position: 0, playing: true))
    }

    func previousTrack() {
        if current.elapsed() > 3 {
            seek(to: 0)
            return
        }
        index = (index - 1 + tracks.count) % tracks.count
        publish(makeNowPlaying(index: index, position: 0, playing: true))
    }

    func seek(to seconds: TimeInterval) {
        var next = current
        next.position = min(max(0, seconds), current.duration)
        next.positionTimestamp = Date()
        publish(next)
    }

    func openPlayerApp() {
        NSSound.beep()
    }

    private func publish(_ value: NowPlaying) {
        current = value
        store?.debugUpdateSample(value)
    }

    private func makeNowPlaying(index: Int, position: TimeInterval, playing: Bool) -> NowPlaying {
        let track = tracks[index]
        return NowPlaying(
            trackID: "debug-\(index)",
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            position: position,
            positionTimestamp: Date(),
            isPlaying: playing,
            artwork: Self.gradientArtwork(track.colors.0, track.colors.1),
            accentColor: track.colors.0
        )
    }

    private static func gradientArtwork(_ start: NSColor, _ end: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 300, height: 300), flipped: false) { rect in
            if let gradient = NSGradient(starting: start, ending: end) {
                gradient.draw(in: rect, angle: -45)
            }
            let inner = rect.insetBy(dx: rect.width * 0.32, dy: rect.height * 0.32)
            NSColor.white.withAlphaComponent(0.25).setFill()
            NSBezierPath(ovalIn: inner).fill()
            return true
        }
    }
}

enum DebugSamples {
    private static var counter = 0

    /// Alternates between a native app (Messages) and a web service (Messenger, icon fetched from the web).
    @MainActor
    static func notification() -> IslandNotification {
        counter += 1
        if counter.isMultiple(of: 2) {
            return IslandNotification(
                bundleIdentifier: nil,
                appName: "Messenger",
                title: "Debug Friend",
                body: "Sample web-app notification — the icon is downloaded from messenger.com."
            )
        }
        return IslandNotification(
            bundleIdentifier: "com.apple.MobileSMS",
            appName: "Messages",
            title: "Debug Sender",
            body: "This is a sample notification peek triggered from the Isle debug menu."
        )
    }
}
