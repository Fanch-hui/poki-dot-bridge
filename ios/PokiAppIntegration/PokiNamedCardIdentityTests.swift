import XCTest
@testable import PokiCore

final class PokiNamedCardIdentityTests: XCTestCase {
    private let first = "青柠茶店(滨江店)，4.7，月售5000+，人均 ¥22，配送约¥2.6"
    private let second = "青柠茶店(南城店)，4.6，月售2000+，人均 ¥22，配送约¥2"

    func testUniquelyNamedCardUsesItsOwnTitleAsRowIdentity() async throws {
        let wda = FakeWDA()
        wda.tree(page([first, second]))
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let ref = try number(in: screen.text, containing: "Other \"青柠茶店(滨江店)")

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").first?["y"]?.double, 165)
    }

    func testDuplicateCardTitleInEitherReadIsNotEnoughToIdentifyTheRow() async throws {
        let duplicate = "青柠茶店(滨江店)，4.5，月售1000+，人均 ¥18，配送约¥3"
        for initialDuplicate in [false, true] {
            let wda = FakeWDA()
            wda.tree(page(initialDuplicate ? [first, duplicate] : [first, second]))
            let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
            let screen = await core.call("look", [:])
            let ref = try number(in: screen.text, containing: "Other \"青柠茶店(滨江店)，4.7")
            wda.tree(page(initialDuplicate ? [first, second] : [first, duplicate]))

            let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

            XCTAssertTrue(result.isError, result.text)
            XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
        }
    }

    func testNamedCardStillAvoidsItsIndependentOrderButton() async throws {
        let wda = FakeWDA()
        wda.tree([Node("CollectionView", nil, [0, 76, 390, 620], [
            Node("Cell", nil, [10, 100, 370, 130], [
                Node("Other", first, [10, 100, 370, 130], [
                    Node("Button", "提交订单", [100, 120, 160, 90]),
                ]),
            ]),
        ])])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true; $0.approvalWait = 0 }
        let screen = await core.call("look", [:])
        let ref = try number(in: screen.text, containing: "Other \"青柠茶店(滨江店)")

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertNil(core.pendingApproval)
        let tap = try XCTUnwrap(wda.bodies("POST /wda/tap").first)
        let x = try XCTUnwrap(tap["x"]?.double)
        let y = try XCTUnwrap(tap["y"]?.double)
        XCTAssertTrue(x < 100 || x >= 260 || y < 120 || y >= 210, result.text)
    }

    func testChangedCardAndChangedRowRemainUnconfirmed() async throws {
        for fresh in [
            page(["青柠茶店(滨江店)，4.7，月售5001+，人均 ¥22，配送约¥2.6", second]),
            [Node("Other", first, [10, 100, 370, 130])],
        ] {
            let wda = FakeWDA()
            wda.tree(page([first, second]))
            let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
            let screen = await core.call("look", [:])
            let ref = try number(in: screen.text, containing: "Other \"青柠茶店(滨江店)")
            wda.tree(fresh)

            let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

            XCTAssertTrue(result.isError, result.text)
            XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
        }
    }

    private func page(_ labels: [String]) -> [Node] {
        let rows = labels.enumerated().map { index, label -> Node in
            let y = Double(100 + index * 150)
            return Node("Cell", nil, [10, y, 370, 130], [
                Node("Other", label, [10, y, 370, 130]),
            ])
        }
        return [Node("CollectionView", nil, [0, 76, 390, 620], rows)]
    }

    private func number(in text: String, containing marker: String) throws -> Int {
        let line = text.split(separator: "\n").first { $0.contains(marker) }
        let number = line?.split(whereSeparator: \.isWhitespace).first?.drop(while: { !$0.isNumber })
        return try XCTUnwrap(number.flatMap { Int($0) }, text)
    }
}
