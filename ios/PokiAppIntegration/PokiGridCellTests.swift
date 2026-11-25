import XCTest
@testable import PokiCore

final class PokiGridCellTests: XCTestCase {
    func testMirroredGridCellCanBeTapped() async throws {
        let wda = FakeWDA()
        wda.tree(page())
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let ref = try cellReference(screen.text)
        let line = try XCTUnwrap(screen.text.split(separator: "\n").first { $0.contains("Cell \"甜点饮品\"") })
        XCTAssertFalse(line.contains("[row unverified]"), screen.text)

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").first?["x"]?.double, 130.5)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
    }

    func testChangedGridNeighborsPreventTap() async throws {
        let wda = FakeWDA()
        wda.tree(page())
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let ref = try cellReference(screen.text)
        wda.tree(page(labels: ["超市", "甜点饮品", "美食"]))

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
    }

    func testDifferentOverlappingGridBranchesRemainUnverified() async throws {
        let wda = FakeWDA()
        wda.tree(page(secondLabels: ["超市", "甜点饮品", "美食"]))
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let ref = try cellReference(screen.text)
        let line = try XCTUnwrap(screen.text.split(separator: "\n").first { $0.contains("Cell \"甜点饮品\"") })
        XCTAssertTrue(line.contains("[row unverified]"), screen.text)

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
    }

    func testEachMirroredBranchNeedsItsOwnGridNeighbors() async throws {
        let wda = FakeWDA()
        let cells = [
            Node("Cell", "美食", [20, 166, 61, 89]),
            Node("Cell", "甜点饮品", [100, 166, 61, 89]),
            Node("Cell", "超市", [180, 166, 61, 89]),
        ]
        wda.tree([Node("CollectionView", nil, [0, 160, 390, 159], [
            Node("Group", nil, [0, 160, 390, 159], cells),
            Node("Group", nil, [0, 160, 390, 159], [cells[1]]),
        ])])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let ref = try cellReference(screen.text)
        let line = try XCTUnwrap(screen.text.split(separator: "\n").first { $0.contains("Cell \"甜点饮品\"") })
        XCTAssertTrue(line.contains("copies=2 aligned=1 scopes=1"), screen.text)
        XCTAssertTrue(line.hasSuffix("[row unverified]"), screen.text)

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
    }

    func testMirroredBranchesWithinOneScrollerCanBeTapped() async throws {
        let wda = FakeWDA()
        let cells = [
            Node("Cell", "美食", [20, 166, 61, 89]),
            Node("Cell", "甜点饮品", [100, 166, 61, 89]),
            Node("Cell", "超市", [180, 166, 61, 89]),
        ]
        wda.tree([Node("CollectionView", nil, [0, 160, 390, 159], [
            Node("Group", nil, [0, 160, 390, 159], cells),
            Node("Group", nil, [0, 160, 390, 159], cells),
        ])])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let ref = try cellReference(screen.text)

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
    }

    func testNewVisibleDuplicateInAnotherPositionPreventsTap() async throws {
        let wda = FakeWDA()
        wda.tree(page())
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let ref = try cellReference(screen.text)
        wda.tree(page() + [Node("Cell", "甜点饮品", [260, 166, 61, 89])])

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
    }

    func testMirroredGridPaymentStillRequiresApproval() async throws {
        let wda = FakeWDA()
        wda.tree(page(labels: ["美食", "确认支付", "超市"]))
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true; $0.approvalWait = 0 }
        let screen = await core.call("look", [:])
        let ref = try cellReference(screen.text, label: "确认支付")

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertTrue(result.text.contains("approval_required"), result.text)
        XCTAssertNotNil(core.pendingApproval)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
    }

    func testGridCellCoveredByPaymentControlIsNotTapped() async throws {
        let wda = FakeWDA()
        wda.tree(page(covered: true))
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let ref = try cellReference(screen.text)
        let line = try XCTUnwrap(screen.text.split(separator: "\n").first { $0.contains("Cell \"甜点饮品\"") })
        XCTAssertTrue(line.contains("[covered]"), screen.text)

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
    }

    func testPaymentInsideOtherMirroredCellStillCoversTheTarget() async throws {
        let wda = FakeWDA()
        wda.tree(page(paymentInsideSecondMirror: true))
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true; $0.approvalWait = 0 }
        let screen = await core.call("look", [:])
        let ref = try cellReference(screen.text)
        let line = try XCTUnwrap(screen.text.split(separator: "\n").first { $0.contains("Cell \"甜点饮品\"") })
        XCTAssertTrue(line.contains("[covered]"), screen.text)

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
    }

    private func page(labels: [String] = ["美食", "甜点饮品", "超市"],
                      secondLabels: [String]? = nil, covered: Bool = false,
                      paymentInsideSecondMirror: Bool = false) -> [Node] {
        func grid(_ names: [String], paymentInside: Bool = false) -> Node {
            Node("CollectionView", nil, [0, 160, 390, 159], names.enumerated().map { index, name in
                let frame = [Double(20 + index * 80), 166, 61, 89]
                let children = paymentInside && index == 1 ? [Node("Button", "确认支付", frame)] : []
                return Node("Cell", name, frame, children)
            })
        }
        var nodes = [grid(labels), grid(secondLabels ?? labels, paymentInside: paymentInsideSecondMirror)]
        if covered { nodes.append(Node("Button", "确认支付", [100, 166, 61, 89])) }
        return nodes
    }

    private func cellReference(_ text: String, label: String = "甜点饮品") throws -> Int {
        let line = text.split(separator: "\n").first { $0.contains("Cell \"\(label)\"") }
        let ref = line?.split(whereSeparator: \.isWhitespace).first?.drop(while: { !$0.isNumber })
        return try XCTUnwrap(ref.flatMap { Int($0) }, text)
    }
}
