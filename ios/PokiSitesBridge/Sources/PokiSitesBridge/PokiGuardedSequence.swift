import Foundation

/// Executes known, low-risk steps while keeping each later target bound to the
/// screen returned by the preceding step.
enum PokiGuardedSequence {
    typealias Call = ([String: JSONValue], Int) async -> PokiToolReply

    private struct Target {
        let label: String
        let type: String?
        let rowLabel: String?
        let editable: Bool
    }

    private struct Stage {
        let actions: [[String: JSONValue]]
        let target: Target?
        let markers: [String]
        let waitsForResults: Bool
        let waitsForPage: Bool
    }

    private struct Stop: Error {
        let message: String
    }

    static func execute(task: ClaimedTaskDTO, call: Call) async -> PokiToolReply {
        guard let app = task.payload["app"]?.stringValue, !app.isEmpty,
              let stages = parseStages(task.payload["guarded_sequence"]) else {
            return PokiToolReply(text: "error: invalid guarded sequence; nothing was sent", isError: true)
        }
        var previous: PokiToolReply?
        var previousScreen: ObservationPayloadDTO?
        var priorReceipts: [String] = []
        var timings: [String] = []
        var completed = 0

        for (index, stage) in stages.enumerated() {
            if Task.isCancelled {
                return result(previous, receipts: priorReceipts, timings: timings, completed: completed,
                              total: stages.count, stop: "cancelled: later sequence stages were not sent")
            }
            if Int64(Date().timeIntervalSince1970 * 1000) >= task.expires_at {
                return result(previous, receipts: priorReceipts, timings: timings, completed: completed,
                              total: stages.count, stop: "error: sequence expired before the next stage")
            }
            let actions: [[String: JSONValue]]
            do {
                actions = try prepare(stage, screen: previousScreen, expectedApp: app)
            } catch let stop as Stop {
                return result(previous, receipts: priorReceipts, timings: timings, completed: completed,
                              total: stages.count, stop: "error: \(stop.message); later stages were not sent")
            } catch {
                return result(previous, receipts: priorReceipts, timings: timings, completed: completed,
                              total: stages.count, stop: "error: the next stage could not be prepared; later stages were not sent")
            }
            let clock = ContinuousClock()
            let started = clock.now
            let reply = await call([
                "actions": .array(actions.map(JSONValue.object)),
                "app": .bool(false),
                "expect_front": .string(app),
                "full": .bool(index < stages.count - 1 || task.payload["full"]?.boolValue == true),
                "finish": .bool(index == stages.count - 1 && (task.payload["finish"]?.boolValue ?? false)),
            ], index + 1)
            let elapsed = started.duration(to: clock.now).components
            let ms = elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
            timings.append("sequence_timing_ms: stage=\(index + 1) execution=\(ms)")

            if let previous { priorReceipts += receiptLines(previous.text) }
            previous = reply
            let parsed = PokiOutputParser.parse(toolName: "do", text: reply.text, isError: reply.isError, screenshotJPEG: nil)
            previousScreen = parsed.observation
            if let foreground = parsed.observation.app_bundle_id, foreground != app {
                return result(nil, receipts: priorReceipts + receiptLines(reply.text), timings: timings,
                              completed: completed, total: stages.count,
                              stop: "error: the foreground app changed; later stages were not sent")
            }
            if Task.isCancelled {
                return result(reply, receipts: priorReceipts, timings: timings, completed: completed,
                              total: stages.count, stop: "cancelled: later sequence stages were not sent")
            }
            if parsed.status != "succeeded" || parsed.uncertainExecution ||
                parsed.approvalRequired != nil || parsed.handoffRequired != nil {
                return result(reply, receipts: priorReceipts, timings: timings, completed: completed,
                              total: stages.count)
            }
            if let reason = stageFailure(stage, parsed: parsed, expectedApp: app, screenshot: reply.screenshotJPEG) {
                return result(reply, receipts: priorReceipts, timings: timings, completed: completed,
                              total: stages.count, stop: "error: \(reason); later stages were not sent")
            }
            completed += 1
        }
        return result(previous, receipts: priorReceipts, timings: timings, completed: completed, total: stages.count)
    }

    private static func parseStages(_ value: JSONValue?) -> [Stage]? {
        guard let items = value?.arrayValue, (1...6).contains(items.count) else { return nil }
        var stages: [Stage] = []
        for (index, item) in items.enumerated() {
            guard let object = item.objectValue, let rawActions = object["actions"]?.arrayValue else { return nil }
            let actions = rawActions.compactMap(\.objectValue)
            guard actions.count == rawActions.count, (1...3).contains(actions.count),
                  let first = actions.first, let last = actions.last else { return nil }
            let target = object["target"]?.objectValue.flatMap(parseTarget)
            guard (index == 0 && object["target"] == nil) || (index > 0 && target != nil),
                  validAction(first, target: target) else { return nil }
            if actions.count == 1 {
                guard index == items.count - 1, first["tap"] != nil else { return nil }
                stages.append(Stage(actions: actions, target: target, markers: [], waitsForResults: false, waitsForPage: false))
            } else {
                guard let wait = last["wait_until"], let markers = markers(wait), !markers.isEmpty,
                      actions.count == 2 || (first["type"]?.stringValue != nil && actions[1] == ["key": .string("return")]) else { return nil }
                stages.append(Stage(actions: actions, target: target, markers: markers,
                                    waitsForResults: wait.objectValue?["texts_any"] != nil, waitsForPage: true))
            }
        }
        guard stages.reduce(0, { $0 + $1.actions.count }) <= 20 else { return nil }
        return stages
    }

    private static func parseTarget(_ value: [String: JSONValue]) -> Target? {
        guard let label = value["label"]?.stringValue, !label.isEmpty else { return nil }
        return Target(label: label, type: value["type"]?.stringValue, rowLabel: value["row_label"]?.stringValue,
                      editable: value["editable"]?.boolValue ?? false)
    }

    private static func validAction(_ action: [String: JSONValue], target: Target?) -> Bool {
        if let ref = action["tap"]?.intValue {
            return action.count == 1 && ref > 0 && target?.editable != true
        }
        guard let text = action["type"]?.stringValue, !text.isEmpty,
              let ref = action["ref"]?.intValue, ref > 0, target?.editable != false else { return false }
        return Set(action.keys).isSubset(of: ["type", "ref", "clear", "via"])
    }

    private static func markers(_ wait: JSONValue) -> [String]? {
        if let text = wait.stringValue, !text.isEmpty { return [text] }
        guard let object = wait.objectValue, object["gone"]?.boolValue != true,
              object["settled"]?.boolValue != true, object["handoff_done"]?.boolValue != true else { return nil }
        if let text = object["text"]?.stringValue, !text.isEmpty { return [text] }
        guard let values = object["texts_any"]?.arrayValue else { return nil }
        let labels = values.compactMap(\.stringValue)
        return labels.count == values.count && labels.allSatisfy({ !$0.isEmpty }) ? labels : nil
    }

    private static func prepare(_ stage: Stage, screen: ObservationPayloadDTO?, expectedApp: String) throws -> [[String: JSONValue]] {
        guard let target = stage.target else { return stage.actions }
        guard let screen, safeScreen(screen, expectedApp: expectedApp), !screen.raw_text.contains("more not listed") else {
            throw Stop(message: "the current screen or foreground app could not be confirmed")
        }
        let matches = screen.elements.filter {
            $0.label == target.label && (target.type == nil || $0.type == target.type) &&
                (target.rowLabel == nil || $0.row_label == target.rowLabel) && $0.from_picture != true &&
                (target.editable ? ["SearchField", "TextField", "TextView"].contains($0.type) : true)
        }
        guard matches.count == 1, let element = matches.first else {
            throw Stop(message: "found \(matches.count) controls named \"\(target.label)\"")
        }
        guard visible(element, in: screen) else {
            throw Stop(message: "the target \"\(target.label)\" is not confirmed reachable")
        }
        if stage.actions.count == 3 && element.type != "SearchField" {
            throw Stop(message: "Return requires a confirmed search field")
        }
        var actions = stage.actions
        if target.editable {
            actions[0]["ref"] = .number(Double(element.ref))
        } else {
            actions[0]["tap"] = .number(Double(element.ref))
        }
        let present = stage.markers.filter { label in hasMarker(label, in: screen) }
        if stage.waitsForResults {
            var wait = actions[actions.count - 1]["wait_until"]?.objectValue ?? [:]
            wait["present_before"] = .array(present.map(JSONValue.string))
            actions[actions.count - 1]["wait_until"] = .object(wait)
        } else if !present.isEmpty {
            throw Stop(message: "the next page marker is already visible before this action")
        }
        return actions
    }

    private static func stageFailure(_ stage: Stage, parsed: ParsedPokiExecution, expectedApp: String,
                                     screenshot: Data?) -> String? {
        let screen = parsed.observation
        guard screenshot != nil, safeScreen(screen, expectedApp: expectedApp) else {
            return "the resulting screen or foreground app could not be confirmed"
        }
        guard parsed.receipts.count == stage.actions.count,
              parsed.receipts.allSatisfy({ $0.status == "sent" }) else {
            return "the action receipts are incomplete or an action was not sent"
        }
        if stage.waitsForPage {
            guard let wait = parsed.receipts.last, wait.kind.hasPrefix("wait_until"),
                  let detail = wait.detail, stage.markers.contains(where: { marker in
                      let reported = stage.waitsForResults ? marker : String(marker.prefix(40))
                      let prefix = stage.waitsForResults ? "wait_until: result " : "wait_until: "
                      return detail.hasPrefix("\(prefix)\"\(reported)\" appeared after") && hasMarker(marker, in: screen)
                  }) else {
                return "the expected page marker was not confirmed"
            }
        }
        if parsed.receipts.contains(where: {
            $0.kind == "type" && ($0.detail?.contains("no field was focused when the text went") == true ||
                                  $0.detail?.contains("the field could not be read back") == true)
        }) {
            return "the entered text could not be confirmed"
        }
        return nil
    }

    private static func safeScreen(_ screen: ObservationPayloadDTO, expectedApp: String) -> Bool {
        guard screen.app_bundle_id == expectedApp, !screen.screen_locked,
              screen.screen_width != nil, screen.screen_height != nil,
              !screen.notes.contains(where: { note in
                  ["moving", "unconfirmed", "popup", "dialog", "overlay", "screenshot is the one of the read before"]
                      .contains(where: { note.localizedCaseInsensitiveContains($0) })
              }),
              !screen.raw_text.contains("the element tree did not come in time") else { return false }
        return !screen.elements.contains { ["Alert", "Sheet", "Dialog", "Popover"].contains($0.type) }
    }

    private static func hasMarker(_ text: String, in screen: ObservationPayloadDTO) -> Bool {
        screen.elements.contains { element in
            guard element.from_picture != true, visible(element, in: screen), element.type != "SecureTextField" else { return false }
            if ["SearchField", "TextField", "TextView"].contains(element.type) {
                return element.label == text && element.value != text
            }
            return element.label == text || element.value == text
        }
    }

    private static func visible(_ element: ScreenElementDTO, in screen: ObservationPayloadDTO) -> Bool {
        guard element.frame.count == 4, let width = screen.screen_width, let height = screen.screen_height,
              !(element.flags ?? []).contains(where: { ["covered", "collapsed", "row_unverified"].contains($0) }) else { return false }
        let f = element.frame
        return f[0] >= 0 && f[1] >= 0 && f[2] > 0 && f[3] > 0 && f[0] + f[2] <= width && f[1] + f[3] <= height
    }

    private static func receiptLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").filter { $0.hasPrefix("did: ") }
    }

    private static func result(_ reply: PokiToolReply?, receipts: [String], timings: [String], completed: Int,
                               total: Int, stop: String? = nil) -> PokiToolReply {
        let finished = completed == total && stop == nil
        let status = finished ? "complete" : "stopped"
        let text = (receipts + [reply?.text].compactMap { $0 } + timings +
                    ["sequence: completed=\(completed) total=\(total) status=\(status)"] +
                    [stop].compactMap { $0 }).joined(separator: "\n")
        return PokiToolReply(text: text, screenshotJPEG: reply?.screenshotJPEG,
                             isError: stop != nil || reply?.isError == true)
    }
}
