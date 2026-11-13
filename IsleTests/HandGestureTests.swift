import XCTest
@testable import Isle

/// Synthetic hands in Vision's normalized coordinates (origin bottom-left), wrist at the bottom.
final class HandGestureTests: XCTestCase {
    private let wrist = CGPoint(x: 0.5, y: 0.2)

    /// Finger columns: index, middle, ring, little. PIP joints sit at y 0.45.
    private func hand(_ up: [Bool]) -> (tips: [CGPoint?], pips: [CGPoint?]) {
        let xs: [CGFloat] = [0.42, 0.48, 0.54, 0.60]
        let pips = xs.map { CGPoint(x: $0, y: 0.45) as CGPoint? }
        let tips = zip(xs, up).map { x, isUp in CGPoint(x: x, y: isUp ? 0.70 : 0.36) as CGPoint? }
        return (tips, pips)
    }

    func testOneTwoOpen() {
        var h = hand([true, false, false, false])
        XCTAssertEqual(HandGesture.classify(wrist: wrist, tips: h.tips, pips: h.pips), .one)
        h = hand([true, true, false, false])
        XCTAssertEqual(HandGesture.classify(wrist: wrist, tips: h.tips, pips: h.pips), .two)
        h = hand([true, true, true, true])
        XCTAssertEqual(HandGesture.classify(wrist: wrist, tips: h.tips, pips: h.pips), .open)
    }

    func testOtherShapesAreIgnored() {
        var h = hand([false, false, false, false])           // fist
        XCTAssertNil(HandGesture.classify(wrist: wrist, tips: h.tips, pips: h.pips))
        h = hand([true, true, true, false])                  // three fingers
        XCTAssertNil(HandGesture.classify(wrist: wrist, tips: h.tips, pips: h.pips))
        h = hand([false, true, false, false])                // middle finger only
        XCTAssertNil(HandGesture.classify(wrist: wrist, tips: h.tips, pips: h.pips))
        XCTAssertNil(HandGesture.classify(wrist: nil, tips: h.tips, pips: h.pips))
    }

    func testHiddenFoldedFingersStillCount() {
        var h = hand([true, true, false, false])
        h.tips[2] = nil
        h.tips[3] = nil
        XCTAssertEqual(HandGesture.classify(wrist: wrist, tips: h.tips, pips: h.pips), .two)
        var one = hand([true, false, false, false])
        one.tips[1] = nil                                    // middle unknown → not sure it's "one"
        XCTAssertNil(HandGesture.classify(wrist: wrist, tips: one.tips, pips: one.pips))
    }

    func testTargets() {
        XCTAssertEqual(HandGesture.one.target.name, "VS Code")
        XCTAssertEqual(HandGesture.two.target.bundleIdentifiers, ["com.apple.Terminal"])
        XCTAssertTrue(HandGesture.open.target.bundleIdentifiers.contains("com.microsoft.teams2"))
    }

    @MainActor
    func testGestureStateWinsAndClears() {
        let store = IslandStateStore(settings: AppSettings(defaults: UserDefaults(suiteName: "IsleTests.\(UUID())") ?? .standard))
        store.presentPeek(IslandNotification(bundleIdentifier: nil, appName: "Messages", title: "hi"))
        store.setGestureStatus(.listening(nil))
        XCTAssertEqual(store.state, .gesture)
        store.setGestureStatus(nil)
        XCTAssertEqual(store.state, .peek, "the pending peek comes back")
    }
}
