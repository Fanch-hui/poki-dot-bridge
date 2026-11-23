import XCTest
@testable import PokiCore

final class PokiOverlayTests: XCTestCase {
    private let closeText = RecognizedText(text: "X", box: Rect(x: 0.473, y: 0.759, width: 0.05, height: 0.022))
    private let coveredText = RecognizedText(text: "一键下单", box: Rect(x: 0.46, y: 0.59, width: 0.12, height: 0.02))

    private func popup(_ wda: FakeWDA, payment: Bool = false) {
        let body = String(repeating: "神券已到账，外卖大额神券。", count: 6)
        var nodes = [
            Node("StaticText", "一键下单", [182, 498, 45, 15]),
            Node("Other", "双击退出弹窗页面", [0, 0, 390, 844]),
            Node("Other", body, [45, 307, 300, 290]),
            Node("Button", "全部收下", [90, 545, 210, 40]),
        ]
        if payment { nodes.append(Node("Button", "确认支付", [90, 590, 210, 40])) }
        wda.tree(nodes, app: "Shop")
    }

    private func ref(_ result: ToolResult, named label: String) throws -> Int {
        let line = try XCTUnwrap(result.text.split(separator: "\n").first { $0.contains("\"\(label)\"") }, result.text)
        let prefix = try XCTUnwrap(line.split(separator: " ").first, result.text)
        return try XCTUnwrap(Int(prefix.trimmingCharacters(in: CharacterSet(charactersIn: "+~ "))), result.text)
    }

    func testPopupHidesCoveredTreeAndFullReadOCRAndExposesClose() async throws {
        let wda = FakeWDA()
        popup(wda)
        let host = FakeHost()
        host.texts.value = [coveredText, closeText]
        let (core, _, _) = makeCore(wda, host: host) { $0.approvalWait = 0 }

        let look = await core.call("look", ["full": true])
        XCTAssertFalse(look.text.contains("一键下单"), look.text)
        XCTAssertTrue(look.text.contains("全部收下"), look.text)
        let closeRef = try ref(look, named: "关闭弹窗")
        let result = await core.call("do", ["actions": [["tap": .number(Double(closeRef))]]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertNil(core.pendingApproval)
        let tap = try XCTUnwrap(wda.bodies("POST /wda/tap").first, result.text)
        XCTAssertEqual(try XCTUnwrap(tap["x"]?.double), (0.473 + 0.025) * 390, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(tap["y"]?.double), (0.759 + 0.011) * 844, accuracy: 1)
    }

    func testDisappearedOrMovedPopupCloseNeverSendsTheOldTouch() async throws {
        for moved in [false, true] {
            let wda = FakeWDA()
            popup(wda)
            let host = FakeHost()
            host.texts.value = [closeText]
            let (core, _, _) = makeCore(wda, host: host)
            let initial = await core.call("look", [:])
            let closeRef = try ref(initial, named: "关闭弹窗")
            if moved {
                host.texts.value = [RecognizedText(text: "X", box: Rect(x: 0.49, y: 0.80, width: 0.05, height: 0.022))]
            } else {
                wda.tree([Node("Button", "确认支付", [170, 630, 80, 45])], app: "Shop")
            }
            let result = await core.call("do", ["actions": [["tap": .number(Double(closeRef))]]])
            XCTAssertTrue(result.isError, result.text)
            XCTAssertTrue(result.text.contains("nothing was sent"), result.text)
            XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
        }
    }

    func testAmbiguousCloseUsesScreenshotAndDoesNotInventAButton() async {
        let wda = FakeWDA()
        popup(wda)
        let host = FakeHost()
        host.texts.value = [closeText, closeText]
        let (core, _, _) = makeCore(wda, host: host)
        let look = await core.call("look", [:])
        XCTAssertFalse(look.text.contains("Button \"关闭弹窗\""), look.text)
        XCTAssertTrue(look.text.contains("inspect the screenshot"), look.text)
        XCTAssertNotNil(look.jpeg)
    }

    func testBatchedCloseIsRefusedBeforeAnyTouch() async throws {
        let wda = FakeWDA()
        popup(wda)
        let host = FakeHost()
        host.texts.value = [closeText]
        let (core, _, _) = makeCore(wda, host: host)
        let look = await core.call("look", [:])
        let closeRef = try ref(look, named: "关闭弹窗")
        let result = await core.call("do", ["actions": [["tap": .number(Double(closeRef))], ["tap": [100, 100]]]])
        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testPopupIsRecheckedAfterApproval() async throws {
        let wda = FakeWDA()
        wda.set("GET /wda/activeAppInfo") { _ in
            (200, ["value": ["bundleId": "com.apple.Passbook", "name": "Wallet"]])
        }
        popup(wda)
        let host = FakeHost()
        host.texts.value = [closeText]
        let (core, _, _) = makeCore(wda, host: host) { $0.approvalWait = 3 }
        let look = await core.call("look", [:])
        let closeRef = try ref(look, named: "关闭弹窗")
        let call = Task { await core.call("do", ["actions": [["tap": .number(Double(closeRef))]]]) }
        defer { call.cancel() }
        for _ in 0..<100 where core.pendingApproval == nil {
            try await Task.sleep(for: .milliseconds(15))
        }
        let approval = try XCTUnwrap(core.pendingApproval)
        wda.tree([Node("Button", "确认支付", [170, 630, 80, 45])], app: "Wallet")
        core.resolveApproval(id: approval.id, approved: true)
        let result = await call.value
        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testVisiblePaymentStillRequiresApprovalAndNormalPageIsIntact() async throws {
        let wda = FakeWDA()
        popup(wda, payment: true)
        let host = FakeHost()
        host.texts.value = [closeText]
        let (core, _, _) = makeCore(wda, host: host) { $0.approvalWait = 0 }
        let look = await core.call("look", [:])
        let payment = try ref(look, named: "确认支付")
        let result = await core.call("do", ["actions": [["tap": .number(Double(payment))]]])
        XCTAssertTrue(result.text.contains("approval_required"), result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)

        wda.tree([Node("StaticText", "一键下单", [182, 498, 45, 15])], app: "Shop")
        let normal = await core.call("look", [:])
        XCTAssertTrue(normal.text.contains("一键下单"), normal.text)
    }
}
