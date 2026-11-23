# Dot Bridge iOS integration

The unsigned External IPA uses the pinned `JosssphZhou/poki` revision `9184aca5b9368a81f37f4e611827072a94105fcb`. Build it with `bash scripts/build-ios-ipa.sh` from the bridge repository.

- `DotBridgeApp.swift` is the app entry point. It opens the connection screen, with iPhone setup and settings for approvals, notifications, signing, appearance, interface size, and language. Commands and conversation stay in ChatGPT.
- `SitesBridgeSettingsView.swift` handles pairing, turning iPhone control on and off, emergency stop, and foreground approval and handoff. Pairing stores credentials locally. Turning control on starts the automation runner and the Sites connection.
- `PokiCoreBridgeExecutor.swift` connects the app lifecycle and upstream automation to the standalone `PokiSitesBridge` package. The patch stops writing Poki's conversation and activity history; existing user data and operational diagnostics are preserved.
- `DotIslandViews.swift` gives the Live Activity its compact Dots mark and working or attention indicators. Once the current work finishes, the trailing status clears. The small mark stays available for subsequent requests that arrive while Poki is in the background.

The External project uses `project-external.yml`, with the `PokiWidgets` extension and without the VPN extension. The Shadowrocket route `10.7.0.1/32` remains necessary on that setup.

Poki is AGPL-3.0-only. Distribution of a modified IPA requires providing the corresponding source, including the bridge integration and build patches.
