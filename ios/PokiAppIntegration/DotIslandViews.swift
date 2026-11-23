import SwiftUI

/// The generic Dots mark, following OpenAI's published Dots vector.
struct DotMark: Shape {
    static let silver = Color(red: 186 / 255, green: 193 / 255, blue: 211 / 255)

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let outer = CGRect(
            x: rect.midX - side / 2,
            y: rect.midY - side / 2,
            width: side,
            height: side
        )
        let innerSide = side * (31.6797 / 80.0781)
        let inner = CGRect(
            x: rect.midX - innerSide / 2,
            y: rect.midY - innerSide / 2,
            width: innerSide,
            height: innerSide
        )
        var path = Path()
        path.addEllipse(in: outer)
        path.addEllipse(in: inner)
        return path
    }
}

struct DotActivityMark: View {
    let side: CGFloat

    var body: some View {
        DotMark()
            .fill(DotMark.silver, style: FillStyle(eoFill: true))
            .frame(width: min(side * 0.58, 70), height: min(side * 0.58, 70))
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }
}

private struct DotIslandMark: View {
    var body: some View {
        DotMark()
            .fill(DotMark.silver, style: FillStyle(eoFill: true))
            .frame(width: 20, height: 20)
            .frame(width: 30, height: 30)
            .accessibilityLabel("Dot")
    }
}

struct DotIslandLeading: View {
    var body: some View {
        DotIslandMark()
    }
}

struct DotIslandMinimal: View {
    var body: some View {
        DotIslandMark()
    }
}

struct DotIslandTrailing: View {
    let state: PokiState
    let face: ActivityFace
    let isStale: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var dimmed

    var body: some View {
        if state.phase == .pairing, state.pin != nil {
            CompactTrailing(face: face)
        } else if state.phase == .approval, let approval = state.approval {
            if isStale {
                statusText(ActivityWords.local("Timed out"))
            } else {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(String(activity: "Allow?"))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(timerInterval: Countdown.range(approval.expires), countsDown: true)
                        .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 42, alignment: .trailing)
                }
                .foregroundStyle(statusColor)
                .frame(width: 50, height: 30, alignment: .trailing)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(activity: "Needs your confirmation"))
            }
        } else if state.phase == .deciding {
            statusText(String(activity: "Sending decision"))
        } else if let symbol {
            statusIcon(symbol)
                .foregroundStyle(statusColor)
                .frame(height: 30)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(face.content)
        }
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(statusColor)
            .frame(width: 50, height: 30, alignment: .trailing)
    }

    @ViewBuilder
    private func statusIcon(_ symbol: String) -> some View {
        let image = Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .frame(width: 20, height: 24)
        if reduceMotion || dimmed {
            image
        } else {
            image
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.pulse, value: state.headline)
                .animation(.easeInOut(duration: 0.25), value: symbol)
        }
    }

    private var statusColor: Color {
        if isStale && [.working, .approval, .handoff].contains(state.phase) {
            return .orange
        }
        switch state.phase {
        case .approval, .handoff, .problem:
            return .orange
        default:
            return .white
        }
    }

    private var symbol: String? {
        if isStale && [.working, .approval, .handoff].contains(state.phase) {
            return "clock.badge.exclamationmark"
        }
        switch state.phase {
        case .working:
            let action = state.headline.lowercased()
            if action.hasPrefix("look") || action.hasPrefix("read") { return "eye" }
            if action.hasPrefix("tap") || action.hasPrefix("press") { return "hand.tap.fill" }
            if action.hasPrefix("type") { return "keyboard" }
            if action.hasPrefix("scroll") || action.hasPrefix("swipe") || action.hasPrefix("drag") {
                return "hand.draw.fill"
            }
            if action.hasPrefix("open") { return "app.fill" }
            if action.hasPrefix("wait") { return "hourglass" }
            return "sparkles"
        case .approval, .deciding:
            return "hand.raised.fill"
        case .handoff:
            return "person.fill"
        case .problem:
            return "exclamationmark.triangle.fill"
        case .pairing, .setup:
            return "gearshape.fill"
        case .done:
            return isStale ? nil : "checkmark"
        case .idle, .stopped:
            // Keep the activity alive so a later background request can show its status.
            return nil
        }
    }
}
