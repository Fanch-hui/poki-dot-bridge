import Foundation

struct NavigationEntryEvidence {
    let target: SkillTarget
    let element: Element
    let point: (x: Double, y: Double)
    let observedAt: Double
}

extension Computer {
    func captionEvidence(_ entry: SkillTarget, elements: [Element], screen: ScreenSize, png: Data,
                         screenshotAt: Double, until: Double) async -> NavigationEntryEvidence? {
        guard let label = entry.label else { return nil }
        let candidates = elements.filter { $0.type == "Button" && entry.matches($0) }
        guard candidates.count == 1, let button = candidates.first else { return nil }
        let frame = PokiControlTargets(elements, screen: screen).visibleFrame(button)
        let budget = min(screenshotAt + 2.5, until - 0.2) - now()
        guard budget > 0.2, PokiIconCaption.isTile(button, frame: frame, screen: screen),
              let text = try? await withDeadline(budget, "reading an icon caption", {
                  PokiIconCaption.recognize(in: png, frame: frame, screen: screen, label: label)
              }) else { return nil }
        return visibleEntry(entry, in: elements, screen: screen, texts: [text], observedAt: screenshotAt)
    }

    func visibleEntry(_ target: SkillTarget, in elements: [Element], screen: ScreenSize,
                      texts: [RecognizedText], observedAt: Double,
                      confirmedPage: Bool = false) -> NavigationEntryEvidence? {
        guard let label = target.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return nil }
        let candidates = elements.filter { ["Button", "Link"].contains($0.type) && target.matches($0) }
        guard candidates.count == 1, let element = candidates.first,
              element.label?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(label) == .orderedSame else { return nil }
        let targets = PokiControlTargets(elements, screen: screen)
        guard let usualPoint = targets.safePoint(for: element) else { return nil }
        let frame = targets.visibleFrame(element)
        let matches = texts.filter {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(label) == .orderedSame
        }
        let scoped = confirmedPage ? matches.filter {
            frame.contains((x: $0.box.centre.x * screen.width, y: $0.box.centre.y * screen.height))
        } : matches
        guard scoped.count == 1, let match = scoped.first else { return nil }
        let box = Rect(x: match.box.x * screen.width, y: match.box.y * screen.height,
                       width: match.box.width * screen.width, height: match.box.height * screen.height)
        // OCR rectangles and accessibility frames can differ by a pixel at a text edge.
        guard !box.isEmpty, frame.contains(box.centre),
              box.x >= frame.x - 1, box.y >= frame.y - 1,
              box.maxX <= frame.maxX + 1, box.maxY <= frame.maxY + 1 else { return nil }
        let point: (x: Double, y: Double)
        if box.contains(usualPoint) {
            point = usualPoint
        } else {
            // An icon tile has its caption below the icon. Touch the verified caption itself.
            guard PokiIconCaption.isTile(element, frame: frame, screen: screen),
                  box.centre.y > frame.centre.y, box.width >= 8, box.height >= 8,
                  targets.canTouch(box.centre, on: element) else { return nil }
            point = box.centre
        }
        guard entryHasNoCompetingControl(element, point, elements, targets) else { return nil }
        return NavigationEntryEvidence(target: target, element: element, point: point, observedAt: observedAt)
    }

    private func entryHasNoCompetingControl(_ entry: Element, _ point: (x: Double, y: Double), _ elements: [Element],
                                            _ targets: PokiControlTargets) -> Bool {
        let contact = Rect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
        let actionable: Set<String> = ["Button", "Link", "TextField", "SearchField", "SecureTextField",
                                       "Switch", "Toggle", "CheckBox", "RadioButton", "Slider", "TextView",
                                       "Stepper", "PickerWheel", "ComboBox", "PopUpButton", "MenuButton", "Tab"]
        return !elements.contains {
            $0.node != entry.node && actionable.contains($0.type) && !targets.visibleFrame($0).intersection(contact).isEmpty
        }
    }

    func tapVisibleEntry(_ evidence: NavigationEntryEvidence, app: String, screen: ScreenSize,
                         until: Double) async throws -> String {
        try Task.checkCancellation()
        guard let tree = try? await runner.tree(timeout: min(config.readTimeout, max(0.3, until - now() - 0.2)),
                                                format: config.treeFormat, countsAsMiss: false),
              tree.foreground.bundleID == app, !blockedScreen(tree.elements),
              PokiOverlay.detect(in: tree.elements, screen: screen) == nil, now() - evidence.observedAt <= 2.5 else {
            throw ActionFailure(message: "navigation target changed before its touch; continue from the current screen", delivery: .notSent)
        }
        let matching = tree.elements.filter { ["Button", "Link"].contains($0.type) && evidence.target.matches($0) }
        guard matching.count == 1, let entry = matching.first,
              entry.key == evidence.element.key, entry.identifier == evidence.element.identifier,
              entry.frame == evidence.element.frame else {
            throw ActionFailure(message: "navigation target changed before its touch; continue from the current screen", delivery: .notSent)
        }
        let targets = PokiControlTargets(tree.elements, screen: screen)
        let point = evidence.point
        guard targets.canTouch(point, on: entry), entryHasNoCompetingControl(entry, point, tree.elements, targets) else {
            throw ActionFailure(message: "navigation target is no longer safely tappable; continue from the current screen", delivery: .notSent)
        }
        lastAll = tree.elements
        lastForeground = tree.foreground
        refs[Self.runRef] = entry
        verifiedTargets[Self.runRef] = (entry, point)
        defer { refs[Self.runRef] = nil; verifiedTargets[Self.runRef] = nil }
        let tap: JSON = ["tap": .number(Double(Self.runRef))]
        var scan = SensitiveScan(front: tree.foreground, secureOnScreen: tree.elements.contains(where: \.isSecure),
                                 allElements: tree.elements)
        if let reason = sensitive(tap, &scan) {
            throw ActionFailure(message: "navigation entry needs the owner's approval (\(reason)); choose it from the current screen", delivery: .notSent)
        }
        try Task.checkCancellation()
        let description: String
        do {
            (_, description) = try await perform(tap, until: until)
        } catch let failure as RunnerError {
            throw ActionFailure(message: "navigation entry failed (\(failure))", delivery: failure.delivery)
        }
        let recordedTarget = evidence.target.type == SkillTarget.anyType ? SkillTarget(entry) : evidence.target
        let step = SkillStep(action: ["tap": ["ref": "@"]], target: recordedTarget, app: app, secret: nil)
        trace.append(RecordedStep(step: step, typed: nil, keysBefore: []))
        return "\(description) (sent; screen-confirmed entry)"
    }
}
