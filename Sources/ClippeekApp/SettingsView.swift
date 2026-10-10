import ClippeekCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var token: String
    @State private var status: ConnectionStatus?
    @State private var testing = false
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    init(model: AppModel, token: String? = nil) {
        self.model = model
        _token = State(initialValue: token ?? model.token ?? "")
    }

    var body: some View {
        Form {
            Section {
                Toggle("Send screenshots to clippeek", isOn: capture(.screenshot))
                expiryPicker($model.expiry)
                Toggle("Copy the link after each upload", isOn: $model.copyLinkAfterUpload)
            } header: {
                Text("Screenshots")
            } footer: {
                Text("Screenshots go to your clipboard and Zipline instead of the Desktop. Turning this off restores your previous screenshot settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Send screen recordings to clippeek", isOn: capture(.video))
                expiryPicker($model.expiryVideo)
                Toggle("Copy the link when uploaded", isOn: $model.copyLinkVideo)
                Toggle("Notify when uploaded", isOn: $model.notifyVideo)
            } header: {
                Text("Screen recordings")
            } footer: {
                Text("Recordings upload when they finish and are removed from this Mac. Zipline allows 100 MB per file by default; raise \"Max file size\" in its settings for longer videos.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Zipline") {
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
            }
            Section("General") {
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in
                        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                        openAtLogin = SMAppService.mainApp.status == .enabled
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
    }

    private func capture(_ kind: CaptureKind) -> Binding<Bool> {
        Binding(get: { model.isCapturing(kind) }, set: { model.setCapture(kind, $0) })
    }

    private func expiryPicker(_ selection: Binding<Expiry>) -> some View {
        Picker("Delete from server after", selection: selection) {
            Text("Never").tag(Expiry.never)
            Text("1 day").tag(Expiry.oneDay)
            Text("7 days").tag(Expiry.sevenDays)
            Text("30 days").tag(Expiry.thirtyDays)
        }
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
        model.saveToken(token)
        testing = true
        Task {
            status = await model.testConnection()
            testing = false
        }
    }
}
