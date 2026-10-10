import AppKit
import ClippeekCore

/// Run by the Homebrew cask before the app is removed. The saved state stays, since `brew upgrade` runs
/// this too and the next launch points capture back at the inbox.
func restoreCapture() {
    let defaults = UserDefaults.standard
    let state = defaults.data(forKey: "captureState").flatMap { try? JSONDecoder().decode(CaptureState.self, from: $0) }
        ?? defaults.data(forKey: "previousScreenshotSettings").flatMap(CaptureState.migrating(legacy:))
        ?? CaptureState()
    if let change = state.restoreChange() { SystemPreferences.apply(change) }

    let files = FileManager.default
    let inbox = Folders.standard.inbox
    let current = SystemPreferences.read(CaptureState.allKeys)
    for name in (try? files.contentsOfDirectory(atPath: inbox.path)) ?? [] {
        guard let kind = Inbox.kind(of: name) else { continue }
        let folder = state.userFolder(for: kind, current: current, inbox: inbox, home: files.homeDirectoryForCurrentUser)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var destination = folder.appending(path: name)
        var copy = 2
        while files.fileExists(atPath: destination.path) {
            destination = folder.appending(path: "\(base) \(copy).\(ext)")
            copy += 1
        }
        try? files.moveItem(at: inbox.appending(path: name), to: destination)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        Notifier.shared.start()
        model.start()
        let statusItem = StatusItemController(model: model)
        self.statusItem = statusItem
        Task {
            await model.loadToken()
            statusItem.openWelcomeIfNeeded()
        }
    }
}

if CommandLine.arguments.contains("--restore-capture") {
    restoreCapture()
    exit(0)
}

let app = NSApplication.shared

#if DEBUG
if let index = CommandLine.arguments.firstIndex(of: "--snapshots"), index + 1 < CommandLine.arguments.count {
    Snapshots.render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    exit(0)
}
#endif

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
