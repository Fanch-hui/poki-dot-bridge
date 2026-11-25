import XCTest
@testable import PokiCore

final class PokiNavigationBarReachabilityTests: XCTestCase {
    private func reference(in text: String, label: String) throws -> Int {
        let line = try XCTUnwrap(text.split(separator: "\n").first { $0.contains("Other \"\(label)\"") })
        let first = try XCTUnwrap(line.trimmingCharacters(in: .whitespaces).split(separator: " ").first)
        return try XCTUnwrap(Int(first))
    }

    func testNavigationBarRoundingDoesNotCoverItsSearchControl() async throws {
        let wda = FakeWDA()
        wda.tree([
            Node("NavigationBar", "Shop", [0, 62, 390, 44]),
            Node("Other", "搜索", [196, 61, 30, 30]),
        ])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let observed = await core.call("look", [:])
        let ref = try reference(in: observed.text, label: "搜索")
        let line = try XCTUnwrap(observed.text.split(separator: "\n").first { $0.contains("Other \"搜索\"") })
        XCTAssertFalse(line.contains("[covered]"), observed.text)

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertFalse(result.isError, result.text)
        let tap = try XCTUnwrap(wda.bodies("POST /wda/tap").first)
        XCTAssertEqual(tap["x"]?.double, 211)
        XCTAssertEqual(tap["y"]?.double, 76)
    }

    func testARealOverlappingActionStillCoversTheHeaderControl() async throws {
        let wda = FakeWDA()
        wda.tree([
            Node("NavigationBar", "Shop", [0, 62, 390, 44]),
            Node("Other", "搜索", [196, 61, 30, 30]),
            Node("Button", "确认支付", [196, 61, 30, 30]),
        ])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let observed = await core.call("look", [:])
        let ref = try reference(in: observed.text, label: "搜索")
        let line = try XCTUnwrap(observed.text.split(separator: "\n").first { $0.contains("Other \"搜索\"") })
        XCTAssertTrue(line.contains("[covered]"), observed.text)

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testBarThatOnlyPartlyOverlapsDoesNotBecomeTheControlsContainer() async throws {
        let wda = FakeWDA()
        wda.tree([
            Node("NavigationBar", "Shop", [196, 66, 30, 30]),
            Node("Other", "搜索", [196, 61, 30, 30]),
        ])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let observed = await core.call("look", [:])
        let ref = try reference(in: observed.text, label: "搜索")
        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testSimilarSizedBarOverlappingByOnePointStillCoversTheControl() async throws {
        let wda = FakeWDA()
        wda.tree([
            Node("NavigationBar", "Shop", [196, 62, 30, 30]),
            Node("Other", "搜索", [196, 61, 30, 30]),
        ])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let observed = await core.call("look", [:])
        let ref = try reference(in: observed.text, label: "搜索")
        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }
}
