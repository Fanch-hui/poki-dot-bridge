import XCTest
@testable import PokiCore

final class PokiSearchCandidateTests: XCTestCase {
    private let query = "广东省博物馆"

    private func screen(_ query: String?, results: [Node] = [], history: Bool = false) -> [Node] {
        var nodes = [
            Node("TextField", query ?? "请输入地点", [24, 75, 260, 42]),
            Node("Image", "搜索", [300, 80, 60, 32]),
        ]
        if history { nodes.append(Node("StaticText", "历史记录", [20, 140, 100, 20])) }
        nodes += results
        nodes.append(Node("Keyboard", nil, [0, 900, 390, 344], [
            Node("Button", "搜索", [300, 1100, 80, 40]),
        ]))
        return nodes
    }

    private func run(before: [Node], after: [Node], switchForeground: Bool = false, unknownForeground: Bool = false,
                     searchSubmit: Bool = false) async -> (ToolResult, FakeWDA) {
        let wda = FakeWDA()
        wda.tree(before, app: "Maps")
        wda.set("GET /wda/activeAppInfo") { _ in
            (200, ["value": ["bundleId": "com.example.maps", "name": "Maps"]])
        }
        wda.set("POST /wda/keys") { [wda] _ in
            wda.tree(after, app: "Maps")
            if switchForeground {
                wda.set("GET /wda/activeAppInfo") { _ in
                    (200, ["value": ["bundleId": "com.example.other", "name": "Other"]])
                }
            } else if unknownForeground {
                wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": [:]]) }
            }
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) {
            $0.standaloneObservations = true
            $0.toolDeadline = 18
            $0.actionCap = 5
        }
        _ = await core.call("look", [:])
        let actions: [JSON] = searchSubmit
            ? [["search_submit": ["text": .string(query), "ref": 1, "result_texts": ["No results"]]]]
            : [["type": .string(query)], ["key": "return"]]
        let result = await core.call("do", ["actions": .array(actions)])
        return (result, wda)
    }

    func testNewVisibleMapCandidateKeepsTheUnsentReturnReceipt() async {
        let (result, wda) = await run(
            before: screen(nil),
            after: screen(query, results: [Node("Image", query, [40, 170, 260, 55])])
        )
        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("search: input_sent; submit_not_sent; candidates_available"), result.text)
        XCTAssertTrue(result.text.contains("outside the visible screen"), result.text)
        XCTAssertTrue(result.text.contains("not_sent"), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/keys").count, 1)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
    }

    func testSearchSubmitReportsCandidateWhenReturnIsUnsent() async {
        var before = screen(nil)
        before[0] = Node("SearchField", "搜索", [24, 75, 260, 42])
        var after = screen(query, results: [Node("Image", query, [40, 170, 260, 55])])
        after[0] = Node("SearchField", query, [24, 75, 260, 42])
        let (result, wda) = await run(before: before, after: after, searchSubmit: true)
        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("search: input_sent; submit_not_sent; candidates_available"), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/keys").count, 1)
    }

    func testInputEchoAndPriorOrAmbiguousResultsAreNotNewCandidates() async {
        let candidate = Node("Image", query, [40, 170, 260, 55])
        let duplicate = Node("Image", query, [40, 230, 260, 55])
        let cases: [([Node], [Node])] = [
            (screen(nil), screen(query)),
            (screen(nil, results: [candidate]), screen(query, results: [candidate])),
            (screen(nil), screen(query, results: [candidate, duplicate])),
            (screen(nil), screen(query, results: [candidate], history: true)),
            (screen(nil), screen(query, results: [
                candidate, Node("Alert", "Permission", [10, 130, 370, 400]),
            ])),
            (screen(nil), screen(query, results: [
                Node("Keyboard", nil, [0, 160, 390, 400], [candidate]),
            ])),
        ]
        for (before, after) in cases {
            let (result, wda) = await run(before: before, after: after)
            XCTAssertTrue(result.isError, result.text)
            XCTAssertFalse(result.text.contains("candidates_available"), result.text)
            XCTAssertEqual(wda.bodies("POST /wda/keys").count, 1)
        }
    }

    func testCandidateOnAnotherAppIsNotReported() async {
        let (result, _) = await run(
            before: screen(nil),
            after: screen(query, results: [Node("Image", query, [40, 170, 260, 55])]),
            switchForeground: true
        )
        XCTAssertTrue(result.isError, result.text)
        XCTAssertFalse(result.text.contains("candidates_available"), result.text)
    }

    func testCandidateWithUnknownForegroundIsNotReported() async {
        let (result, _) = await run(
            before: screen(nil),
            after: screen(query, results: [Node("Image", query, [40, 170, 260, 55])]),
            unknownForeground: true
        )
        XCTAssertTrue(result.isError, result.text)
        XCTAssertFalse(result.text.contains("candidates_available"), result.text)
    }

    func testCandidateWithoutSearchControlIsNotReported() async {
        let before = [Node("TextField", "Message", [24, 75, 260, 42]),
                      Node("Keyboard", nil, [0, 900, 390, 344], [
                          Node("Button", "搜索", [300, 1100, 80, 40]),
                      ])]
        let after = [Node("TextField", query, [24, 75, 260, 42]),
                     Node("Image", query, [40, 170, 260, 55]),
                     Node("Keyboard", nil, [0, 900, 390, 344], [
                         Node("Button", "搜索", [300, 1100, 80, 40]),
                     ])]
        let (result, _) = await run(before: before, after: after)
        XCTAssertTrue(result.isError, result.text)
        XCTAssertFalse(result.text.contains("candidates_available"), result.text)
    }

    func testOffscreenReturnSubmitsAnUnambiguousSearchButton() async {
        let before = searchForm(field: "请输入地点")
        let after = searchForm(field: query)
        let (result, wda) = await run(before: before, after: after)

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("tapped the visible \"搜索\" search button"), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/keys").count, 1)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
        XCTAssertEqual(wda.bodies("POST /wda/tap").first?["x"]?.double, 330)
    }

    func testOffscreenReturnStopsWhenSearchButtonIsAmbiguousOrFieldChanges() async {
        let cases: [[Node]] = [
            searchForm(field: "another query"),
            searchForm(field: query, extra: [Node("Button", "搜索", [285, 81, 12, 28])]),
            searchForm(field: query, extra: [Node("Alert", "Permission", [10, 130, 370, 400])]),
            searchForm(field: query, button: "发送"),
            searchForm(field: query, buttonFrame: [300, 180, 60, 32]),
            [
                Node("TextView", query, [24, 75, 260, 42]),
                Node("Button", "搜索", [300, 80, 60, 32], [
                    Node("StaticText", "确认支付", [300, 80, 60, 32]),
                ]),
                Node("Keyboard", nil, [0, 900, 390, 344], [
                    Node("Button", "搜索", [300, 1100, 80, 40]),
                ]),
            ],
            [
                Node("Other", nil, [0, 0, 390, 844], searchForm(field: query)),
                Node("Other", nil, [0, 0, 390, 844], [
                    Node("StaticText", "Payment", [24, 75, 260, 42]),
                    Node("Button", "Continue", [300, 80, 60, 32]),
                ]),
            ],
        ]
        for after in cases {
            let (result, wda) = await run(before: searchForm(field: "请输入地点"), after: after)
            XCTAssertTrue(result.isError, result.text)
            XCTAssertTrue(result.text.contains("outside the visible screen"), result.text)
            XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
        }
    }

    func testOffscreenReturnStopsIfForegroundAppChanges() async {
        let (result, wda) = await run(
            before: searchForm(field: "请输入地点"), after: searchForm(field: query),
            switchForeground: true
        )
        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testSearchSubmitContinuesAfterOffscreenReturnFallback() async {
        let wda = FakeWDA()
        var before = searchForm(field: "搜索")
        before[0] = Node("SearchField", "搜索", [24, 75, 260, 42])
        let after: [Node] = {
            var nodes = searchForm(field: query)
            nodes[0] = Node("SearchField", query, [24, 75, 260, 42])
            return nodes
        }()
        wda.tree(before, app: "Maps")
        wda.set("GET /wda/activeAppInfo") { _ in
            (200, ["value": ["bundleId": "com.example.maps", "name": "Maps"]])
        }
        wda.set("POST /wda/keys") { [wda] _ in
            wda.tree(after, app: "Maps")
            return (200, ["value": .null])
        }
        let taps = LockedBox(0)
        wda.set("POST /wda/tap") { [wda] _ in
            let count = taps.update { $0 += 1; return $0 }
            if count == 2 {
                wda.tree([Node("StaticText", "No results", [24, 140, 200, 30])], app: "Maps")
            }
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) {
            $0.standaloneObservations = true
            $0.toolDeadline = 18
            $0.actionCap = 5
        }
        _ = await core.call("look", [:])

        let result = await core.call("do", ["actions": [["search_submit": [
            "text": .string(query), "ref": 1, "result_texts": ["No results"],
        ]]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("tapped the visible \"搜索\" search button"), result.text)
        XCTAssertTrue(result.text.contains("result \"No results\" appeared"), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 2)
    }

    private func searchForm(
        field: String, button: String = "搜索", buttonFrame: [Double] = [300, 80, 60, 32],
        extra: [Node] = []
    ) -> [Node] {
        [
            Node("TextView", field, [24, 75, 260, 42]),
            Node("Button", button, buttonFrame),
        ] + extra + [
            Node("Keyboard", nil, [0, 900, 390, 344], [
                Node("Button", "搜索", [300, 1100, 80, 40]),
            ]),
        ]
    }
}
