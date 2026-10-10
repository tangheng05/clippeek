import AppKit
import ClippeekCore
import SwiftUI

struct WelcomeView: View {
    @Bindable var model: AppModel
    let done: () -> Void
    @State private var token: String
    @State private var status: ConnectionStatus?
    @State private var connecting = false

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
                            .onChange(of: model.serverText) { status = nil }
                        HStack {
                            SecureField("Token", text: $token, prompt: Text("Token from Zipline Settings"))
                                .onSubmit { connect() }
                                .onChange(of: token) { status = nil }
                            // Return connects until the server is connected, then it means Done.
                            Button("Connect") { connect() }
                                .disabled(connecting || token.isEmpty || model.serverText.isEmpty)
                                .keyboardShortcut(connected ? nil : .defaultAction)
                        }
                        connection
                    }
                    .textFieldStyle(.roundedBorder)
                }
                step(2, "Choose what to send") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Screenshots", isOn: captureBinding(.screenshot, model))
                        Toggle("Screen recordings", isOn: captureBinding(.video, model))
                    }
                }
                step(3, "Start with your Mac") {
                    OpenAtLoginToggle()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: finish) {
                Text("Done").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(connecting)
            .keyboardShortcut(connected ? .defaultAction : nil)
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

    private var connected: Bool { status?.ok == true }

    /// A typed token that was never tested is connected first, and the window stays open if it fails.
    private func finish() {
        guard status == nil, !token.isEmpty, !model.serverText.isEmpty else { return done() }
        connect { done() }
    }

    private func connect(then success: @escaping () -> Void = {}) {
        guard !connecting, !token.isEmpty, !model.serverText.isEmpty else { return }
        connecting = true
        Task {
            status = await model.connect(token: token)
            connecting = false
            if status?.ok == true { success() }
        }
    }
}
