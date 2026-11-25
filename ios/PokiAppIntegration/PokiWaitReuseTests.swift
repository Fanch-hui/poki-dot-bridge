import Foundation
import CoreGraphics
import XCTest
@testable import PokiCore

final class PokiWaitReuseTests: XCTestCase {
    private func page(_ elements: [Node]) async throws -> JSON {
        let fake = FakeWDA()
        fake.tree(elements)
        let result = try await fake.send(method: "GET", url: URL(string: "http://127.0.0.1/source")!, body: nil, timeout: 1)
        return try JSON.parse(result.body)["value"]!
    }

    func testSuccessfulTapAndWaitUseTheSamePairedRead() async throws {
        let wda = FakeWDA()
        let sourceReads = LockedBox(0)
        let initial = PictureSketchTests.png { _ in }
        let final = PictureSketchTests.png { $0.fill(CGRect(x: 0, y: 0, width: 402, height: 300)) }
        let picture = LockedBox(initial)
        wda.tree([Node("Cell", "Shop", [20, 100, 150, 44])])
        let destination = try await page([Node("Button", "Menu", [20, 150, 150, 44])])
        wda.set("GET /screenshot") { _ in (200, ["value": .string(picture.value.base64EncodedString())]) }
        wda.set("POST /wda/tap") { [wda] _ in
            picture.value = final
            wda.set("GET /source") { _ in
                sourceReads.update { $0 += 1 }
                return (200, ["value": destination])
            }
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["tap": 1], ["wait_until": "Menu"]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Button \"Menu\""), result.text)
        XCTAssertTrue(result.text.contains("wait_until: \"Menu\" appeared"), result.text)
        XCTAssertEqual(result.jpeg, Data("jpeg:\(final.count)".utf8))
        XCTAssertEqual(sourceReads.value, 1, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
    }

    func testMarkerAlreadyOnOldPageFallsBackToFreshRead() async throws {
        let wda = FakeWDA()
        let sourceReads = LockedBox(0)
        let initial = PictureSketchTests.png { _ in }
        let final = PictureSketchTests.png { $0.fill(CGRect(x: 0, y: 0, width: 402, height: 300)) }
        let picture = LockedBox(initial)
        let initialNodes = [Node("Cell", "Shop", [20, 100, 150, 44]), Node("Button", "Menu", [20, 150, 150, 44])]
        wda.tree(initialNodes)
        let destination = try await page([Node("Button", "Menu", [20, 150, 150, 44])])
        wda.set("GET /screenshot") { _ in (200, ["value": .string(picture.value.base64EncodedString())]) }
        wda.set("POST /wda/tap") { [wda] _ in
            picture.value = final
            wda.set("GET /source") { _ in
                sourceReads.update { $0 += 1 }
                return (200, ["value": destination])
            }
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["tap": 1], ["wait_until": "Menu"]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(sourceReads.value, 2, result.text)
    }

    func testDialogDuringWaitFallsBackToNormalRead() async throws {
        let wda = FakeWDA()
        let sourceReads = LockedBox(0)
        let initial = PictureSketchTests.png { _ in }
        let final = PictureSketchTests.png { $0.fill(CGRect(x: 0, y: 0, width: 402, height: 300)) }
        let picture = LockedBox(initial)
        wda.tree([Node("Cell", "Shop", [20, 100, 150, 44])])
        let dialog = try await page([Node("Alert", "Notice", [10, 80, 370, 500], [Node("Button", "Menu", [20, 150, 150, 44])])])
        wda.set("GET /screenshot") { _ in (200, ["value": .string(picture.value.base64EncodedString())]) }
        wda.set("POST /wda/tap") { [wda] _ in
            picture.value = final
            wda.set("GET /source") { _ in
                sourceReads.update { $0 += 1 }
                return (200, ["value": dialog])
            }
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["tap": 1], ["wait_until": "Menu"]]])

        XCTAssertTrue(result.text.contains("Alert"), result.text)
        XCTAssertEqual(sourceReads.value, 2, result.text)
    }

    func testDuplicateMarkersFallBackToFreshRead() async throws {
        let wda = FakeWDA()
        let sourceReads = LockedBox(0)
        let initial = PictureSketchTests.png { _ in }
        let final = PictureSketchTests.png { $0.fill(CGRect(x: 0, y: 0, width: 402, height: 300)) }
        let picture = LockedBox(initial)
        wda.tree([Node("Cell", "Shop", [20, 100, 150, 44])])
        let destination = try await page([
            Node("Button", "Menu", [20, 150, 150, 44]),
            Node("Button", "Menu", [20, 220, 150, 44]),
        ])
        wda.set("GET /screenshot") { _ in (200, ["value": .string(picture.value.base64EncodedString())]) }
        wda.set("POST /wda/tap") { [wda] _ in
            picture.value = final
            wda.set("GET /source") { _ in
                sourceReads.update { $0 += 1 }
                return (200, ["value": destination])
            }
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["tap": 1], ["wait_until": "Menu"]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(sourceReads.value, 2, result.text)
    }

    func testSearchFieldLabelCanConfirmTheNextPage() async throws {
        let wda = FakeWDA()
        let sourceReads = LockedBox(0)
        let initial = PictureSketchTests.png { _ in }
        let final = PictureSketchTests.png { $0.fill(CGRect(x: 0, y: 0, width: 402, height: 300)) }
        let picture = LockedBox(initial)
        wda.tree([Node("Button", "搜索", [20, 100, 150, 44])])
        let destination = try await page([Node("TextField", "请输入商品名", [20, 100, 260, 44])])
        wda.set("GET /screenshot") { _ in (200, ["value": .string(picture.value.base64EncodedString())]) }
        wda.set("POST /wda/tap") { [wda] _ in
            picture.value = final
            wda.set("GET /source") { _ in
                sourceReads.update { $0 += 1 }
                return (200, ["value": destination])
            }
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["tap": 1], ["wait_until": "请输入商品名"]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("TextField \"请输入商品名\""), result.text)
        XCTAssertEqual(sourceReads.value, 1, result.text)
    }

    func testLiveSearchReusesTheResultRead() async throws {
        let wda = FakeWDA()
        let sourceReads = LockedBox(0)
        let initial = PictureSketchTests.png { _ in }
        let final = PictureSketchTests.png { $0.fill(CGRect(x: 0, y: 0, width: 402, height: 300)) }
        let picture = LockedBox(initial)
        let search = Node("StaticText", "搜索", [300, 102, 40, 35])
        wda.tree([Node("TextField", "请输入商品名", [20, 100, 260, 44]), search])
        let resultPage = try await page([
            Node("TextField", "请输入商品名", [20, 100, 260, 44], value: "tea"),
            search, Node("StaticText", "Results", [16, 160, 200, 44]),
        ])
        wda.set("GET /screenshot") { _ in (200, ["value": .string(picture.value.base64EncodedString())]) }
        wda.set("POST /wda/keys") { [wda] _ in
            picture.value = final
            wda.set("GET /source") { _ in
                sourceReads.update { $0 += 1 }
                return (200, ["value": resultPage])
            }
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true; $0.toolDeadline = 20 }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [
            ["type": "tea", "ref": 1],
            ["wait_until": ["texts_any": ["Results"], "present_before": [], "ms": 5000]],
        ]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("result \"Results\" appeared"), result.text)
        // Typing verifies the field once, then the wait returns its paired result.
        XCTAssertEqual(sourceReads.value, 2, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/keys").count, 1)
    }
}
