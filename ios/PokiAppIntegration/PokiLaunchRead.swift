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

    func unconfirmedLaunchResult(_ reading: Reading, app: String, did: [String], extra: [String]) -> ToolResult {
        refs.removeAll()
        listed.removeAll()
        lastAll.removeAll()
        lastTreeAt = nil
        lastTree = nil
        lastPicture = nil
        lastPNG = nil
        lastPNGAt = nil
        swipeUnread = true
        lastForeground = reading.foreground
        var notes = reading.notes
        var jpeg: Data?
        if let png = reading.png {
            do { jpeg = try host.jpeg(fromPNG: png, width: Self.pictureWidth(size), quality: 0.6) }
            catch { notes.append("screenshot not encoded: \(error)") }
        }
        let front = reading.foreground?.bundleID ?? "unknown"
        let message = "launch sent for \(app); its current screen is not yet confirmed (foreground: \(front)). The screenshot may show another or loading screen. Look again before acting; do not resend the launch."
        return ToolResult(text: ([message] + did.map { "did: \($0)" } + extra + notes).joined(separator: "\n"),
                          jpeg: jpeg, isError: true, screenEvidence: [])
    }
}
