"""Keep cancelled actions out of PokiCore and classify scroll containers as such."""

from pathlib import Path
from shutil import copy2

from patch_poki_overlay import patch_overlay
from patch_poki_ui import replace_once


def patch_core_safety(bridge_root: Path, poki_root: Path) -> None:
    core = poki_root / "native/ios/PokiCore"
    source = core / "Sources/PokiCore"
    patch_overlay(bridge_root, core)
    patch_deadline(source / "Deadline.swift")
    computer = source / "Computer.swift"
    patch_hit_testing(computer)
    replace_once(
        computer,
        r"""                    return ToolResult(text: "cancelled: the caller stopped waiting before the owner answered; nothing was sent from action \(at + 1).", jpeg: nil, isError: true)""",
        r"""                    let cancellation = "cancelled: the caller stopped waiting before the owner answered; nothing was sent from action \(at + 1)."
                    let text = ([cancellation] + did.map { "did: \($0)" }).joined(separator: "\n")
                    return ToolResult(text: text, jpeg: nil, isError: true)""",
        "PokiCore cancelled approval receipts",
    )
    replace_once(
        computer,
        """        for (i, action) in actions.enumerated() {
            let index = offset + i
            defer""",
        r"""        for (i, action) in actions.enumerated() {
            let index = offset + i
            guard !Task.isCancelled else {
                error = "cancelled before action \(index + 1); nothing more was sent"
                break
            }
            defer""",
        "PokiCore cancelled action batch",
    )
    replace_once(
        computer,
        """            return [(down, false, .stroke)]""",
        """            // Native lists can repeat a payment button's label in the container.
            // A web surface can hide its own controls, so keep checking it.
            if Layout.scrollers.contains(down.type), down.type != "WebView" { return [] }
            return [(down, false, .stroke)]""",
        "PokiCore scroll container",
    )
    # The release build skips tests; a full source checkout can run the same patch's regression cases.
    tests = core / "Tests/PokiCoreTests"
    if tests.is_dir():
        copy2(bridge_root / "ios/PokiAppIntegration/PokiCoreSafetyTests.swift", tests)


def patch_hit_testing(computer: Path) -> None:
    replace_once(
        computer,
        """        (elements ?? lastElements).filter { f in f.frame.x <= point.x && point.x <= f.frame.x + f.frame.width && f.frame.y <= point.y && point.y <= f.frame.y + f.frame.height }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }""",
        """        // As with CGRect, the right and bottom edges are outside a touch target.
        func hits(_ element: Element) -> Bool {
            let frame = element.frame
            return frame.x <= point.x && point.x < frame.maxX && frame.y <= point.y && point.y < frame.maxY
        }
        func smallest(_ candidates: [Element]) -> Element? {
            candidates.min { $0.frame.area < $1.frame.area }
        }
        let candidates = (elements ?? lastElements).filter(hits)
        let modal = (elements ?? lastAll).last {
            !$0.fromPicture && ($0.type == "Alert" || $0.type == "Sheet") && hits($0)
        }
        // WDA may still list a smaller control from the covered page behind a sheet.
        if let modal, let control = smallest(candidates.filter({ modal.contains($0) })) { return control }
        return smallest(candidates)""",
        "PokiCore foreground touch classification",
    )


def patch_deadline(path: Path) -> None:
    replace_once(
        path,
        """    let holder = LockedBox<(ResumeOnce<T>, Task<Void, Never>)?>(nil)
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let once = ResumeOnce(continuation)
            let work = Task {
                do { once.resume(.success(try await operation())) } catch { once.resume(.failure(error)) }
            }
            holder.value = (once, work)""",
        """    let holder = LockedBox<(cancelled: Bool, running: (ResumeOnce<T>, Task<Void, Never>)?)>((false, nil))
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let once = ResumeOnce(continuation)
            // The cancellation handler can run before this continuation registers the work.
            let registered = holder.update { state -> Task<Void, Never>? in
                guard !state.cancelled else { return nil }
                let task = Task {
                    do {
                        try Task.checkCancellation()
                        once.resume(.success(try await operation()))
                    } catch {
                        once.resume(.failure(error))
                    }
                }
                state.running = (once, task)
                return task
            }
            guard let work = registered else {
                once.resume(.failure(CancellationError()))
                return
            }""",
        "PokiCore deadline registration",
    )
    replace_once(
        path,
        """        if let (once, work) = holder.value, once.resume(.failure(CancellationError())) { work.cancel() }""",
        """        let running = holder.update { state in
            state.cancelled = true
            return state.running
        }
        if let (once, work) = running {
            work.cancel()
            once.resume(.failure(CancellationError()))
        }""",
        "PokiCore deadline cancellation",
    )
