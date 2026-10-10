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
            case .general: host(GeneralPane(model: model))
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

/// Moves each upload to a folder instead of deleting it.
private struct KeepCopyRows: View {
    @Bindable var model: AppModel
    let kind: CaptureKind

    var body: some View {
        Toggle("Keep a copy on this Mac", isOn: kind == .screenshot ? $model.keepScreenshots : $model.keepVideos)
        if kind == .screenshot ? model.keepScreenshots : model.keepVideos {
            LabeledContent("Save copies to") {
                HStack(spacing: 6) {
                    Text(FileManager.default.displayName(atPath: model.keepFolder(for: kind).path))
                        .foregroundStyle(.secondary)
                        .help(model.keepFolder(for: kind).path)
                    Button("Choose…", action: choose)
                }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = model.keepFolder(for: kind)
        panel.prompt = "Choose"
        // The inbox would upload every kept copy again.
        guard panel.runModal() == .OK, let folder = panel.url,
              folder.standardizedFileURL.path != model.folders.inbox.standardizedFileURL.path else { return }
        model.keepFolders[kind] = folder
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
    @Bindable var model: AppModel
    var loginStatus = SMAppService.mainApp.status

    var body: some View {
        Form {
            OpenAtLoginToggle(status: loginStatus)
            Section {
                Picker("Copy links as", selection: $model.linkFormat) {
                    Text("Plain link").tag(LinkFormat.plain)
                    Text("Markdown").tag(LinkFormat.markdown)
                    Text("HTML").tag(LinkFormat.html)
                }
            } footer: {
                Text("Used after each upload and when you click a thumbnail. To upload other files, drop them on the menu bar icon or choose Services → Upload with clippeek in Finder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                LabeledContent("Open history shortcut") {
                    ShortcutRecorder(model: model)
                }
            } footer: {
                if model.shortcutTaken {
                    Text("Another app already uses this shortcut. Pick a different one.")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
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
                    KeepCopyRows(model: model, kind: .screenshot)
                }
                .disabled(!model.isCapturing(.screenshot))
            } footer: {
                Text("Screenshots go to your clipboard and Zipline instead of the Desktop. Turning this off restores your previous screenshot settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Picker("Compress on Zipline", selection: compressionFormat) {
                    Text("Off").tag(ImageCompression.Format?.none)
                    Text("WebP").tag(ImageCompression.Format?.some(.webp))
                    Text("JPEG").tag(ImageCompression.Format?.some(.jpeg))
                }
                if model.compression != nil {
                    Picker("Quality", selection: compressionQuality) {
                        Text("High").tag(90)
                        Text("Medium").tag(75)
                        Text("Low").tag(50)
                    }
                }
            } footer: {
                Text("Zipline stores a smaller copy of screenshots and images you drop, so links load faster. Your clipboard and any kept copy stay full quality.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .pane()
    }
}

extension ScreenshotsPane {
    private var compressionFormat: Binding<ImageCompression.Format?> {
        Binding(get: { model.compression?.format }, set: { format in
            model.compression = format.map { ImageCompression(format: $0, quality: model.compression?.quality ?? 90) }
        })
    }

    private var compressionQuality: Binding<Int> {
        Binding(get: { model.compression?.quality ?? 90 }, set: { quality in
            model.compression = model.compression.map { ImageCompression(format: $0.format, quality: quality) }
        })
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
                    KeepCopyRows(model: model, kind: .video)
                }
                .disabled(!model.isCapturing(.video))
            } footer: {
                Text("Recordings upload when they finish. Unless you keep a copy, they're removed from this Mac. Zipline allows 100 MB per file by default; raise \"Max file size\" in its settings for longer videos.")
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

/// Click, then press the new combination. Esc cancels.
private struct ShortcutRecorder: View {
    @Bindable var model: AppModel
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleRecording) {
                Text(label)
                    .frame(minWidth: 96)
                    .foregroundStyle(model.recordingShortcut ? .secondary : .primary)
            }
            if model.shortcut != nil, !model.recordingShortcut {
                Button {
                    model.shortcut = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Turn off the shortcut")
                .accessibilityLabel("Turn off the shortcut")
            }
        }
        .onDisappear(perform: stop)
    }

    private var label: String {
        if model.recordingShortcut { return hint ?? "Press keys…" }
        return model.shortcut?.display ?? "Record Shortcut"
    }

    private func toggleRecording() {
        model.recordingShortcut ? stop() : start()
    }

    private func start() {
        model.recordingShortcut = true
        hint = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { record(event) }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        model.recordingShortcut = false
    }

    private func record(_ event: NSEvent) {
        if event.keyCode == 53 { return stop() }
        let flags = event.modifierFlags
        let combo = KeyCombo(keyCode: UInt32(event.keyCode), key: keyName(event),
                             command: flags.contains(.command), option: flags.contains(.option),
                             control: flags.contains(.control), shift: flags.contains(.shift))
        guard combo.isValid else {
            hint = "Add ⌘, ⌥ or ⌃"
            return
        }
        model.shortcut = combo
        stop()
    }

    private func keyName(_ event: NSEvent) -> String {
        switch event.keyCode {
        case 49: return "Space"
        case 36: return "↩"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            let key = event.charactersIgnoringModifiers ?? ""
            return key.unicodeScalars.allSatisfy { $0.properties.isAlphabetic || $0.properties.numericType != nil
                || CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) } ? key : ""
        }
    }
}
