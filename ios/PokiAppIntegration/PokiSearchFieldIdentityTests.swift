import XCTest
@testable import PokiCore

final class PokiSearchFieldIdentityTests: XCTestCase {
    func testSearchFieldIdentityDiagnosticDoesNotExposeAccessibilityIdentifiers() async throws {
        @Sendable func tree(_ identifier: String) -> JSON {
            ["type": "XCUIElementTypeApplication", "children": [[
                "type": "XCUIElementTypeSearchField", "label": "搜索", "name": .string(identifier),
                "rect": ["x": 12, "y": 127, "width": 366, "height": 33],
            ]]]
        }
        let wda = FakeWDA()
        wda.set("GET /source") { _ in (200, ["value": tree("private-old-id")]) }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let ref = try number(in: screen.text, containing: "SearchField \"搜索\"")
        wda.set("GET /source") { _ in (200, ["value": tree("private-new-id")]) }

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("identity counts: previous=1, current=1, same_identifier=0, at_point=0"), result.text)
        XCTAssertFalse(result.text.contains("private-old-id"), result.text)
        XCTAssertFalse(result.text.contains("private-new-id"), result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testSearchFieldIdentityDiagnosticCountsUnlistedMirrors() async throws {
        let frame: [Double] = [12, 127, 366, 33]
        let wda = FakeWDA()
        wda.tree([
            Node("SearchField", "搜索", frame),
            Node("ScrollView", nil, [0, 64, 390, 700], [Node("SearchField", "搜索", frame)]),
        ])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let ref = try number(in: screen.text, containing: "SearchField \"搜索\"")
        XCTAssertTrue(screen.text.contains("[row unverified]"), screen.text)
        XCTAssertEqual(screen.text.split(separator: "\n").filter { $0.contains("SearchField \"搜索\"") }.count, 1)

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("identity counts: previous=2, current=2, same_identifier=2, at_point=2"), result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testNestedSearchFieldMirrorsUseStablePageAnchors() async throws {
        let frame: [Double] = [12, 127, 366, 33]
        let field = Node("SearchField", "搜索", frame, [Node("SearchField", "搜索", frame)])
        let wda = FakeWDA()
        wda.tree(searchPage([field]))
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let line = try XCTUnwrap(screen.text.split(separator: "\n").first { $0.contains("SearchField \"搜索\"") })
        XCTAssertFalse(line.contains("[row unverified]"), screen.text)
        XCTAssertFalse(line.contains("[covered]"), screen.text)
        let ref = try number(in: String(line), containing: "SearchField")
        wda.tree(searchPage([field, Node("Cell", "A different loaded item", [0, 250, 390, 80])]))

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").first?["x"]?.double, 195)
        XCTAssertEqual(wda.bodies("POST /wda/tap").first?["y"]?.double, 143.5)
    }

    func testSearchFieldMirrorsWithinOneSearchBarCanBeTapped() async throws {
        let frame: [Double] = [12, 127, 366, 33]
        let search = Node("SearchBar", nil, frame, [
            Node("Group", nil, frame, [Node("SearchField", "搜索", frame)]),
            Node("Other", nil, frame, [Node("SearchField", "搜索", frame)]),
        ])
        let wda = FakeWDA()
        wda.tree(searchPage([search]))
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let ref = try number(in: screen.text, containing: "SearchField \"搜索\"")

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1, result.text)
    }

    func testSearchFieldMirrorsRejectAChangedPageAnchor() async throws {
        let frame: [Double] = [12, 127, 366, 33]
        let field = Node("SearchField", "搜索", frame, [Node("SearchField", "搜索", frame)])
        let wda = FakeWDA()
        wda.tree(searchPage([field]))
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let ref = try number(in: screen.text, containing: "SearchField \"搜索\"")
        wda.tree(searchPage([field], secondTitle: "其他页面"))

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testSearchFieldMirrorsDoNotHideDistinctControlsOrListRows() async throws {
        let frame: [Double] = [12, 127, 366, 33]
        let field = Node("SearchField", "搜索", frame, [Node("SearchField", "搜索", frame)])
        let bar = Node("SearchBar", nil, frame, [field])
        let cases: [[Node]] = [
            [Node("SearchBar", nil, frame, [Node("SearchField", "搜索", frame)]),
             Node("SearchBar", nil, frame, [Node("SearchField", "搜索", frame)])],
            [field, Node("SearchField", "其他搜索", frame)],
            [field, Node("TextField", "搜索", frame)],
            [field, Node("Button", "立即支付", frame)],
            [field, Node("Alert", "Overlay", frame)],
            [Node("SearchBar", nil, frame, [
                Node("Group", "First search", frame, [Node("SearchField", "搜索", frame)]),
                Node("Group", "Second search", frame, [Node("SearchField", "搜索", frame)]),
            ])],
            [Node("Cell", "Shop A", [0, 110, 390, 70], [bar])],
            [Node("ScrollView", nil, [0, 105, 390, 600], [
                Node("Group", nil, [0, 110, 390, 70], [bar]),
                Node("Group", nil, [0, 200, 390, 70], [Node("StaticText", "Shop B", [12, 205, 200, 30])]),
            ])],
        ]
        for content in cases {
            let wda = FakeWDA()
            wda.tree(searchPage(content))
            let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
            let screen = await core.call("look", [:])
            let ref = try number(in: screen.text, containing: "SearchField \"搜索\"")

            let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

            XCTAssertTrue(result.isError, result.text)
            XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
        }
    }

    func testSearchFieldMirrorsCannotChangeAccessibilityIdentifier() async throws {
        @Sendable func tree(_ identifier: String) -> JSON {
            let field: JSON = ["type": "XCUIElementTypeSearchField", "label": "搜索", "name": .string(identifier),
                               "rect": ["x": 12, "y": 127, "width": 366, "height": 33]]
            let parent: JSON = ["type": "XCUIElementTypeSearchField", "label": "搜索", "name": .string(identifier),
                                "rect": ["x": 12, "y": 127, "width": 366, "height": 33], "children": [field]]
            return ["type": "XCUIElementTypeApplication", "children": [
                ["type": "XCUIElementTypeStaticText", "label": "首页", "rect": ["x": 130, "y": 59, "width": 50, "height": 26]],
                ["type": "XCUIElementTypeStaticText", "label": "自取", "rect": ["x": 190, "y": 59, "width": 50, "height": 26]],
                parent,
            ]]
        }
        let wda = FakeWDA()
        wda.set("GET /source") { _ in (200, ["value": tree("old-search")]) }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let ref = try number(in: screen.text, containing: "SearchField \"搜索\"")
        wda.set("GET /source") { _ in (200, ["value": tree("new-search")]) }

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testSearchFieldMirrorsRejectTwoUnrelatedHeaderRows() async throws {
        let frame: [Double] = [12, 127, 366, 33]
        let field = Node("SearchField", "搜索", frame, [Node("SearchField", "搜索", frame)])
        let wda = FakeWDA()
        wda.tree([
            Node("StaticText", "首页", [130, 49, 50, 20]),
            Node("StaticText", "地址", [130, 90, 50, 20]),
            field,
        ])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let ref = try number(in: screen.text, containing: "SearchField \"搜索\"")

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testSearchFieldMirrorRecognitionCachesSuccessAndFailure() {
        let frame = Rect(x: 12, y: 127, width: 366, height: 33)
        for includeMirror in [false, true] {
            let outer = Element(type: "SearchField", label: "搜索", value: nil, identifier: nil,
                                frame: frame, depth: 1, node: 3, end: includeMirror ? 4 : 3)
            let inner = Element(type: "SearchField", label: "搜索", value: nil, identifier: nil,
                                frame: frame, depth: 2, node: 4, end: 4)
            let headers = [
                Element(type: "StaticText", label: "首页", value: nil, identifier: nil,
                        frame: Rect(x: 130, y: 59, width: 50, height: 26), depth: 1, node: 1, end: 1),
                Element(type: "StaticText", label: "自取", value: nil, identifier: nil,
                        frame: Rect(x: 190, y: 59, width: 50, height: 26), depth: 1, node: 2, end: 2),
            ]
            let candidates = includeMirror ? [outer, inner] : [outer]
            let identity = PokiSearchFieldIdentity(all: headers + candidates, scrollers: [], rows: [],
                                                   wrappers: [], chrome: [])
            var reads = 0
            let visible: (Element) -> Rect = { element in reads += 1; return element.frame }
            let first = identity.mirrors(outer, candidates: candidates, visibleFrame: visible, parent: { _ in nil })
            XCTAssertEqual(first != nil, includeMirror)
            let firstReads = reads
            _ = identity.mirrors(outer, candidates: candidates, visibleFrame: visible, parent: { _ in nil })
            if includeMirror {
                _ = identity.mirrors(inner, candidates: candidates, visibleFrame: visible, parent: { _ in nil })
            }
            XCTAssertEqual(reads, firstReads)
        }
    }

    private func searchPage(_ content: [Node], secondTitle: String = "自取") -> [Node] {
        [Node("StaticText", "首页", [130, 59, 50, 26]),
         Node("StaticText", secondTitle, [190, 59, 50, 26])] + content
    }

    private func number(in text: String, containing marker: String) throws -> Int {
        let line = text.split(separator: "\n").first { $0.contains(marker) }
        let number = line?.split(whereSeparator: \.isWhitespace).first?.drop(while: { !$0.isNumber })
        return try XCTUnwrap(number.flatMap { Int($0) }, text)
    }
}
