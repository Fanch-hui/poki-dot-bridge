import Foundation

public struct ParsedPokiExecution: Sendable, Equatable {
    public var status: String
    public var summary: String
    public var observation: ObservationPayloadDTO
    public var receipts: [ActionReceiptDTO]
    public var approvalRequired: PendingApprovalDTO?
    public var handoffRequired: PendingHandoffDTO?
    public var errorCode: String?
    public var errorMessage: String?
    public var uncertainExecution: Bool
    public var finishedAppReturn: Bool
}

/// Parses PokiCore `look`, `do`, and `status` outputs into structured D1/R2 observation payloads.
public enum PokiOutputParser {
    private static let elementRegex = try! NSRegularExpression(
        pattern: #"^\s*([+~]?)\s*(\d+)\s+([A-Za-z0-9_]+)(?:\s+"(.*)")?\s+\[(-?\d+),(-?\d+),(-?\d+),(-?\d+)\](.*)$"#
    )
    private static let rowLabelRegex = try! NSRegularExpression(pattern: #"\[row: (.+)\]$"#)
    private static let approvalRegex = try! NSRegularExpression(
        pattern: #"^not_sent from action \d+:\s+approval_required\s+\(id\s+([^)\s]+)\)"#
    )
    private static let withdrawnApprovalRegex = try! NSRegularExpression(
        pattern: #"^approval: withdrawn \(id\s+([^)\s]+)\)"#
    )
    private static let cancellationRegex = try! NSRegularExpression(
        pattern: #"^(cancelled:|cancelled (?:before|at) action \d+\b)"#
    )
    private static let didRegex = try! NSRegularExpression(
        pattern: #"^did:\s+(.+)$"#
    )
    private static let deliveryRegex = try! NSRegularExpression(
        pattern: #"\((sent|not_sent|unknown)(?:[,:][^)]*)?\)\s*$"#
    )
    private static let screenChangedRegex = try! NSRegularExpression(
        pattern: #"^screen_changed:\s+(true|false)"#
    )
    private static let screenshotWidthRegex = try! NSRegularExpression(
        pattern: #"^screenshot:\s+(\d+)\s+px\s+wide"#
    )

    public static func parse(
        toolName: String,
        text: String,
        isError: Bool,
        screenshotJPEG: Data?
    ) -> ParsedPokiExecution {
        let currentText: String
        if text.hasPrefix("earlier, never delivered to you: "),
           let boundary = text.range(of: "\n\nnow:\n", options: .backwards) {
            currentText = String(text[boundary.upperBound...])
        } else {
            currentText = text
        }
        let lines = currentText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var appName: String?
        var screenWidth: Double?
        var screenLocked = false
        var screenChanged: Bool?
        var notes: [String] = []
        var elements: [ScreenElementDTO] = []
        var receipts: [ActionReceiptDTO] = []
        var errorLine: String?
        var approvalId: String?
        var cancelled = false
        var withdrawnApprovalIds: Set<String> = []
        var handoff: PendingHandoffDTO?
        var finishedAppReturn = false

        for line in lines {
            if line.hasPrefix("app: ") {
                let raw = String(line.dropFirst(5))
                appName = raw.components(separatedBy: "   read:").first?.trimmingCharacters(in: .whitespaces)
                if let noteRange = raw.range(of: "note: ") {
                    notes.append(String(raw[noteRange.upperBound...]).trimmingCharacters(in: .whitespaces))
                }
                continue
            }
            if let width = firstCapture(screenshotWidthRegex, in: line).flatMap(Double.init) {
                screenWidth = width
                continue
            }
            if line.hasPrefix("screen: locked") {
                screenLocked = true
                notes.append(line)
                continue
            }
            if let changed = firstCapture(screenChangedRegex, in: line) {
                screenChanged = changed == "true"
                continue
            }
            if let didDesc = firstCapture(didRegex, in: line) {
                if didDesc.hasPrefix("paused ") || didDesc.hasPrefix("read after ") { continue }
                let status = firstCapture(deliveryRegex, in: didDesc) ?? "unknown"
                let kind = didDesc.split(separator: " ").first.map(String.init) ?? "action"
                receipts.append(ActionReceiptDTO(index: receipts.count, kind: kind, status: status, detail: didDesc))
                continue
            }
            if let id = firstCapture(withdrawnApprovalRegex, in: line) {
                withdrawnApprovalIds.insert(id)
                continue
            }
            if line.hasPrefix("error: ") || line.hasPrefix("cancelled:") ||
                line.hasPrefix("not_sent: ") || line.hasPrefix("not_sent from action ") {
                let failure = line.hasPrefix("error: ") ? String(line.dropFirst(7)) : line
                errorLine = failure
                if firstCapture(cancellationRegex, in: failure) != nil {
                    cancelled = true
                }
                if let id = firstCapture(approvalRegex, in: failure),
                   !failure.contains("The owner approved on the phone, but too late"),
                   !failure.contains("The approval went to another call") {
                    approvalId = id
                }
                continue
            }
            if line.hasPrefix("handoff: waiting ") {
                let validKinds: Set<String> = ["passcode", "password", "verification", "payment", "other"]
                let detectedKind = validKinds.first { line.localizedCaseInsensitiveContains($0) } ?? "other"
                handoff = PendingHandoffDTO(
                    id: UUID().uuidString.lowercased(),
                    kind: detectedKind,
                    text: line,
                    app: appName,
                    requested_at: Int64(Date().timeIntervalSince1970 * 1000)
                )
                continue
            }
            if line.hasPrefix("finish: ") {
                finishedAppReturn = true
                continue
            }
            if let el = parseElementLine(line) {
                elements.append(el)
            }
        }

        let pendingId = approvalId.flatMap { withdrawnApprovalIds.contains($0) ? nil : $0 }
        let approval: PendingApprovalDTO? = pendingId.map { id in
            PendingApprovalDTO(
                id: id,
                app: appName,
                summary: errorLine ?? "Approval required on iPhone",
                reason: "Poki sensitive action policy",
                expires_at: Int64((Date().timeIntervalSince1970 + 120) * 1000)
            )
        }

        let visibleText = elements
            .compactMap { [$0.label, $0.value].compactMap { $0 }.joined(separator: " = ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        let maxScreenshotBytes = 3 * 1024 * 1024
        var effectiveJPEG = screenshotJPEG
        if let jpeg = screenshotJPEG, jpeg.count > maxScreenshotBytes {
            effectiveJPEG = nil
            notes.append("Screenshot omitted: exceeded 3 MiB limit")
        }
        let b64 = effectiveJPEG?.base64EncodedString()
        let validScreenWidth = screenWidth.flatMap { $0 > 0 ? $0 : nil }
        let obs = ObservationPayloadDTO(
            observation_id: nil,
            app_bundle_id: nil,
            app_name: appName,
            screen_width: validScreenWidth,
            screen_height: nil,
            coordinate_unit: "points",
            screen_locked: screenLocked,
            screen_changed: screenChanged,
            screen_hash: nil,
            elements: elements,
            visible_text: visibleText.isEmpty ? currentText : visibleText,
            raw_text: text,
            notes: notes,
            screenshot_base64: b64,
            screenshot_mime: "image/jpeg"
        )

        let uncertain = currentText.contains("what was sent is unknown") || receipts.contains(where: { $0.status == "unknown" })
        let finalStatus: String
        if cancelled {
            finalStatus = "cancelled"
        } else if approval != nil {
            finalStatus = "awaiting_approval"
        } else if isError || errorLine != nil {
            finalStatus = "failed"
        } else {
            finalStatus = "succeeded"
        }
        let errorCode: String?
        switch finalStatus {
        case "cancelled": errorCode = "CANCELLED"
        case "awaiting_approval": errorCode = "APPROVAL_REQUIRED"
        case "failed": errorCode = "POKI_ERROR"
        default: errorCode = nil
        }

        let summaryLine = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "\(toolName) completed"
        return ParsedPokiExecution(
            status: finalStatus,
            summary: String(summaryLine.prefix(160)),
            observation: obs,
            receipts: receipts,
            approvalRequired: cancelled ? nil : approval,
            handoffRequired: handoff,
            errorCode: errorCode,
            errorMessage: errorLine,
            uncertainExecution: uncertain,
            finishedAppReturn: finishedAppReturn
        )
    }

    private static func parseElementLine(_ line: String) -> ScreenElementDTO? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = elementRegex.firstMatch(in: line, range: range),
              match.numberOfRanges >= 9 else {
            return nil
        }
        func str(_ idx: Int) -> String? {
            let r = match.range(at: idx)
            guard r.location != NSNotFound, let sr = Range(r, in: line) else { return nil }
            return String(line[sr])
        }
        guard let refStr = str(2), let ref = Int(refStr),
              let type = str(3),
              let x = str(5).flatMap(Double.init),
              let y = str(6).flatMap(Double.init),
              let w = str(7).flatMap(Double.init),
              let h = str(8).flatMap(Double.init) else {
            return nil
        }
        let mark = str(1) ?? ""
        let change: String? = mark == "+" ? "added" : mark == "~" ? "moved" : nil
        let rawText = str(4)
        var label = rawText
        var value: String?
        if let rawText, let sep = rawText.range(of: " = ") {
            label = String(rawText[..<sep.lowerBound])
            value = String(rawText[sep.upperBound...])
        }
        let tail = (str(9) ?? "").trimmingCharacters(in: .whitespaces)
        var flags: [String] = []
        if tail.contains("[collapsed]") { flags.append("collapsed") }
        if tail.hasSuffix("[row unverified]") { flags.append("row_unverified") }
        let fromPic = tail.contains("(read from the picture)")
        return ScreenElementDTO(
            ref: ref,
            type: type,
            label: label,
            value: value,
            identifier: nil,
            frame: [x, y, w, h],
            row_label: firstCapture(rowLabelRegex, in: tail),
            flags: flags.isEmpty ? nil : flags,
            from_picture: fromPic ? true : nil,
            change: change
        )
    }

    private static func firstCapture(_ regex: NSRegularExpression, in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let sr = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[sr])
    }
}
