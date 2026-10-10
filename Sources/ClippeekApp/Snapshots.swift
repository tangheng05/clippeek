#if DEBUG
import AppKit
import SwiftUI

/// `ClippeekApp --snapshots <dir>` renders the popover and Settings to PNGs with sample data,
/// so the UI can be reviewed without touching the real inbox, history or Keychain.
@MainActor
enum Snapshots {
    static func render(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = FileManager.default.temporaryDirectory.appending(path: "clippeek-snapshots")
        let folders = Folders(inbox: base.appending(path: "Inbox"), thumbnails: base.appending(path: "Thumbnails"),
                              historyFile: base.appending(path: "history.json"))
        func model(_ configure: (AppModel) -> Void) -> AppModel {
            let model = AppModel(folders: folders)
            model.serverText = "zip.example.com"
            configure(model)
            return model
        }
        let states: [(String, AppModel)] = [
            ("empty", model { $0.loadSample(items: 0) }),
            ("few", model { $0.loadSample(items: 4) }),
            ("many", model { $0.loadSample(items: 17, waiting: 2) }),
            ("problems", model {
                $0.loadSample(items: 5, waiting: 1, problem: "Zipline rejected the token. Check it in Settings.", capturing: [])
            }),
        ]
        for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            guard let appearance = NSAppearance(named: name) else { continue }
            for (label, model) in states {
                let popover = HistoryView(model: model, visible: true)
                    .background(Color(nsColor: .windowBackgroundColor))
                write(view(popover, appearance: appearance), to: directory.appending(path: "popover-\(label)-\(suffix).png"))
            }
            let settings = SettingsView(model: model { _ in }, token: String(repeating: "x", count: 273))
                .background(Color(nsColor: .windowBackgroundColor))
            write(view(settings, appearance: appearance), to: directory.appending(path: "settings-\(suffix).png"))
        }
    }

    /// Hosts the view in an offscreen window so AppKit-backed controls render too.
    private static func view(_ content: some View, appearance: NSAppearance) -> NSBitmapImageRep? {
        let hosting = NSHostingView(rootView: content)
        hosting.appearance = appearance
        let size = hosting.fittingSize
        print("  fitting size \(Int(size.width))×\(Int(size.height))")
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: .now + 0.5)
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        return rep
    }

    private static func write(_ rep: NSBitmapImageRep?, to url: URL) {
        guard let data = rep?.representation(using: .png, properties: [:]) else {
            print("Couldn't render \(url.lastPathComponent)")
            return
        }
        try? data.write(to: url)
        print("Wrote \(url.lastPathComponent)")
    }
}
#endif
