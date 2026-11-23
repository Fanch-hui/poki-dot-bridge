"""Connect custom popup accessibility markers and screenshot OCR to PokiCore reads."""

from pathlib import Path
from shutil import copy2

from patch_poki_ui import replace_once


def patch_overlay(bridge_root: Path, core: Path) -> None:
    source = core / "Sources/PokiCore"
    copy2(bridge_root / "ios/PokiAppIntegration/PokiOverlay.swift", source)
    tests = core / "Tests/PokiCoreTests"
    if tests.is_dir():
        copy2(bridge_root / "ios/PokiAppIntegration/PokiOverlayTests.swift", tests)
    computer = source / "Computer.swift"
    replace_once(
        computer,
        """        var notes = reading.notes
        if let modal = modalOnly(reading.elements) { notes.append(modal) }""",
        """        var notes = reading.notes
        let popup = size.flatMap { PokiOverlay.detect(in: reading.elements, screen: $0) }
        var popupTexts: [RecognizedText]?
        if let popup {
            reading.elements = popup.foreground(reading.elements)
            notes.append("popup detected; controls behind it are hidden")
            if let png = reading.png {
                let host = self.host
                let left = min(3.5, until - now() - 0.6)
                if left >= 0.3 {
                    popupTexts = (try? await withDeadline(left, "reading popup controls", { await host.recognizeText(inPNG: png) })) ?? nil
                }
            }
            if let texts = popupTexts, let close = popup.closeControl(in: texts) {
                reading.elements.append(close)
            } else {
                notes.append("popup close control could not be identified; inspect the screenshot")
            }
        }
        if let modal = modalOnly(reading.elements) { notes.append(modal) }""",
        "PokiCore popup foreground",
    )
    replace_once(
        computer,
        """            if let texts = (try? await withDeadline(left, "reading text from the picture", { await host.recognizeText(inPNG: png) })) ?? nil {
                // Each text goes right after the collapsed element it lies in, top to bottom.""",
        """            let texts: [RecognizedText]?
            if popup != nil {
                // OCR also sees dimmed text behind custom popups; the screenshot
                // carries visual detail while the foreground tree remains authoritative.
                texts = []
            } else {
                texts = (try? await withDeadline(left, "reading text from the picture", { await host.recognizeText(inPNG: png) })) ?? nil
            }
            if let texts {
                // Each text goes right after the collapsed element it lies in, top to bottom.""",
        "PokiCore exclude covered screenshot OCR",
    )
    replace_once(
        computer,
        """        if config.sensitive.enabled {
            var scan = SensitiveScan(front: lastForeground, secureOnScreen: lastElements.contains(where: \\.isSecure))""",
        """        let popupClose = actions.flatMap(Self.refs(in:)).compactMap { refs[$0] }.first(where: \\.isPopupClose)
        if let close = popupClose {
            guard actions.count == 1, let tap = actions[0]["tap"], target(tap) == close else {
                return await readAndReply(until: until, full: true, error: "popup close control could not be confirmed on the current screen; nothing was sent")
            }
        }

        if config.sensitive.enabled {
            var scan = SensitiveScan(front: lastForeground, secureOnScreen: lastElements.contains(where: \\.isSecure))""",
        "PokiCore reject batched popup close",
    )
    replace_once(
        computer,
        """        let actionsStarted = now()
        let approved = approvedNote == nil ? [:] : Dictionary(steps.map { ($0.at, $0.reason) }, uniquingKeysWith: { a, _ in a })""",
        """        if let close = popupClose, !(await popupCloseStillVisible(close, until: until)) {
            return await readAndReply(until: until, full: true, error: "popup close control could not be confirmed on the current screen; nothing was sent")
        }
        let actionsStarted = now()
        let approved = approvedNote == nil ? [:] : Dictionary(steps.map { ($0.at, $0.reason) }, uniquingKeysWith: { a, _ in a })""",
        "PokiCore recheck popup close before touch",
    )
