import Foundation
import XCTest
@testable import PokiCore

final class PokiObservationTests: XCTestCase {
    private let pageFrame: [Double] = [0, 60, 390, 740]

    func testCoveredEditorDoesNotSupplyActionableControlsOnTheHomePage() async {
        let wda = FakeWDA()
        let host = FakeHost()
        let editor = Node("Other", nil, pageFrame, [
            Node("Button", "返回", [8, 76, 60, 44]),
            Node("StaticText", "你好 私人", [118, 76, 154, 44]),
            Node("Button", "共享", [304, 76, 78, 44]),
            Node("TextField", "标题", [16, 128, 358, 44], value: "你好"),
            Node("TextView", "正文", [16, 180, 358, 44], value: "你好"),
        ])
        wda.tree([editor], app: "Notes")
        let (core, _, _) = makeCore(wda, host: host) { $0.standaloneObservations = true }
        let old = await core.call("look", [:])
        XCTAssertTrue(old.text.contains("5 TextView"), old.text)

        let home = Node("Group", nil, pageFrame, [
            Node("StaticText", "主页", [118, 76, 154, 44]),
            Node("StaticText", "私人", [16, 128, 120, 44]),
            Node("Button", "撰写操作", [302, 710, 66, 66]),
        ])
        wda.tree([editor, home], app: "Notes")
        host.texts.value = [visualText("主页", x: 195, y: 98), visualText("私人", x: 60, y: 150)]
        let result = await core.call("look", ["full": true])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertNotNil(result.jpeg)
        XCTAssertTrue(result.text.contains("StaticText \"主页\""), result.text)
        XCTAssertTrue(result.text.contains("StaticText \"私人\""), result.text)
        XCTAssertTrue(result.text.contains("Button \"撰写操作\""), result.text)
        for hidden in ["返回", "共享", "你好"] {
            XCTAssertFalse(result.text.contains(hidden), result.text)
        }
        let tap = await core.call("do", ["actions": [["tap": 5]]])
        XCTAssertTrue(tap.isError, tap.text)
        XCTAssertTrue(tap.text.contains("element 5 is not in the latest read"), tap.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, tap.text)
    }

    func testOverlappingBranchesWithVisibleControlsInBothStayActionable() async {
        let wda = FakeWDA()
        let host = FakeHost()
        wda.tree([
            Node("Other", nil, pageFrame, [
                Node("Button", "Workspace", [16, 80, 160, 44]),
                Node("Button", "Settings", [16, 160, 160, 44]),
            ]),
            Node("Group", nil, pageFrame, [
                Node("Button", "Documents", [210, 80, 160, 44]),
                Node("Button", "New page", [210, 160, 160, 44]),
            ]),
        ])
        let sidebar = [
            visualText("Workspace", x: 90, y: 100),
            visualText("Settings", x: 90, y: 180),
        ]
        host.texts.value = sidebar + [
            visualText("Documents", x: 290, y: 100),
            visualText("New page", x: 290, y: 180),
        ]
        let (core, _, _) = makeCore(wda, host: host) { $0.standaloneObservations = true }

        let bothRecognized = await core.call("look", [:])
        host.texts.value = sidebar
        let oneRecognized = await core.call("look", [:])

        for result in [bothRecognized, oneRecognized] {
            for label in ["Workspace", "Settings", "Documents", "New page"] {
                XCTAssertTrue(result.text.contains("Button \"\(label)\""), result.text)
            }
        }
    }

    private func visualText(_ text: String, x: Double, y: Double) -> RecognizedText {
        RecognizedText(text: text, box: Rect(x: (x - 10) / 390, y: (y - 5) / 844, width: 20 / 390, height: 10 / 844))
    }

    func testTypingReturnsTheUnchangedKeyboardKeyWithTheCurrentField() async {
        let wda = FakeWDA()
        let keyboard = Node("Keyboard", nil, [0, 535, 390, 309], [
            Node("Button", "换行", [290, 760, 90, 47]),
        ])
        let titleFrame: [Double] = [16, 100, 350, 44]
        wda.tree([Node("TextField", "Title", titleFrame), keyboard])
        wda.set("POST /wda/keys") { [wda] _ in
            wda.tree([Node("TextField", "Title", titleFrame, value: "你好"), keyboard])
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }

        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["type": "你好"]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("TextField \"Title = 你好\""), result.text)
        XCTAssertTrue(result.text.contains("Button \"换行\""), result.text)
    }

    func testPictureChangeDuringTheTreeReadRefreshesTheControlsInTheSameResult() async {
        let wda = FakeWDA()
        let screenshots = LockedBox(0)
        wda.set("GET /screenshot") { _ in
            let number = screenshots.update { $0 += 1; return $0 }
            let png = Data((number == 1 ? "editor" : "workspace home").utf8)
            return (200, ["value": .string(png.base64EncodedString())])
        }
        wda.set("GET /source") { [wda] _ in
            wda.source([("Button", "Workspace"), ("Button", "New page")], app: "Notes")
            try await Task.sleep(for: .milliseconds(720))
            return (200, ["value": [
                "type": "XCUIElementTypeApplication", "label": "Notes", "children": [
                    ["type": "XCUIElementTypeButton", "label": "Editor", "rect": ["x": 16, "y": 100, "width": 358, "height": 44]],
                ],
            ]])
        }
        let (core, _, _) = makeCore(wda) { $0.readTimeout = 2 }

        let result = await core.call("look", [:])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Button \"Workspace\""), result.text)
        XCTAssertFalse(result.text.contains("Button \"Editor\""), result.text)
        XCTAssertEqual(result.jpeg, Data("jpeg:14".utf8))
    }

    func testAnUnconfirmedTransitionDoesNotLeaveOldReferencesUsable() async {
        let wda = FakeWDA()
        wda.source([("Button", "Old page")])
        let (core, _, _) = makeCore(wda) { $0.readTimeout = 2 }
        _ = await core.call("look", [:])

        let screenshots = LockedBox(0)
        wda.set("GET /screenshot") { _ in
            let number = screenshots.update { $0 += 1; return $0 }
            return (200, ["value": .string(Data("page \(number)".utf8).base64EncodedString())])
        }
        wda.set("GET /source") { [wda] _ in
            wda.set("GET /source") { _ in (500, ["value": ["error": "unknown error", "message": "transitioning"]]) }
            try await Task.sleep(for: .milliseconds(720))
            return (200, ["value": [
                "type": "XCUIElementTypeApplication", "label": "Settings", "children": [
                    ["type": "XCUIElementTypeButton", "label": "Old page", "rect": ["x": 16, "y": 100, "width": 358, "height": 44]],
                ],
            ]])
        }

        let result = await core.call("look", [:])
        XCTAssertFalse(result.text.contains("Old page"), result.text)
        XCTAssertNotNil(result.jpeg, result.text)
        let tap = await core.call("do", ["actions": [["tap": 1]]])
        XCTAssertTrue(tap.isError, tap.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, tap.text)
    }
}
