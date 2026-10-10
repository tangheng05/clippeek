import AppKit
import ClippeekCore
import ServiceManagement
import SwiftUI

enum SettingsTabs {
    enum Pane: CaseIterable {
        case general, screenshots, recordings, server

        var title: String {
            switch self {
            case .general: "General"
            case .screenshots: "Screenshots"
            case .recordings: "Recordings"
            case .server: "Server"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .screenshots: "camera.viewfinder"
            case .recordings: "record.circle"
            case .server: "server.rack"
            }
        }
    }

    @MainActor
    static func controller(model: AppModel) -> NSTabViewController {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for pane in Pane.allCases {
            let hosting: NSViewController = switch pane {
            case .general: host(GeneralPane())
            case .screenshots: host(ScreenshotsPane(model: model))
            case .recordings: host(RecordingsPane(model: model))
            case .server: host(ServerPane(model: model))
            }
            // The toolbar tabs title the window after the selected pane's controller.
            hosting.title = pane.title
            let item = NSTabViewItem(viewController: hosting)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        return tabs
    }

    @MainActor
    private static func host(_ view: some View) -> NSViewController {
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = .preferredContentSize
        return hosting
    }
}

private extension View {
    func pane() -> some View {
        formStyle(.grouped)
            .frame(width: 460)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private func expiryPicker(_ selection: Binding<Expiry>) -> some View {
    Picker("Delete from server after", selection: selection) {
        Text("Never").tag(Expiry.never)
        Text("1 day").tag(Expiry.oneDay)
        Text("7 days").tag(Expiry.sevenDays)
        Text("30 days").tag(Expiry.thirtyDays)
    }
}

@MainActor
func captureBinding(_ kind: CaptureKind, _ model: AppModel) -> Binding<Bool> {
    Binding(get: { model.isCapturing(kind) }, set: { model.setCapture(kind, $0) })
}

struct OpenAtLoginToggle: View {
    @State private var status: SMAppService.Status

    init(status: SMAppService.Status = SMAppService.mainApp.status) {
        _status = State(initialValue: status)
    }

    var body: some View {
        Toggle("Open clippeek at login", isOn: Binding(get: { status == .enabled || status == .requiresApproval }, set: { on in
            if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
            status = SMAppService.mainApp.status
        }))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = SMAppService.mainApp.status
        }
        if status == .requiresApproval {
            HStack {
                Text("Allow clippeek in System Settings → Login Items.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Open…") { SMAppService.openSystemSettingsLoginItems() }
                    .controlSize(.small)
            }
        }
    }
}

struct GeneralPane: View {
    var loginStatus = SMAppService.mainApp.status

    var body: some View {
        Form {
            OpenAtLoginToggle(status: loginStatus)
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                LabeledContent("Version", value: version)
            }
        }
        .pane()
    }
}

struct ScreenshotsPane: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Send screenshots to clippeek", isOn: captureBinding(.screenshot, model))
                Group {
                    expiryPicker($model.expiry)
                    Toggle("Copy the link after each upload", isOn: $model.copyLinkAfterUpload)
                }
                .disabled(!model.isCapturing(.screenshot))
            } footer: {
                Text("Screenshots go to your clipboard and Zipline instead of the Desktop. Turning this off restores your previous screenshot settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .pane()
    }
}

struct RecordingsPane: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Send screen recordings to clippeek", isOn: captureBinding(.video, model))
                Group {
                    expiryPicker($model.expiryVideo)
                    Toggle("Copy the link after each upload", isOn: $model.copyLinkVideo)
                    Toggle("Notify after each upload", isOn: $model.notifyVideo)
                }
                .disabled(!model.isCapturing(.video))
            } footer: {
                Text("Recordings upload when they finish and are removed from this Mac. Zipline allows 100 MB per file by default; raise \"Max file size\" in its settings for longer videos.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .pane()
    }
}

struct ServerPane: View {
    @Bindable var model: AppModel
    @State private var token: String
    @State private var status: ConnectionStatus?
    @State private var testing = false

    init(model: AppModel, token: String? = nil) {
        self.model = model
        _token = State(initialValue: token ?? model.token ?? "")
    }

    var body: some View {
        Form {
            Section {
                TextField("Server", text: $model.serverText, prompt: Text("zip.example.com"))
                    .onChange(of: model.serverText) { status = nil }
                LabeledContent("Token") {
                    // A long token would otherwise run into its label.
                    SecureField("Token", text: $token, prompt: Text("Paste from Zipline"))
                        .labelsHidden()
                        .frame(maxWidth: 240)
                        .onChange(of: token) { status = nil }
                        .onChange(of: model.token) { _, saved in if token.isEmpty { token = saved ?? "" } }
                        .onSubmit(saveAndTest)
                }
                HStack {
                    connectionStatus
                    Spacer()
                    Button("Save and Test", action: saveAndTest)
                        .disabled(testing || token.isEmpty || model.serverText.isEmpty)
                }
            } footer: {
                Text("Find your token in Zipline under your name, then Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .pane()
    }

    @ViewBuilder
    private var connectionStatus: some View {
        if testing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing…").foregroundStyle(.secondary)
            }
        } else if let status {
            Label(status.message, systemImage: status.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(status.ok ? .green : .orange)
        }
    }

    private func saveAndTest() {
        guard !testing else { return }
        testing = true
        Task {
            status = await model.connect(token: token)
            testing = false
        }
    }
}
