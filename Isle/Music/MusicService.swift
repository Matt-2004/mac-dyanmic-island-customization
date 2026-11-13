import AppKit
import Combine
import OSLog

/// A scriptable media player Isle can follow.
struct MediaPlayer: Equatable {
    let id: String
    let bundleID: String
    /// Name used in `tell application "…"`.
    let scriptName: String
    let displayName: String
    /// Distributed notification posted on play/pause/track change.
    let notificationName: String
    /// Spotify reports durations in milliseconds, Music in seconds.
    let durationDivisor: Double
    let previousCommand: String
    let stateScript: String
    /// Returns {trackID, artwork}: raw image data (Music) or an image URL string (Spotify).
    let artworkScript: String
    let artworkIsURL: Bool

    static let appleMusic = MediaPlayer(
        id: "music",
        bundleID: "com.apple.Music",
        scriptName: "Music",
        displayName: "Music",
        notificationName: "com.apple.Music.playerInfo",
        durationDivisor: 1,
        previousCommand: "back track",
        stateScript: Scripts.state(app: "Music", trackID: "persistent ID of t", streamTitle: true),
        artworkScript: """
        if application "Music" is not running then return {}
        tell application "Music"
            try
                set t to current track
                if (count of artworks of t) > 0 then
                    set tid to ""
                    try
                        set tid to persistent ID of t
                    end try
                    if tid is "" then set tid to (name of t) & (ASCII character 31) & (artist of t)
                    return {tid, raw data of artwork 1 of t}
                end if
            end try
        end tell
        return {}
        """,
        artworkIsURL: false
    )

    static let spotify = MediaPlayer(
        id: "spotify",
        bundleID: "com.spotify.client",
        scriptName: "Spotify",
        displayName: "Spotify",
        notificationName: "com.spotify.client.PlaybackStateChanged",
        durationDivisor: 1000,
        previousCommand: "previous track",
        stateScript: Scripts.state(app: "Spotify", trackID: "id of t", streamTitle: false),
        artworkScript: """
        if application "Spotify" is not running then return {}
        tell application "Spotify"
            try
                set t to current track
                return {id of t, artwork url of t}
            end try
        end tell
        return {}
        """,
        artworkIsURL: true
    )

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

/// Tracks playback in Apple Music and Spotify and exposes transport controls.
///
/// - Each player's distributed notification triggers a refresh.
/// - AppleScript (on a background queue) reads the full state of every running,
///   enabled player. The one to show: a playing player, preferring the one with the
///   most recent activity, otherwise the most recently active paused one.
/// - While playing, the position is re-synced every 5 s (every 1 s while the island
///   is expanded) so seeks made inside the player show up quickly.
/// - Artwork: Music raw data or Spotify's artwork URL. Optionally, when a track has
///   none, the iTunes Search API is asked for the album cover (sends artist + title).
/// - Players are never launched by Isle: every script checks the app is running.
@MainActor
final class MusicService: ObservableObject, PlaybackControlling {
    enum Status: Equatable {
        case notRunning
        case stopped
        case paused
        case playing
        case notAuthorized
        case error(String)

        var displayText: String {
            switch self {
            case .notRunning: return "No player running"
            case .stopped: return "Nothing playing"
            case .paused: return "Paused"
            case .playing: return "Playing"
            case .notAuthorized: return "Automation permission needed"
            case .error(let message): return "Error: \(message)"
            }
        }
    }

    /// Kept for callers that open Music directly.
    static let musicBundleID = MediaPlayer.appleMusic.bundleID

    @Published private(set) var status: Status = .notRunning
    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var activePlayer: MediaPlayer?

    /// Ask the iTunes Search API for covers the player doesn't provide.
    var fetchMissingArtwork = true

    private struct Reading {
        let player: MediaPlayer
        let state: String
        let nowPlaying: NowPlaying?
        let error: AppleScriptRunner.ScriptError?
    }

    private let log = Logger(subsystem: "com.wai.Isle", category: "music")
    private let runner = AppleScriptRunner()
    private let artwork = ArtworkProcessor()
    private let onChange: (NowPlaying?) -> Void
    private var players: [MediaPlayer] = [.appleMusic, .spotify]
    private var lastActivity: [String: Date] = [:]
    private var observers: [NSObjectProtocol] = []
    private var resyncTimer: Timer?
    private var fastResync = false
    private var refreshInFlight = false
    private var refreshPending = false
    private var coalesceWorkItem: DispatchWorkItem?
    private var artworkRequestedFor: String?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        return URLSession(configuration: configuration)
    }()

    init(onChange: @escaping (NowPlaying?) -> Void) {
        self.onChange = onChange
    }

    func start() {
        let distributed = DistributedNotificationCenter.default()
        for player in [MediaPlayer.appleMusic, MediaPlayer.spotify] {
            observers.append(distributed.addObserver(
                forName: Notification.Name(player.notificationName), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.lastActivity[player.id] = Date()
                    self?.scheduleRefresh(after: 0.1)
                }
            })
        }

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                MainActor.assumeIsolated {
                    guard let self, self.players.contains(where: { $0.bundleID == bundleID }) else { return }
                    self.scheduleRefresh(after: name == NSWorkspace.didLaunchApplicationNotification ? 1.0 : 0.1)
                }
            })
        }

        refresh()
    }

    func stop() {
        for observer in observers {
            DistributedNotificationCenter.default().removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        resyncTimer?.invalidate()
        resyncTimer = nil
    }

    /// Forces a fresh read, e.g. after the user grants Automation permission.
    func refreshNow() {
        refresh()
    }

    func setSpotifyEnabled(_ enabled: Bool) {
        players = enabled ? [.appleMusic, .spotify] : [.appleMusic]
        refresh()
    }

    /// Re-sync every second while the user is looking at the expanded player.
    func setFastResync(_ enabled: Bool) {
        guard enabled != fastResync else { return }
        fastResync = enabled
        resyncTimer?.invalidate()
        resyncTimer = nil
        updateResyncTimer()
        if enabled { refresh() }
    }

    // MARK: PlaybackControlling

    func playPause() {
        if var optimistic = nowPlaying {
            optimistic.position = optimistic.elapsed()
            optimistic.positionTimestamp = Date()
            optimistic.isPlaying.toggle()
            publish(optimistic)
        }
        control("playpause")
    }

    func nextTrack() {
        control("next track")
    }

    func previousTrack() {
        control(activePlayer?.previousCommand ?? "previous track")
    }

    func seek(to seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        if var optimistic = nowPlaying {
            optimistic.position = min(max(0, seconds), optimistic.duration)
            optimistic.positionTimestamp = Date()
            publish(optimistic)
        }
        let position = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), max(0, seconds))
        control("set player position to \(position)", cache: false)
    }

    func openPlayerApp() {
        let bundleID = activePlayer?.bundleID ?? MediaPlayer.appleMusic.bundleID
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Refreshing

    private func scheduleRefresh(after delay: TimeInterval) {
        coalesceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        coalesceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func refresh() {
        let running = players.filter(\.isRunning)
        guard !running.isEmpty else {
            activePlayer = nil
            apply(status: .notRunning, nowPlaying: nil)
            return
        }
        guard !refreshInFlight else {
            refreshPending = true
            return
        }
        refreshInFlight = true
        read(running, collected: [])
    }

    /// Reads players one after another (the runner is serial anyway), then picks one.
    private func read(_ remaining: [MediaPlayer], collected: [Reading]) {
        guard let player = remaining.first else {
            finishRefresh(collected)
            return
        }
        runner.run(player.stateScript) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                let reading = self.makeReading(player, result)
                self.read(Array(remaining.dropFirst()), collected: collected + [reading])
            }
        }
    }

    private func finishRefresh(_ readings: [Reading]) {
        refreshInFlight = false
        defer {
            if refreshPending {
                refreshPending = false
                refresh()
            }
        }

        func activity(_ reading: Reading) -> Date {
            lastActivity[reading.player.id] ?? .distantPast
        }
        let playing = readings.filter { $0.state == "playing" && $0.nowPlaying != nil }
        let paused = readings.filter { $0.state == "paused" && $0.nowPlaying != nil }
        let chosen = playing.max { activity($0) < activity($1) } ?? paused.max { activity($0) < activity($1) }

        guard let chosen, let value = chosen.nowPlaying else {
            activePlayer = nil
            if readings.contains(where: { $0.error == .notAuthorized }) {
                apply(status: .notAuthorized, nowPlaying: nil)
            } else if let failure = readings.compactMap(\.error).first {
                apply(status: .error(String(describing: failure)), nowPlaying: nil)
            } else {
                apply(status: readings.isEmpty ? .notRunning : .stopped, nowPlaying: nil)
            }
            return
        }
        if activePlayer != chosen.player {
            activePlayer = chosen.player
        }

        let cacheKey = "\(chosen.player.id):\(value.trackID)"
        let cached = artwork.cached(for: cacheKey)
        let sameTrack = nowPlaying?.trackID == value.trackID
        var merged = value
        merged.artwork = cached?.image ?? (sameTrack ? nowPlaying?.artwork : nil)
        merged.accentColor = cached?.accentColor ?? (sameTrack ? nowPlaying?.accentColor : nil)
        apply(status: value.isPlaying ? .playing : .paused, nowPlaying: merged)
        if merged.artwork == nil {
            loadArtwork(for: chosen.player, nowPlaying: value, cacheKey: cacheKey)
        }
    }

    private func makeReading(_ player: MediaPlayer, _ result: Result<NSAppleEventDescriptor, AppleScriptRunner.ScriptError>) -> Reading {
        switch result {
        case .failure(let error):
            return Reading(player: player, state: "error", nowPlaying: nil, error: error)
        case .success(let descriptor):
            let state = descriptor.stringItem(1) ?? "stopped"
            guard state == "playing" || state == "paused" else {
                return Reading(player: player, state: state, nowPlaying: nil, error: nil)
            }
            let title = descriptor.stringItem(3) ?? ""
            let artist = descriptor.stringItem(4) ?? ""
            let trackID = descriptor.stringItem(2) ?? "\(title)\u{1F}\(artist)"
            let value = NowPlaying(
                trackID: trackID,
                title: title.isEmpty ? "Unknown Title" : title,
                artist: artist,
                album: descriptor.stringItem(5) ?? "",
                duration: max(0, (descriptor.doubleItem(6) ?? 0) / player.durationDivisor),
                position: max(0, descriptor.doubleItem(7) ?? 0),
                positionTimestamp: Date(),
                isPlaying: state == "playing",
                artwork: nil,
                accentColor: nil
            )
            return Reading(player: player, state: state, nowPlaying: value, error: nil)
        }
    }

    // MARK: Artwork

    private func loadArtwork(for player: MediaPlayer, nowPlaying value: NowPlaying, cacheKey: String) {
        guard artworkRequestedFor != cacheKey else { return }
        artworkRequestedFor = cacheKey
        runner.run(player.artworkScript) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                if case .success(let descriptor) = result,
                   descriptor.numberOfItems >= 2,
                   descriptor.stringItem(1) == value.trackID,
                   let payload = descriptor.atIndex(2) {
                    if player.artworkIsURL, let string = payload.stringValue, let url = URL(string: string) {
                        self.download(url, cacheKey: cacheKey, trackID: value.trackID, fallback: value)
                        return
                    }
                    if !player.artworkIsURL, !payload.data.isEmpty {
                        self.process(payload.data, cacheKey: cacheKey, trackID: value.trackID)
                        return
                    }
                }
                self.lookUpArtworkOnline(for: value, cacheKey: cacheKey)
            }
        }
    }

    private func download(_ url: URL, cacheKey: String, trackID: String, fallback: NowPlaying) {
        Task { [weak self, session] in
            let data = try? await session.data(from: url).0
            guard let self else { return }
            if let data, !data.isEmpty {
                self.process(data, cacheKey: cacheKey, trackID: trackID)
            } else {
                self.lookUpArtworkOnline(for: fallback, cacheKey: cacheKey)
            }
        }
    }

    /// iTunes Search API: public, no key. Sends only "artist title".
    private func lookUpArtworkOnline(for value: NowPlaying, cacheKey: String) {
        guard fetchMissingArtwork, !value.title.isEmpty, value.title != "Unknown Title" else { return }
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: "\(value.artist) \(value.title)"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "5")
        ]
        guard let url = components?.url else { return }
        Task { [weak self, session] in
            guard let (data, _) = try? await session.data(from: url),
                  let artworkURL = ITunesArtworkSearch.bestArtworkURL(in: data, title: value.title, artist: value.artist),
                  let image = try? await session.data(from: artworkURL).0 else { return }
            self?.process(image, cacheKey: cacheKey, trackID: value.trackID)
        }
    }

    private func process(_ data: Data, cacheKey: String, trackID: String) {
        artwork.process(data: data, trackID: cacheKey) { [weak self] processed in
            MainActor.assumeIsolated {
                guard let self, let processed, var current = self.nowPlaying, current.trackID == trackID else { return }
                current.artwork = processed.image
                current.accentColor = processed.accentColor
                self.publish(current)
            }
        }
    }

    // MARK: Controls

    private func control(_ command: String, cache: Bool = true) {
        guard let player = activePlayer ?? players.first(where: \.isRunning), player.isRunning else { return }
        lastActivity[player.id] = Date()
        let source = """
        if application "\(player.scriptName)" is running then
            tell application "\(player.scriptName)" to \(command)
        end if
        """
        runner.runIgnoringResult(source, cache: cache) { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let error {
                    self.log.error("Control '\(command, privacy: .public)' failed: \(String(describing: error), privacy: .public)")
                }
                if error == .notAuthorized {
                    self.apply(status: .notAuthorized, nowPlaying: nil)
                    return
                }
                self.scheduleRefresh(after: 0.25)
            }
        }
    }

    private func apply(status: Status, nowPlaying: NowPlaying?) {
        if self.status != status {
            log.notice("Music status: \(status.displayText, privacy: .public)")
            self.status = status
        }
        publish(nowPlaying)
        updateResyncTimer()
    }

    private func publish(_ value: NowPlaying?) {
        guard value != nowPlaying else { return }
        if value?.trackID != nowPlaying?.trackID {
            artworkRequestedFor = nil
        }
        nowPlaying = value
        onChange(value)
    }

    private func updateResyncTimer() {
        let shouldRun = status == .playing || (fastResync && status == .paused)
        if shouldRun, resyncTimer == nil {
            let timer = Timer(timeInterval: fastResync ? 1 : 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            timer.tolerance = fastResync ? 0.2 : 1
            RunLoop.main.add(timer, forMode: .common)
            resyncTimer = timer
        } else if !shouldRun, let timer = resyncTimer {
            timer.invalidate()
            resyncTimer = nil
        }
    }
}

/// Picks the best cover from an iTunes Search API response.
enum ITunesArtworkSearch {
    static func bestArtworkURL(in data: Data, title: String, artist: String) -> URL? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]], !results.isEmpty else { return nil }
        func fold(_ string: String) -> String {
            string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        let wantedTitle = fold(title)
        let wantedArtist = fold(artist)
        let scored = results.map { result -> (Int, [String: Any]) in
            let trackName = fold(result["trackName"] as? String ?? "")
            let artistName = fold(result["artistName"] as? String ?? "")
            var score = 0
            if trackName == wantedTitle { score += 3 } else if trackName.contains(wantedTitle) || wantedTitle.contains(trackName) { score += 1 }
            if !wantedArtist.isEmpty, artistName.contains(wantedArtist) || wantedArtist.contains(artistName) { score += 2 }
            return (score, result)
        }
        guard let best = scored.max(by: { $0.0 < $1.0 }), best.0 >= 3,
              let small = best.1["artworkUrl100"] as? String else { return nil }
        return URL(string: small.replacingOccurrences(of: "100x100bb", with: "600x600bb"))
    }
}

private enum Scripts {
    /// Returns {state, trackID, name, artist, album, duration, position}
    /// or {"stopped"} / {"notrunning"}. Every property is read defensively
    /// because streams and radio stations omit some of them.
    static func state(app: String, trackID: String, streamTitle: Bool) -> String {
        """
        if application "\(app)" is not running then return {"notrunning"}
        tell application "\(app)"
            set ps to "stopped"
            try
                if player state is playing then
                    set ps to "playing"
                else if player state is paused then
                    set ps to "paused"
                end if
            end try
            if ps is "stopped" then return {"stopped"}
            try
                set t to current track
            on error
                return {"stopped"}
            end try
            set tid to ""
            set tn to ""
            set ta to ""
            set tal to ""
            set td to 0.0
            set pp to 0.0
            try
                set tid to \(trackID)
            end try
            try
                set tn to name of t
            end try
            try
                set ta to artist of t
            end try
            try
                set tal to album of t
            end try
            try
                set td to duration of t
            end try
            try
                set pp to player position
            end try
            \(streamTitle ? """
            if tn is "" then
                try
                    set tn to current stream title
                end try
            end if
            """ : "")
            return {ps, tid, tn, ta, tal, td, pp}
        end tell
        """
    }
}
