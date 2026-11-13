import XCTest
@testable import Isle

final class BluetoothParsingTests: XCTestCase {
    func testParsesBatteriesAndToleratesMissingFields() throws {
        let json = """
        {"SPBluetoothDataType":[{"controller_properties":{},
          "device_connected":[
            {"AirPods":{"device_address":"AA:BB:CC:DD:EE:FF","device_batteryLevelLeft":"100%","device_batteryLevelRight":"95%",
                        "device_batteryLevelCase":"82%","device_minorType":"Headphones","device_vendorID":"0x004C"}},
            {"MX Master 3S":{"device_address":"11:22:33:44:55:66","device_minorType":"Mouse"}}
          ],
          "device_not_connected":[
            {"AirPods Max":{"device_address":"01-02-03-04-05-06","device_batteryLevelMain":"40%"}},
            {"Broken":{"device_address":"0A:0B:0C:0D:0E:0F","device_batteryLevelLeft":"n/a"}}
          ]}]}
        """
        let devices = BluetoothBatteryReader.parse(Data(json.utf8))
        let airpods = try XCTUnwrap(devices["AABBCCDDEEFF"])
        XCTAssertTrue(airpods.isConnected)
        XCTAssertEqual(airpods.battery, BatteryLevels(left: 100, right: 95, caseLevel: 82, main: nil))
        XCTAssertEqual(AudioDeviceKind.classify(name: airpods.name, minorType: airpods.minorType, vendorID: airpods.vendorID), .airpods)

        XCTAssertTrue(try XCTUnwrap(devices["112233445566"]).battery.isEmpty)
        XCTAssertEqual(devices["010203040506"]?.battery.main, 40)
        XCTAssertNil(devices["0A0B0C0D0E0F"]?.battery.left, "unparseable value is nil, not a crash")
    }

    func testGarbageInputIsEmpty() {
        XCTAssertTrue(BluetoothBatteryReader.parse(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(BluetoothBatteryReader.parse(Data("{}".utf8)).isEmpty)
    }

    func testMergeKeepsCaseLevelWhenCaseCloses() {
        let old = BatteryLevels(left: 90, right: 90, caseLevel: 70, main: nil)
        let new = BatteryLevels(left: 88, right: 89, caseLevel: nil, main: nil)
        XCTAssertEqual(new.merged(over: old), BatteryLevels(left: 88, right: 89, caseLevel: 70, main: nil))
        XCTAssertEqual(BatteryLevels.text(nil), "--")
    }

    func testClassification() {
        XCTAssertEqual(AudioDeviceKind.classify(name: "Cap's AirPods Pro", minorType: nil, vendorID: nil), .airpodsPro)
        XCTAssertEqual(AudioDeviceKind.classify(name: "AirPods Max", minorType: nil, vendorID: nil), .airpodsMax)
        XCTAssertEqual(AudioDeviceKind.classify(name: "Renamed Buds", minorType: "Headphones", vendorID: "0x004C"), .airpods)
        XCTAssertEqual(AudioDeviceKind.classify(name: "EMBERTON", minorType: "Speaker", vendorID: "0x090A"), .speaker)
        XCTAssertEqual(BluetoothAddress.normalize("aa-bb-cc-dd-ee-ff"), "AABBCCDDEEFF")
    }
}

final class PowerTests: XCTestCase {
    func testStatusText() {
        var snapshot = PowerSnapshot(percent: 40, isCharging: true, isPluggedIn: true, isCharged: false,
                                     minutesToFull: 80, minutesToEmpty: nil)
        XCTAssertEqual(snapshot.statusText, "Charging, 1h 20m to full")
        snapshot.minutesToFull = nil
        XCTAssertEqual(snapshot.statusText, "Charging")
        snapshot.percent = 100
        XCTAssertEqual(snapshot.statusText, "Fully charged")
        snapshot = PowerSnapshot(percent: 80, isCharging: false, isPluggedIn: true, isCharged: false,
                                 minutesToFull: nil, minutesToEmpty: nil)
        XCTAssertEqual(snapshot.statusText, "Plugged in, not charging")
        XCTAssertEqual(PowerSnapshot.duration(45), "45m")
        // Charger connected but macOS hasn't started charging yet: still drawn as charging.
        let negotiating = PowerSnapshot(percent: 77, isCharging: false, isPluggedIn: true, isCharged: false,
                                        minutesToFull: nil, minutesToEmpty: nil)
        XCTAssertTrue(negotiating.showsChargingStyle)
        XCTAssertEqual(negotiating.chargeDescription, ", plugged in")
        XCTAssertFalse(PowerSnapshot(percent: 77, isCharging: false, isPluggedIn: false, isCharged: false,
                                     minutesToFull: nil, minutesToEmpty: 300).showsChargingStyle)
        XCTAssertEqual(PowerSnapshot.duration(120), "2h")
    }

    @MainActor
    func testTransitions() {
        let service = PowerService()
        var events: [PowerEvent] = []
        service.onEvent = { event, _ in events.append(event) }
        func reading(_ percent: Int, plugged: Bool, charged: Bool = false) -> PowerSnapshot {
            PowerSnapshot(percent: percent, isCharging: plugged && !charged, isPluggedIn: plugged,
                          isCharged: charged, minutesToFull: nil, minutesToEmpty: nil)
        }
        service.apply(reading(25, plugged: false))         // baseline: nothing
        service.apply(reading(20, plugged: false))         // 20 %
        service.apply(reading(19, plugged: false))         // already warned
        service.apply(reading(10, plugged: false))         // 10 % critical
        service.apply(reading(10, plugged: true))          // plugged in
        service.apply(reading(100, plugged: true, charged: true)) // full
        service.apply(reading(100, plugged: true, charged: true)) // only once
        service.apply(reading(100, plugged: false))        // unplugged
        XCTAssertEqual(events, [
            .lowBattery(threshold: 20),
            .lowBattery(threshold: 10),
            .pluggedIn,
            .fullyCharged,
            .unplugged
        ])
    }

    @MainActor
    func testJustPluggedInReadsAsStartingToCharge() {
        let service = PowerService()
        func reading(plugged: Bool, charging: Bool) -> PowerSnapshot {
            PowerSnapshot(percent: 77, isCharging: charging, isPluggedIn: plugged, isCharged: false,
                          minutesToFull: charging ? 48 : nil, minutesToEmpty: nil)
        }
        service.apply(reading(plugged: false, charging: false), now: 100)
        service.apply(reading(plugged: true, charging: false), now: 101)
        XCTAssertEqual(service.snapshot?.isStartingToCharge, true)
        XCTAssertEqual(service.snapshot?.statusText, "Charging…")
        service.apply(reading(plugged: true, charging: true), now: 104)
        XCTAssertEqual(service.snapshot?.statusText, "Charging, 48m to full")
        // Still not charging long after plug-in (charge limit / paused): say so.
        service.apply(reading(plugged: true, charging: false), now: 101 + PowerService.chargeStartGrace + 1)
        XCTAssertEqual(service.snapshot?.statusText, "Plugged in, not charging")
    }

    @MainActor
    func testNoLowBatteryWhilePluggedIn() {
        let service = PowerService()
        var events: [PowerEvent] = []
        service.onEvent = { event, _ in events.append(event) }
        service.apply(PowerSnapshot(percent: 30, isCharging: true, isPluggedIn: true, isCharged: false, minutesToFull: nil, minutesToEmpty: nil))
        service.apply(PowerSnapshot(percent: 8, isCharging: true, isPluggedIn: true, isCharged: false, minutesToFull: nil, minutesToEmpty: nil))
        XCTAssertTrue(events.isEmpty)
    }
}

final class IconAndArtworkTests: XCTestCase {
    func testIconLinksPreferAppleTouchAndLargestAndSkipSVG() throws {
        let html = """
        <link rel="icon" href="/small.png" sizes="16x16">
        <link rel="icon" type="image/svg+xml" href="/vector.svg">
        <link rel="apple-touch-icon" sizes="180x180" href="https://cdn.example.com/touch.png">
        <link rel="icon" sizes="192x192" href="big.png">
        <link rel="stylesheet" href="/style.css">
        """
        let urls = IconLinkParser.iconURLs(in: html, baseURL: try XCTUnwrap(URL(string: "https://example.com/app/")))
        XCTAssertEqual(urls.first?.absoluteString, "https://cdn.example.com/touch.png")
        XCTAssertEqual(urls[1].absoluteString, "https://example.com/app/big.png")
        XCTAssertEqual(urls.last?.pathExtension, "svg")
        XCTAssertFalse(urls.contains { $0.path.hasSuffix(".css") })
    }

    func testPageMentionsName() {
        XCTAssertTrue(IconLinkParser.page("<title>Notion – Your workspace</title>", mentions: "notion"))
        XCTAssertTrue(IconLinkParser.page(#"<meta property="og:site_name" content="Trello">"#, mentions: "Trello"))
        XCTAssertFalse(IconLinkParser.page("<title>Domain for sale</title>", mentions: "Zapp"))
    }

    func testWebServiceLookup() {
        XCTAssertEqual(WebServiceDirectory.lookup(appName: "Messenger")?.domain, "www.messenger.com")
        XCTAssertEqual(WebServiceDirectory.lookup(appName: "Messenger")?.isGuess, false)
        XCTAssertEqual(WebServiceDirectory.lookup(appName: "Trello")?.isGuess, false)
        XCTAssertEqual(WebServiceDirectory.lookup(appName: "Zapp")?.domain, "zapp.com")
        XCTAssertEqual(WebServiceDirectory.lookup(appName: "Zapp")?.isGuess, true)
        XCTAssertNil(WebServiceDirectory.lookup(appName: "Login Items"))
        XCTAssertNil(WebServiceDirectory.lookup(appName: "Notification"))
    }

    func testITunesArtworkPicksMatchingTrack() throws {
        let json = """
        {"results":[
          {"trackName":"Other Song","artistName":"Someone","artworkUrl100":"https://a/1/100x100bb.jpg"},
          {"trackName":"Anti-Hero","artistName":"Taylor Swift","artworkUrl100":"https://a/2/100x100bb.jpg"}
        ]}
        """
        let url = ITunesArtworkSearch.bestArtworkURL(in: Data(json.utf8), title: "Anti-Hero", artist: "Taylor Swift")
        XCTAssertEqual(url?.absoluteString, "https://a/2/600x600bb.jpg")
        XCTAssertNil(ITunesArtworkSearch.bestArtworkURL(in: Data(json.utf8), title: "Nothing Like It", artist: "Nobody"))
    }
}

final class MiscParsingTests: XCTestCase {
    func testUsernotedRecordParsing() throws {
        let plist: [String: Any] = ["app": "com.apple.MobileSMS", "req": ["titl": "Sam", "body": "hello", "subt": ""]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let parsed = try XCTUnwrap(UsernotedNotificationSource.parse(data: data, bundleID: nil))
        XCTAssertEqual(parsed.bundleIdentifier, "com.apple.MobileSMS")
        XCTAssertEqual(parsed.title, "Sam")
        XCTAssertEqual(parsed.body, "hello")
        XCTAssertNil(parsed.subtitle)
        XCTAssertEqual(parsed.source, "usernoted")
        XCTAssertNil(UsernotedNotificationSource.parse(data: Data("junk".utf8), bundleID: nil))
    }

    func testNowPlayingExtrapolationIsClamped() {
        let start = Date()
        var track = NowPlaying(trackID: "t", title: "", artist: "", album: "", duration: 100, position: 95,
                               positionTimestamp: start, isPlaying: true, artwork: nil, accentColor: nil)
        XCTAssertEqual(track.elapsed(at: start.addingTimeInterval(3)), 98, accuracy: 0.001)
        XCTAssertEqual(track.elapsed(at: start.addingTimeInterval(30)), 100, accuracy: 0.001)
        track.isPlaying = false
        XCTAssertEqual(track.elapsed(at: start.addingTimeInterval(30)), 95, accuracy: 0.001)
        XCTAssertEqual(TimeFormatting.string(from: 3725), "1:02:05")
        XCTAssertEqual(TimeFormatting.string(from: .nan), "0:00")
    }
}
