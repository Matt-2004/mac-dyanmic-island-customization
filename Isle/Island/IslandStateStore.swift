import Foundation
import Combine

/// Single source of truth for what the island shows.
///
/// State is *derived*, never set directly:
/// 1. An active peek wins. Peeks have priorities
///    (notification > critical 10 % battery > AirPods > other power events).
///    A higher-priority peek pre-empts a lower one, which goes back into the
///    queue. The queue holds at most 3 items; anything older than 10 s is
///    dropped when it would be shown.
/// 2. Otherwise, if there is something to expand (music loaded, or the charging
///    indicator) and the user expanded the island (hover/click or debug pin),
///    show the expanded view.
/// 3. Otherwise, compact while music is *playing* or the Mac is charging
///    (with the charging indicator enabled).
/// 4. Otherwise idle.
/// When a peek ends, rules 2–4 apply again, so the previous state is restored.
@MainActor
final class IslandStateStore: ObservableObject {
    static let maxQueuedPeeks = 3
    static let stalePeekAge: TimeInterval = 10

    @Published private(set) var state: IslandState = .idle
    @Published private(set) var metrics: NotchMetrics = .fallback
    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var activePeek: PeekItem?
    @Published private(set) var power: PowerSnapshot?
    @Published private(set) var audioDevices: [AudioDevice] = []
    @Published private(set) var isHovering = false
    @Published private(set) var isDebugOverrideActive = false

    /// Live transport controls (Apple Music). Set by the app delegate.
    weak var liveController: PlaybackControlling?
    /// Debug transport controls, used while debug music is shown.
    weak var debugController: PlaybackControlling?

    /// Called when the user clicks a notification peek (opens the posting app).
    var openNotificationHandler: ((IslandNotification) -> Void)?

    /// Controls that match whatever `nowPlaying` currently represents.
    var playbackController: PlaybackControlling? {
        debugNowPlaying != nil ? debugController : liveController
    }

    /// The notification currently peeking, if the active peek is a notification.
    var activeNotification: IslandNotification? {
        if case .notification(let notification)? = activePeek?.content {
            return notification
        }
        return nil
    }

    enum GestureStatus: Equatable {
        /// Camera on; the sign currently seen (nil = none yet).
        case listening(HandGesture?)
        /// Sign confirmed; its app is being opened.
        case opening(HandGesture)
        /// Camera unavailable / app missing.
        case unavailable(String)
    }

    /// Non-nil while left ⌥ is held (and briefly after a sign is recognized).
    @Published private(set) var gestureStatus: GestureStatus?

    func setGestureStatus(_ status: GestureStatus?) {
        guard status != gestureStatus else { return }
        gestureStatus = status
        recompute()
    }

    /// Battery percent + icon to the right of the notch (MacBooks only).
    var showsBatteryWing: Bool {
        !debugSuppressMusic && settings.alwaysShowBattery && power != nil
    }

    /// True while the compact island shows the charging indicator.
    var showsChargingIndicator: Bool {
        !debugSuppressMusic && settings.chargingIndicatorEnabled && (power?.isCharging ?? false)
    }

    private let settings: AppSettings
    private var liveNowPlaying: NowPlaying?
    private var debugNowPlaying: NowPlaying?
    private var debugSuppressMusic = false
    private var expandRequested = false
    private var pinnedExpanded = false
    private var hoverTask: Task<Void, Never>?
    private var peekTask: Task<Void, Never>?
    /// True only when the pointer *entered* the island while a peek was showing.
    /// A pointer that was already resting there when the peek arrived doesn't hold it open.
    private var peekHeldByHover = false
    private var peekQueue: [PeekItem] = []
    private var cancellables = Set<AnyCancellable>()

    init(settings: AppSettings) {
        self.settings = settings
        settings.$chargingIndicatorEnabled
            .merge(with: settings.$alwaysShowBattery)
            .dropFirst(2)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    // Geometry can change without a state change (compact gains/loses the battery).
                    self?.objectWillChange.send()
                    self?.recompute()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: Inputs

    func updateMetrics(_ metrics: NotchMetrics) {
        guard metrics != self.metrics else { return }
        self.metrics = metrics
    }

    func updateLiveNowPlaying(_ nowPlaying: NowPlaying?) {
        liveNowPlaying = nowPlaying
        recompute()
    }

    func updatePower(_ snapshot: PowerSnapshot?) {
        if power != snapshot {
            power = snapshot
        }
        // Live power peeks follow the latest reading (time to full arrives a moment after plug-in).
        if let snapshot, var active = activePeek,
           case .power(let event, _, true) = active.content {
            active.content = .power(event: event, snapshot: snapshot, isLive: true)
            activePeek = active
        }
        recompute()
    }

    func updateAudioDevices(_ devices: [AudioDevice]) {
        if audioDevices != devices {
            audioDevices = devices
        }
        // Keep an AirPods peek's battery rings current while it is on screen.
        if var active = activePeek, case .airpods(var info) = active.content,
           info.connected, let fresh = devices.first(where: { $0.id == info.device.id }) {
            info.device = fresh
            active.content = .airpods(info)
            activePeek = active
        }
    }

    /// Shows a notification peek (highest priority).
    func presentPeek(_ notification: IslandNotification) {
        present(PeekItem(content: .notification(notification), kind: .notification, duration: settings.peekDuration))
    }

    /// Shows a peek now if nothing more important is visible; otherwise queues it.
    func present(_ item: PeekItem) {
        if let active = activePeek {
            if item.kind > active.kind {
                // Pre-empt: the lower peek goes back into the queue and shows again afterwards (if still fresh).
                enqueue(active)
                show(item)
            } else {
                enqueue(item)
            }
        } else {
            show(item)
        }
        recompute()
    }

    func dismissPeek() {
        peekTask?.cancel()
        peekTask = nil
        peekHeldByHover = false
        activePeek = nil
        let now = Date()
        peekQueue.removeAll { now.timeIntervalSince($0.createdAt) > Self.stalePeekAge }
        if !peekQueue.isEmpty {
            show(peekQueue.removeFirst())
        }
        recompute()
    }

    /// Called by the window controller whenever the pointer enters/leaves the island.
    func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        hoverTask?.cancel()
        hoverTask = nil

        if hovering {
            if state.isPeek {
                // Keep the peek on screen while the user is reading it.
                peekHeldByHover = true
                peekTask?.cancel()
                peekTask = nil
            } else if state == .compact {
                let delay = settings.hoverDelay
                hoverTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
                    guard !Task.isCancelled, let self, self.isHovering else { return }
                    self.expandRequested = true
                    self.recompute()
                }
            }
        } else {
            if state.isPeek, peekHeldByHover {
                peekHeldByHover = false
                schedulePeekDismissal(after: 1.5)
            }
            guard expandRequested else { return }
            hoverTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled, let self, !self.isHovering else { return }
                self.expandRequested = false
                self.recompute()
            }
        }
    }

    /// Click on the island.
    func handleClick() {
        switch state {
        case .compact:
            hoverTask?.cancel()
            expandRequested = true
        case .expanded:
            expandRequested = false
            pinnedExpanded = false
        case .peek:
            if let notification = activeNotification {
                openNotificationHandler?(notification)
            }
            dismissPeek()
            return
        case .powerPeek, .airpodsPeek:
            dismissPeek()
            return
        case .idle, .battery, .gesture:
            break
        }
        recompute()
    }

    func collapse() {
        expandRequested = false
        pinnedExpanded = false
        recompute()
    }

    // MARK: Debug

    func debugShowIdle() {
        isDebugOverrideActive = true
        debugSuppressMusic = true
        debugNowPlaying = nil
        clearPeeks()
        collapse()
    }

    func debugShowCompact(sample: NowPlaying) {
        isDebugOverrideActive = true
        debugSuppressMusic = false
        debugNowPlaying = sample
        clearPeeks()
        collapse()
    }

    func debugShowExpanded(sample: NowPlaying) {
        isDebugOverrideActive = true
        debugSuppressMusic = false
        debugNowPlaying = sample
        clearPeeks()
        pinnedExpanded = true
        recompute()
    }

    func debugUpdateSample(_ sample: NowPlaying) {
        guard debugNowPlaying != nil else { return }
        debugNowPlaying = sample
        recompute()
    }

    func debugClearOverrides() {
        isDebugOverrideActive = false
        debugSuppressMusic = false
        debugNowPlaying = nil
        clearPeeks()
        collapse()
    }

    // MARK: Private

    private func show(_ item: PeekItem) {
        activePeek = item
        peekHeldByHover = false
        schedulePeekDismissal(after: item.duration)
    }

    /// Keeps the queue ordered by priority (then age) and at most `maxQueuedPeeks` long,
    /// dropping the least important, newest item when full.
    private func enqueue(_ item: PeekItem) {
        peekQueue.removeAll { $0.id == item.id }
        peekQueue.append(item)
        peekQueue.sort { lhs, rhs in
            lhs.kind != rhs.kind ? lhs.kind > rhs.kind : lhs.createdAt < rhs.createdAt
        }
        if peekQueue.count > Self.maxQueuedPeeks {
            peekQueue.removeLast(peekQueue.count - Self.maxQueuedPeeks)
        }
    }

    private func clearPeeks() {
        peekQueue.removeAll()
        peekTask?.cancel()
        peekTask = nil
        peekHeldByHover = false
        activePeek = nil
    }

    private func schedulePeekDismissal(after seconds: Double) {
        peekTask?.cancel()
        guard let current = activePeek?.id else { return }
        peekTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.5, seconds) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.activePeek?.id == current, !self.peekHeldByHover else { return }
            self.dismissPeek()
        }
    }

    private func recompute() {
        let music: NowPlaying? = debugSuppressMusic ? nil : (debugNowPlaying ?? liveNowPlaying)
        if nowPlaying != music {
            nowPlaying = music
        }

        let isPlaying = music?.isPlaying ?? false
        let batteryWing = showsBatteryWing
        // With the battery wing on, charging is shown there instead of in compact wings.
        let charging = showsChargingIndicator && !batteryWing
        let canExpand = music != nil || charging
        let newState: IslandState
        if gestureStatus != nil {
            // The user is deliberately holding ⌥: show that above everything else.
            newState = .gesture
        } else if let peek = activePeek {
            newState = peek.islandState
        } else if canExpand, expandRequested || pinnedExpanded {
            // Stays expanded while the pointer is on it, even if the user just paused.
            newState = .expanded
        } else if isPlaying || charging {
            newState = .compact
        } else if batteryWing {
            newState = .battery
        } else {
            newState = .idle
        }

        if !canExpand {
            expandRequested = false
            pinnedExpanded = false
        }
        if newState != state {
            state = newState
        }
    }
}
