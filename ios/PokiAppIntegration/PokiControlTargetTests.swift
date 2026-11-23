import XCTest
@testable import PokiCore

final class PokiControlTargetTests: XCTestCase {
    func testRepeatedButtonCarriesItsRowAndTapsTheIntendedPosition() async throws {
        let wda = FakeWDA()
        wda.tree(menu(["生椰拿铁", "橙 C 美式"]))
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }

        let screen = await core.call("look", [:])
        let ref = try number(in: screen.text, onRow: "生椰拿铁")
        _ = try number(in: screen.text, onRow: "橙 C 美式")
        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertFalse(result.isError, result.text)
        let taps = wda.bodies("POST /wda/tap")
        XCTAssertEqual(taps.count, 1, result.text)
        XCTAssertEqual(taps.first?["y"]?.double, 135)
    }

    func testRecycledRowCannotReceiveTapForPreviousItemAtTheSamePosition() async throws {
        let wda = FakeWDA()
        wda.tree(menu(["生椰拿铁", "橙 C 美式"]))
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let ref = try number(in: screen.text, onRow: "生椰拿铁")

        wda.tree(menu(["橙 C 美式", "生椰拿铁"]))
        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("could not be confirmed in the same row and position"), result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
        _ = try number(in: result.text, onRow: "生椰拿铁")
    }

    func testRepeatedControlsWithoutRowEvidenceAreMarkedAndDoNotReceiveNumberedTaps() async throws {
        let wda = FakeWDA()
        wda.tree([
            Node("Button", "Edit", [50, 100, 60, 40]),
            Node("Button", "Edit", [50, 180, 60, 40]),
        ])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        XCTAssertEqual(screen.text.split(separator: "\n").filter { $0.contains("[row unverified]") }.count, 2, screen.text)

        let result = await core.call("do", ["actions": [["tap": 1]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testControlInsideScreenButOutsideItsScrollViewportIsNotListed() async {
        let wda = FakeWDA()
        wda.tree([Node("CollectionView", nil, [0, 90, 390, 160], [
            Node("Button", "Visible row", [16, 102, 350, 44]),
            Node("Button", "Outside the scroll viewport", [16, 280, 350, 44]),
        ])])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }

        let result = await core.call("look", ["full": true])

        XCTAssertTrue(result.text.contains("Visible row"), result.text)
        XCTAssertFalse(result.text.contains("Outside the scroll viewport"), result.text)
    }

    private func menu(_ names: [String]) -> [Node] {
        let rows = names.enumerated().map { index, name -> Node in
            let y = Double(90 + 100 * index)
            return Node("Cell", nil, [0, y, 390, 90], [
                Node("StaticText", name, [16, y + 13, 150, 35]),
                Node("Button", "选规格", [302, y + 23, 72, 44]),
            ])
        }
        return [Node("CollectionView", nil, [0, 76, 390, 620], rows)]
    }

    private func number(in text: String, onRow name: String) throws -> Int {
        let line = text.split(separator: "\n").first { $0.contains("Button \"选规格\"") && $0.contains("[row: \(name)]") }
        let number = line?.split(whereSeparator: \.isWhitespace).first?.drop(while: { !$0.isNumber })
        return try XCTUnwrap(number.flatMap { Int($0) }, text)
    }
}
