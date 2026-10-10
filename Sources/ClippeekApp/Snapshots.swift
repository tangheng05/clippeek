#if DEBUG
import AppKit
import SwiftUI

/// `ClippeekApp --snapshots <dir>` renders the popover and Settings to PNGs with sample data,
/// so the UI can be reviewed without touching the real inbox, history or Keychain.
@MainActor
enum Snapshots {
    static func render(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let icon = NSImage(contentsOfFile: "build/AppIcon.icns") { NSApp.applicationIconImage = icon }
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
            ("readme", model { $0.loadSample(items: 6, videos: 1) }),
            ("few", model { $0.loadSample(items: 4, videos: 1, videoProgress: 0.4) }),
            ("video-starting", model { $0.loadSample(items: 4, videos: 1, videoProgress: 0) }),
            ("many", model { $0.loadSample(items: 17, waiting: 2) }),
            ("problems", model {
                $0.loadSample(items: 5, waiting: 1, problem: "Zipline answered with an error (502). Retrying automatically.", capturing: [])
            }),
        ]
        for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            guard let appearance = NSAppearance(named: name) else { continue }
            for (label, model) in states {
                let popover = HistoryView(model: model, visible: true)
                    .background(Color(nsColor: .windowBackgroundColor))
                write(view(popover, appearance: appearance), to: directory.appending(path: "popover-\(label)-\(suffix).png"))
            }
            let icons: [(String, MenuBarIcon.Center)] = [("idle", .none), ("uploading", .arrow(rise: 0)),
                                                         ("done", .check), ("problem", .exclamation)]
            for (label, center) in icons {
                write(menuBar(MenuBarIcon.image(center), appearance: appearance),
                      to: directory.appending(path: "menubar-\(label)-\(suffix).png"))
            }
            let welcome = WelcomeView(model: model { _ in }, token: "") {}
                .background(Color(nsColor: .windowBackgroundColor))
            write(view(welcome, appearance: appearance), to: directory.appending(path: "welcome-\(suffix).png"))
            let panes: [(String, AnyView)] = [
                ("general", AnyView(GeneralPane(loginStatus: .notRegistered))),
                ("general-approval", AnyView(GeneralPane(loginStatus: .requiresApproval))),
                ("screenshots", AnyView(ScreenshotsPane(model: model { $0.loadSample(items: 0, capturing: [.screenshot]) }))),
                ("recordings", AnyView(RecordingsPane(model: model { $0.loadSample(items: 0, capturing: [.video]) }))),
                ("recordings-off", AnyView(RecordingsPane(model: model { $0.loadSample(items: 0, capturing: []) }))),
                ("server", AnyView(ServerPane(model: model { _ in }, token: String(repeating: "x", count: 273)))),
            ]
            for (label, pane) in panes {
                write(view(pane.background(Color(nsColor: .windowBackgroundColor)), appearance: appearance),
                      to: directory.appending(path: "settings-\(label)-\(suffix).png"))
            }
        }
    }

    /// The item on a plain menu-bar-coloured strip, at 4x so it's easy to inspect.
    private static func menuBar(_ image: NSImage, appearance: NSAppearance) -> NSBitmapImageRep? {
        let padding: CGFloat = 8
        let size = NSSize(width: image.size.width + padding * 2, height: 24)
        let scale: CGFloat = 4
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance.performAsCurrentDrawingAppearance {
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.92, alpha: 1)).setFill()
            NSRect(origin: .zero, size: size).fill()
            let target = NSRect(x: padding, y: (size.height - image.size.height) / 2,
                                width: image.size.width, height: image.size.height)
            // What the menu bar does with a template: keep the alpha, paint it in the label colour.
            let context = NSGraphicsContext.current?.cgContext
            context?.beginTransparencyLayer(in: target, auxiliaryInfo: nil)
            image.draw(in: target)
            NSColor.labelColor.set()
            target.fill(using: .sourceAtop)
            context?.endTransparencyLayer()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
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
