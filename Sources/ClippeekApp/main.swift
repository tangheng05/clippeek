import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        model.start()
        let statusItem = StatusItemController(model: model)
        self.statusItem = statusItem
        Task {
            await model.loadToken()
            statusItem.openSettingsIfNeeded()
        }
    }
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
