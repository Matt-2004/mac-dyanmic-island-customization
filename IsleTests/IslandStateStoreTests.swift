import XCTest
@testable import Isle

@MainActor
final class IslandStateStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var settings: AppSettings!
    private var store: IslandStateStore!

    override func setUp() async throws {
        let suite = "IsleTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        settings = AppSettings(defaults: defaults)
        store = IslandStateStore(settings: settings)
    }

    private func track(playing: Bool) -> NowPlaying {
        NowPlaying(trackID: "t", title: "Song", artist: "Artist", album: "", duration: 200, position: 10,
                   positionTimestamp: Date(), isPlaying: playing, artwork: nil, accentColor: nil)
    }

    private func power(charging: Bool, percent: Int = 50) -> PowerSnapshot {
        PowerSnapshot(percent: percent, isCharging: charging, isPluggedIn: charging, isCharged: false,
                      minutesToFull: charging ? 60 : nil, minutesToEmpty: nil)
    }

    private func airpodsPeek(age: TimeInterval = 0) -> PeekItem {
        let device = AudioDevice(id: "A", name: "AirPods", kind: .airpods, battery: nil, isConnected: true)
        return PeekItem(content: .airpods(AirPodsPeekInfo(device: device, connected: true)), kind: .airpods,
                        duration: 3, createdAt: Date().addingTimeInterval(-age))
    }

    private func powerPeek(_ event: PowerEvent = .pluggedIn, age: TimeInterval = 0) -> PeekItem {
        PeekItem(content: .power(event: event, snapshot: power(charging: true), isLive: false),
                 kind: event.isCritical ? .criticalPower : .power, duration: 3,
                 createdAt: Date().addingTimeInterval(-age))
    }

    private func notification(_ title: String = "Hi") -> IslandNotification {
        IslandNotification(bundleIdentifier: "com.apple.MobileSMS", appName: "Messages", title: title)
    }

    func testIdleCompactAndPaused() {
        XCTAssertEqual(store.state, .idle)
        store.updateLiveNowPlaying(track(playing: true))
        XCTAssertEqual(store.state, .compact)
        store.updateLiveNowPlaying(track(playing: false))
        XCTAssertEqual(store.state, .idle, "paused music goes idle")
    }

    func testChargingShowsCompactOnlyWhenEnabled() {
        settings.alwaysShowBattery = false
        store.updatePower(power(charging: true))
        XCTAssertEqual(store.state, .compact)
        settings.chargingIndicatorEnabled = false
        store.updatePower(power(charging: true, percent: 51))
        XCTAssertEqual(store.state, .idle)
    }

    func testBatteryWingWhenNothingElseShows() {
        store.updatePower(power(charging: false, percent: 64))
        XCTAssertEqual(store.state, .battery)
        store.updatePower(power(charging: true, percent: 65))
        XCTAssertEqual(store.state, .battery, "charging is shown in the battery wing, not compact")
        store.updateLiveNowPlaying(track(playing: true))
        XCTAssertEqual(store.state, .compact)
        store.updateLiveNowPlaying(track(playing: false))
        XCTAssertEqual(store.state, .battery)
        store.presentPeek(notification())
        XCTAssertEqual(store.state, .peek)
        store.dismissPeek()
        XCTAssertEqual(store.state, .battery, "peek returns to the battery wing")
    }

    func testBatteryWingGrowsOnlyToTheRight() {
        let metrics = NotchMetrics(notchSize: CGSize(width: 200, height: 32), hasNotch: true)
        let size = IslandLayout.size(for: .battery, metrics: metrics, battery: true)
        let offset = IslandLayout.centerOffset(for: .battery, metrics: metrics, battery: true)
        XCTAssertEqual(offset - size.width / 2, -metrics.notchSize.width / 2, "left edge stays on the notch")
        let panel = IslandLayout.panelSize(metrics: metrics)
        XCTAssertGreaterThanOrEqual(panel.width / 2, offset + size.width / 2, "panel contains the shifted island")
    }

    func testNotificationPreemptsAirPodsWhichIsRestored() {
        store.updateLiveNowPlaying(track(playing: true))
        store.present(airpodsPeek())
        XCTAssertEqual(store.state, .airpodsPeek)
        store.presentPeek(notification())
        XCTAssertEqual(store.state, .peek)
        store.dismissPeek()
        XCTAssertEqual(store.state, .airpodsPeek, "pre-empted AirPods peek comes back")
        store.dismissPeek()
        XCTAssertEqual(store.state, .compact, "music restored afterwards")
    }

    func testLowerPriorityWaitsBehindHigher() {
        store.present(airpodsPeek())
        store.present(powerPeek())
        XCTAssertEqual(store.state, .airpodsPeek, "power does not interrupt AirPods")
        store.dismissPeek()
        XCTAssertEqual(store.state, .powerPeek)
    }

    func testCriticalBatteryBeatsAirPodsButNotNotification() {
        store.presentPeek(notification())
        store.present(powerPeek(.lowBattery(threshold: 10)))
        XCTAssertEqual(store.state, .peek, "notification keeps priority")
        store.present(airpodsPeek())
        store.dismissPeek()
        XCTAssertEqual(store.state, .powerPeek, "critical battery comes before AirPods")
        if case .power(let event, _, _)? = store.activePeek?.content {
            XCTAssertEqual(event, .lowBattery(threshold: 10))
        } else {
            XCTFail("expected the critical power peek")
        }
    }

    func testQueueIsCappedAtThree() {
        store.presentPeek(notification("first"))
        for _ in 0..<5 {
            store.present(powerPeek())
        }
        var shown = 0
        while store.activePeek != nil {
            store.dismissPeek()
            if store.activePeek != nil { shown += 1 }
        }
        XCTAssertEqual(shown, IslandStateStore.maxQueuedPeeks)
    }

    func testStalePeeksAreDropped() {
        store.presentPeek(notification())
        store.present(powerPeek(age: 30))
        store.dismissPeek()
        XCTAssertNil(store.activePeek, "a peek older than 10 s is not shown")
        XCTAssertEqual(store.state, .idle)
    }

    func testClickOnPowerPeekDismisses() {
        store.present(powerPeek())
        store.handleClick()
        XCTAssertNil(store.activePeek)
    }

    func testClickOnNotificationPeekOpensApp() {
        var opened: IslandNotification?
        store.openNotificationHandler = { opened = $0 }
        let item = notification("Open me")
        store.presentPeek(item)
        store.handleClick()
        XCTAssertEqual(opened?.title, "Open me")
        XCTAssertNil(store.activePeek)
    }
}
