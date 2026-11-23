import PokiSitesBridge
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct SitesBridgeSettingsView: View {
    @Environment(AppModel.self) private var model
    let session: PokiSitesBridgeSession
    let deviceName: String
    let openSetup: () -> Void

    @AppStorage("poki.sites.lastUrl") private var sitesURL = ""
    @State private var pairingCode = ""
    @State private var siwcBypassToken = ""
    @State private var rotateToken = ""
    @State private var confirmingUnpair = false

    init(session: PokiSitesBridgeSession, deviceName: String, openSetup: @escaping () -> Void) {
        self.session = session
        self.deviceName = deviceName
        self.openSetup = openSetup
    }

    var body: some View {
        Form {
            statusSection
            ownerActionSection
            if session.isPaired {
                automationSection
                deviceDetailsSection
            } else {
                pairingSection
                Section {
                    Button(action: openSetup) { Label("iPhone Setup", systemImage: "iphone") }
                }
            }
            if let error = connectionError {
                Section {
                    Label {
                        Text(verbatim: error)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle(AppLocalization.text("Dot Bridge"))
        .confirmationDialog("Unpair from Dot?", isPresented: $confirmingUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) {
                model.stopSession()
                session.unpair()
            }
        } message: {
            Text("You’ll need a new pairing code to connect again.")
        }
    }

    private var connectionError: String? {
        let developerToolsError = model.developerToolsFailure.map { AppLocalization.text($0) }
        return session.pairingError ?? developerToolsError ?? model.problem ?? session.snapshot.lastError
    }

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: statusIconName)
                    .font(.title3)
                    .foregroundStyle(statusColor)
                    .accessibilityHidden(true)
                Text(statusTitle)
                    .font(.headline)
                Spacer()
                if session.snapshot.activeTaskId != nil {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        } footer: {
            if session.snapshot.state == .emergencyStopped {
                Text("Turn on iPhone control and ask Dot to resume before sending more commands.")
            } else {
                Text("Send commands to your dot in ChatGPT.")
            }
        }
    }

    @ViewBuilder private var ownerActionSection: some View {
        ForEach(model.approvals, id: \.id) { approval in
            Section {
                Text(approval.summary)
                Button("Allow") { model.resolve(approval, approved: true) }
                Button("Don’t Allow", role: .destructive) { model.resolve(approval, approved: false) }
            } header: {
                Text(approval.question)
            }
        }
        if let handoff = model.handoffText {
            Section("Your Turn") {
                Text(verbatim: handoff)
                Button("Done") { model.handoffDoneInApp() }
            }
        }
    }

    private var pairingSection: some View {
        Section("Pair with Dot") {
            TextField("Site URL", text: $sitesURL, prompt: Text("https://your-site.chatgpt.site"))
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Pairing Code", text: $pairingCode, prompt: Text("XXXX-XXXX-XXXX"))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.body.monospaced())
            DisclosureGroup("Connection Details") {
                SecureField("Site Access Token", text: $siwcBypassToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Button {
                Task {
                    await session.pair(
                        sitesURL: sitesURL,
                        pairingCode: pairingCode,
                        deviceName: deviceName,
                        siwcBypassToken: siwcBypassToken
                    )
                    if session.isPaired {
                        pairingCode = ""
                        siwcBypassToken = ""
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text("Pair")
                    if session.isPairing {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(
                session.isPairing ||
                sitesURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).count < 8
            )
        }
    }

    private var deviceDetailsSection: some View {
        Section("Connection Details") {
            LabeledContent("Site", value: sitesURL)
                .font(.footnote.monospaced())
            if let deviceId = session.snapshot.deviceId {
                Button {
                    #if canImport(UIKit)
                    UIPasteboard.general.string = deviceId
                    #endif
                } label: {
                    LabeledContent("Device", value: deviceId)
                        .font(.footnote.monospaced())
                }
                .foregroundStyle(.primary)
            }
            DisclosureGroup("Site Access Token") {
                SecureField("New Site Access Token", text: $rotateToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save Token") {
                    Task {
                        await session.updateSIWCBypassToken(rotateToken)
                        if session.pairingError == nil { rotateToken = "" }
                    }
                }
                .disabled(rotateToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Button("Unpair", role: .destructive) { confirmingUnpair = true }
        }
    }

    private var automationSection: some View {
        Section("iPhone Control") {
            Toggle("Allow Dot to Control This iPhone", isOn: Binding(
                get: { model.sessionOn || model.sessionStarting },
                set: { if $0 { model.startSession() } else { model.stopSession() } }
            ))
            Button(action: openSetup) { Label("iPhone Setup", systemImage: "iphone") }
            if model.sessionOn || model.sessionStarting {
                Button(role: .destructive) {
                    session.triggerEmergencyStop()
                } label: {
                    Label("Emergency Stop", systemImage: "hand.raised")
                }
            }
        }
    }

    private var statusIconName: String {
        switch session.snapshot.state {
        case .online: return "checkmark.circle.fill"
        case .connecting: return "arrow.triangle.2.circlepath.circle.fill"
        case .offline: return "wifi.slash"
        case .emergencyStopped: return "hand.raised.circle.fill"
        case .revoked: return "xmark.shield.fill"
        case .stopped, .unpaired: return "circle.dashed"
        }
    }

    private var statusColor: Color {
        switch session.snapshot.state {
        case .online: return .green
        case .connecting: return .blue
        case .offline: return .orange
        case .emergencyStopped, .revoked: return .red
        case .stopped, .unpaired: return .secondary
        }
    }

    private var statusTitle: LocalizedStringKey {
        switch session.snapshot.state {
        case .online:
            if !model.sessionOn { return "Paired · Control Off" }
            return session.snapshot.activeTaskId != nil ? "Dot Is Working" : "Ready for Dot"
        case .connecting: return "Connecting"
        case .offline: return "Offline"
        case .emergencyStopped: return "Emergency Stop Is On"
        case .revoked: return "Pairing Revoked"
        case .stopped: return "Paired · Control Off"
        case .unpaired: return "Unpaired"
        }
    }
}
