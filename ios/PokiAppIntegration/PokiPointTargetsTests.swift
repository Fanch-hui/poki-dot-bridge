import XCTest
@testable import PokiCore

final class PokiPointTargetsTests: XCTestCase {
    private let screen = ScreenSize(width: 420, height: 912)
    private let app = Foreground(bundleID: "com.example.shop", name: "Shop")
    private let tap: JSON = ["tap": [380, 676]]

    private func makeComputer(_ elements: [Element]) -> Computer {
        let (core, _, _) = makeCore(FakeWDA()) { $0.standaloneObservations = true }
        let computer = core.computer
        computer.lastAll = elements
        computer.lastForeground = app
        computer.size = screen
        return computer
    }

    func testRepeatedControlRequiresSameProductAtTheOriginalPoint() throws {
        let initial = menu(["生椰拿铁", "橙 C 美式"])
        let computer = makeComputer(initial)
        guard case let .guarded(target) = computer.pointTargetToVerify(tap) else {
            return XCTFail("expected the first product row to be identified")
        }
        XCTAssertEqual(target.point.x, 380)
        XCTAssertEqual(target.point.y, 676)
        XCTAssertNil(computer.pointTargetProblem(target, in: initial, foreground: app, screen: screen))
        XCTAssertNotNil(computer.pointTargetProblem(target, in: menu(["橙 C 美式", "生椰拿铁"]),
                                                    foreground: app, screen: screen))
        XCTAssertNotNil(computer.pointTargetProblem(target, in: menu(["生椰拿铁", "橙 C 美式"], firstOffset: 30),
                                                    foreground: app, screen: screen))
        XCTAssertNotNil(computer.pointTargetProblem(target, in: initial,
                                                    foreground: Foreground(bundleID: "com.example.other", name: "Other"),
                                                    screen: screen))
    }

    func testCoordinateDoesNotTapWhenAnotherProductMovesUnderIt() async {
        let wda = FakeWDA()
        wda.tree(menuNodes(["生椰拿铁", "橙 C 美式"]))
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        _ = await core.call("look", [:])
        wda.tree(menuNodes(["橙 C 美式", "生椰拿铁"]))

        let result = await core.call("do", ["actions": [tap]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("not sent"), result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testRepeatedControlWithoutDistinctRowIdentityIsBlocked() {
        for rows in [["同名商品", "同名商品"], ["", "橙 C 美式"]] {
            let computer = makeComputer(menu(rows))
            guard case .blocked = computer.pointTargetToVerify(tap) else {
                return XCTFail("a coordinate must not select an unidentified product")
            }
        }
    }

    func testCoveredRepeatedControlIsBlockedBeforeDispatch() {
        var elements = menu(["生椰拿铁", "橙 C 美式"])
        elements.append(element("Button", "覆盖", [357, 665, 48, 22], node: 9, end: 9, depth: 2))
        let computer = makeComputer(elements)
        guard case .blocked = computer.pointTargetToVerify(tap) else {
            return XCTFail("a covered coordinate must not be sent")
        }
    }

    func testNewCoverOrDifferentControlAtPointStopsTap() throws {
        let initial = menu(["生椰拿铁", "橙 C 美式"])
        let computer = makeComputer(initial)
        guard case let .guarded(target) = computer.pointTargetToVerify(tap) else {
            return XCTFail("expected the first product row to be identified")
        }
        var covered = initial
        covered.append(element("Button", "覆盖", [357, 665, 48, 22], node: 9, end: 9, depth: 2))
        XCTAssertNotNil(computer.pointTargetProblem(target, in: covered, foreground: app, screen: screen))
        var replaced = initial
        replaced[3].label = "添加"
        XCTAssertNotNil(computer.pointTargetProblem(target, in: replaced, foreground: app, screen: screen))
    }

    func testPureVisualCoordinateKeepsExistingBehavior() {
        let computer = makeComputer(menu(["生椰拿铁", "橙 C 美式"]))
        guard case .unmanaged = computer.pointTargetToVerify(["tap": [240, 550]]) else {
            return XCTFail("a point without an accessible repeated control stays a visual tap")
        }
    }

    func testCoordinateShapesAndNumberedReferencePriorityMatchTheAction() {
        let computer = makeComputer(menu(["生椰拿铁", "橙 C 美式"]))
        for tap: JSON in [
            ["tap": [380, 676, 0]],
            ["tap": ["x": 380, "y": 676]],
        ] {
            XCTAssertTrue(computer.pointTargetToVerify(tap).requiresVerification)
        }
        let reference: JSON = ["tap": ["ref": 8, "x": 380, "y": 676]]
        XCTAssertFalse(computer.pointTargetToVerify(reference).requiresVerification)
        XCTAssertFalse(computer.pointTargetToVerify(["tap": [240, 550]]).requiresVerification)
    }

    private func menu(_ names: [String], firstOffset: Double = 0) -> [Element] {
        [
            element("CollectionView", nil, [0, 120, 420, 760], node: 1, end: 7, depth: 1),
            element("Cell", nil, [0, 625 + firstOffset, 420, 80], node: 2, end: 4, depth: 2),
            element("StaticText", names[0], [20, 630 + firstOffset, 200, 24], node: 3, end: 3, depth: 3),
            element("Other", "选规格", [357, 665 + firstOffset, 48, 22], node: 4, end: 4, depth: 3),
            element("Cell", nil, [0, 786, 420, 80], node: 5, end: 7, depth: 2),
            element("StaticText", names[1], [20, 791, 200, 24], node: 6, end: 6, depth: 3),
            element("Other", "选规格", [357, 826, 48, 22], node: 7, end: 7, depth: 3),
        ]
    }

    private func menuNodes(_ names: [String]) -> [Node] {
        let rows = names.enumerated().map { index, name -> Node in
            let y = index == 0 ? 625.0 : 786.0
            let controlY = index == 0 ? 665.0 : 826.0
            return Node("Cell", nil, [0, y, 390, 80], [
                Node("StaticText", name, [20, y + 5, 200, 24]),
                Node("Other", "选规格", [357, controlY, 48, 22]),
            ])
        }
        return [Node("CollectionView", nil, [0, 120, 390, 724], rows)]
    }

    private func element(_ type: String, _ label: String?, _ frame: [Double],
                         node: Int, end: Int, depth: Int) -> Element {
        Element(type: type, label: label, value: nil, identifier: nil,
                frame: Rect(x: frame[0], y: frame[1], width: frame[2], height: frame[3]),
                depth: depth, node: node, end: end)
    }
}
