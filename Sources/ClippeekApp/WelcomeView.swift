import AppKit
import ClippeekCore
import ServiceManagement
import SwiftUI

struct WelcomeView: View {
    @Bindable var model: AppModel
    let done: () -> Void
    @State private var token: String
    @State private var status: ConnectionStatus?
    @State private var connecting = false
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    init(model: AppModel, token: String? = nil, done: @escaping () -> Void) {
        self.model = model
        self.done = done
        _token = State(initialValue: token ?? model.token ?? "")
    }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                Text("Welcome to clippeek")
                    .font(.title2.bold())
                Text("Screenshots and screen recordings, straight to your Zipline.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 20) {
                step(1, "Connect your server") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Server", text: $model.serverText, prompt: Text("zip.example.com"))
                        HStack {
                            SecureField("Token", text: $token, prompt: Text("Token from Zipline Settings"))
                                .onSubmit(connect)
                            Button("Connect", action: connect)
                                .disabled(connecting || token.isEmpty || model.serverText.isEmpty)
                        }
                        connection
                    }
                    .textFieldStyle(.roundedBorder)
                }
                step(2, "Choose what to send") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Screenshots", isOn: Binding(get: { model.isCapturing(.screenshot) },
                                                            set: { model.setCapture(.screenshot, $0) }))
                        Toggle("Screen recordings", isOn: Binding(get: { model.isCapturing(.video) },
                                                                  set: { model.setCapture(.video, $0) }))
                    }
                }
                step(3, "Start with your Mac") {
                    Toggle("Open clippeek at login", isOn: $openAtLogin)
                        .onChange(of: openAtLogin) { _, on in
                            if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                            openAtLogin = SMAppService.mainApp.status == .enabled
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: done) {
                Text("Done").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .padding(.top, 8)
        .frame(width: 420)
    }

    @ViewBuilder
    private var connection: some View {
        if connecting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Connecting…").foregroundStyle(.secondary)
            }
        } else if let status {
            Label(status.message, systemImage: status.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(status.ok ? .green : .orange)
        }
    }

    private func step(_ number: Int, _ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .frame(width: 22, height: 22)
                .background(.quaternary, in: .circle)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content()
            }
        }
    }

    private func connect() {
        guard !connecting, !token.isEmpty else { return }
        model.saveToken(token)
        connecting = true
        Task {
            status = await model.testConnection()
            connecting = false
        }
    }
}
