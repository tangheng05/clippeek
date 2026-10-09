import ClippeekCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var token = Keychain.token() ?? ""
    @State private var status = ""
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle("Send screenshots to clippeek", isOn: Binding(get: { model.captureOn }, set: { model.setCapture($0) }))
            } footer: {
                Text("Screenshots go to your clipboard and Zipline instead of the Desktop. Turning this off restores your previous screenshot settings.")
                    .foregroundStyle(.secondary)
            }
            Section("Zipline") {
                TextField("Server", text: $model.serverText, prompt: Text("zip.example.com"))
                SecureField("Token", text: $token)
                    .onSubmit { model.saveToken(token) }
                LabeledContent(status) {
                    Button("Save and Test") {
                        model.saveToken(token)
                        Task { status = await model.testConnection() }
                    }
                }
                Picker("Delete from server after", selection: $model.expiry) {
                    Text("Never").tag(Expiry.never)
                    Text("1 day").tag(Expiry.oneDay)
                    Text("7 days").tag(Expiry.sevenDays)
                    Text("30 days").tag(Expiry.thirtyDays)
                }
                Toggle("Copy the link after each upload", isOn: $model.copyLinkAfterUpload)
            }
            Section {
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in
                        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                        openAtLogin = SMAppService.mainApp.status == .enabled
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}
