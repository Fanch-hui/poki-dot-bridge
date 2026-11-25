import Foundation

extension Computer {
    func searchSubmitButton(
        query: String, elements: [Element], foreground: Foreground, screen: ScreenSize
    ) -> (Element, (x: Double, y: Double))? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !query.contains(where: \.isNewline),
              let bundle = lastForeground?.bundleID, foreground.bundleID == bundle,
              !elements.contains(where: { ["Alert", "Sheet", "Dialog", "Popover"].contains($0.type) && !$0.frame.isEmpty }),
              PokiPageVisibility(elements: elements, screen: screen) == nil
        else { return nil }

        let targets = PokiControlTargets(elements, screen: screen)
        let keyboards = elements.filter { $0.type == "Keyboard" }
        let fields = elements.filter {
            ["SearchField", "TextField", "TextView"].contains($0.type) && !$0.fromPicture &&
                $0.frame.y < screen.height * 0.4 && matchesSearchText($0, query) &&
                targets.safePoint(for: $0) != nil
        }
        guard fields.count == 1, let field = fields.first else { return nil }

        let buttons = elements.filter { element in
            guard element.type == "Button", !element.fromPicture,
                  let label = element.label?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  ["搜索", "搜尋", "search"].contains(label),
                  element.frame.x >= field.frame.maxX,
                  element.frame.x - field.frame.maxX <= max(64, screen.width * 0.2),
                  element.frame.intersection(Rect(x: 0, y: field.frame.y, width: screen.width, height: field.frame.height)).height > 0,
                  !keyboards.contains(where: { $0.contains(element) || $0.frame.intersects(element.frame) }),
                  targets.annotation(for: element).isEmpty else { return false }
            return targets.safePoint(for: element) != nil
        }
        guard buttons.count == 1, let button = buttons.first, let point = targets.safePoint(for: button) else {
            return nil
        }
        var scan = SensitiveScan(
            front: foreground, secureOnScreen: elements.contains(where: \.isSecure),
            elements: elements, allElements: elements
        )
        let tap: JSON = ["tap": [.number(point.x), .number(point.y)]]
        guard sensitive(tap, &scan) == nil else { return nil }
        return (button, point)
    }

    /// Candidate evidence is advisory. It never changes the receipt for the unsent Return.
    func searchCandidateAvailable(
        actions: [JSON], did: [String], error: String?, before: Foreground?,
        elementsBefore: [Element], result: ToolResult
    ) -> Bool {
        guard config.standaloneObservations,
              actions.count >= 2, did.count >= 2,
              let query = actions[0]["type"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              query.count >= 2, Self.isReturn(actions[1]),
              did[0].contains("(sent,"), did[1].contains("(not_sent"),
              error?.contains("the keyboard's return key is outside the visible screen") == true,
              let bundle = before?.bundleID, bundle == lastForeground?.bundleID,
              let screen = size, result.screen?.hasPrefix("\(bundle)\n") == true,
              result.screenEvidence?.contains(.references) == true,
              result.screenEvidence?.contains(.screenshot) == true,
              !lastAll.contains(where: { ["Alert", "Sheet", "Dialog", "Popover"].contains($0.type) })
        else { return false }

        let earlier = elementsBefore.filter { !$0.fromPicture && !Self.fieldTypes.contains($0.type) }
        guard !earlier.contains(where: { matchesSearchText($0, query) }) else { return false }
        let history = ["历史记录", "搜尋紀錄", "搜索历史", "最近搜索", "search history", "recent searches"]
        guard !lastAll.contains(where: { element in
            history.contains { element.text.localizedCaseInsensitiveContains($0) }
        }) else { return false }

        let targets = PokiControlTargets(lastAll, screen: screen)
        let keyboards = lastAll.filter { $0.type == "Keyboard" }
        func isKeyboardElement(_ element: Element) -> Bool {
            keyboards.contains { keyboard in
                keyboard.contains(element) || keyboard.frame.intersection(element.frame).area > 0
            }
        }
        let searchLabels = ["搜索", "搜尋", "search"]
        guard lastAll.contains(where: { element in
            ["Button", "Image", "SearchField"].contains(element.type) &&
                searchLabels.contains((element.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) &&
                element.frame.y < screen.height * 0.4 && !isKeyboardElement(element)
        }) else { return false }

        let fields = lastAll.filter {
            ["SearchField", "TextField"].contains($0.type) && !$0.fromPicture &&
                $0.frame.y < screen.height * 0.4 && matchesSearchText($0, query)
        }
        guard fields.count == 1, let field = fields.first else { return false }
        // The last slot may be replaced by a keyboard key in bounded results.
        let candidates = listed.prefix(Self.lineLimit - 1).filter { item in
            let element = item.element
            return ["Image", "Button", "Cell", "Link"].contains(element.type) &&
                !element.fromPicture && matchesSearchText(element, query) &&
                element.frame.y >= field.frame.maxY && !isKeyboardElement(element) &&
                targets.safePoint(for: element) != nil &&
                targets.annotation(for: element).isEmpty
        }
        return candidates.count == 1
    }

    private func matchesSearchText(_ element: Element, _ query: String) -> Bool {
        [element.label, element.value].contains {
            $0?.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(query) == .orderedSame
        }
    }
}
