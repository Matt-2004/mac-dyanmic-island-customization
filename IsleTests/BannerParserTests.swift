import XCTest
@testable import Isle

/// Fixtures mirror the macOS 26 NotificationCenter tree captured in ax-dump.txt
/// (structure only; texts are invented).
final class BannerParserTests: XCTestCase {
    private let closeAction = "Name:Close\nTarget:0x0\nSelector:(null)"

    private func resolver(_ name: String) -> String? {
        ["Script Editor": "com.apple.ScriptEditor2", "Messages": "com.apple.MobileSMS"][name]
    }

    private func window(banners: [AXNode], panelOpen: Bool = false) -> AXNode {
        AXNode(role: "AXWindow", subrole: "AXSystemDialog", title: "Notification Center",
               frame: CGRect(x: 0, y: 0, width: 1710, height: 1107), children: [
            AXNode(role: "AXGroup", subrole: "AXHostingView", children: [
                AXNode(role: "AXGroup", children: [
                    AXNode(role: "AXScrollArea", children: banners),
                    AXNode(role: "AXGroup", identifier: "widgets-overlay-view",
                           frame: panelOpen ? CGRect(x: 855, y: 50, width: 400, height: 800) : CGRect(x: 855, y: 554, width: 0, height: 0))
                ])
            ])
        ])
    }

    private func banner(id: String, desc: String, texts: [(String?, String)]) -> AXNode {
        AXNode(role: "AXGroup", subrole: "AXNotificationCenterBanner", identifier: id, descriptionText: desc,
               actions: ["AXPress", closeAction],
               children: texts.map { AXNode(role: "AXStaticText", identifier: $0.0, value: $0.1) })
    }

    func testNativeAppBanner() throws {
        let tree = window(banners: [
            banner(id: "8BE5EC43-689F-4002-9297-5D88E32000D5",
                   desc: "Script Editor, Second Test, Second body",
                   texts: [("title", "Second Test"), ("body", "Second body")])
        ])
        let result = BannerParser.banners(inWindows: [tree], resolveBundleID: resolver)
        let parsed = try XCTUnwrap(result.first)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(parsed.appName, "Script Editor")
        XCTAssertEqual(parsed.bundleIdentifier, "com.apple.ScriptEditor2")
        XCTAssertEqual(parsed.title, "Second Test")
        XCTAssertEqual(parsed.body, "Second body")
        XCTAssertFalse(parsed.isInHistoryPanel)
        XCTAssertEqual(parsed.identity, "id:8BE5EC43-689F-4002-9297-5D88E32000D5")
        XCTAssertEqual(parsed.closeAction, closeAction)
    }

    func testWebAppBannerRebuildsSenderAndMessageWithCommas() throws {
        let tree = window(banners: [
            banner(id: "mid.$gAAX4aQs3nDG",
                   desc: "Messenger, Alex Doe, ok, see you at 5, bring snacks",
                   texts: [("title", "Messenger"), ("body", "Notification")])
        ])
        let parsed = try XCTUnwrap(BannerParser.banners(inWindows: [tree], resolveBundleID: resolver).first)
        XCTAssertEqual(parsed.appName, "Messenger")
        XCTAssertNil(parsed.bundleIdentifier)
        XCTAssertEqual(parsed.title, "Alex Doe")
        XCTAssertEqual(parsed.body, "ok, see you at 5, bring snacks", "commas inside the message must survive")
    }

    func testPanelOpenMarksHistory() throws {
        let tree = window(banners: [
            banner(id: "A", desc: "Messages, Sam, hi", texts: [("title", "Sam"), ("body", "hi")])
        ], panelOpen: true)
        let parsed = try XCTUnwrap(BannerParser.banners(inWindows: [tree], resolveBundleID: resolver).first)
        XCTAssertTrue(parsed.isInHistoryPanel)
        XCTAssertEqual(parsed.appName, "Messages")
    }

    func testIdenticalMessagesHaveDifferentIdentities() {
        let tree = window(banners: [
            banner(id: "one", desc: "Messages, Sam, ok", texts: [("title", "Sam"), ("body", "ok")]),
            banner(id: "two", desc: "Messages, Sam, ok", texts: [("title", "Sam"), ("body", "ok")])
        ])
        let parsed = BannerParser.banners(inWindows: [tree], resolveBundleID: resolver)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].fingerprint, parsed[1].fingerprint)
        XCTAssertNotEqual(parsed[0].identity, parsed[1].identity)
    }

    func testStackSubroleIsNotABanner() {
        let stack = AXNode(role: "AXGroup", subrole: "AXNotificationCenterBannerStack", children: [
            banner(id: "inner", desc: "Messages, Sam, hi", texts: [("title", "Sam"), ("body", "hi")])
        ])
        let parsed = BannerParser.banners(inWindows: [window(banners: [stack])], resolveBundleID: resolver)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.identifier, "inner")
    }

    func testFallbackGroupWithoutSubrole() {
        let group = AXNode(role: "AXGroup", children: [
            AXNode(role: "AXStaticText", identifier: "title", value: "Build finished"),
            AXNode(role: "AXStaticText", identifier: "body", value: "Isle succeeded")
        ])
        let parsed = BannerParser.banners(inWindows: [window(banners: [group])], resolveBundleID: resolver)
        XCTAssertEqual(parsed.first?.title, "Build finished")
        XCTAssertEqual(parsed.first?.identity.hasPrefix("fp:"), true, "no identifier → content identity")
    }

    func testWidgetsWindowsProduceNothing() {
        let widget = AXNode(role: "AXWindow", subrole: "AXUnknown", title: "Forecast", children: [
            AXNode(role: "AXGroup", identifier: "widget-local:com.apple.weather", descriptionText: "Weather", children: [
                AXNode(role: "AXStaticText", value: "26°")
            ])
        ])
        XCTAssertTrue(BannerParser.banners(inWindows: [widget], resolveBundleID: resolver).isEmpty)
    }

    func testRebuildFromDescription() {
        XCTAssertNil(BannerParser.rebuildFromDescription("Script Editor, Title, Body", appName: "Title"))
        let onlySender = BannerParser.rebuildFromDescription("Gmail, New mail", appName: "Gmail")
        XCTAssertEqual(onlySender?.sender, "New mail")
        XCTAssertNil(onlySender?.message)
    }
}
