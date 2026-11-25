import Foundation

extension Computer {
    private enum LaunchReadStatus {
        case ready, pending, imageMismatch
    }

    /// The post-launch read itself is the first readiness check, including its paired screenshot.
    func confirmLaunchRead(_ initial: Reading, app: String, until: Double) async -> (Reading, Bool) {
        var reading = initial
        var imageMismatch = false
        let deadline = min(now() + 3, until - 0.3)
        while !Task.isCancelled {
            let status = launchReadStatus(reading, app: app)
            if status == .ready { return (reading, true) }
            imageMismatch = status == .imageMismatch
            guard deadline - now() > 0.5 else { break }
            if let screen = size, reading.foreground?.bundleID == app,
               reading.png != nil, !reading.invalidatesReferences,
               PokiLoadingScreen.isPlaceholder(reading.elements, screen: screen) {
                reading = await waitForLoadingScreen(reading, screen: screen, app: app,
                                                     action: "launch", until: deadline)
                imageMismatch = false
                if reading.foreground?.bundleID == app,
                   PokiLoadingScreen.isPlaceholder(reading.elements, screen: screen) { break }
                continue
            }
            await sleep(seconds: 0.25)
            guard !Task.isCancelled, deadline - now() > 0.3 else { break }
            reading = await runner.read(timeout: min(config.readTimeout, deadline - now()), extra: 0,
                                        format: config.treeFormat, callEnds: deadline,
                                        allowHostPicture: false, workspace: false)
            imageMismatch = false
        }
        if imageMismatch {
            reading.notes.append("the screenshot may not yet match the app controls")
        }
        return (reading, false)
    }

    private func launchReadStatus(_ reading: Reading, app: String) -> LaunchReadStatus {
        guard let screen = size, let png = reading.png, !reading.invalidatesReferences else { return .pending }
        let front = reading.foreground?.bundleID
        let modal = reading.elements.contains {
            ["Alert", "Sheet", "Dialog", "Popover"].contains($0.type) && !$0.frame.isEmpty
        }
        guard front == app || (modal && front == "com.apple.springboard") else { return .pending }
        let page = reading.elements.filter { $0.frame.maxY > 64 }
        let targets = PokiControlTargets(reading.elements, screen: screen)
        let visible = listable(reading.elements, screen).filter { !targets.visibleFrame($0).isEmpty }
        if !modal {
            guard !PokiLoadingScreen.isPlaceholder(page, screen: screen),
                  visible.contains(where: { $0.frame.maxY > 64 }) else { return .pending }
            guard !PokiLaunchImageEvidence.hasMissingLabels(reading, screen: screen) else { return .imageMismatch }
        }
        let tree = visible.map { "\($0.key)@\($0.frame.described)" }.joined(separator: "\n")
        if let previous = lastPicture {
            let picture = PictureSketch(png: png)
            if tree == lastTree, let change = picture.change(from: previous), change.share >= 0.9 { return .pending }
            if lastForeground?.bundleID != nil, lastForeground?.bundleID != front,
               tree != lastTree, !picture.differs(from: previous) { return .pending }
        }
        return .ready
    }

    /// A destination tree may arrive before the screenshot has left a loading skeleton.
    func confirmTransitionRead(_ initial: Reading, screen: ScreenSize, app: String,
                               previousTree: String, until: Double) async -> (Reading, Bool) {
        guard !hasModal(initial, screen: screen),
              PokiLaunchImageEvidence.hasMissingLabels(initial, screen: screen) else { return (initial, true) }
        let targets = PokiControlTargets(initial.elements, screen: screen)
        let tree = listable(initial.elements, screen)
            .filter { !targets.visibleFrame($0).isEmpty }
            .map { "\($0.key)@\($0.frame.described)" }.joined(separator: "\n")
        guard tree != previousTree else { return (initial, true) }

        var reading = initial
        let started = now()
        let deadline = min(started + 3, until - 0.3)
        var checkedPicture = reading.png
        if await confirmsChangedText(reading, screen: screen, app: app, until: deadline) {
            return (reading, true)
        }
        while !Task.isCancelled, deadline - now() > 0.5 {
            await sleep(seconds: min(0.25, max(0, deadline - now() - 0.3)))
            guard !Task.isCancelled, deadline - now() > 0.3 else { break }
            reading = await runner.read(timeout: min(config.readTimeout, deadline - now()), extra: 0,
                                        format: config.treeFormat, callEnds: deadline,
                                        allowHostPicture: false, workspace: false)
            reading.ms = initial.ms + Int((now() - started) * 1000)
            guard !reading.invalidatesReferences, reading.png != nil else { return (reading, false) }
            if reading.foreground?.bundleID == "com.apple.springboard", hasModal(reading, screen: screen) {
                return (reading, true)
            }
            guard reading.foreground?.bundleID == app else { return (reading, false) }
            if hasModal(reading, screen: screen) { return (reading, true) }
            if !reading.elements.isEmpty, !PokiLoadingScreen.isPlaceholder(reading.elements, screen: screen) {
                if !PokiLaunchImageEvidence.hasMissingLabels(reading, screen: screen) { return (reading, true) }
                if reading.png != checkedPicture {
                    checkedPicture = reading.png
                    if await confirmsChangedText(reading, screen: screen, app: app, until: deadline) {
                        return (reading, true)
                    }
                }
            }
        }
        reading.notes.append("the screenshot may not yet match the app controls")
        return (reading, false)
    }

    private func confirmsChangedText(_ reading: Reading, screen: ScreenSize, app: String, until: Double) async -> Bool {
        guard !reading.invalidatesReferences, reading.foreground?.bundleID == app,
              lastForeground?.bundleID == app, let beforePNG = lastPNG, let afterPNG = reading.png,
              beforePNG != afterPNG, !PokiLoadingScreen.isPlaceholder(reading.elements, screen: screen) else { return false }
        let changed = PokiLaunchImageEvidence.changedLabels(before: lastAll, after: reading.elements, screen: screen)
        let budget = min(2, until - now() - 0.4)
        guard !changed.isEmpty, budget >= 0.4 else { return false }
        let host = self.host
        guard let pair = try? await withDeadline(budget, "confirming changed screen text", {
            async let before = host.recognizeText(inPNG: beforePNG)
            async let after = host.recognizeText(inPNG: afterPNG)
            return await (before, after)
        }), !Task.isCancelled, let before = pair.0, let after = pair.1 else { return false }
        return PokiLaunchImageEvidence.confirmsChangedLabel(changed, before: before, after: after, screen: screen)
    }

    private func hasModal(_ reading: Reading, screen: ScreenSize) -> Bool {
        reading.elements.contains { ["Alert", "Sheet", "Dialog", "Popover"].contains($0.type) && !$0.frame.isEmpty } ||
            PokiOverlay.detect(in: reading.elements, screen: screen) != nil
    }

    func unconfirmedLaunchResult(_ reading: Reading, app: String, did: [String], extra: [String]) -> ToolResult {
        let front = reading.foreground?.bundleID ?? "unknown"
        let message = "launch sent for \(app); its current screen is not yet confirmed (foreground: \(front)). The screenshot may show another or loading screen. Look again before acting; do not resend the launch."
        return unconfirmedReadResult(reading, message: message, did: did, extra: extra)
    }

    func unconfirmedTransitionResult(_ reading: Reading, did: [String], extra: [String]) -> ToolResult {
        let message = "the action was sent, but the current screen is not yet confirmed. Look again before acting; do not repeat the action."
        return unconfirmedReadResult(reading, message: message, did: did, extra: extra)
    }

    private func unconfirmedReadResult(_ reading: Reading, message: String, did: [String], extra: [String]) -> ToolResult {
        refs.removeAll()
        listed.removeAll()
        lastAll.removeAll()
        lastTreeAt = nil
        lastTree = nil
        lastPicture = nil
        lastPNG = nil
        lastPNGAt = nil
        pictureOnlyShare = nil
        swipeUnread = true
        lastForeground = reading.foreground
        var notes = reading.notes
        var jpeg: Data?
        if let png = reading.png {
            do { jpeg = try host.jpeg(fromPNG: png, width: Self.pictureWidth(size), quality: 0.6) }
            catch { notes.append("screenshot not encoded: \(error)") }
        }
        return ToolResult(text: ([message] + did.map { "did: \($0)" } + extra + notes).joined(separator: "\n"),
                          jpeg: jpeg, isError: true, screenEvidence: [])
    }
}
