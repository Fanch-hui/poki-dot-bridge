import Foundation

struct PokiPointTarget {
    let point: (x: Double, y: Double)
    let element: Element
    let row: String
}

enum PokiPointTargetSelection {
    case unmanaged
    case guarded(PokiPointTarget)
    case blocked(String)

    var requiresVerification: Bool {
        if case .unmanaged = self { return false }
        return true
    }
}

extension Computer {
    /// A repeated control under a coordinate needs an identifiable row on the
    /// observed screen, even though the caller supplied a point rather than a ref.
    func pointTargetToVerify(_ action: JSON) -> PokiPointTargetSelection {
        guard config.standaloneObservations, let tap = action["tap"], let screen = size,
              let point = Self.pointFromTap(tap) else { return .unmanaged }
        let controls = PokiControlTargets(lastAll, screen: screen)
        let named = lastAll.filter { element in
            ["Other", "Button", "Link", "StaticText", "Cell"].contains(element.type) &&
                !element.fromPicture && !element.text.isEmpty &&
                !controls.visibleFrame(element).isEmpty
        }
        let repeated = named.filter { element in
            controls.containsTouch(point, in: element) && named.contains {
                $0.node != element.node && $0.key == element.key &&
                    $0.frame.described != element.frame.described
            }
        }
        guard !repeated.isEmpty else { return .unmanaged }
        let leaves = repeated.filter { element in
            !repeated.contains { element.contains($0) }
        }
        guard leaves.count == 1, let element = leaves.first else {
            return .blocked("the repeated controls at this point could not be distinguished")
        }
        let row = controls.annotation(for: element)
        guard row.contains("[row: ") else {
            return .blocked("the list item at this point could not be identified")
        }
        guard controls.canTouch(point, on: element) else {
            return .blocked("the control at this point is covered or outside its visible area")
        }
        return .guarded(PokiPointTarget(point: point, element: element, row: row))
    }

    func pointTargetProblem(_ target: PokiPointTarget, in fresh: [Element],
                            foreground: Foreground, screen: ScreenSize) -> String? {
        guard let app = lastForeground?.bundleID, foreground.bundleID == app else {
            return "the foreground app changed or could not be confirmed"
        }
        let previous = PokiControlTargets(lastAll, screen: screen)
        let current = PokiControlTargets(fresh, screen: screen)
        guard let live = current.control(matching: target.element, at: target.point),
              current.annotation(for: live) == target.row,
              previous.identityProblem(for: target.element, matching: live, on: current) == nil else {
            return "the list item at this point changed or could not be confirmed"
        }
        guard current.canTouch(target.point, on: live) else {
            return "the control at this point is covered or outside its visible area"
        }
        return nil
    }

    private static func pointFromTap(_ tap: JSON) -> (x: Double, y: Double)? {
        if let pair = tap.array, pair.count >= 2, let x = pair[0].double, let y = pair[1].double {
            return (x, y)
        }
        if tap["ref"]?.int != nil { return nil }
        guard let x = tap["x"]?.double, let y = tap["y"]?.double else { return nil }
        return (x, y)
    }
}
