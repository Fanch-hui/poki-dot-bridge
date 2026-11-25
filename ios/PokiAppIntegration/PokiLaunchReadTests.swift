import Foundation
import CoreGraphics
import XCTest
@testable import PokiCore

final class PokiLaunchReadTests: XCTestCase {
    private let app = "com.example.store"

    func testReadyScreenUsesFirstPairedReadWithoutSettling() async {
        let wda = FakeWDA()
        let reads = LockedBox(0)
        let ready = page("Button", "Shop home")
        let readyPNG = Data("store-ready".utf8)
        wda.set("POST /wda/apps/activate") { [wda] _ in
            wda.set("GET /source") { _ in reads.update { $0 += 1 }; return (200, ["value": ready]) }
            wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "com.example.store", "name": "Store"]]) }
            wda.set("GET /screenshot") { _ in (200, ["value": .string(readyPNG.base64EncodedString())]) }
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["launch": .string(app)]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Button \"Shop home\""), result.text)
        XCTAssertFalse(result.text.contains("paused "), result.text)
        XCTAssertEqual(reads.value, 1, result.text)
        XCTAssertEqual(result.jpeg, Data("jpeg:\(readyPNG.count)".utf8))
        XCTAssertEqual(wda.bodies("POST /wda/apps/activate").count, 1)
    }

    func testOldAppIsRereadUntilTargetAndScreenshotAreCurrent() async {
        let wda = FakeWDA()
        let readyAt = LockedBox(0.0)
        let old = page("Button", "Old app")
        let ready = page("Button", "Store home")
        let readyPNG = Data("store-ready-now".utf8)
        wda.set("POST /wda/apps/activate") { [wda] _ in
            readyAt.value = Date.timeIntervalSinceReferenceDate + 0.45
            wda.set("GET /source") { _ in
                (200, ["value": Date.timeIntervalSinceReferenceDate >= readyAt.value ? ready : old])
            }
            wda.set("GET /wda/activeAppInfo") { _ in
                let app = Date.timeIntervalSinceReferenceDate >= readyAt.value ? "com.example.store" : "com.example.old"
                return (200, ["value": ["bundleId": .string(app), "name": "App"]])
            }
            wda.set("GET /screenshot") { _ in
                let picture = Date.timeIntervalSinceReferenceDate >= readyAt.value ? readyPNG : Data("old".utf8)
                return (200, ["value": .string(picture.base64EncodedString())])
            }
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["launch": .string(app)]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Button \"Store home\""), result.text)
        XCTAssertFalse(result.text.contains("Button \"Old app\""), result.text)
        XCTAssertEqual(result.jpeg, Data("jpeg:\(readyPNG.count)".utf8))
        XCTAssertEqual(wda.bodies("POST /wda/apps/activate").count, 1)
    }

    func testWrongForegroundDoesNotReturnOldControlsAsLaunchSuccess() async {
        let wda = FakeWDA()
        wda.tree([Node("Button", "Old screen", [20, 100, 150, 44])])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["launch": .string(app)]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("launch sent for com.example.store"), result.text)
        XCTAssertTrue(result.text.contains("current screen is not yet confirmed"), result.text)
        XCTAssertFalse(result.text.contains("Button \"Old screen\""), result.text)
        XCTAssertTrue(core.computer.refs.isEmpty)
        XCTAssertEqual(wda.bodies("POST /wda/apps/activate").count, 1)
    }

    func testLoadingShellWaitsForContentAndReturnsFreshPicture() async {
        let wda = FakeWDA()
        let reads = LockedBox(0)
        let ready = LockedBox(false)
        let shell = page("Toolbar", "工具栏", frame: [0, 0, 390, 844])
        let content = page("Button", "Ready to shop")
        let readyPNG = Data("loaded-store".utf8)
        wda.set("POST /wda/apps/activate") { [wda] _ in
            wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "com.example.store"]]) }
            wda.set("GET /source") { _ in
                let count = reads.update { $0 += 1; return $0 }
                if count > 1 { ready.value = true }
                return (200, ["value": count > 1 ? content : shell])
            }
            wda.set("GET /screenshot") { _ in
                (200, ["value": .string((ready.value ? readyPNG : Data("shell".utf8)).base64EncodedString())])
            }
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["launch": .string(app)]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Ready to shop"), result.text)
        XCTAssertEqual(result.jpeg, Data("jpeg:\(readyPNG.count)".utf8))
        XCTAssertGreaterThanOrEqual(reads.value, 3)
    }

    func testUnchangedLoadingShellReturnsWithoutRepeatedLoadingNotes() async {
        let wda = FakeWDA()
        let shell = page("Toolbar", "工具栏", frame: [0, 0, 390, 844])
        wda.set("POST /wda/apps/activate") { [wda] _ in
            wda.set("GET /source") { _ in (200, ["value": shell]) }
            wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "com.example.store"]]) }
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["launch": .string(app)]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertEqual(result.text.components(separatedBy: "the page is still loading").count, 2, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/apps/activate").count, 1)
    }

    func testNewTreeWithOldPictureIsNotAcceptedAsTheTargetScreen() async {
        let wda = FakeWDA()
        let captures = LockedBox(0)
        let ready = page("Button", "Store home")
        let readyPNG = Data("the store picture".utf8)
        wda.set("POST /wda/apps/activate") { [wda] _ in
            wda.set("GET /source") { _ in (200, ["value": ready]) }
            wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "com.example.store"]]) }
            wda.set("GET /screenshot") { _ in
                let count = captures.update { $0 += 1; return $0 }
                return (200, ["value": .string((count == 1 ? Data("png".utf8) : readyPNG).base64EncodedString())])
            }
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["launch": .string(app)]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Store home"), result.text)
        XCTAssertEqual(result.jpeg, Data("jpeg:\(readyPNG.count)".utf8))
        XCTAssertGreaterThanOrEqual(captures.value, 2)
    }

    func testStatusBarAloneDoesNotCountAsUsableAppContent() async {
        let wda = FakeWDA()
        let status = page("StaticText", "9:41", frame: [20, 10, 45, 30])
        wda.set("POST /wda/apps/activate") { [wda] _ in
            wda.set("GET /source") { _ in (200, ["value": status]) }
            wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "com.example.store"]]) }
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["launch": .string(app)]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("current screen is not yet confirmed"), result.text)
        XCTAssertTrue(core.computer.refs.isEmpty)
    }

    func testSystemAlertReturnsImmediatelyAndCanBeAnswered() async {
        let wda = FakeWDA()
        let reads = LockedBox(0)
        let buttons: [JSON] = (0..<12).map { index in
            let x = Double(40 + (index % 2) * 160)
            let y = Double(200 + (index / 2) * 65)
            let label = index == 0 ? "Allow" : "Choice \(index)"
            let frame: JSON = ["x": .number(x), "y": .number(y), "width": 100, "height": 30]
            return ["type": "XCUIElementTypeButton", "label": .string(label), "rect": frame]
        }
        let alert: JSON = ["type": "XCUIElementTypeApplication", "children": [[
            "type": "XCUIElementTypeAlert", "label": "Permission",
            "rect": ["x": 30, "y": 180, "width": 330, "height": 400],
            "children": .array(buttons),
        ]]]
        let alertPNG = PictureSketchTests.png { _ in }
        wda.set("POST /wda/apps/activate") { [wda] _ in
            wda.set("GET /source") { _ in reads.update { $0 += 1 }; return (200, ["value": alert]) }
            wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "com.apple.springboard"]]) }
            wda.set("GET /screenshot") { _ in (200, ["value": .string(alertPNG.base64EncodedString())]) }
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["launch": .string(app)]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Allow"), result.text)
        XCTAssertTrue(result.text.contains("system alert is in front after launch"), result.text)
        XCTAssertEqual(reads.value, 1, result.text)
        XCTAssertFalse(core.computer.refs.isEmpty)
    }

    func testMissingScreenshotCannotReturnAppControlsAsConfirmed() async {
        let wda = FakeWDA()
        let ready = page("Button", "Store home")
        wda.set("POST /wda/apps/activate") { [wda] _ in
            wda.set("GET /source") { _ in (200, ["value": ready]) }
            wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "com.example.store"]]) }
            wda.set("GET /screenshot") { _ in (500, ["value": ["error": "no screenshot"]]) }
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["launch": .string(app)]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("current screen is not yet confirmed"), result.text)
        XCTAssertFalse(result.text.contains("Button \"Store home\""), result.text)
        XCTAssertTrue(core.computer.refs.isEmpty)
    }

    func testMissingAccessibilityServerDoesNotTerminateOrRelaunch() async {
        let wda = FakeWDA()
        wda.set("POST /wda/apps/activate") { [wda] _ in
            wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "com.example.store"]]) }
            wda.set("GET /source") { _ in
                (500, ["value": ["error": "unknown error", "message": "Error getting main window kAXErrorServerNotFound"]])
            }
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true; $0.toolDeadline = 12 }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["launch": .string(app)]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("launch sent for com.example.store"), result.text)
        XCTAssertTrue(result.text.contains("kAXErrorServerNotFound"), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/apps/activate").count, 1)
        XCTAssertTrue(wda.bodies("POST /wda/apps/terminate").isEmpty)
        XCTAssertTrue(wda.bodies("POST /wda/apps/launch").isEmpty)
    }

    func testLaunchWaitsForTheVisibleScreenWhenTheTreeAlreadyHasHomeControls() async {
        let wda = FakeWDA()
        let captures = LockedBox(0)
        let activation = LockedBox(0.0)
        let splash = PictureSketchTests.png { _ in }
        let home = stripedHome()
        let controls = manyLabels()
        wda.set("POST /wda/apps/activate") { [wda] _ in
            activation.value = Date.timeIntervalSinceReferenceDate
            wda.tree(controls, app: "Store")
            wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "com.example.store"]]) }
            wda.set("GET /screenshot") { _ in
                captures.update { $0 += 1 }
                let ready = Date.timeIntervalSinceReferenceDate - activation.value >= 0.5
                return (200, ["value": .string((ready ? home : splash).base64EncodedString())])
            }
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["launch": .string(app)]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Entry 1"), result.text)
        XCTAssertEqual(result.jpeg, Data("jpeg:\(home.count)".utf8))
        XCTAssertGreaterThanOrEqual(captures.value, 2)
        XCTAssertEqual(wda.bodies("POST /wda/apps/activate").count, 1)
    }

    func testUnchangedSplashDoesNotExposeTheHomeReferences() async {
        let wda = FakeWDA()
        let splash = PictureSketchTests.png { _ in }
        let controls = manyLabels()
        wda.set("POST /wda/apps/activate") { [wda] _ in
            wda.tree(controls, app: "Store")
            wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "com.example.store"]]) }
            wda.set("GET /screenshot") { _ in (200, ["value": .string(splash.base64EncodedString())]) }
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["launch": .string(app)]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("screenshot may not yet match the app controls"), result.text)
        XCTAssertTrue(result.text.contains("launch sent"), result.text)
        XCTAssertFalse(result.text.contains("Entry 1"), result.text)
        XCTAssertTrue(core.computer.refs.isEmpty)
        XCTAssertEqual(wda.bodies("POST /wda/apps/activate").count, 1)
    }

    func testReadyScreenWithManyLabelsKeepsTheFirstRead() async {
        let wda = FakeWDA()
        let reads = LockedBox(0)
        let home = stripedHome()
        let controls = manyLabels()
        wda.set("POST /wda/apps/activate") { [wda] _ in
            wda.tree(controls, app: "Store")
            wda.set("GET /source") { _ in
                reads.update { $0 += 1 }
                return (200, ["value": Self.labelTree()])
            }
            wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "com.example.store"]]) }
            wda.set("GET /screenshot") { _ in (200, ["value": .string(home.base64EncodedString())]) }
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["launch": .string(app)]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Entry 1"), result.text)
        XCTAssertEqual(reads.value, 1)
        XCTAssertEqual(result.jpeg, Data("jpeg:\(home.count)".utf8))
    }

    func testLowContrastScreenWithManyLabelsKeepsTheFirstRead() async {
        let wda = FakeWDA()
        let reads = LockedBox(0)
        let home = PictureSketchTests.png { context in
            context.setFillColor(CGColor(gray: 0.92, alpha: 1))
            for y in stride(from: 0, to: 874, by: 8) {
                context.fill(CGRect(x: 0, y: y, width: 402, height: 4))
            }
        }
        wda.set("POST /wda/apps/activate") { [wda] _ in
            wda.set("GET /source") { _ in reads.update { $0 += 1 }; return (200, ["value": Self.labelTree()]) }
            wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "com.example.store"]]) }
            wda.set("GET /screenshot") { _ in (200, ["value": .string(home.base64EncodedString())]) }
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["launch": .string(app)]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(reads.value, 1)
    }

    func testOverlappingControlsDoNotCountAsIndependentImageEvidence() {
        var reading = Reading()
        reading.png = PictureSketchTests.png { _ in }
        reading.elements = (0..<12).map { index in
            Element(type: "StaticText", label: "Entry \(index)", value: nil, identifier: nil,
                    frame: Rect(x: 20, y: 100, width: 130, height: 30), depth: 0)
        }
        XCTAssertFalse(PokiLaunchImageEvidence.hasMissingLabels(reading, screen: ScreenSize(width: 390, height: 844)))
    }

    func testMissingOrInvalidImageDoesNotProduceVisualEvidence() {
        var reading = Reading()
        reading.elements = manyLabels().map { node in
            Element(type: node.type, label: node.label, value: nil, identifier: nil,
                    frame: Rect(x: node.frame[0], y: node.frame[1], width: node.frame[2], height: node.frame[3]), depth: 0)
        }
        let screen = ScreenSize(width: 390, height: 844)
        XCTAssertFalse(PokiLaunchImageEvidence.hasMissingLabels(reading, screen: screen))
        reading.png = Data("not an image".utf8)
        XCTAssertFalse(PokiLaunchImageEvidence.hasMissingLabels(reading, screen: screen))
    }

    func testTapWaitsForThePairedResultWhenPictureStillShowsASkeleton() async {
        let wda = FakeWDA()
        let captures = LockedBox(0)
        let skeleton = PictureSketchTests.png { _ in }
        let ready = stripedHome()
        let controls = manyLabels()
        wda.tree([Node("StaticText", "Popular search", [20, 100, 160, 44])])
        wda.set("POST /wda/tap") { [wda] _ in
            wda.tree(controls)
            wda.set("GET /screenshot") { _ in
                let count = captures.update { $0 += 1; return $0 }
                return (200, ["value": .string((count > 1 ? ready : skeleton).base64EncodedString())])
            }
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true; $0.toolDeadline = 15 }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["tap": 1]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Entry 1"), result.text)
        XCTAssertTrue(result.text.contains("did: tap"), result.text)
        XCTAssertEqual(result.jpeg, Data("jpeg:\(ready.count)".utf8))
        XCTAssertGreaterThanOrEqual(captures.value, 2)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
    }

    func testPersistentPostTapSkeletonDoesNotExposeResultReferences() async {
        let wda = FakeWDA()
        let skeleton = PictureSketchTests.png { _ in }
        let controls = manyLabels()
        wda.tree([Node("StaticText", "Popular search", [20, 100, 160, 44])])
        wda.set("POST /wda/tap") { [wda] _ in
            wda.tree(controls)
            wda.set("GET /screenshot") { _ in (200, ["value": .string(skeleton.base64EncodedString())]) }
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true; $0.toolDeadline = 10 }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["tap": 1]]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("the action was sent"), result.text)
        XCTAssertTrue(result.text.contains("did: tap"), result.text)
        XCTAssertFalse(result.text.contains("Entry 1"), result.text)
        XCTAssertTrue(core.computer.refs.isEmpty)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
    }

    func testChangedOptionSummaryConfirmsThePairedResultWithoutRepeatingTheTap() async {
        for screenshotIsOld in [false, true] {
            let wda = FakeWDA()
            let before = PictureSketchTests.png { _ in }
            let after = screenshotIsOld ? before : PictureSketchTests.png { $0.fill(CGRect(x: 0, y: 0, width: 4, height: 4)) }
            let oldText = "已选规格：中、不换料、温、默认糖、不另外加糖（推荐）"
            let newText = "已选规格：中、不换料、正常冰、默认糖、不另外加糖（推荐）"
            let host = TransitionEvidenceHost(before: before, after: after,
                                              beforeTexts: [summaryOCR("已选规格：中、不换料、温、默认糖")],
                                              afterTexts: [summaryOCR("已选规格：中、不换料、正常冰、默认糖")])
            let button = Node("Button", "Default option", [20, 60, 150, 30])
            let old = manyLabels() + [Node("StaticText", oldText, [20, 700, 280, 35])]
            let current = manyLabels() + [Node("StaticText", newText, [20, 700, 280, 35])]
            wda.tree([button] + old)
            wda.set("GET /screenshot") { _ in (200, ["value": .string(before.base64EncodedString())]) }
            wda.set("POST /wda/tap") { [wda] _ in
                wda.tree([button] + current)
                wda.set("GET /screenshot") { _ in (200, ["value": .string(after.base64EncodedString())]) }
                return (200, ["value": .null])
            }
            var config = CoreConfig(approvalWait: 0.3, toolDeadline: 10, actionCap: 3, readTimeout: 1,
                                    busyWait: 0.2, treeFormat: "json", humanize: false)
            config.standaloneObservations = true
            let core = PokiCore(config: config, host: host, transport: wda)
            _ = await core.call("look", [:])

            let result = await core.call("do", ["actions": [["tap": 1]]])

            XCTAssertEqual(result.isError, screenshotIsOld, result.text)
            XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1, result.text)
            if screenshotIsOld {
                XCTAssertTrue(result.text.contains("the action was sent"), result.text)
                XCTAssertTrue(core.computer.refs.isEmpty)
            } else {
                XCTAssertTrue(result.text.contains(newText), result.text)
                XCTAssertEqual(host.recognitions.value, 2)
            }
        }
    }

    func testChangedLabelNeedsDistinctTextAtTheMatchingPositionInBothImages() {
        let screen = ScreenSize(width: 390, height: 844)
        let frame = Rect(x: 20, y: 700, width: 280, height: 35)
        let old = "已选规格：中、不换料、温、默认糖、不另外加糖（推荐）"
        let new = "已选规格：中、不换料、正常冰、默认糖、不另外加糖（推荐）"
        let before = Element(type: "StaticText", label: old, value: nil, identifier: nil, frame: frame, depth: 0)
        let after = Element(type: "StaticText", label: new, value: nil, identifier: nil, frame: frame, depth: 0)
        let labels = PokiLaunchImageEvidence.changedLabels(before: [before], after: [after], screen: screen)
        XCTAssertEqual(labels.count, 1)
        XCTAssertTrue(PokiLaunchImageEvidence.confirmsChangedLabel(labels, before: [summaryOCR(old)], after: [summaryOCR(new)], screen: screen))
        XCTAssertFalse(PokiLaunchImageEvidence.confirmsChangedLabel(labels, before: [], after: [summaryOCR(new)], screen: screen))
        XCTAssertFalse(PokiLaunchImageEvidence.confirmsChangedLabel(labels, before: [summaryOCR(old)], after: [summaryOCR(old)], screen: screen))
        XCTAssertFalse(PokiLaunchImageEvidence.confirmsChangedLabel(labels, before: [summaryOCR(old)], after: [summaryOCR("已选规格：中、不换料")], screen: screen))
        var elsewhere = summaryOCR(new)
        elsewhere.box.y = 100 / 844
        XCTAssertFalse(PokiLaunchImageEvidence.confirmsChangedLabel(labels, before: [summaryOCR(old)], after: [elsewhere], screen: screen))
        XCTAssertTrue(PokiLaunchImageEvidence.changedLabels(before: [before, before], after: [after], screen: screen).isEmpty)
        XCTAssertTrue(PokiLaunchImageEvidence.changedLabels(before: [before], after: [after, after], screen: screen).isEmpty)
    }

    func testChangedLabelDoesNotConfirmAnotherForegroundApp() async {
        let beforePNG = PictureSketchTests.png { _ in }
        let afterPNG = PictureSketchTests.png { $0.fill(CGRect(x: 0, y: 0, width: 4, height: 4)) }
        let old = "Selected option: medium, warm, no sugar"
        let new = "Selected option: medium, cold, no sugar"
        let frame = Rect(x: 20, y: 700, width: 280, height: 35)
        let previous = Element(type: "StaticText", label: old, value: nil, identifier: nil, frame: frame, depth: 0)
        let changed = Element(type: "StaticText", label: new, value: nil, identifier: nil, frame: frame, depth: 0)
        let host = TransitionEvidenceHost(before: beforePNG, after: afterPNG,
                                          beforeTexts: [summaryOCR(old)], afterTexts: [summaryOCR(new)])
        let core = PokiCore(config: CoreConfig(), host: host, transport: FakeWDA())
        core.computer.lastPNG = beforePNG
        core.computer.lastAll = [previous]
        core.computer.lastForeground = Foreground(bundleID: app, name: "Store")
        var reading = Reading()
        reading.foreground = Foreground(bundleID: "com.example.other", name: "Other")
        reading.elements = manyLabels().map { node in
            Element(type: node.type, label: node.label, value: nil, identifier: nil,
                    frame: Rect(x: node.frame[0], y: node.frame[1], width: node.frame[2], height: node.frame[3]), depth: 0)
        } + [changed]
        reading.png = afterPNG

        let result = await core.computer.confirmTransitionRead(reading, screen: ScreenSize(width: 390, height: 844),
                                                               app: app, previousTree: "old", until: now() + 0.6)

        XCTAssertFalse(result.1)
        XCTAssertEqual(host.recognitions.value, 0)
    }

    private func summaryOCR(_ text: String) -> RecognizedText {
        RecognizedText(text: text, box: Rect(x: 20 / 390, y: 700 / 844, width: 220 / 390, height: 20 / 844))
    }

    func testSearchReturnWaitsForThePairedResult() async {
        await assertSearchResultScreenshot(actions: [["type": "tea", "ref": 1], ["key": "return"]])
    }

    func testSearchSubmitWaitsForThePairedResult() async {
        await assertSearchResultScreenshot(actions: [["search_submit": [
            "text": "tea", "ref": 1, "result_texts": ["Entry 1"],
        ]]])
    }

    private func assertSearchResultScreenshot(actions: [JSON]) async {
        let wda = FakeWDA()
        let captures = LockedBox(0)
        let skeleton = PictureSketchTests.png { _ in }
        let ready = stripedHome()
        let controls = manyLabels()
        wda.tree([Node("SearchField", "Search", [20, 100, 160, 44])])
        wda.set("POST /wda/keys") { [wda] body in
            let keys = body?["value"]?.array?.compactMap(\.string) ?? []
            if keys.contains("\n") {
                wda.tree(controls)
                wda.set("GET /screenshot") { _ in
                    let count = captures.update { $0 += 1; return $0 }
                    return (200, ["value": .string((count > 1 ? ready : skeleton).base64EncodedString())])
                }
            }
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true; $0.toolDeadline = 15 }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": .array(actions)])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Entry 1"), result.text)
        XCTAssertEqual(result.jpeg, Data("jpeg:\(ready.count)".utf8))
        let keyCalls = wda.bodies("POST /wda/keys")
        XCTAssertEqual(keyCalls.filter { $0["value"]?.array?.contains(.string("\n")) == true }.count, 1)
        XCTAssertGreaterThanOrEqual(captures.value, 2)
    }

    func testSystemDialogAfterTapDoesNotWaitForTheCoveredPage() async {
        let wda = FakeWDA()
        let reads = LockedBox(0)
        let skeleton = PictureSketchTests.png { _ in }
        let controls = manyLabels()
        wda.tree([Node("StaticText", "Popular search", [20, 100, 160, 44])])
        wda.set("POST /wda/tap") { [wda] _ in
            wda.tree(controls + [
                Node("Alert", "Permission", [30, 200, 330, 300],
                     [Node("Button", "Allow", [50, 300, 120, 44])]),
            ])
            wda.set("GET /source") { _ in
                reads.update { $0 += 1 }
                let children: [JSON] = [
                    ["type": "XCUIElementTypeAlert", "label": "Permission",
                     "rect": ["x": 30, "y": 200, "width": 330, "height": 300],
                     "children": [["type": "XCUIElementTypeButton", "label": "Allow",
                                   "rect": ["x": 50, "y": 300, "width": 120, "height": 44]]]],
                ]
                var result = Self.labelTree().object!
                result["children"] = .array(Self.labelTree()["children"]!.array! + children)
                return (200, ["value": .object(result)])
            }
            wda.set("GET /screenshot") { _ in (200, ["value": .string(skeleton.base64EncodedString())]) }
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["tap": 1]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Permission"), result.text)
        XCTAssertEqual(reads.value, 1)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
    }

    private func manyLabels() -> [Node] {
        (0..<12).map { index in
            let x = Double(20 + (index % 2) * 170)
            let y = Double(100 + (index / 2) * 90)
            return Node("StaticText", "Entry \(index + 1)", [x, y, 130, 30])
        }
    }

    private static func labelTree() -> JSON {
        let children: [JSON] = (0..<12).map { index in
            let x = Double(20 + (index % 2) * 170)
            let y = Double(100 + (index / 2) * 90)
            let frame: JSON = ["x": .number(x), "y": .number(y), "width": 130, "height": 30]
            return ["type": "XCUIElementTypeStaticText", "label": .string("Entry \(index + 1)"), "rect": frame]
        }
        return ["type": "XCUIElementTypeApplication", "children": .array(children)]
    }

    private func stripedHome() -> Data {
        PictureSketchTests.png { context in
            for y in stride(from: 0, to: 874, by: 8) {
                context.fill(CGRect(x: 0, y: y, width: 402, height: 4))
            }
        }
    }

    private func page(_ type: String, _ label: String, frame: [Double] = [20, 100, 150, 44]) -> JSON {
        ["type": "XCUIElementTypeApplication", "children": [[
            "type": .string("XCUIElementType\(type)"), "label": .string(label),
            "rect": ["x": .number(frame[0]), "y": .number(frame[1]),
                     "width": .number(frame[2]), "height": .number(frame[3])],
        ]]]
    }
}

private final class TransitionEvidenceHost: CoreHost, @unchecked Sendable {
    let before: Data
    let after: Data
    let beforeTexts: [RecognizedText]
    let afterTexts: [RecognizedText]
    let recognitions = LockedBox(0)

    init(before: Data, after: Data, beforeTexts: [RecognizedText], afterTexts: [RecognizedText]) {
        self.before = before
        self.after = after
        self.beforeTexts = beforeTexts
        self.afterTexts = afterTexts
    }

    func recognizeText(inPNG png: Data) async -> [RecognizedText]? {
        recognitions.update { $0 += 1 }
        if png == before { return beforeTexts }
        if png == after { return afterTexts }
        return nil
    }

    func signingKey() throws -> RelayKey { FakeKey() }
    func accessHashes() -> [String] { ["abc123"] }
    func jpeg(fromPNG png: Data, width: Int, quality: Double) throws -> Data { Data("jpeg:\(png.count)".utf8) }
    func runnerState() -> RunnerState { .running }
    func restartRunner() {}
}
