import Foundation

/// Reuses text already read from this observation's screenshot to confirm a first navigation control.
enum OpeningEntryEvidence {
    private static let entryTypes: Set<String> = ["Button", "Cell", "Link", "SearchField"]
    private static let interactiveTypes: Set<String> = [
        "Button", "Cell", "Link", "SearchField", "TextField", "TextView", "SecureTextField",
        "Switch", "Toggle", "CheckBox", "RadioButton", "Slider", "Stepper", "PickerWheel",
        "ComboBox", "PopUpButton", "MenuButton", "Tab",
    ]

    static func applying(to parsed: ParsedPokiExecution, task: ClaimedTaskDTO) -> ObservationPayloadDTO {
        let observation = parsed.observation
        guard parsed.status == "succeeded", !parsed.uncertainExecution,
              parsed.approvalRequired == nil, parsed.handoffRequired == nil,
              !observation.screen_locked, observation.screenshot_base64 != nil,
              isPlainLaunch(task),
              let labels = task.payload["opening_labels"]?.arrayValue?.compactMap(\.stringValue),
              let width = observation.screen_width, let height = observation.screen_height,
              width > 0, height > 0,
              !observation.elements.contains(where: isModal),
              !observation.notes.contains(where: isUnreliableNote),
              !isPartialRead(observation.raw_text),
              let index = matchingEntry(in: observation.elements, labels: labels, width: width, height: height)
        else { return observation }

        var result = observation
        result.elements[index].flags = ["opening_label_visible"]
        return result
    }

    private static func isPlainLaunch(_ task: ClaimedTaskDTO) -> Bool {
        guard task.tool_name == "do", let actions = task.payload["actions"]?.arrayValue,
              actions.count == 1, let action = actions.first?.objectValue else { return false }
        return action.count == 1 && action["launch"] != nil
    }

    private static func isModal(_ element: ScreenElementDTO) -> Bool {
        if ["Alert", "Sheet", "Dialog", "Popover"].contains(element.type) { return true }
        guard element.type == "Other" || element.type == "Window" else { return false }
        let label = (element.label ?? "").lowercased()
        return ["弹窗", "彈窗", "弹出窗口", "彈出視窗", "popup", "pop-up", "dialog", "modal"]
            .contains { label.contains($0) }
    }

    private static func isUnreliableNote(_ note: String) -> Bool {
        let text = note.lowercased()
        return ["screenshot", "moving", "loading", "unconfirmed", "popup", "dialog", "overlay", "modal"]
            .contains { text.contains($0) }
    }

    private static func isPartialRead(_ text: String) -> Bool {
        text.contains("only the changed are listed") || text.contains("more not listed") ||
            text.contains("elements: none changed")
    }

    private static func matchingEntry(
        in elements: [ScreenElementDTO], labels: [String], width: Double, height: Double
    ) -> Int? {
        for label in labels {
            let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }
            let entries = elements.indices.filter { index in
                let element = elements[index]
                return element.from_picture != true && entryTypes.contains(element.type) &&
                    element.label == label
            }
            guard entries.count == 1, let index = entries.first else { continue }
            let entry = elements[index]
            guard entry.row_label == nil, (entry.flags ?? []).isEmpty,
                  isValidFrame(entry.frame, width: width, height: height),
                  entry.frame[2] >= 8, entry.frame[3] >= 8 else { continue }
            let texts = elements.filter { element in
                element.from_picture == true && element.type == "Text" &&
                    element.label?.trimmingCharacters(in: .whitespacesAndNewlines)
                        .caseInsensitiveCompare(label) == .orderedSame
            }
            guard texts.count == 1, let text = texts.first,
                  (text.flags ?? []).isEmpty, text.row_label == nil,
                  isValidFrame(text.frame, width: width, height: height),
                  contains(entry.frame, text.frame),
                  !hasCompetingControl(for: index, in: elements) else { continue }
            return index
        }
        return nil
    }

    private static func isValidFrame(_ frame: [Double], width: Double, height: Double) -> Bool {
        guard frame.count == 4 else { return false }
        return frame[0] >= 0 && frame[1] >= 0 && frame[2] > 0 && frame[3] > 0 &&
            frame[0] + frame[2] <= width && frame[1] + frame[3] <= height
    }

    private static func contains(_ outer: [Double], _ inner: [Double]) -> Bool {
        inner[0] >= outer[0] && inner[1] >= outer[1] &&
            inner[0] + inner[2] <= outer[0] + outer[2] &&
            inner[1] + inner[3] <= outer[1] + outer[3]
    }

    private static func hasCompetingControl(for index: Int, in elements: [ScreenElementDTO]) -> Bool {
        let entry = elements[index].frame
        return elements.indices.contains { otherIndex in
            let other = elements[otherIndex]
            guard otherIndex != index, other.from_picture != true,
                  interactiveTypes.contains(other.type), other.frame.count == 4,
                  other.frame[2] > 0, other.frame[3] > 0 else { return false }
            return entry[0] < other.frame[0] + other.frame[2] && other.frame[0] < entry[0] + entry[2] &&
                entry[1] < other.frame[1] + other.frame[3] && other.frame[1] < entry[1] + entry[3]
        }
    }
}
