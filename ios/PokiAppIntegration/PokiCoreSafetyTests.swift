import XCTest
@testable import PokiCore

final class PokiCoreSafetyTests: XCTestCase {
    func testAlreadyCancelledDeadlineDoesNotDispatchWork() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await withDeadline(1, "dispatching the touch") { true }
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled call ran the touch operation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testScrollingAnOrderListDoesNotRequirePaymentApproval() async {
        let wda = FakeWDA()
        wda.tree([
            Node("ScrollView", "优惠券，一键下单", [0, 68, 390, 742], [
                Node("Button", "一键下单", [16, 734, 358, 44]),
            ]),
        ], app: "Shop")
        let (core, _, _) = makeCore(wda) { $0.approvalWait = 0 }
        _ = await core.call("look", [:])

        let swipe = await core.call("do", ["actions": [["swipe": "up"]]])
        XCTAssertFalse(swipe.isError, swipe.text)
        XCTAssertEqual(wda.bodies("POST /wda/pressAndDragWithVelocity").count, 1, swipe.text)
        XCTAssertNil(core.pendingApproval)

        let order = await core.call("do", ["actions": [["tap": [195, 756]]]])
        XCTAssertTrue(order.isError, order.text)
        XCTAssertNotNil(core.pendingApproval)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
    }

    func testOrderActivityOnProductCardsDoesNotRequireApproval() async {
        let cards: [(String, String, JSON)] = [
            ("StaticText", "近期100+人已下单", 1),
            ("Button", "刚刚有用户下单 最近3小时20+人下单 最近24小时70+人下单", 1),
            ("StaticText", "最近3小时7人下单", [150, 125]),
            ("Button", "128人已购买", 1),
            ("Button", "3位用户已支付", 1),
            ("StaticText", "近期100人+下单", 1),
            ("Table", "商品列表 " + String(repeating: "饮品推荐 ", count: 180) + "最近3小时20+人下单", [150, 125]),
        ]
        for (type, label, target) in cards {
            let wda = FakeWDA()
            wda.tree([Node(type, label, [20, 100, 280, 50])], app: "Shop")
            let (core, _, _) = makeCore(wda) {
                $0.approvalWait = 0
                $0.standaloneObservations = true
            }
            _ = await core.call("look", [:])

            let result = await core.call("do", ["actions": [["tap": target]]])

            XCTAssertFalse(result.isError, "\(label): \(result.text)")
            XCTAssertNil(core.pendingApproval, label)
            XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1, label)
        }
    }

    func testMerchantPromotionsDoNotRequirePaymentApproval() async {
        let cards: [(String, String, JSON)] = [
            ("Other", "示例茶饮(示例广场店)\n月售9999+\n起送 ¥25\n配送 约¥4.1\n支付再减\n0.2元", 1),
            ("Button", "商店, 月售999+, 配送 ¥3, 支付再减, 0.2元, 进店", [150, 125]),
            ("Button", "店铺活动：支付再减、0.2元", 1),
            ("Other", "门店 月售300+ 配送 ¥3 支付立减5元", 1),
            ("Other", "门店 月售300+ 配送 ¥3 支付后立减3元", [150, 125]),
            ("Other", "门店 月售300+ 配送 ¥3 付款满减 优惠券", 1),
            ("Other", "门店 月售300+ 起送 ¥20 支付返券", 1),
            ("Other", "门店 月售300+ 配送 ¥3 购买后返券", 1),
            ("Other", "门店 月售300+ 配送 ¥3 支付宝红包", 1),
            ("Button", "商家活动：支付享优惠", 1),
        ]
        for (type, label, target) in cards {
            let wda = FakeWDA()
            wda.tree([Node(type, label, [20, 100, 280, 50])], app: "Shop")
            let (core, _, _) = makeCore(wda) { $0.approvalWait = 0; $0.standaloneObservations = true }
            _ = await core.call("look", [:])

            let result = await core.call("do", ["actions": [["tap": target]]])

            XCTAssertFalse(result.isError, "\(label): \(result.text)")
            XCTAssertNil(core.pendingApproval, label)
            XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1, label)
        }
    }

    func testPaymentAndOrderActionsStillRequireApprovalWithPromotions() async {
        let labels = [
            "支付再减", "支付再减0.2元", "立即支付再减0.2元", "去支付再减，进店",
            "月售999+，支付再减0.2元，立即支付", "进店，点击这里支付再减0.2元",
            "月售999+，立即支付享优惠", "店铺活动：支付后立减，确认付款领券",
            "月售999+，立即购买后返券", "配送 ¥3，购买后返券，立即购买",
            "商家活动：使用支付宝支付享优惠",
            "门店 月售300+ 支付立减5元，确认支付", "确认付款领券",
            "运费¥3，支付享优惠", "应付¥12，配送费¥0，支付立减",
            "配送¥3，支付再减", "店铺券，付款立减", "起送¥20，支付返券", "门店，起送¥20，支付返券",
            "月售999+，店铺券，支付享优惠",
            "月售999+，配送¥3，应付¥12，支付立减", "店铺活动，实付¥12，支付再减",
            "近期100人+下单，为2人下单",
        ]
        for label in labels {
            let wda = FakeWDA()
            wda.tree([Node("Button", label, [20, 100, 280, 50])], app: "Shop")
            let (core, _, _) = makeCore(wda) { $0.approvalWait = 0; $0.approvalMode = { .off } }
            _ = await core.call("look", [:])

            let result = await core.call("do", ["actions": [["tap": 1]]])

            XCTAssertTrue(result.text.contains("approval_required"), "\(label): \(result.text)")
            XCTAssertNotNil(core.pendingApproval, label)
            XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, label)
        }
    }

    func testPromotionalChildAndPaymentChildFollowTheirOwnControl() async {
        let wda = FakeWDA()
        wda.tree([Node("Button", "商店 月售999+ 配送 ¥3 支付再减、0.2元 进店", [20, 100, 340, 120], [
            Node("StaticText", "支付再减、0.2元", [30, 110, 120, 30]),
            Node("Button", "立即支付", [220, 165, 110, 35]),
        ])], app: "Shop")
        let (core, _, _) = makeCore(wda) { $0.approvalWait = 0; $0.standaloneObservations = true }
        let look = await core.call("look", ["full": true])
        XCTAssertTrue(look.text.contains("StaticText \"支付再减、0.2元\""), look.text)

        let promotion = await core.call("do", ["actions": [["tap": [70, 125]]]])
        XCTAssertFalse(promotion.isError, promotion.text)
        XCTAssertNil(core.pendingApproval)

        let payment = await core.call("do", ["actions": [["tap": [260, 180]]]])
        XCTAssertTrue(payment.text.contains("approval_required"), payment.text)
        XCTAssertNotNil(core.pendingApproval)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1, payment.text)
    }

    func testPromotionInsidePaymentButtonStillRequiresApproval() async {
        let wda = FakeWDA()
        wda.tree([Node("Button", nil, [20, 100, 280, 80], [
            Node("StaticText", "确认付款领券", [30, 105, 160, 25]),
            Node("StaticText", "支付再减0.2元", [30, 140, 150, 30]),
        ])], app: "Shop")
        let (core, _, _) = makeCore(wda) { $0.approvalWait = 0 }
        _ = await core.call("look", [:])

        let result = await core.call("do", ["actions": [["tap": [60, 155]]]])

        XCTAssertTrue(result.text.contains("approval_required"), result.text)
        XCTAssertNotNil(core.pendingApproval)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testPaymentChildInPromotionalMerchantCardIsJudgedAtTheTouch() async {
        for type in ["Other", "Button"] {
            let wda = FakeWDA()
            wda.tree([Node(type, "商店 月售999+ 配送 ¥3 支付再减 进店", [20, 100, 280, 80], [
                Node("Button", nil, [200, 140, 90, 30], [
                    Node("StaticText", "立即支付", [200, 140, 40, 30]),
                ]),
            ])], app: "Shop")
            let (core, _, _) = makeCore(wda) { $0.approvalWait = 0; $0.standaloneObservations = true }
            _ = await core.call("look", [:])

            let card = await core.call("do", ["actions": [["tap": [70, 125]]]])
            XCTAssertFalse(card.isError, card.text)
            XCTAssertNil(core.pendingApproval)

            let payment = await core.call("do", ["actions": [["tap": [280, 155]]]])
            XCTAssertTrue(payment.text.contains("approval_required"), payment.text)
            XCTAssertNotNil(core.pendingApproval)
            XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1, payment.text)
        }
    }

    func testCheckoutChildKeepsPromotionalParentSubjectToApproval() async {
        for (type, target): (String, JSON) in [("Button", 1), ("Button", [60, 155]), ("Other", 1)] {
            let wda = FakeWDA()
            wda.tree([Node(type, "商店 月售999+ 配送 ¥3 支付再减 进店", [20, 100, 280, 80], [
                Node("StaticText", "应付¥12", [30, 105, 160, 25]),
                Node("StaticText", "支付再减", [30, 140, 150, 30]),
            ])], app: "Shop")
            let (core, _, _) = makeCore(wda) { $0.approvalWait = 0 }
            _ = await core.call("look", [:])

            let result = await core.call("do", ["actions": [["tap": target]]])

            XCTAssertTrue(result.text.contains("approval_required"), result.text)
            XCTAssertNotNil(core.pendingApproval)
            XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
        }
    }

    func testRealOrderActionsStillRequireApprovalAlongsideActivity() async {
        let actions: [(String, String, JSON)] = [
            ("Button", "近期100+人已下单，立即下单", 1),
            ("Button", "刚刚有用户下单，提交订单", 1),
            ("Button", "为2人下单", 1),
            ("Button", "帮3人付款", 1),
            ("Button", "最近3小时20+人下单，为2人下单", 1),
            ("Button", "提交订单", 1),
            ("Button", "提交訂單", 1),
            ("Button", "确认支付", 1),
            ("Table", "商品列表 最近3小时20+人下单，提交订单", [150, 125]),
        ]
        for (type, label, target) in actions {
            let wda = FakeWDA()
            wda.tree([Node(type, label, [20, 100, 280, 50])], app: "Shop")
            let (core, _, _) = makeCore(wda) {
                $0.approvalWait = 0
                $0.approvalMode = { .off }
            }
            _ = await core.call("look", [:])

            let result = await core.call("do", ["actions": [["tap": target]]])

            XCTAssertTrue(result.text.contains("approval_required"), "\(label): \(result.text)")
            XCTAssertNotNil(core.pendingApproval, label)
            XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, label)
        }
    }

    func testPriceInsideAnOrderButtonRequiresApproval() async {
        for target: JSON in [2, [60, 155]] {
            let wda = FakeWDA()
            wda.tree([Node("Button", nil, [20, 100, 280, 80], [
                Node("StaticText", "提交订单", [30, 105, 100, 25]),
                Node("StaticText", "¥16.5", [30, 140, 100, 30]),
            ])], app: "Shop")
            let (core, _, _) = makeCore(wda) { $0.approvalWait = 0 }
            _ = await core.call("look", [:])

            let result = await core.call("do", ["actions": [["tap": target]]])

            XCTAssertTrue(result.text.contains("approval_required"), result.text)
            XCTAssertNotNil(core.pendingApproval)
            XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
        }
    }

    func testFreshPriceControlIsRecheckedAgainstItsNewOrderButton() async {
        let wda = FakeWDA()
        let price = Node("StaticText", "¥16.5", [30, 140, 100, 30])
        wda.tree([Node("Button", nil, [20, 100, 280, 80], [price])], app: "Shop")
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        _ = await core.call("look", [:])
        wda.tree([Node("Button", nil, [20, 100, 280, 80], [
            price, Node("StaticText", "提交订单", [150, 140, 100, 30]),
        ])], app: "Shop")

        let result = await core.call("do", ["actions": [["tap": 1]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("needs the owner's approval"), result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testSeparateOrderButtonDoesNotBlockProductCard() async {
        let wda = FakeWDA()
        wda.tree([Node("Button", nil, [20, 100, 340, 100], [
            Node("StaticText", "多肉葡萄", [30, 110, 140, 30]),
            Node("Button", "提交订单", [230, 150, 110, 35]),
        ])], app: "Shop")
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        _ = await core.call("look", [:])

        let result = await core.call("do", ["actions": [["tap": 1]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertNil(core.pendingApproval)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1, result.text)
    }

    func testCancellingPendingPaymentKeepsTheButtonUntouched() async throws {
        let wda = FakeWDA()
        wda.source([("Button", "一键下单")], app: "Shop")
        let (core, _, _) = makeCore(wda) { $0.approvalWait = 3 }
        _ = await core.call("look", [:])
        let call = Task { await core.call("do", ["actions": [["tap": 1]]]) }
        defer { call.cancel() }

        for _ in 0..<100 where core.pendingApproval == nil {
            try await Task.sleep(for: .milliseconds(15))
        }
        let approval = try XCTUnwrap(core.pendingApproval)
        call.cancel()
        core.resolveApproval(id: approval.id, approved: true)
        let result = await call.value

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
    }

    func testARawTapOnTheCouponOverlayDoesNotHitAnOrderLabelsBottomEdge() async {
        let wda = FakeWDA()
        let order = Node("StaticText", "一键下单", [196, 539, 48, 16])
        wda.tree([order, Node("Other", "优惠券", [0, 68, 390, 720])], app: "Shop")
        let (core, _, _) = makeCore(wda) { $0.approvalWait = 0 }
        _ = await core.call("look", [:])
        let dismiss = await core.call("do", ["actions": [["tap": [210, 555]]]])
        XCTAssertFalse(dismiss.isError, dismiss.text)
        XCTAssertNil(core.pendingApproval)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1, dismiss.text)

        wda.tree([order], app: "Shop")
        _ = await core.call("look", [:])
        let purchase = await core.call("do", ["actions": [["tap": [210, 548]]]])
        XCTAssertTrue(purchase.isError, purchase.text)
        XCTAssertNotNil(core.pendingApproval)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1, purchase.text)
    }

    func testAForegroundCouponSheetTakesPriorityOverSmallerBackgroundPaymentText() async {
        let wda = FakeWDA()
        wda.tree([
            Node("StaticText", "一键下单", [196, 539, 48, 16]),
            Node("Sheet", nil, [0, 440, 390, 350], [
                Node("Button", "关闭优惠券", [185, 520, 80, 48]),
            ]),
        ], app: "Shop")
        let (core, _, _) = makeCore(wda) { $0.approvalWait = 0 }
        _ = await core.call("look", [:])

        let dismiss = await core.call("do", ["actions": [["tap": [210, 548]]]])
        XCTAssertFalse(dismiss.isError, dismiss.text)
        XCTAssertNil(core.pendingApproval)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1, dismiss.text)
    }
}
