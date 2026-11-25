import XCTest
@testable import PokiCore

final class PokiSequenceGuardTests: XCTestCase {
    private let shop = "com.example.shop"

    func testAppChangeStopsSequenceWithoutLaunchingOrTapping() async {
        let wda = FakeWDA()
        wda.tree([Node("Button", "Search", [16, 100, 150, 44])], app: "Shop")
        wda.set("GET /wda/activeAppInfo") { [shop] _ in
            (200, ["value": ["bundleId": .string(shop), "name": "Shop"]])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let look = await core.call("look", [:])
        XCTAssertTrue(look.text.contains("bundle_id: \(shop)"), look.text)

        wda.set("GET /wda/activeAppInfo") { _ in
            (200, ["value": ["bundleId": "com.example.other", "name": "Other"]])
        }
        let result = await core.call("do", ["actions": [["tap": 1]], "expect_front": .string(shop)])
        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("no longer confirmed in front"), result.text)
        XCTAssertNil(result.jpeg)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
        XCTAssertTrue(wda.bodies("POST /wda/apps/launch").isEmpty)
    }

    func testSequenceStopsBeforeTapThatNeedsApproval() async {
        let wda = FakeWDA()
        wda.tree([Node("Button", "立即支付", [16, 100, 150, 44])], app: "Shop")
        wda.set("GET /wda/activeAppInfo") { [shop] _ in
            (200, ["value": ["bundleId": .string(shop), "name": "Shop"]])
        }
        let (core, _, _) = makeCore(wda) {
            $0.standaloneObservations = true
            $0.sensitive.enabled = true
        }
        _ = await core.call("look", [:])

        let result = await core.call("do", ["actions": [["tap": 1]], "expect_front": .string(shop)])
        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("sequence stopped before action 1"), result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
    }
}
