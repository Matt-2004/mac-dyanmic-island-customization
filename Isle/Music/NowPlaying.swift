import AppKit

/// Snapshot of what Apple Music (or the debug player) is currently playing.
struct NowPlaying: Equatable {
    var trackID: String
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    /// Player position at `positionTimestamp`.
    var position: TimeInterval
    var positionTimestamp: Date
    var isPlaying: Bool
    var artwork: NSImage?
    var accentColor: NSColor?

    /// Position extrapolated to `date` while playing, clamped to the track length.
    func elapsed(at date: Date = Date()) -> TimeInterval {
        guard isPlaying else { return clampedPosition(position) }
        return clampedPosition(position + date.timeIntervalSince(positionTimestamp))
    }

    func progress(at date: Date = Date()) -> Double {
        guard duration > 0 else { return 0 }
        return elapsed(at: date) / duration
    }

    private func clampedPosition(_ value: TimeInterval) -> TimeInterval {
        guard duration > 0 else { return max(0, value) }
        return min(max(0, value), duration)
    }

    static func == (lhs: NowPlaying, rhs: NowPlaying) -> Bool {
        lhs.trackID == rhs.trackID
            && lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.album == rhs.album
            && lhs.duration == rhs.duration
            && lhs.position == rhs.position
            && lhs.positionTimestamp == rhs.positionTimestamp
            && lhs.isPlaying == rhs.isPlaying
            && lhs.artwork === rhs.artwork
            && lhs.accentColor == rhs.accentColor
    }
}

/// Transport controls the island UI can invoke. Implemented by the real
/// Apple Music service and by the debug player.
@MainActor
protocol PlaybackControlling: AnyObject {
    func playPause()
    func nextTrack()
    func previousTrack()
    func seek(to seconds: TimeInterval)
    func openPlayerApp()
}

enum TimeFormatting {
    static func string(from seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
