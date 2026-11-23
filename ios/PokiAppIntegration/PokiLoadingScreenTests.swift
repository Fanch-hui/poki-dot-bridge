import Foundation
import XCTest
@testable import PokiCore

final class PokiLoadingScreenTests: XCTestCase {
    private let shell = Node("Toolbar", "工具栏", [0, 0, 390, 844])

    func testTapWaitsForContentAndReturnsItsScreenshotAndReferences() async throws {
        let wda = FakeWDA()
        let reads = LockedBox(0)
        let loaded = LockedBox(false)
        let readyPNG = Data("ready picture".utf8)
        wda.tree([Node("Button", "Search", [20, 100, 120, 40])])
        wda.set("GET /screenshot") { _ in
            let data = loaded.value ? readyPNG : Data("shell".utf8)
            return (200, ["value": .string(data.base64EncodedString())])
        }
        let shellTree = source([shell])
        let readyTree = source([Node("Button", "Tea result", [20, 140, 180, 44])])
        wda.set("POST /wda/tap") { [wda] _ in
            wda.set("GET /source") { _ in
                let count = reads.update { $0 += 1; return $0 }
                if count > 1 { loaded.value = true }
                return (200, ["value": count > 1 ? readyTree : shellTree])
            }
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        _ = await core.call("look", [:])

        let result = await core.call("do", ["actions": [["tap": 1]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Button \"Tea result\""), result.text)
        XCTAssertTrue(result.text.contains("did: tap"), result.text)
        XCTAssertTrue(result.text.contains("screen_changed: true"), result.text)
        XCTAssertEqual(result.jpeg, Data("jpeg:\(readyPNG.count)".utf8))
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
        XCTAssertGreaterThanOrEqual(reads.value, 3)

        let line = try XCTUnwrap(result.text.split(separator: "\n").first { $0.contains("Button \"Tea result\"") })
        let ref = try XCTUnwrap(Int(line.split(separator: " ").first!.trimmingCharacters(in: CharacterSet(charactersIn: "+"))))
        let next = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])
        XCTAssertFalse(next.isError, next.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 2)
    }

    func testTimeoutKeepsTheReceiptAndReportsLoading() async {
        let wda = FakeWDA()
        wda.tree([Node("Button", "Search", [20, 100, 120, 40])])
        let shell = self.shell
        wda.set("POST /wda/tap") { [wda] _ in
            wda.tree([shell])
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        _ = await core.call("look", [:])

        let result = await core.call("do", ["actions": [["tap": 1]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("page is still loading"), result.text)
        XCTAssertTrue(result.text.contains("tap was already sent"), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
        XCTAssertNotNil(result.jpeg)
    }

    func testExplicitLoadingIndicatorReturnsAsSoonAsContentAppears() async {
        let wda = FakeWDA()
        let reads = LockedBox(0)
        wda.tree([Node("Button", "Search", [20, 100, 120, 40])])
        let loading = source([
            Node("ActivityIndicator", nil, [180, 400, 30, 30]),
            Node("StaticText", "加载中…", [130, 450, 130, 30]),
        ])
        let ready = source([Node("StaticText", "Found", [20, 150, 120, 44])])
        wda.set("POST /wda/tap") { [wda] _ in
            wda.set("GET /source") { _ in
                let count = reads.update { $0 += 1; return $0 }
                return (200, ["value": count > 1 ? ready : loading])
            }
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        _ = await core.call("look", [:])

        let result = await core.call("do", ["actions": [["tap": 1]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("StaticText \"Found\""), result.text)
        XCTAssertEqual(reads.value, 3, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
    }

    func testOrdinaryPagesAndDialogsDoNotPoll() async {
        let cases: [[Node]] = [
            [Node("StaticText", "No results", [20, 150, 200, 44])],
            [Node("Alert", "Permission", [30, 200, 330, 300], [Node("Button", "Allow", [50, 300, 120, 44])])],
            [shell, Node("Button", "Details", [30, 150, 150, 44])],
            [Node("ActivityIndicator", nil, [180, 400, 30, 30]), Node("StaticText", "No results", [20, 150, 200, 44])],
        ]
        for nodes in cases {
            let wda = FakeWDA()
            let reads = LockedBox(0)
            wda.tree([Node("Button", "Search", [20, 100, 120, 40])])
            let page = source(nodes)
            wda.set("POST /wda/tap") { [wda] _ in
                wda.set("GET /source") { _ in
                    reads.update { $0 += 1 }
                    return (200, ["value": page])
                }
                return (200, ["value": .null])
            }
            let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
            _ = await core.call("look", [:])
            let result = await core.call("do", ["actions": [["tap": 1]]])
            XCTAssertFalse(result.isError, result.text)
            XCTAssertEqual(reads.value, 1, result.text)
            XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
        }
    }

    private func source(_ nodes: [Node]) -> JSON {
        func json(_ node: Node) -> JSON {
            ["type": .string("XCUIElementType\(node.type)"), "label": node.label.map(JSON.string) ?? .null,
             "rect": ["x": .number(node.frame[0]), "y": .number(node.frame[1]),
                      "width": .number(node.frame[2]), "height": .number(node.frame[3])],
             "children": .array(node.children.map(json))]
        }
        return ["type": "XCUIElementTypeApplication", "rect": ["x": 0, "y": 0, "width": 390, "height": 844],
                "children": .array(nodes.map(json))]
    }
}
