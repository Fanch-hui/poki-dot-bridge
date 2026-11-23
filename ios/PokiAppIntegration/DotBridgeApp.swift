import SwiftUI
import UIKit

@main
struct PokiApp: App {
    @State private var model: AppModel

    init() {
        // The launcher can write to a socket after its peer has closed it.
        signal(SIGPIPE, SIG_IGN)
        if #available(iOS 26.0, *) { ContinuedRun.registerAtLaunch() }
        SettingsVault.restore()
        SettingsVault.watch()
        AppLocalization.publish()
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            DotBridgeHome()
                .environment(model)
                .environment(\.locale, AppLocalization.locale)
                .onChange(of: AppLocalization.shared.preference) { _, _ in
                    model.languageChanged()
                }
        }
    }
}

extension EnvironmentValues {
    @Entry var inDuoSplitView = false
}

private enum DotBridgeRoute: Hashable {
    case setup, settings, approvals
}

struct DotBridgeHome: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(Appearance.key) private var appearance = Appearance.automatic.rawValue
    @AppStorage(AppInterfaceSize.defaultsKey) private var interfaceSize = AppInterfaceSize.system
    @State private var path = NavigationPath()

    var body: some View {
        Group {
            if let message = model.signer.installMessage {
                UpdateFinishView(message: message, needsReopen: model.signer.needsReopen)
            } else {
                navigation
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                model.becameActive()
                model.startSigner()
                model.signer.maintain()
                Task { await model.verifyPairing() }
            } else if phase == .background {
                model.wentToBackground()
            }
        }
        .onChange(of: model.sitesBridge.isPaired) { _, isPaired in
            if !isPaired {
                model.stopSession()
            } else if scenePhase == .active {
                model.restoreDotAutomationIfNeeded()
            }
        }
        .onOpenURL(perform: open)
        .onChange(of: appearance, initial: true) { _, value in
            let style = (Appearance(rawValue: value) ?? .automatic).style
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                for window in scene.windows { window.overrideUserInterfaceStyle = style }
            }
        }
        .task(id: interfaceSize) {
            await Task.yield()
            guard !Task.isCancelled else { return }
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                for window in scene.windows { AppInterfaceSize.apply(interfaceSize, to: window) }
            }
        }
        .modifier(DotBridgeNotices())
    }

    private var navigation: some View {
        NavigationStack(path: $path) {
            SitesBridgeSettingsView(session: model.sitesBridge, deviceName: model.deviceName) {
                path.append(DotBridgeRoute.setup)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: DotBridgeRoute.settings) {
                        Image(systemName: "gearshape")
                            .accessibilityLabel(AppLocalization.text("Settings"))
                    }
                }
            }
            .navigationDestination(for: DotBridgeRoute.self) { route in
                switch route {
                case .setup: SetupChecklist()
                case .settings: preferences
                case .approvals: approvalPreferences
                }
            }
            .navigationDestination(for: SetupStep.self) { SetupStepPage(step: $0) }
        }
        .sheet(isPresented: Bindable(model.signer).needsCodeSheet) { VerificationCodeSheet() }
    }

    private var preferences: some View {
        Form {
            Section {
                NavigationLink(value: DotBridgeRoute.approvals) { Label("Approvals", systemImage: "checkmark.shield") }
                Button {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Notifications", systemImage: "bell")
                }
                NavigationLink { SigningUpdatesPage() } label: { Label("Signing & Updates", systemImage: "signature") }
            }
            Section {
                NavigationLink { AppearanceView() } label: { Label("Appearance", systemImage: "circle.lefthalf.filled") }
                NavigationLink { InterfaceSizeSettingsView() } label: { Label("Interface Size", systemImage: "textformat.size") }
                NavigationLink { LanguageSettingsView() } label: { Label("Language", systemImage: "globe") }
            }
        }
        .navigationTitle(AppLocalization.text("Settings"))
    }

    private var approvalPreferences: some View {
        Form {
            Section {
                Toggle("Ask before sensitive actions", isOn: Binding(
                    get: { model.approvalMode != .off },
                    set: { model.approvalMode = $0 ? .confirm : .off }
                ))
            } footer: {
                Text("Respond in Poki, a notification, or the Live Activity. Payments, deletions and actions in Wallet always need your confirmation.")
            }
        }
        .navigationTitle(AppLocalization.text("Approvals"))
    }

    private func open(_ url: URL) {
        guard !model.pairingUnderWay else { return }
        if url.isFileURL || url.scheme == "poki" && ["setup", "pairing"].contains(url.host() ?? "") {
            if let step = model.open(link: url) {
                path = NavigationPath()
                path.append(DotBridgeRoute.setup)
                path.append(step)
            } else if url.host() == "setup" {
                path = NavigationPath([DotBridgeRoute.setup])
            }
        } else if url.scheme == "poki", url.host() == "approvals" {
            path = model.approvals.isEmpty ? NavigationPath([DotBridgeRoute.approvals]) : NavigationPath()
        } else if url.scheme == "poki" {
            path = NavigationPath()
        }
    }
}

private struct DotBridgeNotices: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .alert("Poki Restarts to Turn On", isPresented: Bindable(model).relaunchNotice) {
                Button("Cancel", role: .cancel) {}
                Button("Continue") { model.continueRelaunch() }
            } message: {
                Text("Open Poki again afterwards, from the notification or the Home Screen.")
            }
            .alert("Enter Your Passcode Next", isPresented: Bindable(model).passcodeHeadsUp) {
                Button("Cancel", role: .cancel) { model.cancelPasscodeHeadsUp() }
                Button("Continue") { model.continueAfterPasscodeHeadsUp() }
            } message: {
                Text(AppModel.passcodeHeadsUpMessage)
            }
            .alert("Poki Will Close to Finish the Update", isPresented: Binding(
                get: { model.signer.finishNotice },
                set: { if !$0 { model.signer.finishNoticeAnswered() } }
            )) {
                Button("OK") { model.signer.finishNoticeAnswered() }
            } message: {
                Text("Open Poki again afterwards.")
            }
    }
}
