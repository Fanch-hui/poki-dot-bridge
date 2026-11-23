import Foundation
import CoreGraphics
import XCTest
@testable import PokiCore

final class PokiTapLatencyTests: XCTestCase {
    func testReadyNavigationUsesOneImmediatePairedRead() async {
        let wda = FakeWDA()
        let sourceReads = LockedBox(0)
        let before = PictureSketchTests.png { _ in }
        let after = PictureSketchTests.png { $0.fill(CGRect(x: 0, y: 0, width: 402, height: 300)) }
        let picture = LockedBox(before)
        let destination = page("Destination")
        wda.tree([Node("Button", "Search", [20, 100, 150, 44])])
        wda.set("GET /screenshot") { _ in (200, ["value": .string(picture.value.base64EncodedString())]) }
        wda.set("POST /wda/tap") { [wda] _ in
            picture.value = after
            wda.set("GET /source") { _ in
                sourceReads.update { $0 += 1 }
                return (200, ["value": destination])
            }
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        _ = await core.call("look", [:])
        let began = Date.timeIntervalSinceReferenceDate
        let result = await core.call("do", ["actions": [["tap": 1]]])
        let elapsed = Date.timeIntervalSinceReferenceDate - began

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Button \"Destination\""), result.text)
        XCTAssertFalse(result.text.contains("paused 450 ms"), result.text)
        XCTAssertEqual(sourceReads.value, 1, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
        XCTAssertEqual(result.jpeg, Data("jpeg:\(after.count)".utf8))
        print("immediate navigation: \(Int(elapsed * 1000)) ms in FakeWDA")
    }

    func testDelayedNavigationWaitsThenReturnsFreshPage() async {
        let wda = FakeWDA()
        let sourceReads = LockedBox(0)
        let tapAt = LockedBox(0.0)
        let before = PictureSketchTests.png { _ in }
        let after = PictureSketchTests.png { $0.fill(CGRect(x: 0, y: 0, width: 402, height: 300)) }
        let initialPage = page("Search")
        let destination = page("Destination")
        let ready: @Sendable () -> Bool = {
            tapAt.value > 0 && Date.timeIntervalSinceReferenceDate - tapAt.value > 0.2
        }
        wda.tree([Node("Button", "Search", [20, 100, 150, 44])])
        wda.set("GET /screenshot") { _ in
            (200, ["value": .string((ready() ? after : before).base64EncodedString())])
        }
        wda.set("POST /wda/tap") { [wda] _ in
            tapAt.value = Date.timeIntervalSinceReferenceDate
            wda.set("GET /source") { _ in
                sourceReads.update { $0 += 1 }
                return (200, ["value": ready() ? destination : initialPage])
            }
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["tap": 1]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Button \"Destination\""), result.text)
        XCTAssertEqual(result.jpeg, Data("jpeg:\(after.count)".utf8))
        XCTAssertEqual(sourceReads.value, 2, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
    }

    func testOrdinaryToggleKeepsTheExistingSingleRead() async {
        let wda = FakeWDA()
        let sourceReads = LockedBox(0)
        let page = page("Favorite")
        wda.tree([Node("Button", "Favorite", [20, 100, 150, 44])])
        wda.set("POST /wda/tap") { [wda] _ in
            wda.set("GET /source") { _ in
                sourceReads.update { $0 += 1 }
                return (200, ["value": page])
            }
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["tap": 1]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("paused 450 ms"), result.text)
        XCTAssertEqual(sourceReads.value, 1, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
    }

    func testChangingHomeAdvertisementDoesNotConfirmNavigation() async {
        let wda = FakeWDA()
        let sourceReads = LockedBox(0)
        let tapAt = LockedBox(0.0)
        let before = PictureSketchTests.png { _ in }
        let advertisement = PictureSketchTests.png { $0.fill(CGRect(x: 0, y: 0, width: 402, height: 300)) }
        let destinationImage = PictureSketchTests.png { $0.fill(CGRect(x: 0, y: 300, width: 402, height: 300)) }
        let changingHome = page("Search", detail: "Limited-time promotion")
        let destination = page("Destination")
        let ready: @Sendable () -> Bool = {
            tapAt.value > 0 && Date.timeIntervalSinceReferenceDate - tapAt.value > 0.2
        }
        wda.tree([Node("Button", "Search", [20, 100, 150, 44])])
        wda.set("GET /screenshot") { _ in
            let picture = tapAt.value == 0 ? before : (ready() ? destinationImage : advertisement)
            return (200, ["value": .string(picture.base64EncodedString())])
        }
        wda.set("POST /wda/tap") { [wda] _ in
            tapAt.value = Date.timeIntervalSinceReferenceDate
            wda.set("GET /source") { _ in
                sourceReads.update { $0 += 1 }
                return (200, ["value": ready() ? destination : changingHome])
            }
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["tap": 1]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Button \"Destination\""), result.text)
        XCTAssertEqual(result.jpeg, Data("jpeg:\(destinationImage.count)".utf8))
        XCTAssertEqual(sourceReads.value, 2, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
    }

    private func page(_ title: String, detail: String? = nil) -> JSON {
        var children: [JSON] = [[
            "type": "XCUIElementTypeButton", "label": .string(title),
            "rect": ["x": 20, "y": 100, "width": 150, "height": 44],
        ]]
        if let detail {
            children.append(["type": "XCUIElementTypeStaticText", "label": .string(detail),
                             "rect": ["x": 20, "y": 180, "width": 200, "height": 44]])
        }
        return ["type": "XCUIElementTypeApplication", "children": [[
            "type": "XCUIElementTypeOther", "children": .array(children),
            "rect": ["x": 0, "y": 0, "width": 390, "height": 844],
        ]]]
    }
}
