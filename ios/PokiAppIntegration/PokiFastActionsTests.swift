import XCTest
@testable import PokiCore

final class PokiFastActionsTests: XCTestCase {
    private let bundle = "com.example.shop"

    private func install(_ wda: FakeWDA, initial: [Node], destination: [Node]? = nil) {
        wda.tree(initial, app: "Shop")
        wda.set("GET /wda/activeAppInfo") { _ in
            (200, ["value": ["bundleId": "com.example.shop", "name": "Shop"]])
        }
        if let destination {
            wda.set("POST /wda/tap") { [wda] _ in
                wda.tree(destination, app: "Shop")
                return (200, ["value": .null])
            }
        }
    }

    private func installPageTransition(_ wda: FakeWDA, initial: [Node], next: [Node]) -> LockedBox<Int> {
        let first = FakeWDA()
        let second = FakeWDA()
        first.tree(initial, app: "Shop")
        second.tree(next, app: "Shop")
        install(wda, initial: [], destination: [Node("StaticText", "Categories", [16, 160, 200, 44])])
        let reads = LockedBox(0)
        wda.set("GET /source") { _ in
            reads.update { $0 += 1 }
            let source = reads.value == 1 ? first : second
            let reply = try await source.send(method: "GET", url: URL(string: "http://127.0.0.1/source")!, body: nil, timeout: 1)
            return (reply.status, try JSON.parse(reply.body))
        }
        return reads
    }

    private func navigate(_ label: String = "Explore", ready: String = "Search catalog", fresh: Bool = false) -> JSON {
        ["path": ["goal": "Open destination", "steps": [["navigate": [
            "app": .string(bundle), "destination": ["label": .string(label), "type": "Button", "ready_text": .string(ready)],
            "fresh": .bool(fresh),
        ]]]]]
    }

    private func visual(_ text: String, x: Double, y: Double) -> RecognizedText {
        RecognizedText(text: text, box: Rect(x: (x - 10) / 390, y: (y - 5) / 844, width: 20 / 390, height: 10 / 844))
    }

    private func overlappingSearchPage(label: String = "搜索", extra: [Node] = []) -> [Node] {
        let frame: [Double] = [0, 60, 390, 740]
        return [
            Node("Other", nil, frame, [
                Node("StaticText", "Old page", [16, 230, 150, 44]),
                Node("StaticText", "Old item", [16, 280, 150, 44]),
            ] + extra),
            Node("Group", nil, frame, [
                Node("TextField", "搜索框", [16, 98, 270, 38], value: "喜茶"),
                Node("Button", label, [300, 100, 72, 34]),
                Node("StaticText", "Today's entries", [16, 350, 150, 44]),
            ]),
        ]
    }

    func testNavigateOpensAnUnambiguousEntryAndConfirmsDestination() async {
        let wda = FakeWDA()
        install(wda, initial: [Node("Button", "Explore", [16, 100, 150, 44])],
                destination: [Node("StaticText", "Search catalog", [16, 160, 200, 44])])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true; $0.toolDeadline = 12 }
        let result = await core.call("do", ["actions": [navigate()]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("destination \"Search catalog\" visible"), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
        let beforeTap = wda.sent.prefix { $0 != "POST /wda/tap" }
        XCTAssertEqual(beforeTap.filter { $0 == "GET /source" }.count, 2, beforeTap.joined(separator: ", "))
    }

    func testOpensOnlyTheUniqueInteractiveEntryByLabelWithoutALandmark() async {
        let action: JSON = ["path": ["steps": [["navigate": [
            "app": .string(bundle), "destination": ["label": "Explore"],
        ]]]]]
        for count in [1, 2] {
            let wda = FakeWDA()
            var nodes = [Node("StaticText", "Explore", [24, 148, 55, 18])]
            for index in 0..<count {
                nodes.append(Node("Button", "Explore", [Double(16 + 90 * index), 100, 78, 72]))
            }
            install(wda, initial: nodes, destination: [Node("StaticText", "Catalog", [16, 160, 200, 44])])
            let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
            let result = await core.call("do", ["actions": [action]])
            XCTAssertEqual(result.isError, count != 1, result.text)
            XCTAssertEqual(wda.bodies("POST /wda/tap").count, count == 1 ? 1 : 0, result.text)
        }
    }

    func testIconTileCanBeTappedOnItsScreenshotCaption() async {
        let wda = FakeWDA()
        let host = FakeHost()
        var page = overlappingSearchPage(label: "Delivery")
        page[1].children[1].frame = [11, 143, 74, 77]
        install(wda, initial: page, destination: [Node("StaticText", "Categories", [16, 160, 200, 44])])
        host.texts.value = [visual("Delivery", x: 48, y: 210), visual("Old page", x: 90, y: 250)]
        let (core, _, _) = makeCore(wda, host: host) { $0.standaloneObservations = true }
        let result = await core.call("do", ["actions": [navigate("Delivery", ready: "Categories")]])
        XCTAssertFalse(result.isError, result.text)
        let taps = wda.bodies("POST /wda/tap")
        XCTAssertEqual(taps.count, 1)
        XCTAssertEqual(taps.first?["y"]?.double ?? 0, 210, accuracy: 1)
    }

    func testIconTileDoesNotBypassDuplicateScreenshotLabels() async {
        let wda = FakeWDA()
        let host = FakeHost()
        var page = overlappingSearchPage(label: "Delivery")
        page[1].children[1].frame = [11, 143, 74, 77]
        install(wda, initial: page)
        host.texts.value = [visual("Delivery", x: 48, y: 210), visual("Delivery", x: 90, y: 250)]
        let (core, _, _) = makeCore(wda, host: host) { $0.standaloneObservations = true }

        let result = await core.call("do", ["actions": [navigate("Delivery", ready: "Categories")]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("entry label appears more than once"), result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testVerifiedEntryIsTappedBeforeRepeatingOverlappingPageRecognition() async {
        let wda = FakeWDA()
        let host = FakeHost()
        var page = overlappingSearchPage(label: "Delivery")
        page[0].children[1].frame = [16, 350, 150, 44]
        page[1].children[1].frame = [11, 143, 74, 77]
        install(wda, initial: page, destination: [Node("StaticText", "Categories", [16, 160, 200, 44])])
        host.texts.value = [visual("Delivery", x: 48, y: 210), visual("Today's entries", x: 90, y: 370)]
        let screenshots = LockedBox(0)
        wda.set("GET /screenshot") { _ in
            screenshots.update { $0 += 1 }
            if screenshots.value > 1 { host.texts.value = [] }
            return (200, ["value": .string(Data("png".utf8).base64EncodedString())])
        }
        let (core, _, _) = makeCore(wda, host: host) { $0.standaloneObservations = true; $0.toolDeadline = 12 }

        let result = await core.call("do", ["actions": [navigate("Delivery", ready: "Categories")]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1, result.text)
    }

    func testNavigationKeepsItsTargetWhenTheNextReadHasOverlappingPages() async {
        let wda = FakeWDA()
        let host = FakeHost()
        var page = overlappingSearchPage(label: "Delivery")
        page[1].children[1].frame = [11, 143, 74, 77]
        let reads = installPageTransition(wda, initial: [Node("Button", "Delivery", [11, 143, 74, 77])], next: page)
        host.texts.value = [visual("Delivery", x: 48, y: 210)]
        let (core, _, _) = makeCore(wda, host: host) { $0.standaloneObservations = true; $0.toolDeadline = 12 }

        let result = await core.call("do", ["actions": [navigate("Delivery", ready: "Categories")]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("sent; screen-confirmed entry"), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1, result.text)
        XCTAssertGreaterThan(reads.value, 1)
    }

    func testNavigationRefreshesOneFrameWhenEntryLabelsAreTemporarilyDuplicated() async {
        for freshTreeHasOnePage in [false, true] {
            let wda = FakeWDA()
            let host = FakeHost()
            let entry = Node("Button", "Delivery", [11, 143, 74, 77])
            var page = overlappingSearchPage(label: "Delivery")
            page[1].children[1].frame = [11, 143, 74, 77]
            _ = installPageTransition(wda, initial: [entry], next: page)
            let screenshots = LockedBox(0)
            let screenshotsAtTap = LockedBox(0)
            wda.set("GET /screenshot") { _ in
                screenshots.update { $0 += 1 }
                if screenshots.value == 1, freshTreeHasOnePage { wda.tree([entry], app: "Shop") }
                host.texts.value = screenshots.value == 1
                    ? [self.visual("Delivery", x: 48, y: 210), self.visual("Delivery", x: 90, y: 250)]
                    : [self.visual("Delivery", x: 48, y: 210)]
                return (200, ["value": .string(Data("png".utf8).base64EncodedString())])
            }
            wda.set("POST /wda/tap") { [wda] _ in
                screenshotsAtTap.value = screenshots.value
                wda.tree([Node("StaticText", "Categories", [16, 160, 200, 44])], app: "Shop")
                return (200, ["value": .null])
            }
            let (core, _, _) = makeCore(wda, host: host) { $0.standaloneObservations = true; $0.toolDeadline = 12 }

            let result = await core.call("do", ["actions": [navigate("Delivery", ready: "Categories")]])

            XCTAssertFalse(result.isError, result.text)
            XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1, result.text)
            XCTAssertEqual(screenshotsAtTap.value, 2)
        }
    }

    func testNavigationStopsAfterOneFrameWhenDuplicateLabelsPersist() async {
        let wda = FakeWDA()
        let host = FakeHost()
        var page = overlappingSearchPage(label: "Delivery")
        page[1].children[1].frame = [11, 143, 74, 77]
        _ = installPageTransition(wda, initial: [Node("Button", "Delivery", [11, 143, 74, 77])], next: page)
        host.texts.value = [visual("Delivery", x: 48, y: 210), visual("Delivery", x: 90, y: 250)]
        let (core, _, _) = makeCore(wda, host: host) { $0.standaloneObservations = true; $0.toolDeadline = 12 }

        let result = await core.call("do", ["actions": [navigate("Delivery", ready: "Categories")]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("2 matches, 1 within the target"), result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
        XCTAssertEqual(wda.sent.filter { $0 == "GET /screenshot" }.count, 3)
    }

    func testConfirmedPageCanLocateAnEntryWhenOtherVisibleTextRepeatsItsLabel() async {
        let wda = FakeWDA()
        let host = FakeHost()
        let frame: [Double] = [0, 60, 390, 740]
        install(wda, initial: [
            Node("Other", nil, frame, [
                Node("StaticText", "Old page", [16, 230, 150, 44]),
                Node("StaticText", "Old item", [16, 350, 150, 44]),
            ]),
            Node("Group", nil, frame, [
                Node("Button", "Delivery", [11, 143, 74, 77]),
                Node("StaticText", "Fresh choices", [16, 350, 150, 44]),
            ]),
        ], destination: [Node("StaticText", "Categories", [16, 160, 200, 44])])
        host.texts.value = [visual("Delivery", x: 48, y: 210),
                            visual("Fresh choices", x: 90, y: 370),
                            visual("Delivery", x: 275, y: 500),
                            visual("Delivery", x: 325, y: 520)]
        let screenshotsAtTap = LockedBox(0)
        wda.set("POST /wda/tap") { [wda] _ in
            screenshotsAtTap.value = wda.sent.filter { $0 == "GET /screenshot" }.count
            wda.tree([Node("StaticText", "Categories", [16, 160, 200, 44])], app: "Shop")
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda, host: host) { $0.standaloneObservations = true; $0.toolDeadline = 12 }

        let result = await core.call("do", ["actions": [navigate("Delivery", ready: "Categories")]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1, result.text)
        XCTAssertEqual(screenshotsAtTap.value, 1)
    }

    func testConfirmedPageStillRejectsMultipleLabelsInsideTheEntry() async {
        let wda = FakeWDA()
        let host = FakeHost()
        let frame: [Double] = [0, 60, 390, 740]
        install(wda, initial: [
            Node("Other", nil, frame, [
                Node("StaticText", "Old page", [16, 230, 150, 44]),
                Node("StaticText", "Old item", [16, 350, 150, 44]),
            ]),
            Node("Group", nil, frame, [
                Node("Button", "Delivery", [11, 143, 74, 77]),
                Node("StaticText", "Fresh choices", [16, 350, 150, 44]),
            ]),
        ])
        host.texts.value = [visual("Delivery", x: 38, y: 210),
                            visual("Delivery", x: 58, y: 210),
                            visual("Fresh choices", x: 90, y: 370)]
        let (core, _, _) = makeCore(wda, host: host) { $0.standaloneObservations = true; $0.toolDeadline = 12 }

        let result = await core.call("do", ["actions": [navigate("Delivery", ready: "Categories")]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testDuplicateEntryDoesNotPreventRecognizingTheVisibleDestination() async {
        let wda = FakeWDA()
        let host = FakeHost()
        let frame: [Double] = [0, 60, 390, 740]
        install(wda, initial: [
            Node("Other", nil, frame, [
                Node("StaticText", "Old page", [16, 230, 150, 44]),
                Node("StaticText", "Old item", [16, 350, 150, 44]),
            ]),
            Node("Group", nil, frame, [
                Node("Button", "Delivery", [11, 143, 74, 77]),
                Node("StaticText", "Fresh choices", [16, 350, 150, 44]),
                Node("StaticText", "Categories", [16, 450, 150, 44]),
            ]),
        ])
        host.texts.value = [visual("Delivery", x: 38, y: 210),
                            visual("Delivery", x: 58, y: 210),
                            visual("Fresh choices", x: 90, y: 370)]
        let (core, _, _) = makeCore(wda, host: host) { $0.standaloneObservations = true; $0.toolDeadline = 12 }

        let result = await core.call("do", ["actions": [navigate("Delivery", ready: "Categories")]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("already visible"), result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testNavigationRejectsDuplicatesWhenAnotherPageCannotBeRuledOut() async {
        let frames: [([Double], [Double])] = [
            ([0, 60, 390, 740], [0, 60, 390, 740]),
            ([0, 120, 390, 500], [0, 60, 390, 740]),
        ]
        for (frame, otherFrame) in frames {
            let wda = FakeWDA()
            let host = FakeHost()
            install(wda, initial: [
                Node("Other", nil, frame, [
                    Node("StaticText", "Old page", [16, 230, 150, 44]),
                    Node("StaticText", "Old item", [16, 350, 150, 44]),
                ]),
                Node("Group", nil, frame, [
                    Node("Button", "Delivery", [11, 143, 74, 77]),
                    Node("StaticText", "Fresh choices", [16, 350, 150, 44]),
                ]),
                Node("CollectionView", nil, otherFrame, [
                    Node("StaticText", "Loading", [16, 500, 150, 44]),
                ]),
            ])
            host.texts.value = [visual("Delivery", x: 48, y: 210),
                                visual("Fresh choices", x: 90, y: 370),
                                visual("Delivery", x: 275, y: 500)]
            let (core, _, _) = makeCore(wda, host: host) { $0.standaloneObservations = true; $0.toolDeadline = 12 }

            let result = await core.call("do", ["actions": [navigate("Delivery", ready: "Categories")]])

            XCTAssertTrue(result.isError, result.text)
            XCTAssertTrue(result.text.contains("2 matches, 1 within the target"), result.text)
            XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
        }
    }

    func testNavigationDoesNotRefreshDuplicatesWhenTimeBudgetIsShort() async {
        let wda = FakeWDA()
        let host = FakeHost()
        var page = overlappingSearchPage(label: "Delivery")
        page[1].children[1].frame = [11, 143, 74, 77]
        _ = installPageTransition(wda, initial: [Node("Button", "Delivery", [11, 143, 74, 77])], next: page)
        host.texts.value = [visual("Delivery", x: 48, y: 210), visual("Delivery", x: 90, y: 250)]
        let (core, _, _) = makeCore(wda, host: host) {
            $0.standaloneObservations = true; $0.actionCap = 1; $0.toolDeadline = 12
        }

        let result = await core.call("do", ["actions": [navigate("Delivery", ready: "Categories")]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
        XCTAssertEqual(wda.sent.filter { $0 == "GET /screenshot" }.count, 2)
    }

    func testNavigationDoesNotRefreshDuplicatesAcrossANewDialog() async {
        let wda = FakeWDA()
        let host = FakeHost()
        var page = overlappingSearchPage(label: "Delivery")
        page[1].children[1].frame = [11, 143, 74, 77]
        _ = installPageTransition(wda, initial: [Node("Button", "Delivery", [11, 143, 74, 77])], next: page)
        host.texts.value = [visual("Delivery", x: 48, y: 210), visual("Delivery", x: 90, y: 250)]
        let covered = page + [Node("Alert", "Permission", [30, 300, 330, 200])]
        wda.set("GET /screenshot") { [wda] _ in
            wda.tree(covered, app: "Shop")
            return (200, ["value": .string(Data("png".utf8).base64EncodedString())])
        }
        let (core, _, _) = makeCore(wda, host: host) { $0.standaloneObservations = true; $0.toolDeadline = 12 }

        let result = await core.call("do", ["actions": [navigate("Delivery", ready: "Categories")]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("navigation target changed"), result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testNavigationDoesNotRefreshDuplicatesAfterForegroundAppChanges() async {
        let wda = FakeWDA()
        let host = FakeHost()
        var page = overlappingSearchPage(label: "Delivery")
        page[1].children[1].frame = [11, 143, 74, 77]
        _ = installPageTransition(wda, initial: [Node("Button", "Delivery", [11, 143, 74, 77])], next: page)
        host.texts.value = [visual("Delivery", x: 48, y: 210), visual("Delivery", x: 90, y: 250)]
        wda.set("GET /screenshot") { [wda] _ in
            wda.set("GET /wda/activeAppInfo") { _ in
                (200, ["value": ["bundleId": "com.example.other", "name": "Other"]])
            }
            return (200, ["value": .string(Data("png".utf8).base64EncodedString())])
        }
        let (core, _, _) = makeCore(wda, host: host) { $0.standaloneObservations = true; $0.toolDeadline = 12 }

        let result = await core.call("do", ["actions": [navigate("Delivery", ready: "Categories")]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("navigation target changed"), result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testNavigationTransitionStillStopsForPaymentAndNewDialogs() async {
        for label in ["立即支付", "Delivery"] {
            let wda = FakeWDA()
            let host = FakeHost()
            var page = overlappingSearchPage(label: label)
            page[1].children[1].frame = [11, 143, 74, 77]
            _ = installPageTransition(wda, initial: [Node("Button", label, [11, 143, 74, 77])], next: page)
            host.texts.value = [visual(label, x: 48, y: 210)]
            if label == "Delivery" {
                let covered = page + [Node("Alert", "Permission", [30, 300, 330, 200])]
                wda.set("GET /screenshot") { [wda] _ in
                    wda.tree(covered, app: "Shop")
                    return (200, ["value": .string(Data("png".utf8).base64EncodedString())])
                }
            }
            let (core, _, _) = makeCore(wda, host: host) { $0.standaloneObservations = true; $0.toolDeadline = 12 }

            let result = await core.call("do", ["actions": [navigate(label, ready: "Categories")]])

            XCTAssertTrue(result.isError, result.text)
            XCTAssertTrue(result.text.contains(label == "Delivery" ? "target changed" : "owner's approval"), result.text)
            XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
        }
    }

    func testNavigationTransitionDoesNotTapAnEntryOnTheHiddenPage() async {
        let wda = FakeWDA()
        let host = FakeHost()
        let frame: [Double] = [0, 60, 390, 740]
        let page = [
            Node("Group", nil, frame, [
                Node("StaticText", "搜", [300, 100, 72, 34]),
                Node("StaticText", "Visible page", [16, 230, 150, 44]),
                Node("StaticText", "Visible item", [16, 280, 150, 44]),
            ]),
            Node("Other", nil, frame, [
                Node("Button", "搜", [300, 100, 72, 34]),
                Node("StaticText", "Old page", [16, 230, 150, 44]),
                Node("StaticText", "Old item", [16, 280, 150, 44]),
            ]),
        ]
        _ = installPageTransition(wda, initial: [Node("Button", "搜", [300, 100, 72, 34])], next: page)
        host.texts.value = [visual("搜", x: 336, y: 117),
                            visual("Visible page", x: 90, y: 250), visual("Visible item", x: 90, y: 300)]
        let (core, _, _) = makeCore(wda, host: host) {
            $0.standaloneObservations = true; $0.actionCap = 1; $0.toolDeadline = 12
        }

        let result = await core.call("do", ["actions": [navigate("搜", ready: "Categories")]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testScreenshotTextDoesNotProveAnEntryOnAHiddenPage() async {
        let wda = FakeWDA()
        let host = FakeHost()
        let frame: [Double] = [0, 60, 390, 740]
        install(wda, initial: [
            Node("Group", nil, frame, [
                Node("StaticText", "搜", [300, 100, 72, 34]),
                Node("StaticText", "Visible page", [16, 230, 150, 44]),
                Node("StaticText", "Visible item", [16, 280, 150, 44]),
            ]),
            Node("Other", nil, frame, [
                Node("Button", "搜", [300, 100, 72, 34]),
                Node("StaticText", "Old page", [16, 230, 150, 44]),
                Node("StaticText", "Old item", [16, 280, 150, 44]),
            ]),
        ])
        host.texts.value = [visual("搜", x: 336, y: 117),
                            visual("Visible page", x: 90, y: 250), visual("Visible item", x: 90, y: 300)]
        let (core, _, _) = makeCore(wda, host: host) {
            $0.standaloneObservations = true; $0.actionCap = 1; $0.toolDeadline = 12
        }

        let result = await core.call("do", ["actions": [navigate("搜", ready: "Categories")]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testIconCaptionAllowsOnePointOfTextFrameRounding() async {
        let wda = FakeWDA()
        let host = FakeHost()
        var page = overlappingSearchPage(label: "Delivery")
        page[1].children[1].frame = [11, 143, 74, 77]
        install(wda, initial: page, destination: [Node("StaticText", "Categories", [16, 160, 200, 44])])
        host.texts.value = [visual("Delivery", x: 48, y: 215.5)]
        let (core, _, _) = makeCore(wda, host: host) { $0.standaloneObservations = true; $0.toolDeadline = 12 }

        let result = await core.call("do", ["actions": [navigate("Delivery", ready: "Categories")]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1, result.text)
    }

    func testRepeatedPageRecognitionReportsWhyItStopped() async {
        let wda = FakeWDA()
        let host = FakeHost()
        var page = overlappingSearchPage(label: "Delivery")
        page[0].children[1].frame = [16, 350, 150, 44]
        install(wda, initial: page)
        host.texts.value = [visual("搜索框", x: 90, y: 117), visual("Today's entries", x: 90, y: 370)]
        let screenshots = LockedBox(0)
        wda.set("GET /screenshot") { _ in
            screenshots.update { $0 += 1 }
            if screenshots.value > 1 { host.texts.value = [] }
            return (200, ["value": .string(Data("png".utf8).base64EncodedString())])
        }
        let (core, _, _) = makeCore(wda, host: host) { $0.standaloneObservations = true; $0.toolDeadline = 12 }

        let result = await core.call("do", ["actions": [navigate("Delivery", ready: "Categories")]])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("entry label could not be read"), result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testNavigationLaunchesTheRequestedAppBeforeTapping() async {
        let wda = FakeWDA()
        wda.tree([Node("Button", "Old screen", [16, 100, 150, 44])], app: "Other")
        wda.set("GET /wda/activeAppInfo") { _ in
            (200, ["value": ["bundleId": "com.example.other", "name": "Other"]])
        }
        wda.set("POST /wda/apps/activate") { [wda] _ in
            self.install(wda, initial: [Node("Button", "Explore", [16, 100, 150, 44])],
                         destination: [Node("StaticText", "Search catalog", [16, 160, 200, 44])])
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true; $0.toolDeadline = 12 }
        let result = await core.call("do", ["actions": [navigate()]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/apps/activate").count, 1)
        let beforeLaunch = wda.sent.prefix { $0 != "POST /wda/apps/activate" }
        XCTAssertFalse(beforeLaunch.contains("GET /source"), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
        XCTAssertTrue(result.text.contains("launch_timing:"), result.text)
    }

    func testNavigationCanLeavePokiButCannotNavigateInsideIt() async {
        let wda = FakeWDA()
        wda.tree([Node("Button", "Settings", [16, 100, 150, 44])], app: "Poki")
        wda.set("GET /wda/activeAppInfo") { _ in
            (200, ["value": ["bundleId": "nz.zheha.poki", "name": "Poki"]])
        }
        wda.set("POST /wda/apps/activate") { [wda] _ in
            self.install(wda, initial: [Node("Button", "Explore", [16, 100, 150, 44])],
                         destination: [Node("StaticText", "Search catalog", [16, 160, 200, 44])])
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true; $0.toolDeadline = 12 }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [navigate()]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/apps/activate").count, 1)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)

        let inPoki: JSON = ["path": ["steps": [["navigate": [
            "app": "nz.zheha.poki", "destination": ["label": "Settings", "ready_text": "Advanced"],
        ]]]]]
        let rejected = await core.call("do", ["actions": [inPoki]])
        XCTAssertTrue(rejected.isError, rejected.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
    }

    func testAlreadyAtDestinationDoesNotTapAnIdenticallyNamedEntry() async {
        let wda = FakeWDA()
        install(wda, initial: [Node("Button", "Explore", [16, 100, 150, 44]),
                               Node("StaticText", "Search catalog", [16, 160, 200, 44])])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let result = await core.call("do", ["actions": [navigate()]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("already visible"), result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
    }

    func testNavigationDoesNotTreatEntryOrInputEchoAsDestination() async {
        let wda = FakeWDA()
        install(wda, initial: [Node("Button", "Explore", [16, 100, 150, 44]),
                               Node("TextField", "Search catalog", [16, 160, 200, 44])],
                destination: [Node("StaticText", "Search catalog", [16, 160, 200, 44])])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true; $0.toolDeadline = 12 }
        let result = await core.call("do", ["actions": [navigate()]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)

        let invalid = await core.call("do", ["actions": [navigate("Explore", ready: "Explore")]])
        XCTAssertTrue(invalid.isError, invalid.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
    }

    func testNavigationAcceptsANativeSearchFieldAsDestinationLandmark() async {
        let wda = FakeWDA()
        install(wda, initial: [Node("Button", "Explore", [16, 100, 150, 44])],
                destination: [Node("SearchField", "Search catalog", [16, 160, 200, 44])])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true; $0.toolDeadline = 12 }
        let result = await core.call("do", ["actions": [navigate()]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
    }

    func testTravelGridUsesTheSearchFieldLabelRatherThanItsValue() async {
        let wda = FakeWDA()
        wda.tree([
            Node("CollectionView", nil, [0, 60, 390, 280], [
                Node("Cell", nil, [10, 100, 100, 80], [Node("Button", "火车票", [10, 100, 100, 80])]),
                Node("Cell", nil, [120, 100, 100, 80], [Node("Button", "酒店", [120, 100, 100, 80])]),
                Node("Cell", nil, [230, 100, 100, 80], [Node("Button", "景点", [230, 100, 100, 80])]),
            ]),
            Node("SearchField", "搜索行程", [16, 400, 200, 44], value: "搜索车次"),
        ], app: "出行")
        wda.set("GET /wda/activeAppInfo") { _ in
            (200, ["value": ["bundleId": "com.example.travel", "name": "出行"]])
        }
        wda.set("POST /wda/tap") { [wda] _ in
            wda.tree([Node("SearchField", "搜索车次", [16, 160, 200, 44])], app: "出行")
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true; $0.toolDeadline = 12 }
        let action: JSON = ["path": ["goal": "Open train search", "steps": [["navigate": [
            "app": "com.example.travel", "destination": ["label": "火车票", "type": "Button", "ready_text": "搜索车次"],
        ]]]]]
        let result = await core.call("do", ["actions": [action]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1, result.text)
        XCTAssertTrue(result.text.contains("destination \"搜索车次\" visible"), result.text)
    }

    func testNavigationStopsForAnAlertOrAmbiguousEntry() async {
        for nodes in [
            [Node("Button", "Explore", [16, 100, 150, 44]),
             Node("Alert", "Permission", [30, 300, 330, 200], [Node("Button", "Allow", [70, 350, 200, 44])])],
            [Node("Button", "Explore", [16, 100, 150, 44]), Node("Button", "Explore", [16, 180, 150, 44])],
        ] {
            let wda = FakeWDA()
            install(wda, initial: nodes)
            let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true; $0.actionCap = 0.8 }
            let result = await core.call("do", ["actions": [navigate()]])
            XCTAssertTrue(result.isError, result.text)
            XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
        }
    }

    func testNavigationDoesNotAutoSelectOrAddToCart() async {
        for label in ["选规格", "加入购物车", "提交订单"] {
            let wda = FakeWDA()
            install(wda, initial: [Node("Button", label, [16, 100, 150, 44])])
            let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
            let result = await core.call("do", ["actions": [navigate(label)]])
            XCTAssertTrue(result.isError, result.text)
            XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
        }
    }

    func testNavigationIgnoresDestinationOutsideItsScrollViewport() async {
        let wda = FakeWDA()
        install(wda, initial: [Node("Button", "Explore", [16, 100, 150, 44]),
            Node("ScrollView", nil, [0, 200, 390, 200], [
                Node("StaticText", "Search catalog", [16, 450, 200, 40]),
            ])],
            destination: [Node("StaticText", "Search catalog", [16, 160, 200, 44])])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true; $0.toolDeadline = 12 }
        let result = await core.call("do", ["actions": [navigate()]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
    }

    func testNavigationIgnoresADestinationBehindAnOverlay() async {
        let wda = FakeWDA()
        install(wda, initial: [Node("Button", "Explore", [16, 100, 150, 44]),
                               Node("StaticText", "Search catalog", [16, 200, 200, 44]),
                               Node("Button", "Close panel", [0, 190, 250, 70])],
                destination: [Node("StaticText", "Search catalog", [16, 160, 200, 44])])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true; $0.toolDeadline = 12 }
        let result = await core.call("do", ["actions": [navigate()]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
    }

    func testNavigationUsesScreenshotEvidenceToSelectTheVisiblePage() async {
        let wda = FakeWDA()
        let host = FakeHost()
        let frame: [Double] = [0, 60, 390, 740]
        install(wda, initial: [
            Node("Other", nil, frame, [
                Node("Button", "Old page", [16, 100, 150, 44]),
                Node("StaticText", "Other item", [16, 160, 150, 44]),
            ]),
            Node("Group", nil, frame, [
                Node("Button", "Explore", [16, 100, 150, 44]),
                Node("StaticText", "Today's entries", [16, 160, 150, 44]),
            ]),
        ], destination: [Node("StaticText", "Search catalog", [16, 160, 200, 44])])
        host.texts.value = [visual("Explore", x: 90, y: 120), visual("Today's entries", x: 90, y: 180)]
        let (core, _, _) = makeCore(wda, host: host) { $0.standaloneObservations = true; $0.toolDeadline = 12 }
        let result = await core.call("do", ["actions": [navigate()]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
    }

    func testNavigationStopsWhenOverlappingPagesCannotBeConfirmed() async {
        let wda = FakeWDA()
        let host = FakeHost()
        let frame: [Double] = [0, 60, 390, 740]
        install(wda, initial: [
            Node("Other", nil, frame, [
                Node("Button", "Old page", [16, 100, 150, 44]),
                Node("StaticText", "Other item", [16, 160, 150, 44]),
            ]),
            Node("Group", nil, frame, [
                Node("Button", "Explore", [16, 100, 150, 44]),
                Node("StaticText", "Today's entries", [16, 160, 150, 44]),
            ]),
        ])
        host.texts.value = []
        let (core, _, _) = makeCore(wda, host: host) { $0.standaloneObservations = true }
        let result = await core.call("do", ["actions": [navigate()]])
        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("overlapping pages could not be confirmed"), result.text)
        XCTAssertTrue(result.text.contains("entry label could not be read"), result.text)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
    }

    func testNavigationUsesUniqueScreenshotProvenEntryWhenPagesOverlap() async {
        let wda = FakeWDA()
        let host = FakeHost()
        install(wda, initial: overlappingSearchPage(),
                destination: [Node("StaticText", "销量", [16, 160, 200, 44])])
        host.texts.value = [visual("搜索", x: 336, y: 117), visual("Old page", x: 90, y: 250)]
        let (core, _, _) = makeCore(wda, host: host) { $0.standaloneObservations = true; $0.toolDeadline = 12 }
        let result = await core.call("do", ["actions": [navigate("搜索", ready: "销量")]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("destination \"销量\" visible"), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1, result.text)
    }

    func testNavigationRequiresOneMatchingScreenshotLabelInsideEntry() async {
        for texts in [
            [visual("Old page", x: 90, y: 250)],
            [visual("搜索", x: 336, y: 117), visual("搜索", x: 90, y: 250)],
            [visual("搜索", x: 90, y: 250)],
            [visual("搜索", x: 310, y: 110), visual("Old page", x: 90, y: 250)],
        ] {
            let wda = FakeWDA()
            let host = FakeHost()
            install(wda, initial: overlappingSearchPage())
            host.texts.value = texts
            let (core, _, _) = makeCore(wda, host: host) { $0.standaloneObservations = true; $0.toolDeadline = 12 }
            let result = await core.call("do", ["actions": [navigate("搜索", ready: "销量")]])
            XCTAssertTrue(result.isError, result.text)
            XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
        }
    }

    func testScreenshotProvenEntryStillStopsForCompetingControlAndPayment() async {
        for (label, extra) in [
            ("搜索", [Node("Button", "付款", [300, 100, 72, 34])]),
            ("搜索", [Node("Button", "搜索", [20, 450, 72, 34])]),
            ("立即支付", []),
        ] {
            let wda = FakeWDA()
            let host = FakeHost()
            install(wda, initial: overlappingSearchPage(label: label, extra: extra))
            host.texts.value = [visual(label, x: 336, y: 117), visual("Old page", x: 90, y: 250)]
            let (core, _, _) = makeCore(wda, host: host) { $0.standaloneObservations = true; $0.toolDeadline = 12 }
            let result = await core.call("do", ["actions": [navigate(label, ready: "销量")]])
            XCTAssertTrue(result.isError, result.text)
            if label == "立即支付" { XCTAssertTrue(result.text.contains("owner's approval"), result.text) }
            XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
        }
    }

    func testScreenshotProvenEntryIsRecheckedBeforeTouch() async {
        var moved = overlappingSearchPage()
        moved[1].children[1].frame[0] = 270
        let dialog = overlappingSearchPage() + [Node("Alert", "Permission", [30, 300, 330, 200])]
        for changed in [moved, dialog] {
            let wda = FakeWDA()
            let host = FakeHost()
            install(wda, initial: overlappingSearchPage())
            host.texts.value = [visual("搜索", x: 336, y: 117), visual("Old page", x: 90, y: 250)]
            wda.set("GET /screenshot") { [wda] _ in
                wda.tree(changed, app: "Shop")
                return (200, ["value": .string(Data("png".utf8).base64EncodedString())])
            }
            let (core, _, _) = makeCore(wda, host: host) { $0.standaloneObservations = true; $0.toolDeadline = 12 }
            let result = await core.call("do", ["actions": [navigate("搜索", ready: "销量")]])
            XCTAssertTrue(result.isError, result.text)
            XCTAssertTrue(result.text.contains("navigation target changed before its touch"), result.text)
            XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, result.text)
        }
    }

    func testScreenshotProvenEntryDoesNotTrustHiddenDestination() async {
        let wda = FakeWDA()
        let host = FakeHost()
        install(wda, initial: overlappingSearchPage(extra: [Node("StaticText", "销量", [16, 400, 120, 44])]),
                destination: [Node("StaticText", "Other result", [16, 160, 200, 44])])
        host.texts.value = [visual("搜索", x: 336, y: 117), visual("Old page", x: 90, y: 250)]
        let (core, _, _) = makeCore(wda, host: host) { $0.standaloneObservations = true; $0.toolDeadline = 12 }
        let result = await core.call("do", ["actions": [navigate("搜索", ready: "销量")]])
        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("entry was tapped"), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1, result.text)
    }

    func testNavigationReportsTapWhenDestinationDoesNotAppear() async {
        let wda = FakeWDA()
        install(wda, initial: [Node("Button", "Explore", [16, 100, 150, 44])],
                destination: [Node("StaticText", "Other page", [16, 160, 200, 44])])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true; $0.toolDeadline = 12 }
        let result = await core.call("do", ["actions": [navigate()]])
        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("entry was tapped"), result.text)
        XCTAssertTrue(result.text.contains("(sent"), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1)
    }

    func testFreshNavigationPreservesRelaunchBehavior() async {
        let wda = FakeWDA()
        install(wda, initial: [Node("StaticText", "Search catalog", [16, 160, 200, 44])])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true; $0.toolDeadline = 12 }
        let result = await core.call("do", ["actions": [navigate(fresh: true)]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(wda.bodies("POST /wda/apps/terminate").count, 1)
        XCTAssertEqual(wda.bodies("POST /wda/apps/launch").count, 1)
    }

    func testSearchRejectsTheQueryAsResultMarkerBeforeTyping() async {
        let wda = FakeWDA()
        install(wda, initial: [Node("SearchField", "Search", [16, 100, 200, 44])])
        let (core, _, _) = makeCore(wda)
        let result = await core.call("do", ["actions": [["search_submit": ["text": "tea", "result_texts": ["tea"]]]]])
        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(wda.bodies("POST /wda/keys").isEmpty)
    }

    func testSearchRequiresAReferencedSearchField() async {
        let wda = FakeWDA()
        install(wda, initial: [Node("Button", "Search", [16, 100, 200, 44]),
                               Node("SecureTextField", "Search password", [16, 160, 200, 44])])
        let (core, _, _) = makeCore(wda)
        _ = await core.call("look", [:])
        for ref: JSON in [1, 2, 99, .null] {
            let result = await core.call("do", ["actions": [["search_submit": [
                "text": "tea", "ref": ref, "result_texts": ["No results"],
            ]]]])
            XCTAssertTrue(result.isError, result.text)
            XCTAssertTrue(wda.bodies("POST /wda/keys").isEmpty)
            XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
        }
    }

    func testResultWaitIgnoresInputEchoAndReturnsEitherExactResult() async {
        let wda = FakeWDA()
        install(wda, initial: [Node("TextField", "No results", [16, 100, 200, 44])])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let noResult = await core.call("do", ["actions": [["wait_until": ["texts_any": ["No results", "Results ready"], "ms": 200]]]])
        XCTAssertTrue(noResult.isError, noResult.text)
        install(wda, initial: [Node("StaticText", "No results", [16, 150, 200, 44])])
        let result = await core.call("do", ["actions": [["wait_until": ["texts_any": ["No results", "Results ready"], "ms": 1000]]]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("No results"), result.text)
    }

    func testSearchResultAlreadyVisibleBeforeSubmissionDoesNotCountAsNew() async {
        let wda = FakeWDA()
        install(wda, initial: [Node("StaticText", "No results", [16, 150, 200, 44])])
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true }
        let result = await core.call("do", ["actions": [["wait_until": [
            "texts_any": ["No results"], "present_before": ["No results"], "ms": 200,
        ]]]])
        XCTAssertTrue(result.isError, result.text)
    }

    func testSearchSubmitsOnceAndWaitsForTheResult() async {
        let wda = FakeWDA()
        install(wda, initial: [Node("SearchField", "Search", [16, 100, 200, 44])])
        wda.set("POST /wda/keys") { [wda] body in
            let keys = body?["value"]?.array?.compactMap(\.string) ?? []
            if keys.contains("\n") {
                wda.tree([Node("StaticText", "No results", [16, 150, 200, 44])], app: "Shop")
            } else {
                wda.tree([Node("SearchField", "Search", [16, 100, 200, 44], value: "tea")], app: "Shop")
            }
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true; $0.toolDeadline = 20 }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["search_submit": [
            "text": "tea", "ref": 1, "result_texts": ["No results", "Results ready"],
        ]]]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("result \"No results\" appeared"), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/keys").count, 2)
    }

    func testLiveSearchCanWaitForResultsWithoutSendingReturn() async {
        let wda = FakeWDA()
        let field = Node("TextField", "请输入商品名", [75, 72, 270, 30])
        let search = Node("StaticText", "搜索", [374, 78, 28, 17])
        install(wda, initial: [field, search, Node("StaticText", "No results", [16, 160, 200, 44])])
        wda.set("POST /wda/keys") { [wda] _ in
            wda.tree([Node("TextField", "请输入商品名", [75, 72, 270, 30], value: "tea"), search,
                      Node("StaticText", "Results", [16, 160, 200, 44])], app: "Shop")
            return (200, ["value": .null])
        }
        let (core, _, _) = makeCore(wda) { $0.standaloneObservations = true; $0.toolDeadline = 20 }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [
            ["type": "tea", "ref": 1],
            ["wait_until": ["texts_any": ["Results", "No results"], "present_before": ["No results"], "ms": 5000]],
        ]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("result \"Results\" appeared"), result.text)
        let keys = wda.bodies("POST /wda/keys")
        XCTAssertEqual(keys.count, 1, result.text)
        XCTAssertFalse(keys.contains { ($0["value"]?.array?.compactMap(\.string) ?? []).contains("\n") })
    }
}
