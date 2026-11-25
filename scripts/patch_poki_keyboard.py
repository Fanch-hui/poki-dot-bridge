"""Keep keyboard Return touches inside the current visible screen."""

from pathlib import Path
from shutil import copy2

from patch_poki_ui import replace_once


def patch_keyboard(bridge_root: Path, core: Path) -> None:
    source = core / "Sources/PokiCore"
    copy2(bridge_root / "ios/PokiAppIntegration/PokiSearchCandidates.swift", source)
    tests = core / "Tests/PokiCoreTests"
    if tests.is_dir():
        copy2(bridge_root / "ios/PokiAppIntegration/PokiSearchCandidateTests.swift", tests)
    actions = source / "Actions.swift"
    replace_once(
        actions,
        r'''            if text == "\n", let go = await keyboardReturnKey(timeout: min(1, max(0.3, until - now() - 1))) {
                try await tap(go.frame.centre, within: go.frame)
                return ("key", "key \(key): tapped the keyboard's \"\(go.text)\" key at [\(Int(go.frame.centre.x)), \(Int(go.frame.centre.y))]")
            }''',
        r'''            if text == "\n" {
                await updateReadSize(until: until, force: true)
                guard let screen = size else {
                    throw ActionFailure(message: "the current screen size could not be read; return was not sent", delivery: .notSent)
                }
                switch await keyboardReturnKey(screen: screen, timeout: min(1, max(0.3, until - now() - 1))) {
                case .visible(let go, let frame):
                    try await tap(frame.centre, within: frame)
                    return ("key", "key \(key): tapped the keyboard's \"\(go.text)\" key at [\(Int(frame.centre.x)), \(Int(frame.centre.y))]")
                case .offscreen(let elements, let foreground):
                    if let searchQuery, let (button, point) = searchSubmitButton(
                        query: searchQuery, elements: elements, foreground: foreground, screen: screen
                    ) {
                        try await tap(point, within: button.frame)
                        return ("key", "key \(key): tapped the visible \"\(button.text)\" search button at [\(Int(point.x)), \(Int(point.y))]")
                    }
                    throw ActionFailure(message: "the keyboard's return key is outside the visible screen; choose a visible search or submit button", delivery: .notSent)
                case .unlisted:
                    break
                }
            }''',
        "PokiCore visible keyboard Return dispatch",
    )
    replace_once(
        actions,
        '''    /// The keyboard's return key as the tree lists it (a Button inside the Keyboard whose label is
    /// one of `returnKeyLabels`), or nil when no keyboard is up or the read did not come.
    func keyboardReturnKey(timeout: Double) async -> Element? {
        guard let seen = try? await runner.tree(timeout: timeout, format: config.treeFormat) else { return nil }
        return Self.returnKey(in: seen.elements)
    }

    static func returnKey(in all: [Element]) -> Element? {
        guard let keyboard = all.first(where: { $0.type == "Keyboard" }) else { return nil }
        return all.last { $0.type == "Button" && keyboard.contains($0) && Self.returnKeyLabels.contains($0.text.lowercased()) && $0.frame.width >= 2 }
    }''',
        '''    enum KeyboardReturnTarget {
        case visible(Element, Rect)
        case offscreen([Element], Foreground)
        case unlisted
    }

    func keyboardReturnKey(screen: ScreenSize, timeout: Double) async -> KeyboardReturnTarget {
        guard let seen = try? await runner.tree(timeout: timeout, format: config.treeFormat) else { return .unlisted }
        let keys = Self.keyboardReturnKeys(in: seen.elements)
        guard !keys.isEmpty else { return .unlisted }
        guard let key = Self.visibleReturnKey(in: keys, screen: screen) else { return .offscreen(seen.elements, seen.foreground) }
        return .visible(key.element, key.frame)
    }

    static func keyboardReturnKeys(in all: [Element]) -> [(element: Element, keyboard: Element)] {
        let keyboards = all.filter { $0.type == "Keyboard" }
        return all.reversed().compactMap { element in
            guard element.type == "Button", Self.returnKeyLabels.contains(element.text.lowercased()),
                  let keyboard = keyboards.last(where: { $0.contains(element) }) else { return nil }
            return (element: element, keyboard: keyboard)
        }
    }

    static func visibleReturnKey(in keys: [(element: Element, keyboard: Element)], screen: ScreenSize) -> (element: Element, frame: Rect)? {
        let viewport = Rect(x: 0, y: 0, width: screen.width, height: screen.height)
        for key in keys {
            let frame = key.element.frame.intersection(key.keyboard.frame).intersection(viewport)
            if frame.width >= 8, frame.height >= 8 { return (key.element, frame) }
        }
        return nil
    }

    static func returnKey(in all: [Element], screen: ScreenSize) -> Element? {
        visibleReturnKey(in: keyboardReturnKeys(in: all), screen: screen)?.element
    }''',
        "PokiCore validate keyboard Return candidates",
    )
    replace_once(
        actions,
        "    func perform(_ action: JSON, until: Double, backTarget: BackTarget? = nil) async throws -> (String, String) {",
        "    func perform(_ action: JSON, until: Double, backTarget: BackTarget? = nil, searchQuery: String? = nil) async throws -> (String, String) {",
        "PokiCore retain typed search context for return",
    )
    replace_once(
        source / "Computer.swift",
        '''            let began = now()
            let givenUp = runner.actionsGivenUp.value''',
        '''            let searchQuery = config.standaloneObservations && i > 0 && Self.isReturn(action) &&
                did.last?.contains("(sent,") == true ? actions[i - 1]["type"]?.text : nil
            let began = now()
            let givenUp = runner.actionsGivenUp.value''',
        "PokiCore bind return fallback to the preceding successful input",
    )
    replace_once(
        source / "Computer.swift",
        "try await perform(action, until: actionsUntil, backTarget: check.backTarget)",
        "try await perform(action, until: actionsUntil, backTarget: check.backTarget, searchQuery: searchQuery)",
        "PokiCore pass typed search context to return",
    )
    replace_once(
        source / "Computer.swift",
        '''    private func updateReadSize(until: Double) async {
        guard size == nil || runner.transport.usesDynamicScreenSize else { return }''',
        '''    func updateReadSize(until: Double, force: Bool = false) async {
        guard force || size == nil || runner.transport.usesDynamicScreenSize else { return }''',
        "PokiCore refresh and invalidate screen size for keyboard touches",
    )
    replace_once(
        source / "Computer.swift",
        "let key = Self.returnKey(in: reading.elements), let index = shown.firstIndex(of: key)",
        "let key = Self.returnKey(in: reading.elements, screen: screen), let index = shown.firstIndex(of: key)",
        "PokiCore show only an on-screen keyboard Return key",
    )
    replace_once(
        source / "Computer.swift",
        "let textsBefore = lastAll.filter { !$0.fromPicture && !Self.fieldTypes.contains($0.type) }.map(\\.text)",
        "let elementsBefore = lastAll\n        let textsBefore = elementsBefore.filter { !$0.fromPicture && !Self.fieldTypes.contains($0.type) }.map(\\.text)",
        "PokiCore retain the prior screen for search candidate evidence",
    )
    replace_once(
        source / "Computer.swift",
        '        if let line = sendCheck(toRun, error: error, textsBefore: textsBefore) { result.text += "\\n" + line }',
        '''        if selectedPane == nil, searchCandidateAvailable(actions: toRun, did: did, error: error, before: before,
                                                         elementsBefore: elementsBefore, result: result) {
            result.text += "\\nsearch: input_sent; submit_not_sent; candidates_available"
        }
        if let line = sendCheck(toRun, error: error, textsBefore: textsBefore) { result.text += "\\n" + line }''',
        "PokiCore report visible search candidates after an unsent return",
    )
