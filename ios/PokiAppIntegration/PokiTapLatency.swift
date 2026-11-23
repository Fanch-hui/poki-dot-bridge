import Foundation

extension Computer {
    func navigationTapTarget(_ action: JSON) -> Element? {
        guard let tap = action["tap"], let ref = tap.int ?? tap["ref"]?.int,
              let element = refs[ref], !element.text.isEmpty || !(element.identifier ?? "").isEmpty else { return nil }
        if ["Cell", "Link", "Image"].contains(element.type) { return element }
        guard element.type == "Button" else { return nil }
        let label = element.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let navigationLabels = ["搜索", "搜尋", "查看", "查看详情", "查看詳情", "详情", "詳情", "更多",
                                "search", "view", "view details", "details", "more"]
        return navigationLabels.contains(label) ? element : nil
    }

    /// A tap can finish before its destination is visible. Return the first
    /// paired read early only when both the controls and picture have changed.
    func confirmTapRead(_ initial: Reading, screen: ScreenSize, target: Element,
                        tapFinishedAt: Double, until: Double) async -> Reading {
        if initial.invalidatesReferences { return initial }
        if initial.foreground?.bundleID == lastForeground?.bundleID,
           let beforeTree = lastTree, let beforePicture = lastPicture, let png = initial.png {
            let targets = PokiControlTargets(initial.elements, screen: screen)
            let visible = listable(initial.elements, screen)
                .filter { !targets.visibleFrame($0).isEmpty }
            let tree = visible.map { "\($0.key)@\($0.frame.described)" }.joined(separator: "\n")
            if tree != beforeTree && PokiLoadingScreen.isPlaceholder(initial.elements, screen: screen) { return initial }
            let oldTargetStillVisible = initial.elements.contains { element in
                guard !targets.visibleFrame(element).isEmpty else { return false }
                if let identifier = target.identifier, !identifier.isEmpty, element.identifier == identifier { return true }
                if let label = target.label, !label.isEmpty, element.label == label { return true }
                return target.label == nil && !target.text.isEmpty && element.text == target.text
            }
            let usable = visible.contains { ["Button", "Cell", "Link", "Image", "TextField", "SearchField", "Tab"].contains($0.type) }
            let change = PictureSketch(png: png).change(from: beforePicture)
            if usable, !oldTargetStillVisible, tree != beforeTree, let change, change.share >= 0.1 {
                return initial
            }
        }

        let pause = max(0, tapFinishedAt + (Self.settle["tap"] ?? 0.45) - now())
        if pause > 0 { await sleep(seconds: pause) }
        guard !Task.isCancelled, until - now() > 0.8 else {
            var unconfirmed = initial
            unconfirmed.elements = []
            unconfirmed.png = nil
            unconfirmed.invalidatesReferences = true
            unconfirmed.notes.append("the tap was sent, but its destination could not be confirmed; read again")
            return unconfirmed
        }
        let budget = max(0.8, min(config.readTimeout, until - now() - 0.2))
        var reading = await runner.read(timeout: budget, extra: max(0, min(4, until - now() - budget - 3)),
                                        format: config.treeFormat, callEnds: until, allowHostPicture: true, workspace: false)
        if reading.png == nil && reading.elements.isEmpty {
            reading.invalidatesReferences = true
            reading.notes.append("the tap was sent, but its destination could not be confirmed; read again")
        }
        return reading
    }
}
