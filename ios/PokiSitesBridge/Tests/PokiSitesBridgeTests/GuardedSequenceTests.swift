import Foundation
import XCTest
@testable import PokiSitesBridge

final class GuardedSequenceTests: XCTestCase {
    private let jpeg = Data([0xff, 0xd8, 0xff, 0xd9])

    private actor Calls {
        private var replies: [PokiToolReply]
        private(set) var arguments: [[String: JSONValue]] = []

        init(_ replies: [PokiToolReply]) { self.replies = replies }

        func call(_ args: [String: JSONValue]) -> PokiToolReply {
            arguments.append(args)
            return replies.removeFirst()
        }
    }

    private func task(_ stages: [JSONValue]) -> ClaimedTaskDTO {
        ClaimedTaskDTO(task_id: "sequence", tool_name: "do",
            payload: ["app": .string("com.example.shop"), "guarded_sequence": .array(stages)],
            observation_id: "current", lease_token: "lease",
            lease_expires_at: 9_999_999_999_999, expires_at: 9_999_999_999_999)
    }

    private func stage(_ actions: [[String: JSONValue]], target: [String: JSONValue]? = nil) -> JSONValue {
        var value: [String: JSONValue] = ["actions": .array(actions.map(JSONValue.object))]
        if let target { value["target"] = .object(target) }
        return .object(value)
    }

    private func reply(_ receipts: String, controls: String, app: String = "com.example.shop") -> PokiToolReply {
        PokiToolReply(text: """
        app: Shop   read: now
        bundle_id: \(app)
        viewport: 390x844 points
        \(receipts)
        elements:
        \(controls)
        """, screenshotJPEG: jpeg)
    }

    private func enteredShop(_ controls: String = #"3 Button "搜索" [20,60,80,40]"#) -> PokiToolReply {
        reply("""
        did: tap "Shop" (sent, 100 ms)
        did: wait_until: "点菜" appeared after 200 ms (sent, 200 ms)
        """, controls: """
        1 StaticText "点菜" [20,110,80,30]
        \(controls)
        """)
    }

    private var enter: JSONValue {
        stage([["tap": .number(2)], ["wait_until": .string("点菜")]])
    }

    func testRebindsLaterTapAndReturnsAllReceipts() async {
        let openSearch = stage([["tap": .number(1)]], target: ["label": .string("搜索"), "type": .string("Button")])
        let calls = Calls([enteredShop(), reply(#"did: tap "搜索" (sent, 90 ms)"#,
                                              controls: #"5 TextField "请输入商品名" [10,40,200,40]"#)])
        let result = await PokiGuardedSequence.execute(task: task([enter, openSearch])) { args, _ in
            await calls.call(args)
        }
        let sent = await calls.arguments
        XCTAssertEqual(sent.count, 2)
        guard sent.count == 2 else { return XCTFail(result.text) }
        let secondAction = sent[1]["actions"]?.arrayValue?.first?.objectValue
        XCTAssertEqual(secondAction?["tap"], .number(3))
        XCTAssertEqual(sent[1]["expect_front"], .string("com.example.shop"))
        XCTAssertEqual(sent[1]["app"], .bool(false))
        XCTAssertTrue(result.text.contains("sequence: completed=2 total=2 status=complete"), result.text)
        let parsed = PokiOutputParser.parse(toolName: "do", text: result.text, isError: result.isError, screenshotJPEG: result.screenshotJPEG)
        XCTAssertEqual(parsed.receipts.map(\.kind), ["tap", "wait_until:", "tap"])
        XCTAssertEqual(result.screenshotJPEG, jpeg)
    }

    func testStopsOnDuplicateTargetOrChangedApp() async {
        let openSearch = stage([["tap": .number(1)]], target: ["label": .string("搜索")])
        let replies = [
            enteredShop(#"3 Button "搜索" [20,60,80,40]"# + "\n" + #"4 Button "搜索" [120,60,80,40]"#),
            reply("""
            did: tap "Shop" (sent, 100 ms)
            did: wait_until: "点菜" appeared after 200 ms (sent, 200 ms)
            """, controls: #"3 Button "搜索" [20,60,80,40]"#, app: "com.example.other"),
        ]
        for (index, first) in replies.enumerated() {
            let calls = Calls([first])
            let result = await PokiGuardedSequence.execute(task: task([enter, openSearch])) { args, _ in
                await calls.call(args)
            }
            let count = await calls.arguments.count
            XCTAssertEqual(count, 1)
            XCTAssertTrue(result.isError)
            XCTAssertTrue(result.text.contains("status=stopped"), result.text)
            XCTAssertEqual(result.screenshotJPEG, index == 0 ? jpeg : nil)
        }
    }

    func testDoesNotContinueAfterUnmetWaitOrMissingMarker() async {
        let openSearch = stage([["tap": .number(1)]], target: ["label": .string("搜索")])
        for receipt in [
            #"did: wait_until: not seen within 3000 ms that "点菜" appeared (5 reads) (sent, 3000 ms)"#,
            #"did: wait_until: "点菜" appeared after 200 ms (sent, 200 ms)"#,
        ] {
            let first = reply("""
            did: tap "Shop" (sent, 100 ms)
            \(receipt)
            """, controls: #"3 Button "搜索" [20,60,80,40]"#)
            let calls = Calls([first])
            let result = await PokiGuardedSequence.execute(task: task([enter, openSearch])) { args, _ in
                await calls.call(args)
            }
            let count = await calls.arguments.count
            XCTAssertEqual(count, 1)
            XCTAssertTrue(result.text.contains("completed=0 total=2 status=stopped"), result.text)
            XCTAssertTrue(result.text.contains("expected page marker was not confirmed"), result.text)
        }
    }

    func testTypesIntoCurrentSearchFieldAndWaitsForResult() async {
        let enterSearch = stage([
            ["tap": .number(2)], ["wait_until": .string("请输入商品名")],
        ])
        let type = stage([
            ["type": .string("tea"), "ref": .number(1)],
            ["wait_until": .object(["texts_any": .array([.string("Milk tea")]), "ms": .number(5000)])],
        ], target: ["label": .string("请输入商品名"), "editable": .bool(true)])
        let calls = Calls([
            reply("""
            did: tap "搜索" (sent, 100 ms)
            did: wait_until: "请输入商品名" appeared after 200 ms (sent, 200 ms)
            """, controls: #"5 TextField "请输入商品名" [10,40,200,40]"#),
            reply("""
            did: type "tea" (sent, 150 ms)
            did: wait_until: result "Milk tea" appeared after 180 ms (sent, 180 ms)
            """, controls: #"8 Cell "Milk tea" [10,100,200,40]"#),
        ])
        let result = await PokiGuardedSequence.execute(task: task([enterSearch, type])) { args, _ in
            await calls.call(args)
        }
        let sent = await calls.arguments
        XCTAssertEqual(sent.count, 2)
        guard sent.count == 2 else { return XCTFail(result.text) }
        let actions = sent[1]["actions"]?.arrayValue
        XCTAssertEqual(actions?.first?.objectValue?["ref"], .number(5))
        XCTAssertEqual(actions?.last?.objectValue?["wait_until"]?.objectValue?["present_before"], .array([]))
        XCTAssertTrue(result.text.contains("status=complete"), result.text)
    }
}
