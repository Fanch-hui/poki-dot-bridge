import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Monochrome-first palette for the Dot Live Activity, with orange reserved for attention/timers
/// and red reserved for Stop and error states.
struct DotActivityPalette {
    let mark: Color
    let text: Color
    let secondary: Color
    let accent: Color
    let attention: Color
    let danger: Color
    let primaryFill: Color
    let primaryText: Color
    let secondaryFill: Color
    let track: Color
    let trackFill: Color
    let stopRing: Color
    let thumbnailBorder: Color

    static func lockScreen(dark: Bool) -> DotActivityPalette {
        DotActivityPalette(
            mark: dark ? DotMark.silver : Color.primary.opacity(0.82),
            text: .primary,
            secondary: .secondary,
            accent: .primary,
            attention: .orange,
            danger: ActivityTheme.red,
            primaryFill: dark ? .white : .primary,
            primaryText: dark ? Color(hex: 0x111111) : .white,
            secondaryFill: Color.primary.opacity(dark ? 0.14 : 0.10),
            track: Color.primary.opacity(dark ? 0.18 : 0.14),
            trackFill: Color.primary.opacity(dark ? 0.85 : 0.78),
            stopRing: Color.primary.opacity(dark ? 0.88 : 0.78),
            thumbnailBorder: Color.primary.opacity(0.18)
        )
    }

    static let island = DotActivityPalette(
        mark: DotMark.silver,
        text: .white,
        secondary: ActivityTheme.secondary,
        accent: .white.opacity(0.88),
        attention: .orange,
        danger: ActivityTheme.red,
        primaryFill: .white,
        primaryText: Color(hex: 0x111111),
        secondaryFill: .white.opacity(0.18),
        track: .white.opacity(0.18),
        trackFill: .white.opacity(0.88),
        stopRing: .white.opacity(0.92),
        thumbnailBorder: .white.opacity(0.22)
    )

    func color(_ tone: ActivityTone) -> Color {
        switch tone {
        case .quiet, .reason: return secondary
        case .plain: return text
        case .accent, .done: return accent
        case .approval: return attention
        case .problem: return danger
        }
    }
}

private func hasBottomActionRow(for face: ActivityFace) -> Bool {
    switch face.bottom {
    case .approval, .deciding, .handoff, .openPoki, .segments:
        return true
    case .none:
        return face.endsTalk
    case .progress:
        return false
    }
}

/// Native translucent glass Lock Screen card without opaque blue fills or caller badges.
struct DotLockScreenCard: View {
    let face: ActivityFace
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isLuminanceReduced) private var dimmed

    var body: some View {
        let palette = DotActivityPalette.lockScreen(dark: scheme == .dark || dimmed)
        let shot = face.thumbnail == .none ? nil : Thumbnail.picture
        DotActivityContent(
            face: face,
            surface: .lockScreen,
            palette: palette,
            meta: face.lockMeta ?? face.meta,
            shot: shot
        )
        .padding(.horizontal, 18)
        .padding(.vertical, hasBottomActionRow(for: face) && face.offersStopAsking ? 14 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(palette.text)
        .animation(dimmed ? nil : ActivityMotion.phase, value: face.bear)
        .animation(dimmed ? nil : ActivityMotion.step, value: face.content)
        .accessibilityElement(children: .contain)
    }
}

struct DotIslandExpandedLeading: View {
    var body: some View { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
}

struct DotIslandExpandedTrailing: View {
    var body: some View { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
}

/// Unclipped, vertically centered expanded Dynamic Island content kept clear of iOS corner insets.
struct DotIslandExpandedBottom: View {
    let face: ActivityFace
    @Environment(\.isLuminanceReduced) private var dimmed

    var body: some View {
        let twoRow = hasBottomActionRow(for: face)
        let topPad: CGFloat = twoRow ? (face.offersStopAsking ? 0 : 6) : 2
        let bottomPad: CGFloat = twoRow
            ? (face.offersStopAsking ? 15 : 18)
            : (face.bottom.isProgress || face.hasKicker ? 34 : 36)
        let horizPad: CGFloat = twoRow ? (face.offersStopAsking ? 24 : 22) : 24
        DotActivityContent(
            face: face,
            surface: .island,
            palette: DotActivityPalette.island,
            meta: face.meta,
            shot: nil
        )
        .padding(.leading, horizPad + 4)
        .padding(.trailing, horizPad)
        .padding(.top, topPad)
        .padding(.bottom, bottomPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(DotActivityPalette.island.text)
        .environment(\.colorScheme, .dark)
        .animation(dimmed ? nil : ActivityMotion.phase, value: face.bear)
        .animation(dimmed ? nil : ActivityMotion.step, value: face.content)
        .accessibilityElement(children: .contain)
    }
}

private struct DotActivityContent: View {
    let face: ActivityFace
    let surface: ActivitySurface
    let palette: DotActivityPalette
    let meta: ActivityFace.Meta
    let shot: UIImage?

    private var textAlignment: Alignment { surface == .island ? .center : .leading }

    var body: some View {
        if hasBottomActionRow(for: face) {
            twoRowBody
        } else {
            singleRowBody
        }
    }

    private var singleRowBody: some View {
        let ringSize: CGFloat = surface == .lockScreen ? 36 : 44
        let buttonSize: CGFloat = surface == .lockScreen ? 34 : 38
        let inlineMeta = (surface == .island && face.bottom.isProgress && meta != .none) ? meta : nil
        return HStack(alignment: .center, spacing: 14) {
            DotRingView(diameter: ringSize, color: palette.mark)
            DotTextStack(face: face, palette: palette, surface: surface, maxSubtitleLines: face.subtitleLines, inlineMeta: inlineMeta)
                .frame(maxWidth: .infinity, alignment: textAlignment)
            if case .progress(_, let stop) = face.bottom {
                HStack(spacing: 10) {
                    if surface == .lockScreen, meta != .none { DotMetaView(meta: meta, palette: palette) }
                    if face.endsTalk { DotEndTalkCircleButton(size: buttonSize, palette: palette) }
                    if stop { DotStopCircleButton(size: buttonSize, palette: palette) }
                }
            } else if meta != .none {
                DotMetaView(meta: meta, palette: palette)
            }
            if let shot {
                DotThumbnailView(image: shot, size: CGSize(width: 30, height: 62), corner: 6, border: palette.thumbnailBorder)
            }
        }
    }

    private var twoRowBody: some View {
        let spacing: CGFloat = surface == .island ? (face.offersStopAsking ? 6 : 10) : (face.offersStopAsking ? 10 : 12)
        return VStack(alignment: .leading, spacing: spacing) {
            HStack(alignment: .center, spacing: 12) {
                DotRingView(diameter: surface == .lockScreen ? 34 : 38, color: palette.mark)
                DotTextStack(
                    face: face,
                    palette: palette,
                    surface: surface,
                    maxSubtitleLines: face.offersStopAsking ? 1 : face.subtitleLines,
                    inlineMeta: nil
                )
                .frame(maxWidth: .infinity, alignment: textAlignment)
                if meta != .none { DotMetaView(meta: meta, palette: palette) }
                if let shot {
                    DotThumbnailView(image: shot, size: CGSize(width: 26, height: 52), corner: 5, border: palette.thumbnailBorder)
                }
            }
            DotActionRow(face: face, palette: palette, compactSpacing: face.offersStopAsking)
        }
    }
}

private struct DotRingView: View {
    let diameter: CGFloat
    let color: Color

    var body: some View {
        DotMark()
            .fill(color, style: FillStyle(eoFill: true))
            .frame(width: diameter, height: diameter)
            .accessibilityHidden(true)
    }
}

private struct DotTextStack: View {
    let face: ActivityFace
    let palette: DotActivityPalette
    let surface: ActivitySurface
    let maxSubtitleLines: Int
    let inlineMeta: ActivityFace.Meta?

    var body: some View {
        VStack(alignment: surface == .island ? .center : .leading, spacing: 2) {
            if face.hasKicker || inlineMeta != nil {
                HStack(spacing: 6) {
                    if face.hasKicker { DotKickerRow(face: face, palette: palette) }
                    if let inlineMeta {
                        Spacer(minLength: 4)
                        DotMetaView(meta: inlineMeta, palette: palette)
                    }
                }
            }
            DotTitleText(face: face, palette: palette, surface: surface)
            if face.subtitle != nil {
                DotSubtitleText(face: face, palette: palette, maxLines: maxSubtitleLines)
            }
            if face.bottom.hasLine {
                DotRunLine(palette: palette).padding(.top, 5)
            }
        }
        .multilineTextAlignment(surface == .island ? .center : .leading)
    }
}

private struct DotKickerRow: View {
    let face: ActivityFace
    let palette: DotActivityPalette

    var body: some View {
        HStack(spacing: 6) {
            if let kicker = face.kicker {
                Text(kicker)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(face.bottom.isApproval ? palette.attention : palette.secondary)
                    .contentTransition(.numericText())
                    .layoutPriority(1)
            }
            if let word = face.event {
                Text(word)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.color(face.eventTone))
                    .contentTransition(.interpolate)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

private struct DotTitleText: View {
    let face: ActivityFace
    let palette: DotActivityPalette
    let surface: ActivitySurface

    var body: some View {
        if face.contentIsCode {
            Text(face.content)
                .font(.system(size: 34, weight: .bold).monospacedDigit())
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
        } else {
            Text(face.content)
                .font(.system(size: surface == .lockScreen ? 17 : 18, weight: .semibold))
                .foregroundStyle(palette.text.opacity(face.stale ? 0.72 : 1))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .contentTransition(.interpolate)
        }
    }
}

private struct DotSubtitleText: View {
    let face: ActivityFace
    let palette: DotActivityPalette
    let maxLines: Int

    var body: some View {
        if let subtitle = face.subtitle {
            Text(subtitle)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(palette.secondary)
                .lineLimit(max(1, maxLines))
                .minimumScaleFactor(0.88)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.interpolate)
        }
    }
}

private struct DotMetaView: View {
    let meta: ActivityFace.Meta
    let palette: DotActivityPalette

    var body: some View {
        switch meta {
        case .none:
            EmptyView()
        case .text(let text):
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        case .countdown(let until):
            // Fixed width without fixedSize() avoids blank Live Activity rendering on iOS 26+.
            Text(timerInterval: Countdown.range(until), countsDown: true)
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(palette.attention)
                .multilineTextAlignment(.trailing)
                .frame(width: 46, alignment: .trailing)
        case .clock(let date):
            Text(date, style: .time)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(palette.secondary)
                .lineLimit(1)
        case .elapsed(let since):
            Text(timerInterval: since...since.addingTimeInterval(12 * 3600), countsDown: false)
                .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(palette.secondary)
                .multilineTextAlignment(.trailing)
                .frame(width: 46, alignment: .trailing)
        case .symbol(let name, let tone):
            if tone == .problem {
                Image(systemName: name)
                    .font(.system(size: 16, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, palette.danger)
            } else {
                Image(systemName: name)
                    .font(.system(size: name == "checkmark" ? 15 : 16, weight: .semibold))
                    .foregroundStyle(palette.color(tone))
                    .contentTransition(.symbolEffect(.replace))
            }
        }
    }
}

private struct DotRunLine: View {
    let palette: DotActivityPalette

    var body: some View {
        GeometryReader { box in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.track)
                LinearGradient(
                    colors: [palette.trackFill.opacity(0), palette.trackFill, palette.trackFill.opacity(0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: (box.size.width * 0.34).rounded())
                .clipShape(.capsule)
                .offset(x: box.size.width * 0.28)
            }
        }
        .frame(height: 3)
        .clipShape(.capsule)
        .accessibilityHidden(true)
    }
}

private struct DotSegmentLine: View {
    let step: Int
    let total: Int
    let palette: DotActivityPalette

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...max(1, total), id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(index <= step ? palette.trackFill : palette.track)
                    .frame(height: 3.5)
            }
        }
        .animation(ActivityMotion.step, value: step)
        .accessibilityHidden(true)
    }
}

private struct DotStopCircleButton: View {
    let size: CGFloat
    let palette: DotActivityPalette

    var body: some View {
        Button(intent: StopRunnerIntent()) {
            ZStack {
                Circle().strokeBorder(palette.stopRing, lineWidth: max(1.5, size * 0.055))
                RoundedRectangle(cornerRadius: size * 0.1, style: .continuous)
                    .fill(palette.danger)
                    .frame(width: size * 0.36, height: size * 0.36)
            }
            .frame(width: size, height: size)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(activity: "Stop")))
    }
}

private struct DotEndTalkCircleButton: View {
    let size: CGFloat
    let palette: DotActivityPalette

    var body: some View {
        Button(intent: EndTalkIntent()) {
            Image(systemName: "mic.slash.fill")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(palette.text)
                .frame(width: size, height: size)
                .background(palette.secondaryFill, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(activity: "End talk")))
    }
}

private struct DotActionRow: View {
    let face: ActivityFace
    let palette: DotActivityPalette
    let compactSpacing: Bool

    var body: some View {
        let buttonHeight: CGFloat = compactSpacing ? 34 : 36
        switch face.bottom {
        case .approval(let id):
            approvalRow(id: id, buttonHeight: buttonHeight)
        case .deciding(let text):
            Text(text)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: buttonHeight, maxHeight: buttonHeight)
                .background(palette.secondaryFill, in: .capsule)
                .contentTransition(.interpolate)
        case .handoff(let id):
            Button(intent: HandoffDoneIntent(handoffID: id)) {
                Text(String(activity: "Continue"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, minHeight: buttonHeight, maxHeight: buttonHeight)
                    .background(palette.primaryFill, in: .capsule)
            }
            .buttonStyle(.plain)
            .transition(.activityRow)
        case .openPoki:
            Link(destination: face.link) {
                Text(String(activity: "Open Poki"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .frame(maxWidth: .infinity, minHeight: buttonHeight, maxHeight: buttonHeight)
                    .background(palette.secondaryFill, in: .capsule)
            }
            .transition(.activityRow)
        case .segments(let number, let count):
            DotSegmentLine(step: number, total: count, palette: palette).transition(.activityRow)
        case .none:
            if face.endsTalk { endTalkButton(height: buttonHeight) }
        case .progress:
            EmptyView()
        }
    }

    private func approvalRow(id: String, buttonHeight: CGFloat) -> some View {
        VStack(spacing: compactSpacing ? 3 : 4) {
            HStack(spacing: 8) {
                Button(intent: DenyActionIntent(approvalID: id)) {
                    Text(String(activity: "Don’t Allow"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, minHeight: buttonHeight, maxHeight: buttonHeight)
                        .background(palette.secondaryFill, in: .capsule)
                }
                .buttonStyle(.plain)

                Button(intent: ApproveActionIntent(approvalID: id)) {
                    HStack(spacing: 5) {
                        Image(systemName: "faceid").font(.system(size: 13, weight: .semibold))
                        Text(String(activity: "Allow")).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    }
                    .foregroundStyle(palette.primaryText)
                    .frame(maxWidth: .infinity, minHeight: buttonHeight, maxHeight: buttonHeight)
                    .background(palette.primaryFill, in: .capsule)
                }
                .buttonStyle(.plain)
            }
            if face.offersStopAsking {
                Button(intent: StopAskingIntent(approvalID: id)) {
                    Text(String(activity: "Don’t ask again"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 16, maxHeight: 16)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .transition(.activityRow)
    }

    private func endTalkButton(height: CGFloat) -> some View {
        Button(intent: EndTalkIntent()) {
            HStack(spacing: 6) {
                Image(systemName: "mic.slash.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(palette.danger)
                Text(String(activity: "End")).font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(palette.text)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .background(palette.secondaryFill, in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(activity: "End talk")))
        .transition(.opacity)
    }
}

private struct DotThumbnailView: View {
    let image: UIImage
    let size: CGSize
    let corner: CGFloat
    let border: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(border, lineWidth: 0.5))
    }
}
