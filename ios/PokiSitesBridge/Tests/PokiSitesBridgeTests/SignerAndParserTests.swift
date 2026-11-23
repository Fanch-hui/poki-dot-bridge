import CryptoKit
import XCTest
@testable import PokiSitesBridge

final class SignerAndParserTests: XCTestCase {
    func testCrossLanguageEd25519AndBase32Vectors() throws {
        let seed = Data((0..<32).map { UInt8($0) })
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let signer = SitesRequestSigner(privateKey: key)

        XCTAssertEqual(signer.publicKeyBase64, "A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=")
        XCTAssertEqual(signer.label, "aoqqpp7tzyil4hlq3umoos6atft6jvrqtosq2xy53sdgiesvgg4a")
        XCTAssertEqual(signer.label.count, 52)

        let body = Data("{\"wait_ms\":10000}".utf8)
        let bodySha256 = SitesCrypto.sha256Hex(body)
        XCTAssertEqual(bodySha256, "8032bda751e3e5dd2d6b5894dc955e0a8658365606ba4980fe439e914aad282d")

        let headers = try signer.signedHeaders(
            method: "POST",
            path: "/api/device/poll",
            body: body,
            deviceId: "dev_test",
            deviceToken: "tok_test",
            generation: 1,
            siwcBypassToken: "siwc_secret",
            timestamp: 1795334400,
            nonce: "vector-nonce-0001"
        )
        let deviceMsg = SitesCrypto.canonicalDeviceMessage(
            method: "POST",
            path: "/api/device/poll",
            timestamp: 1795334400,
            nonce: "vector-nonce-0001",
            bodySha256: bodySha256
        )
        let swiftDevSig = try XCTUnwrap(headers["X-Poki-Signature"].flatMap { Data(base64Encoded: $0) })
        let tsDevSig = try XCTUnwrap(Data(base64Encoded: "hsbrpyuEtqmwmzen9VnMm8qWslOtpH801ZfWiimCMuwabj0rTWuL0fko//MYmkGPGnSw1HGEP9BrgLvBLjtACw=="))
        XCTAssertTrue(key.publicKey.isValidSignature(swiftDevSig, for: deviceMsg))
        XCTAssertTrue(key.publicKey.isValidSignature(tsDevSig, for: deviceMsg))
        XCTAssertEqual(headers["OAI-Sites-Authorization"], "Bearer siwc_secret")

        let pairSig = try signer.signPairingProof(
            pairingCode: "ABCD-EFGH-2345",
            timestamp: 1795334400,
            nonce: "vector-pair-nonce-0001"
        )
        let codeHash = SitesCrypto.sha256Hex("ABCD-EFGH-2345")
        XCTAssertEqual(codeHash, "0242fa54beb7faafd5962f6282d9acb94a096b31e2833920720546e4449ec521")
        let pairMsg = SitesCrypto.canonicalPairMessage(
            codeHash: codeHash,
            label: signer.label,
            timestamp: 1795334400,
            nonce: "vector-pair-nonce-0001"
        )
        let swiftPairSig = try XCTUnwrap(Data(base64Encoded: pairSig))
        let tsPairSig = try XCTUnwrap(Data(base64Encoded: "+NCdaQ2zEBFE8dDyxYVzvt63rh9QbKc+8x6OL56WUlHJidH1B13PqfdBcaasjGXn47GAsZ0f+Jp7DL5O4ZfgBw=="))
        XCTAssertTrue(key.publicKey.isValidSignature(swiftPairSig, for: pairMsg))
        XCTAssertTrue(key.publicKey.isValidSignature(tsPairSig, for: pairMsg))
    }

    func testParseLookAndDoOutput() {
        let sample = """
        app: Settings   read: 2026-11-22T07:00:00Z (312 ms)   note: tree warm
        screenshot: 402 px wide, 1 px = 1 screen point
        did: tap "Wi-Fi" (sent, 42 ms)
        screen_changed: true (the elements changed)
        elements (2):
        +1 Button "Wi-Fi = On" [16,120,370,44]
        ~2 WebView "Portal" [0,180,402,400] [collapsed]
        """
        let parsed = PokiOutputParser.parse(
            toolName: "do",
            text: sample,
            isError: false,
            screenshotJPEG: Data([0xFF, 0xD8, 0xFF, 0xD9])
        )
        XCTAssertEqual(parsed.status, "succeeded")
        XCTAssertEqual(parsed.observation.app_name, "Settings")
        XCTAssertEqual(parsed.observation.screen_width, 402)
        XCTAssertEqual(parsed.observation.screen_changed, true)
        XCTAssertEqual(parsed.receipts.count, 1)
        XCTAssertEqual(parsed.receipts[0].status, "sent")
        XCTAssertEqual(parsed.observation.elements.count, 2)
        XCTAssertEqual(parsed.observation.elements[0].change, "added")
        XCTAssertEqual(parsed.observation.elements[0].label, "Wi-Fi")
        XCTAssertEqual(parsed.observation.elements[0].value, "On")
        XCTAssertEqual(parsed.observation.elements[1].change, "moved")
        XCTAssertEqual(parsed.observation.elements[1].flags, ["collapsed"])
    }

    func testDuplicateControlsKeepVerifiedOrUnverifiedRowContext() throws {
        let sample = """
        app: Example
        elements (3):
        1 Button "选规格" [280,100,90,44] [row: 生椰拿铁]
        2 Button "选规格" [280,180,90,44] [collapsed] [row unverified]
        3 Button "设置" [20,20,90,44]
        """
        let parsed = PokiOutputParser.parse(toolName: "look", text: sample, isError: false, screenshotJPEG: nil)
        let elements = parsed.observation.elements
        XCTAssertEqual(elements.map(\.ref), [1, 2, 3])
        XCTAssertEqual(elements[0].row_label, "生椰拿铁")
        XCTAssertNil(elements[0].flags)
        XCTAssertNil(elements[1].row_label)
        XCTAssertEqual(elements[1].flags, ["collapsed", "row_unverified"])
        XCTAssertNil(elements[2].row_label)
        XCTAssertNil(elements[2].flags)

        let encoded = try JSONEncoder().encode(parsed.observation)
        let decoded = try JSONDecoder().decode(ObservationPayloadDTO.self, from: encoded)
        XCTAssertEqual(decoded.elements, elements)
    }

    func testParseApprovalRequiredAndLockedScreen() {
        let sample = """
        app: Messages   read: 2026-11-22T07:01:00Z (180 ms)
        screen: locked (the owner has to unlock the phone before anything can be done)
        did: type "Hello" (sent, 200 ms)
        error: not_sent from action 2: approval_required (id appr_9911)
        """
        let parsed = PokiOutputParser.parse(
            toolName: "do",
            text: sample,
            isError: true,
            screenshotJPEG: nil
        )
        XCTAssertEqual(parsed.status, "awaiting_approval")
        XCTAssertEqual(parsed.approvalRequired?.id, "appr_9911")
        XCTAssertTrue(parsed.observation.screen_locked)
        XCTAssertEqual(parsed.errorCode, "APPROVAL_REQUIRED")
    }

    func testDeclinedApprovalWithScreenAndEarlierSentActionIsFailed() {
        let sample = """
        app: Meituan
        did: tap "Open" (sent, 42 ms)
        error: not_sent from action 2: the owner declined on the phone (payment). Actions 1 to 1 were sent (below).
        elements (1):
        1 Button "Close coupon" [16,120,120,44]
        """
        let parsed = PokiOutputParser.parse(
            toolName: "do", text: sample, isError: true, screenshotJPEG: Data([0xFF, 0xD8])
        )
        XCTAssertEqual(parsed.status, "failed")
        XCTAssertEqual(parsed.errorCode, "POKI_ERROR")
        XCTAssertTrue(parsed.errorMessage?.contains("owner declined") == true)
        XCTAssertEqual(parsed.receipts.map(\.status), ["sent"])
        XCTAssertEqual(parsed.observation.elements.first?.label, "Close coupon")
        XCTAssertNotNil(parsed.observation.screenshot_base64)
    }

    func testWithdrawnApprovalAndUnansweredApprovalAreNotSuccess() {
        let withdrawn = """
        app: Meituan
        did: swipe up (sent, 900 ms)
        error: not_sent from action 2: approval_required (id appr_1): payment.
        approval: withdrawn (id appr_1); the screen changed.
        """
        let denied = """
        not_sent from action 1: the approval request ended unanswered (payment). Nothing was sent.
        app: Meituan
        elements (1):
        1 Button "Coupon" [16,120,120,44]
        """
        for text in [withdrawn, denied] {
            let parsed = PokiOutputParser.parse(
                toolName: "do", text: text, isError: true, screenshotJPEG: Data([0xFF, 0xD8])
            )
            XCTAssertEqual(parsed.status, "failed")
            XCTAssertNil(parsed.approvalRequired)
        }
        let parsed = PokiOutputParser.parse(
            toolName: "do", text: withdrawn, isError: true, screenshotJPEG: nil
        )
        XCTAssertEqual(parsed.receipts.map(\.status), ["sent"])
    }

    func testOnlyExecutionMarkersAreTreatedAsReceiptsOrApprovals() {
        let sample = """
        app: Example
        did: tap "Confirm" (unknown: cancelled)
        did: swipe up (not_sent)
        did: paused 600 ms before reading
        did: read after 200 ms: the screen had changed and held still
        elements (1):
        1 StaticText "approval_required (id fake)" [16,120,200,40]
        """
        let parsed = PokiOutputParser.parse(toolName: "do", text: sample, isError: true, screenshotJPEG: nil)
        XCTAssertEqual(parsed.status, "failed")
        XCTAssertNil(parsed.approvalRequired)
        XCTAssertEqual(parsed.receipts.map(\.status), ["unknown", "not_sent"])
        XCTAssertTrue(parsed.uncertainExecution)
    }

    func testNotSentWithScreenshotIsFailedEvenWhenPokiReturnsNoErrorFlag() {
        let sample = """
        not_sent: the runner is still finishing an earlier action; nothing was sent.
        screenshot: the screen now (nothing was sent)
        """
        let parsed = PokiOutputParser.parse(
            toolName: "do", text: sample, isError: false, screenshotJPEG: Data([0xFF, 0xD8])
        )
        XCTAssertEqual(parsed.status, "failed")
        XCTAssertEqual(parsed.errorCode, "POKI_ERROR")
        XCTAssertEqual(parsed.errorMessage, "not_sent: the runner is still finishing an earlier action; nothing was sent.")
        XCTAssertTrue(parsed.receipts.isEmpty)
        XCTAssertNotNil(parsed.observation.screenshot_base64)
    }

    func testConfirmedCancellationKeepsPriorAndUncertainReceipts() {
        let sample = """
        app: Example
        did: swipe up (sent, 30 ms)
        did: {"tap":2} (unknown: cancelled)
        error: cancelled at action 2
        """
        let parsed = PokiOutputParser.parse(
            toolName: "do", text: sample, isError: true, screenshotJPEG: Data([0xFF, 0xD8])
        )
        XCTAssertEqual(parsed.status, "cancelled")
        XCTAssertEqual(parsed.errorCode, "CANCELLED")
        XCTAssertEqual(parsed.receipts.map(\.status), ["sent", "unknown"])
        XCTAssertTrue(parsed.uncertainExecution)
        XCTAssertNotNil(parsed.observation.screenshot_base64)

        for text in [
            "cancelled: the caller stopped waiting before the owner answered",
            "error: cancelled before action 2; nothing more was sent",
        ] {
            let parsed = PokiOutputParser.parse(toolName: "do", text: text, isError: true, screenshotJPEG: nil)
            XCTAssertEqual(parsed.status, "cancelled")
        }

        let unknown = PokiOutputParser.parse(
            toolName: "do", text: "error: CancellationError(); what was sent is unknown",
            isError: true, screenshotJPEG: nil
        )
        XCTAssertEqual(unknown.status, "failed")
        XCTAssertTrue(unknown.uncertainExecution)
    }

    func testEarlierUndeliveredReplyIsNotTreatedAsCurrentActions() {
        let sample = """
        earlier, never delivered to you: the do call whose connection dropped:
        did: tap "Confirm" (sent, 42 ms)
        error: not_sent from action 2: approval_required (id old): payment

        now:
        app: Example
        did: {"swipe":"up"} (unknown: cancelled)
        error: cancelled at action 1
        elements (1):
        1 Button "Coupon" [16,120,120,44]
        """
        let parsed = PokiOutputParser.parse(toolName: "do", text: sample, isError: true, screenshotJPEG: nil)
        XCTAssertEqual(parsed.status, "cancelled")
        XCTAssertNil(parsed.approvalRequired)
        XCTAssertEqual(parsed.receipts.map(\.status), ["unknown"])
        XCTAssertEqual(parsed.observation.elements.first?.label, "Coupon")
        XCTAssertEqual(parsed.observation.raw_text, sample)
    }

    func testJSONRPCAdapterDecodesTextAndImage() async {
        let adapter = PokiCoreJSONRPCAdapter(
            stateReader: { "automationReady" },
            rpcHandler: { body, _ in
                XCTAssertTrue(body.contains("\"tools/call\""))
                let jpegB64 = Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString()
                let reply = """
                {"jsonrpc":"2.0","id":"tsk_1","result":{"content":[{"type":"text","text":"app: Notes"},{"type":"image","data":"\(jpegB64)","mimeType":"image/jpeg"}],"isError":false}}
                """
                return (200, reply)
            }
        )
        let task = ClaimedTaskDTO(
            task_id: "tsk_1",
            tool_name: "look",
            payload: ["full": .bool(false)],
            observation_id: nil,
            lease_token: "lease_1",
            lease_expires_at: 9999999999999,
            expires_at: 9999999999999
        )
        let reply = await adapter.execute(task: task)
        XCTAssertFalse(reply.isError)
        XCTAssertEqual(reply.text, "app: Notes")
        XCTAssertEqual(reply.screenshotJPEG, Data([0xFF, 0xD8, 0xFF, 0xD9]))
    }

    func testCancelledHandshakeDoesNotDispatchToolCall() async {
        final class Capture: @unchecked Sendable {
            let lock = NSLock()
            var toolCalls = 0
        }
        let capture = Capture()
        let initialized = expectation(description: "session initialization started")
        let adapter = PokiCoreJSONRPCAdapter(
            enableSessionHandshake: true,
            stateReader: { "automationReady" },
            sessionRPCHandler: { body, _ in
                if body.contains("\"initialize\"") {
                    initialized.fulfill()
                    try? await Task.sleep(for: .seconds(30))
                    return (200, ["mcp-session-id": "session"], "{\"result\":{}}")
                }
                capture.lock.withLock { capture.toolCalls += 1 }
                return (200, [:], "{\"result\":{}}")
            }
        )
        let task = ClaimedTaskDTO(
            task_id: "tsk_cancel", tool_name: "do", payload: ["actions": .array([])],
            observation_id: nil, lease_token: "lease", lease_expires_at: 9999999999999,
            expires_at: 9999999999999
        )
        let execution = Task { await adapter.execute(task: task) }
        await fulfillment(of: [initialized], timeout: 2)
        execution.cancel()
        let reply = await execution.value
        XCTAssertTrue(reply.isError)
        XCTAssertTrue(reply.text.contains("nothing was sent"))
        XCTAssertEqual(capture.lock.withLock { capture.toolCalls }, 0)
    }

    func testRunnerStateMapperBearerSanitizationAndSessionHandshake() async {
        XCTAssertEqual(PokiRunnerStateMapper.normalize("standby"), "starting")
        XCTAssertEqual(PokiRunnerStateMapper.normalize("mounting_ddi"), "starting")
        XCTAssertEqual(PokiRunnerStateMapper.normalize("waiting_network"), "starting")
        XCTAssertEqual(PokiRunnerStateMapper.normalize("running", inProcessReady: true), "automationReady")
        XCTAssertEqual(PokiRunnerStateMapper.normalize("idle", awaitingAuthorization: true), "awaitingAuthorization")
        XCTAssertEqual(PokiRunnerStateMapper.normalize("unexpected_state"), "unknown")

        XCTAssertEqual(SitesRequestSigner.normalizeBearerToken("  Bearer  secret_123  "), "secret_123")
        XCTAssertEqual(SitesRequestSigner.normalizeBearerToken("   "), nil)

        final class CaptureBox: @unchecked Sendable {
            let lock = NSLock()
            var seenMethods: [String] = []
            var seenSessionHeaders: [String?] = []
        }
        let box = CaptureBox()
        let adapter = PokiCoreJSONRPCAdapter(
            connectorId: "chatgpt-dot-sites",
            enableSessionHandshake: true,
            stateReader: { "standby" },
            sessionRPCHandler: { body, headers in
                let data = Data(body.utf8)
                let json = try! JSONDecoder().decode([String: JSONValue].self, from: data)
                let method = json["method"]?.stringValue ?? ""
                box.lock.withLock {
                    box.seenMethods.append(method)
                    box.seenSessionHeaders.append(headers["mcp-session-id"])
                }
                if method == "initialize" {
                    return (200, ["mcp-session-id": "sess_poki_1"], "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"result\":{}}")
                }
                XCTAssertFalse(body.contains("want_screenshot"))
                let jpegB64 = Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString()
                return (200, ["mcp-session-id": "sess_poki_1"], "{\"jsonrpc\":\"2.0\",\"id\":\"tsk_2\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"app: Settings\"},{\"type\":\"image\",\"data\":\"\(jpegB64)\",\"mimeType\":\"image/jpeg\"}],\"isError\":false}}")
            }
        )
        let mappedState = await adapter.currentRunnerState()
        XCTAssertEqual(mappedState, "starting")

        let task = ClaimedTaskDTO(
            task_id: "tsk_2",
            tool_name: "look",
            payload: ["full": .bool(false), "want_screenshot": .bool(false)],
            observation_id: nil,
            lease_token: "lease_2",
            lease_expires_at: 9999999999999,
            expires_at: 9999999999999
        )
        let reply = await adapter.execute(task: task)
        XCTAssertEqual(box.lock.withLock { box.seenMethods }, ["initialize", "tools/call"])
        XCTAssertEqual(box.lock.withLock { box.seenSessionHeaders }, [nil, "sess_poki_1"])
        XCTAssertNil(reply.screenshotJPEG)
    }
}
