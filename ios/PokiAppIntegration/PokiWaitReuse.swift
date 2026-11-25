import Foundation

struct PokiWaitReuse {
    let id: UUID
    let app: String
    let oldLabels: Set<String>
    let oldPicture: PictureSketch
    let screen: ScreenSize
    var triedPairedRead = false
    var reading: Reading?
}

struct PokiWaitScreen {
    let elements: [Element]
    let foreground: Foreground
    let reading: Reading?
}

extension Computer {
    func prepareWaitReuse(_ actions: [JSON], allowed: Bool) -> PokiWaitReuse? {
        guard allowed, actions.count >= 2, actions.count <= 3,
              let app = lastForeground?.bundleID, let screen = size,
              let previousPicture = lastPicture, !previousPicture.cells.isEmpty,
              let wait = actions.last?["wait_until"],
              wait.string != "settled", wait["settled"]?.bool != true,
              wait["gone"]?.bool != true, wait["handoff_done"]?.bool != true else { return nil }
        let first = actions[0]
        let ordinaryTap = actions.count == 2 && navigationTapTarget(first) != nil
        let searchField = first["ref"]?.int.flatMap { refs[$0] }
        let search = first["type"]?.string != nil && isSearchField(searchField, screen: screen) &&
            (actions.count == 2 || Self.isReturn(actions[1]))
        guard ordinaryTap || search else { return nil }
        let oldLabels = Set(lastAll.filter { !$0.fromPicture }.flatMap { element -> [String] in
            let labels = [element.label] + (Self.fieldTypes.contains(element.type) ? [] : [element.value])
            return labels.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        })
        let markers = wait["texts_any"]?.array?.compactMap(\.string) ??
            [wait.string ?? wait["text"]?.string].compactMap { $0 }
        guard markers.contains(where: {
            !oldLabels.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }) else { return nil }
        return PokiWaitReuse(id: UUID(), app: app, oldLabels: oldLabels,
                             oldPicture: previousPicture, screen: screen)
    }

    private func isSearchField(_ field: Element?, screen: ScreenSize) -> Bool {
        guard let field, !field.fromPicture, !field.isSecure else { return false }
        if Self.isSearch(field) { return true }
        guard field.type == "TextField", field.frame.y < screen.height * 0.4,
              lastAll.filter({ Self.fieldTypes.contains($0.type) && !$0.fromPicture }).count == 1 else {
            return false
        }
        let targets = PokiControlTargets(lastAll, screen: screen)
        let labels = lastAll.filter { element in
            let name = element.label?.lowercased() ?? ""
            let box = element.frame
            return ["Button", "StaticText"].contains(element.type) &&
                ["搜索", "搜尋", "search"].contains(name) &&
                !targets.visibleFrame(element).isEmpty &&
                box.x >= field.frame.maxX && box.x - field.frame.maxX <= max(64, screen.width * 0.2) &&
                min(box.maxY, field.frame.maxY) > max(box.y, field.frame.y)
        }
        return labels.count == 1
    }

    func waitScreen(timeout: Double, until: Double, countsAsMiss: Bool = true) async -> PokiWaitScreen? {
        let usePairedRead = waitReuse.update { context -> Bool in
            guard context != nil, context?.triedPairedRead == false else { return false }
            context?.triedPairedRead = true
            return true
        }
        if usePairedRead {
            let reading = await runner.read(timeout: timeout, extra: 0, format: config.treeFormat,
                                            callEnds: until, allowHostPicture: false, workspace: false)
            guard !Task.isCancelled, let foreground = reading.foreground, !reading.elements.isEmpty else { return nil }
            return PokiWaitScreen(elements: reading.elements, foreground: foreground, reading: reading)
        }
        guard let tree = try? await runner.tree(timeout: timeout, format: config.treeFormat,
                                                countsAsMiss: countsAsMiss) else { return nil }
        return PokiWaitScreen(elements: tree.elements, foreground: tree.foreground, reading: nil)
    }

    func saveWaitReading(_ seen: PokiWaitScreen, label: String, until: Double, allowField: Bool = false) async {
        guard let context = waitReuse.value, !Task.isCancelled,
              !context.oldLabels.contains(label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else { return }
        let reading: Reading
        if let paired = seen.reading {
            reading = paired
        } else {
            let room = until - now() - 0.3
            guard room >= 0.5 else { return }
            reading = await runner.read(timeout: min(config.readTimeout, room), extra: 0,
                                        format: config.treeFormat, callEnds: until,
                                        allowHostPicture: false, workspace: false)
        }
        guard !Task.isCancelled, isReusableWaitReading(reading, label: label, context: context, allowField: allowField) else { return }
        waitReuse.update { current in
            if current?.id == context.id { current?.reading = reading }
        }
    }

    private func isReusableWaitReading(_ reading: Reading, label: String, context: PokiWaitReuse, allowField: Bool) -> Bool {
        guard reading.foreground?.bundleID == context.app, let png = reading.png,
              !reading.invalidatesReferences, reading.notes.isEmpty,
              !blockedScreen(reading.elements),
              PokiOverlay.detect(in: reading.elements, screen: context.screen) == nil,
              PokiPageVisibility(elements: reading.elements, screen: context.screen) == nil,
              !PokiLoadingScreen.isPlaceholder(reading.elements, screen: context.screen),
              !PokiLaunchImageEvidence.hasMissingLabels(reading, screen: context.screen),
              PictureSketch(png: png).differs(from: context.oldPicture) else { return false }
        let targets = PokiControlTargets(reading.elements, screen: context.screen)
        let layout = Layout(all: reading.elements, screen: context.screen)
        let matches = reading.elements.filter { element in
            guard !element.fromPicture, !element.isSecure, !Self.containers.contains(element.type) else { return false }
            let field = Self.fieldTypes.contains(element.type)
            guard !field || allowField else { return false }
            let labels = [element.label] + (field ? [] : [element.value])
            guard labels.compactMap({ $0 }).contains(where: {
                      $0.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(label) == .orderedSame
                  }),
                  !field || element.value?.caseInsensitiveCompare(label) != .orderedSame else { return false }
            let visible = targets.visibleFrame(element)
            return !visible.isEmpty && !layout.covers(element).contains { $0.frame.contains(visible.centre) }
        }
        return matches.count == 1
    }
}
