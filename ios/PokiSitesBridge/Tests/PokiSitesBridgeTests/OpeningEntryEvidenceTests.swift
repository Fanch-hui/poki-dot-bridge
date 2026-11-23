import XCTest
@testable import PokiSitesBridge

final class OpeningEntryEvidenceTests: XCTestCase {
    private let screenshot = Data("same observation image".utf8)

    private func task(_ labels: [String], actions: [JSONValue]? = nil, tool: String = "do") -> ClaimedTaskDTO {
        ClaimedTaskDTO(
            task_id: "task", tool_name: tool,
            payload: [
                "actions": .array(actions ?? [.object(["launch": .string("com.example.app")])]),
                "opening_labels": .array(labels.map(JSONValue.string)),
            ],
            observation_id: nil, lease_token: "lease", lease_expires_at: 100, expires_at: 200
        )
    }

    private func parsed(_ controls: String, screenshot: Data? = Data("same observation image".utf8)) -> ParsedPokiExecution {
        PokiOutputParser.parse(
            toolName: "do",
            text: """
            app: Shop
            viewport: 420x912 points
            \(controls)
            """,
            isError: false, screenshotJPEG: screenshot
        )
    }

    func testExistingPictureTextConfirmsUniqueNativeEntry() {
        let input = parsed("""
            1 Button "外卖" [20,80,90,70]
            2 Text "外卖" [40,110,40,20] (read from the picture)
            3 Button "支付再减" [200,200,100,40] [covered]
            """)
        let result = OpeningEntryEvidence.applying(to: input, task: task(["外卖", "秒送"]))
        XCTAssertEqual(result.elements[0].flags, ["opening_label_visible"])
        XCTAssertEqual(result.elements[1].from_picture, true)
        XCTAssertEqual(result.screenshot_base64, screenshot.base64EncodedString())
    }

    func testMissingMisplacedAndDuplicatePictureTextDoNotConfirm() {
        for texts in [
            "",
            "2 Text \"秒送\" [40,110,40,20] (read from the picture)",
            "2 Text \"外卖\" [200,200,40,20] (read from the picture)",
            "2 Text \"外卖\" [40,110,40,20] (read from the picture)\n3 Text \"外卖\" [200,200,40,20] (read from the picture)",
            "2 Text \"外卖\" [95,110,40,20] (read from the picture)",
        ] {
            let input = parsed("1 Button \"外卖\" [20,80,90,70]\n\(texts)")
            XCTAssertEqual(OpeningEntryEvidence.applying(to: input, task: task(["外卖"])), input.observation)
        }
    }

    func testCoveredDuplicateRowAndCompetingControlsDoNotConfirm() {
        for entry in [
            "1 Button \"外卖\" [20,80,90,70] [covered]",
            "1 Button \"外卖\" [20,80,90,70] [row: Shop]",
            "1 Button \"外卖\" [20,80,90,70]\n3 Cell \"外卖\" [200,80,90,70]",
            "1 Button \"外卖\" [20,80,90,70]\n3 Button \"Other\" [90,120,60,40]",
        ] {
            let input = parsed("\(entry)\n2 Text \"外卖\" [40,110,40,20] (read from the picture)")
            XCTAssertEqual(OpeningEntryEvidence.applying(to: input, task: task(["外卖"])), input.observation)
        }
    }

    func testKnownModalsAndUnreliableScreensDoNotConfirm() {
        let controls = "1 Button \"外卖\" [20,80,90,70]\n2 Text \"外卖\" [40,110,40,20] (read from the picture)"
        for modal in ["3 Alert \"Permission\" [0,0,420,912]", "3 Other \"关闭弹窗\" [0,0,420,912]"] {
            let input = parsed("\(controls)\n\(modal)")
            XCTAssertEqual(OpeningEntryEvidence.applying(to: input, task: task(["外卖"])), input.observation)
        }
        var input = parsed(controls)
        input.observation.notes.append("a popup is covering the current page")
        XCTAssertEqual(OpeningEntryEvidence.applying(to: input, task: task(["外卖"])), input.observation)
        input.observation.notes = []
        input.observation.screen_locked = true
        XCTAssertEqual(OpeningEntryEvidence.applying(to: input, task: task(["外卖"])), input.observation)
    }

    func testOnlySingleSuccessfulLaunchWithCurrentScreenshotIsEligible() {
        let controls = "1 Button \"外卖\" [20,80,90,70]\n2 Text \"外卖\" [40,110,40,20] (read from the picture)"
        let input = parsed(controls)
        let missing = parsed(controls, screenshot: nil)
        XCTAssertEqual(OpeningEntryEvidence.applying(to: missing, task: task(["外卖"])), missing.observation)
        XCTAssertEqual(OpeningEntryEvidence.applying(to: input, task: task(["搜索"])), input.observation)
        XCTAssertEqual(OpeningEntryEvidence.applying(to: input, task: task(["外卖"], tool: "look")), input.observation)
        let compound = task(["外卖"], actions: [.object(["launch": .string("com.example.app")]), .object(["tap": .number(1)])])
        XCTAssertEqual(OpeningEntryEvidence.applying(to: input, task: compound), input.observation)
        var failed = input
        failed.status = "failed"
        XCTAssertEqual(OpeningEntryEvidence.applying(to: failed, task: task(["外卖"])), failed.observation)
        for note in ["elements (only the changed are listed)", "… 5 more not listed"] {
            var partial = input
            partial.observation.raw_text += "\n\(note)"
            XCTAssertEqual(OpeningEntryEvidence.applying(to: partial, task: task(["外卖"])), partial.observation)
        }
    }
}
