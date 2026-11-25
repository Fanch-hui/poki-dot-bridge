import XCTest
@testable import PokiCore

final class PokiControlTargetTests: XCTestCase {
    func testTheFirstReadMarksACoveredControlAndNamesItsActionableChild() async throws {
        let wda = FakeWDA()
        wda.tree([
            Node("Other", "Store", [10, 100, 280, 80], [
                Node("Button", "Enter", [180, 120, 90, 40]),
            ]),
            Node("Button", "Hidden", [10, 220, 160, 40]),
            Node("Button", "Overlay", [10, 220, 160, 40]),
        ])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let child = try number(in: screen.text, containing: "Button \"Enter\"")
        let row = try XCTUnwrap(screen.text.split(separator: "\n").first { $0.contains("Other \"Store\"") })
        let hidden = try XCTUnwrap(screen.text.split(separator: "\n").first { $0.contains("Button \"Hidden\"") })
        XCTAssertTrue(row.contains("[children: \(child)]"), screen.text)
        XCTAssertTrue(hidden.contains("[covered]"), screen.text)

        let ref = try number(in: screen.text, containing: "Button \"Hidden\"")
        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])
        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
    }

    func testSmallMovementRecomputesTheActuallyDispatchedPoint() async throws {
        let wda = FakeWDA()
        let cover = Node("Button", "Cover", [100, 100, 100, 40])
        wda.tree([Node("Button", "Sort", [100, 100, 120, 40]), cover])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let ref = try number(in: screen.text, containing: "Button \"Sort\"")
        wda.tree([Node("Button", "Sort", [80, 100, 120, 40]),
                  Node("Button", "Cover", [80, 100, 100, 40])])

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])
        XCTAssertFalse(result.isError, result.text)
        let x = try XCTUnwrap(wda.bodies("POST /wda/tap").first?["x"]?.double)
        XCTAssertGreaterThan(x, 184)
        XCTAssertLessThan(x, 196)
    }

    func testContinuousPathStopsWhenTheTargetIsCovered() async {
        let wda = FakeWDA()
        wda.tree([
            Node("Button", "Open", [20, 100, 120, 40]),
            Node("Button", "Overlay", [20, 100, 120, 40]),
        ])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true; $0.actionCap = 1 }
        _ = await core.call("look", [:])

        let result = await core.call("do", ["actions": [["path": [
            "goal": "Open", "steps": [["tap": "Open"]],
        ]]]])
        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testShopCardTapAvoidsItsIndependentOrderButton() async throws {
        for usePath in [false, true] {
            let wda = FakeWDA()
            wda.tree([Node("Button", "Tea shop", [20, 100, 300, 100], [
                Node("Button", "提交订单", [90, 115, 160, 70]),
            ])], app: "Shop")
            let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true; $0.approvalWait = 0 }
            let screen = await core.call("look", [:])
            let ref = try number(in: screen.text, containing: "Button \"Tea shop\"")
            let action: JSON = usePath
                ? ["path": ["goal": "Open shop", "steps": [["tap": "Tea shop"]]]]
                : ["tap": .number(Double(ref))]

            let result = await core.call("do", ["actions": [action]])

            XCTAssertFalse(result.isError, result.text)
            XCTAssertNil(core.pendingApproval)
            let tap = try XCTUnwrap(wda.bodies("POST /wda/tap").first)
            let x = try XCTUnwrap(tap["x"]?.double)
            let y = try XCTUnwrap(tap["y"]?.double)
            XCTAssertTrue(x < 90 || x >= 250 || y < 115 || y >= 185, result.text)
        }
    }

    func testShopCardCoveredByItsOrderButtonNamesTheChildAndStops() async throws {
        let wda = FakeWDA()
        wda.tree([Node("Button", "Tea shop", [20, 100, 300, 100], [
            Node("Button", "提交订单", [20, 100, 300, 100]),
        ])], app: "Shop")
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let child = try number(in: screen.text, containing: "Button \"提交订单\"")
        let line = try XCTUnwrap(screen.text.split(separator: "\n").first { $0.contains("Button \"Tea shop\"") })
        XCTAssertTrue(line.contains("[covered] [children: \(child)]"), screen.text)
        let ref = try number(in: String(line), containing: "Button")

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testContinuousPathDoesNotGuessBetweenSameNamedControls() async {
        let wda = FakeWDA()
        wda.tree([
            Node("Button", "Open", [20, 100, 120, 40]),
            Node("Button", "Open", [20, 200, 120, 40]),
            Node("Button", "Overlay", [20, 200, 120, 40]),
        ])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true; $0.actionCap = 1 }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["path": [
            "goal": "Open", "steps": [["tap": "Open"]],
        ]]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

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

    func testUniqueGridEntryInCellCanBeTappedByItsOwnLabel() async throws {
        let wda = FakeWDA()
        wda.tree([Node("CollectionView", nil, [0, 76, 390, 400], [
            Node("Cell", "外卖", [11, 143, 74, 83], [
                Node("Button", "外卖", [11, 143, 74, 77]),
                Node("StaticText", "外卖", [52, 207, 27, 19]),
            ]),
            Node("Cell", "超市", [108, 143, 84, 83], [
                Node("Button", "超市", [116, 143, 68, 77]),
            ]),
        ])])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let ref = try number(in: screen.text, containing: "Button \"外卖\"")
        XCTAssertFalse(screen.text.contains("[row unverified]"), screen.text)

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").first?["x"]?.double, 48)
        XCTAssertEqual(wda.bodies("POST /wda/tap").first?["y"]?.double, 181.5)
    }

    func testUniqueWebGridLinkCanBeTappedByItsOwnLabel() async throws {
        let wda = FakeWDA()
        wda.tree([Node("WebView", nil, [0, 76, 390, 400], [
            Node("Row", "Delivery", [12, 94, 84, 100], [
                Node("Link", "Delivery", [20, 100, 68, 75]),
            ]),
            Node("Row", "Grocery", [108, 94, 84, 100], [
                Node("Link", "Grocery", [116, 100, 68, 75]),
            ]),
        ])])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let ref = try number(in: screen.text, containing: "Link \"Delivery\"")
        let link = try XCTUnwrap(screen.text.split(separator: "\n").first { $0.contains("Link \"Delivery\"") })
        XCTAssertFalse(link.contains("[row unverified]"), screen.text)

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").first?["x"]?.double, 54)
        XCTAssertEqual(wda.bodies("POST /wda/tap").first?["y"]?.double, 137.5)
    }

    func testGridEntriesInsideOneWideCellCanBeTapped() async throws {
        let wda = FakeWDA()
        wda.tree([Node("CollectionView", nil, [0, 76, 390, 400], [
            Node("Cell", nil, [0, 143, 390, 83], [
                Node("Button", "外卖", [11, 143, 74, 77]),
                Node("Button", "团购", [92, 143, 74, 77]),
                Node("Button", "酒店/旅行", [173, 143, 74, 77]),
            ]),
        ])])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let ref = try number(in: screen.text, containing: "Button \"外卖\"")

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").first?["x"]?.double, 48)
    }

    func testGridEntryRequiresTheSameNeighborOnTheSameSide() async throws {
        func page(_ left: String, _ right: String) -> [Node] {
            [Node("CollectionView", nil, [0, 76, 390, 400], [
                Node("Cell", nil, [0, 143, 390, 83], [
                    Node("Button", left, [11, 143, 74, 77]),
                    Node("Button", "外卖", [92, 143, 74, 77]),
                    Node("Button", right, [173, 143, 74, 77]),
                ]),
            ])]
        }
        for (left, right) in [("超市", "电影"), ("酒店", "团购")] {
            let wda = FakeWDA()
            wda.tree(page("团购", "酒店"))
            let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
            let screen = await core.call("look", [:])
            let ref = try number(in: screen.text, containing: "Button \"外卖\"")
            wda.tree(page(left, right))

            let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

            XCTAssertTrue(result.isError, result.text)
            XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
        }
    }

    func testSingleVisibleListActionStillChecksItsRowTitle() async throws {
        let wda = FakeWDA()
        wda.tree(menu(["生椰拿铁"]))
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let ref = try number(in: screen.text, containing: "Button \"选规格\"")
        let button = try XCTUnwrap(screen.text.split(separator: "\n").first { $0.contains("Button \"选规格\"") })
        XCTAssertFalse(button.contains("[row unverified]"), screen.text)
        let title = try XCTUnwrap(screen.text.split(separator: "\n").first { $0.contains("StaticText \"生椰拿铁\"") })
        XCTAssertFalse(title.contains("[row unverified]"), screen.text)
        wda.tree(menu(["橙 C 美式"]))

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("its list row could not be confirmed"), result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testSingleUntitledListActionRemainsUnverified() async throws {
        for (type, label) in [("Button", "Edit"), ("Link", "Open"), ("TextField", "备注")] {
            let wda = FakeWDA()
            wda.tree([Node("CollectionView", nil, [0, 76, 390, 400], [
                Node("Cell", nil, [0, 90, 390, 80], [Node(type, label, [300, 100, 60, 40])]),
            ])])
            let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
            let screen = await core.call("look", [:])
            let ref = try number(in: screen.text, containing: "\(type) \"\(label)\"")
            XCTAssertTrue(screen.text.contains("\(type) \"\(label)\" [300,100,60,40] [row unverified]"), screen.text)

            let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

            XCTAssertTrue(result.isError, result.text)
            XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
        }
    }

    func testUntitledListRowWithTwoActionsRemainsUnverified() async throws {
        let wda = FakeWDA()
        wda.tree([Node("CollectionView", nil, [0, 76, 390, 400], [
            Node("Cell", nil, [0, 90, 390, 80], [
                Node("Button", "Edit", [210, 100, 60, 40]),
                Node("Button", "Delete", [280, 100, 60, 40]),
                Node("Button", "Delete", [280, 100, 60, 40]),
            ]),
        ])])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let ref = try number(in: screen.text, containing: "Button \"Edit\"")

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testRepeatedCellControlsWithoutTitlesRemainUnverified() async throws {
        let wda = FakeWDA()
        wda.tree([Node("CollectionView", nil, [0, 76, 390, 400], [
            Node("Cell", nil, [0, 90, 390, 80], [Node("Button", "Edit", [300, 100, 60, 40])]),
            Node("Cell", nil, [0, 180, 390, 80], [Node("Button", "Edit", [300, 190, 60, 40])]),
        ])])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let ref = try number(in: screen.text, containing: "Button \"Edit\"")
        XCTAssertTrue(screen.text.contains("[row unverified]"), screen.text)

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testNewDuplicatePreventsTapOnPreviouslyUniqueCellControl() async throws {
        let wda = FakeWDA()
        let first = Node("Cell", nil, [0, 90, 390, 80], [Node("Button", "Edit", [300, 100, 60, 40])])
        let second = Node("Cell", nil, [0, 180, 390, 80], [Node("Button", "Edit", [300, 190, 60, 40])])
        wda.tree([Node("CollectionView", nil, [0, 76, 390, 400], [first])])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let ref = try number(in: screen.text, containing: "Button \"Edit\"")
        wda.tree([Node("CollectionView", nil, [0, 76, 390, 400], [first, second])])

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testReorderedListTapsTheSameNamedItemAtItsNewPosition() async throws {
        for rowType in ["Cell", "Group"] {
            try await assertReorderedRowIsLocated(rowType)
        }
    }

    private func assertReorderedRowIsLocated(_ rowType: String) async throws {
        let wda = FakeWDA()
        wda.tree(menu(["生椰拿铁", "橙 C 美式"], rowType: rowType))
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let ref = try number(in: screen.text, onRow: "生椰拿铁")

        wda.tree(menu(["橙 C 美式", "生椰拿铁"], rowType: rowType))
        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").first?["y"]?.double, 235)
    }

    func testMovedOtherActionUsesItsProductTitle() async throws {
        func page(_ names: [String]) -> [Node] {
            [Node("CollectionView", nil, [0, 76, 390, 620], names.enumerated().map { index, name in
                let y = Double(90 + 124 * index)
                return Node("Cell", nil, [0, y, 390, 114], [
                    Node("StaticText", name, [16, y + 13, 150, 35]),
                    Node("Other", "选规格", [302, y + 23, 72, 44]),
                ])
            })]
        }
        let wda = FakeWDA()
        wda.tree(page(["生椰拿铁", "橙 C 美式"]))
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let ref = try number(in: screen.text, onRow: "生椰拿铁")
        wda.tree(page(["橙 C 美式", "生椰拿铁"]))

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").first?["y"]?.double, 259)
    }

    func testReorderedListDoesNotGuessWhenTheItemIsMissingOrDuplicated() async throws {
        for names in [["橙 C 美式"], ["橙 C 美式", "生椰拿铁", "生椰拿铁"]] {
            let wda = FakeWDA()
            wda.tree(menu(["生椰拿铁", "橙 C 美式"]))
            let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
            let screen = await core.call("look", [:])
            let ref = try number(in: screen.text, onRow: "生椰拿铁")
            wda.tree(menu(names))

            let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

            XCTAssertTrue(result.isError, result.text)
            XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
        }
    }

    func testReorderedListStopsIfTheRelocatedActionIsCovered() async throws {
        func page(_ names: [String], covered: Bool) -> [Node] {
            [Node("CollectionView", nil, [0, 76, 390, 620], names.enumerated().map { index, name in
                let y = Double(90 + 100 * index)
                var controls = [Node("StaticText", name, [16, y + 13, 150, 35]),
                                Node("Button", "选规格", [302, y + 23, 72, 44])]
                if covered && name == "生椰拿铁" {
                    controls.append(Node("Button", "立即支付", [302, y + 23, 72, 44]))
                }
                return Node("Cell", nil, [0, y, 390, 90], controls)
            })]
        }
        let wda = FakeWDA()
        wda.tree(page(["生椰拿铁", "橙 C 美式"], covered: false))
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true; $0.approvalWait = 0 }
        let screen = await core.call("look", [:])
        let ref = try number(in: screen.text, onRow: "生椰拿铁")
        wda.tree(page(["橙 C 美式", "生椰拿铁"], covered: true))

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testMovedActionDoesNotUsePriceOrPromotionAsProductIdentity() async throws {
        func page(_ title: String, _ detail: String, at y: Double) -> [Node] {
            [Node("CollectionView", nil, [0, 76, 390, 620], [
                Node("Cell", nil, [0, y, 390, 100], [
                    Node("StaticText", detail, [16, y + 5, 100, 20]),
                    Node("StaticText", title, [16, y + 30, 150, 35]),
                    Node("Other", "选规格", [302, y + 23, 72, 44]),
                ]),
            ])]
        }
        for detail in ["¥13", "月售98", "推荐"] {
            let wda = FakeWDA()
            wda.tree(page("生椰拿铁", detail, at: 90))
            let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
            let screen = await core.call("look", [:])
            let ref = try number(in: screen.text, containing: "Other \"选规格\"")
            wda.tree(page("橙 C 美式", detail, at: 214))

            let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

            XCTAssertTrue(result.isError, result.text)
            XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
        }
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

    func testSearchFieldDoesNotInheritTheChangingTextOfItsPageHeader() async throws {
        let wda = FakeWDA()
        let frame: [Double] = [22, 100, 340, 44]
        func header(_ promotion: String, _ query: String) -> [Node] {
            [Node("ScrollView", nil, [0, 64, 390, 700], [
                Node("Group", nil, [0, 68, 390, 140], [
                    Node("StaticText", promotion, [22, 150, 340, 38]),
                    Node("TextField", "搜索", frame, value: query),
                ]),
            ])]
        }
        wda.tree(header("限时优惠", "奶茶"))
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let ref = try number(in: screen.text, containing: "TextField \"搜索 = 奶茶\"")
        wda.tree(header("今日推荐", "咖啡"))

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").first?["y"]?.double, 122)
    }

    func testSearchEntrySurvivesItsRotatingSuggestedQuery() async throws {
        let wda = FakeWDA()
        let frame: [Double] = [56, 510, 159, 48]
        let old = "搜索框，输入文字附近的茶饮"
        wda.tree([Node("StaticText", old, frame)])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let ref = try number(in: screen.text, containing: old)
        wda.tree([Node("StaticText", "搜索框，输入文字附近的咖啡", [56, 510, 161, 48])])

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
        XCTAssertEqual(wda.bodies("POST /wda/tap").first?["x"]?.double, 135.5)
        XCTAssertEqual(wda.bodies("POST /wda/tap").first?["y"]?.double, 534)
    }

    func testSearchEntryAcceptsRotatingSuggestionAsAccessibilityName() async throws {
        @Sendable func tree(_ label: String, width: Double) -> JSON {
            ["type": "XCUIElementTypeApplication", "children": [[
                "type": "XCUIElementTypeStaticText", "label": .string(label), "name": .string(label),
                "rect": ["x": 56, "y": 510, "width": .number(width), "height": 48],
            ]]]
        }
        let original = "搜索框，输入文字查找地点、公交、地铁"
        let wda = FakeWDA()
        wda.set("GET /source") { _ in (200, ["value": tree(original, width: 159)]) }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let ref = try number(in: screen.text, containing: original)
        wda.set("GET /source") { _ in
            (200, ["value": tree("搜索框，输入文字附近的咖啡", width: 171)])
        }

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").first?["x"]?.double, 135.5)
        XCTAssertEqual(wda.bodies("POST /wda/tap").first?["y"]?.double, 534)
    }

    func testRotatingAccessibilityNameStillRequiresPaymentApproval() async throws {
        @Sendable func tree(_ label: String) -> JSON {
            ["type": "XCUIElementTypeApplication", "children": [[
                "type": "XCUIElementTypeStaticText", "label": .string(label), "name": .string(label),
                "rect": ["x": 56, "y": 510, "width": 159, "height": 48],
            ]]]
        }
        let original = "搜索框，输入文字附近的茶饮"
        let wda = FakeWDA()
        wda.set("GET /source") { _ in (200, ["value": tree(original)]) }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true; $0.approvalWait = 0 }
        let screen = await core.call("look", [:])
        let ref = try number(in: screen.text, containing: original)
        wda.set("GET /source") { _ in (200, ["value": tree("搜索框，输入文字立即支付")]) }

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("needs the owner's approval"), result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testChangedSearchEntryCannotBecomeAnotherControl() async throws {
        let original = "搜索框，输入文字附近的茶饮"
        let replacement = "搜索框，输入文字附近的咖啡"
        let frame: [Double] = [56, 510, 159, 48]
        let cases: [[Node]] = [
            [Node("Button", replacement, frame)],
            [Node("StaticText", "店内搜索框，输入文字附近的咖啡", frame)],
            [Node("StaticText", replacement, [56, 410, 159, 48])],
            [Node("StaticText", replacement, frame),
             Node("StaticText", "搜索框，输入文字附近的甜品", [56, 590, 159, 48])],
            [Node("StaticText", replacement, frame),
             Node("Button", "确认付款", frame)],
        ]
        for nodes in cases {
            let wda = FakeWDA()
            wda.tree([Node("StaticText", original, frame)])
            let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true; $0.approvalWait = 0 }
            let screen = await core.call("look", [:])
            let ref = try number(in: screen.text, containing: original)
            wda.tree(nodes)

            let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

            XCTAssertTrue(result.isError, "\(nodes): \(result.text)")
            XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, "\(nodes): \(result.text)")
        }
    }

    func testChangedSearchEntryKeepsItsAccessibilityIdentifier() async throws {
        @Sendable func tree(_ label: String, identifier: String) -> JSON {
            ["type": "XCUIElementTypeApplication", "children": [[
                "type": "XCUIElementTypeStaticText", "label": .string(label), "name": .string(identifier),
                "rect": ["x": 56, "y": 510, "width": 159, "height": 48],
            ]]]
        }
        let wda = FakeWDA()
        let original = "搜索框，输入文字附近的茶饮"
        wda.set("GET /source") { _ in (200, ["value": tree(original, identifier: "main-search")]) }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let ref = try number(in: screen.text, containing: original)
        wda.set("GET /source") { _ in
            (200, ["value": tree("搜索框，输入文字附近的咖啡", identifier: "store-search")])
        }

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testChangedSearchEntryStillChecksTheFreshLabelForSensitiveActions() async throws {
        let wda = FakeWDA()
        let frame: [Double] = [56, 510, 159, 48]
        let original = "搜索框，输入文字附近的茶饮"
        wda.tree([Node("StaticText", original, frame)])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true; $0.approvalWait = 0 }
        let screen = await core.call("look", [:])
        let ref = try number(in: screen.text, containing: original)
        wda.tree([Node("StaticText", "搜索框，输入文字立即支付", frame)])

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("needs the owner's approval"), result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testPageSearchButtonIsDistinctFromTheKeyboardSearchKey() async throws {
        let wda = FakeWDA()
        wda.tree([
            Node("Button", "搜索", [310, 76, 64, 38]),
            Node("Keyboard", nil, [0, 500, 390, 344], [
                Node("Button", "搜索", [300, 800, 80, 40]),
            ]),
        ])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let line = try XCTUnwrap(screen.text.split(separator: "\n").first { $0.contains("Button \"搜索\" [310,76,64,38]") })
        let ref = try number(in: String(line), containing: "Button")

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").first?["x"]?.double, 342)
        XCTAssertEqual(wda.bodies("POST /wda/tap").first?["y"]?.double, 95)
    }

    func testKeyboardNamesakeDoesNotHideAmbiguousPageButtons() async throws {
        let wda = FakeWDA()
        let pageSearch = Node("Button", "搜索", [310, 76, 64, 38])
        let keyboard = Node("Keyboard", nil, [0, 500, 390, 344], [
            Node("Button", "搜索", [300, 800, 80, 40]),
        ])
        wda.tree([pageSearch, keyboard])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let line = try XCTUnwrap(screen.text.split(separator: "\n").first { $0.contains("Button \"搜索\" [310,76,64,38]") })
        let ref = try number(in: String(line), containing: "Button")
        wda.tree([pageSearch, Node("Button", "搜索", [30, 150, 64, 38]), keyboard])

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("could not be distinguished"), result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testToolbarButtonWithAListNamesakeAndMirroredLabelsStaysTappable() async throws {
        let wda = FakeWDA()
        func page(buttonX: Double) -> [Node] {
            let frame = [buttonX, 76, 64, 38]
            return [
                Node("NavigationBar", nil, [0, 65, 390, 52], [
                    Node("Button", "搜索", frame),
                    Node("Button", "搜索", frame),
                    Node("StaticText", "搜索", frame),
                ]),
                Node("CollectionView", nil, [0, 120, 390, 600], [
                    Node("Cell", nil, [0, 132, 390, 90], [
                        Node("StaticText", "目录", [16, 145, 160, 35]),
                        Node("Button", "搜索", [280, 150, 64, 38]),
                    ]),
                ]),
            ]
        }
        wda.tree(page(buttonX: 310))
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let line = try XCTUnwrap(screen.text.split(separator: "\n").first { $0.contains("Button \"搜索\" [310,76,64,38]") })
        XCTAssertFalse(line.contains("[row"), screen.text)
        let ref = try number(in: String(line), containing: "Button")
        wda.tree(page(buttonX: 312))

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").first?["x"]?.double, 342)
    }

    func testFreshOverlayStillBlocksPageButtonAtItsOriginalPoint() async throws {
        let wda = FakeWDA()
        let frame: [Double] = [310, 76, 64, 38]
        let search = Node("Button", "Search", frame)
        wda.tree([search])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let ref = try number(in: screen.text, containing: "Button \"Search\"")
        wda.tree([search, Node("Button", "Close overlay", frame)])

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("is covered at its recorded touch point"), result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testPageButtonMustStillCoverTheTouchPointAfterTheHeaderMoves() async throws {
        let wda = FakeWDA()
        wda.tree([Node("Button", "Sort", [205, 240, 64, 38])])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let screen = await core.call("look", [:])
        let ref = try number(in: screen.text, containing: "Button \"Sort\"")
        wda.tree([Node("Button", "Sort", [205, 134, 64, 38])])

        let result = await core.call("do", ["actions": [["tap": .number(Double(ref))]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("is no longer at its recorded position"), result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    private func menu(_ names: [String], rowType: String = "Cell") -> [Node] {
        let rows = names.enumerated().map { index, name -> Node in
            let y = Double(90 + 100 * index)
            return Node(rowType, nil, [0, y, 390, 90], [
                Node("StaticText", name, [16, y + 13, 150, 35]),
                Node("Button", "选规格", [302, y + 23, 72, 44]),
            ])
        }
        return [Node("CollectionView", nil, [0, 76, 390, 620], rows)]
    }

    private func number(in text: String, onRow name: String) throws -> Int {
        try number(in: text, containing: "[row: \(name)]")
    }

    private func number(in text: String, containing marker: String) throws -> Int {
        let line = text.split(separator: "\n").first { $0.contains(marker) }
        let number = line?.split(whereSeparator: \.isWhitespace).first?.drop(while: { !$0.isNumber })
        return try XCTUnwrap(number.flatMap { Int($0) }, text)
    }
}
