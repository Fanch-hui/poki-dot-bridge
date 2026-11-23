import Foundation

/// A loading-only tree has no actionable content to proceed with yet.
struct PokiLoadingScreen {
    static func isPlaceholder(_ elements: [Element], screen: ScreenSize) -> Bool {
        let viewport = Rect(x: 0, y: 0, width: screen.width, height: screen.height)
        let visible = elements.filter { !$0.frame.intersection(viewport).isEmpty }
        guard !visible.contains(where: { ["Alert", "Sheet", "Dialog", "Popover"].contains($0.type) }) else { return false }

        var signal = false
        for element in visible {
            let text = element.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let frame = element.frame.intersection(viewport)
            let toolbar = element.type == "Toolbar" && ["", "工具栏", "工具列", "toolbar"].contains(text)
                && frame.width >= screen.width * 0.85 && frame.height >= screen.height * 0.85
            let indicator = ["ActivityIndicator", "ProgressIndicator"].contains(element.type)
                && (text.isEmpty || isLoadingText(text))
            let loadingText = element.type == "StaticText" && isLoadingText(text)
            if toolbar || indicator || loadingText {
                signal = true
            } else if !text.isEmpty || !["Other", "Group", "Window", "Application"].contains(element.type) {
                return false
            }
        }
        return signal
    }

    private static func isLoadingText(_ text: String) -> Bool {
        let words = text.trimmingCharacters(in: CharacterSet(charactersIn: ".… "))
        return ["加载中", "正在加载", "載入中", "正在載入", "loading"].contains(words)
    }
}

extension Computer {
    func waitForLoadingScreen(_ initial: Reading, screen: ScreenSize, app: String, action: String, until: Double) async -> Reading {
        var initial = initial
        let started = now()
        let refreshBudget = min(config.readTimeout, 2)
        let waitUntil = min(started + 2.5, until - refreshBudget - 0.5)
        guard waitUntil > started + 0.2 else {
            initial.notes.append("the page is still loading; the \(action) was already sent")
            return initial
        }

        while !Task.isCancelled && now() < waitUntil {
            await sleep(seconds: min(0.25, max(0, waitUntil - now())))
            guard !Task.isCancelled && now() < waitUntil else { break }
            guard let tree = try? await runner.tree(timeout: min(1, waitUntil - now()), format: config.treeFormat,
                                                    countsAsMiss: false) else { break }
            if tree.foreground.bundleID != app || !PokiLoadingScreen.isPlaceholder(tree.elements, screen: screen) { break }
        }

        guard !Task.isCancelled, until - now() > 0.5 else {
            initial.notes.append("the page was still loading in the initial read; the \(action) was already sent")
            return initial
        }
        var fresh = await runner.read(timeout: min(config.readTimeout, until - now() - 0.3), extra: 0,
                                      format: config.treeFormat, callEnds: until, allowHostPicture: true, workspace: false)
        fresh.ms = initial.ms + Int((now() - started) * 1000)
        if fresh.foreground?.bundleID == app && PokiLoadingScreen.isPlaceholder(fresh.elements, screen: screen) {
            fresh.notes.append("the page is still loading; the \(action) was already sent")
        } else if fresh.elements.isEmpty {
            fresh.notes.append("the page could not be confirmed after loading; the \(action) was already sent")
        }
        return fresh
    }
}
