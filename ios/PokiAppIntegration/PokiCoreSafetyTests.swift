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
