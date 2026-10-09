import AppKit
import SwiftUI

/// A window for a menu-bar-only app. While any is open the app acts like a regular app
/// (Dock icon, ⌘-Tab), because macOS often won't bring an accessory app's window forward.
@MainActor
final class AppWindow: NSObject, NSWindowDelegate {
    private static var openCount = 0
    private var window: NSWindow?
    private let title: String
    private let plainTitlebar: Bool
    private let makeContent: () -> AnyView
    var onClose: (() -> Void)?

    init(title: String, plainTitlebar: Bool = false, content: @escaping () -> some View) {
        self.title = title
        self.plainTitlebar = plainTitlebar
        self.makeContent = { AnyView(content()) }
    }

    var isOpen: Bool { window?.isVisible == true }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: makeContent()))
            window.title = title
            window.styleMask = [.titled, .closable]
            if plainTitlebar {
                window.styleMask.insert(.fullSizeContentView)
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
            }
            window.isReleasedWhenClosed = false
            window.delegate = self
            fitOnScreen(window)
            window.center()
            self.window = window
        }
        if !isOpen { Self.openCount += 1 }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    /// Starts at the content's natural height, but never taller than the space between the
    /// menu bar and the Dock; a form scrolls for the rest.
    private func fitOnScreen(_ window: NSWindow) {
        guard let content = window.contentViewController?.view,
              let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let natural = content.fittingSize.height
        let chrome = window.frame.height - window.contentLayoutRect.height
        let height = min(natural, visible.height - chrome - 40)
        window.setContentSize(NSSize(width: window.contentLayoutRect.width, height: height))
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        Self.openCount = max(0, Self.openCount - 1)
        if Self.openCount == 0 { NSApp.setActivationPolicy(.accessory) }
        onClose?()
        // A closed window's views would keep updating with the model, so build it fresh next time.
        DispatchQueue.main.async { [weak self] in
            guard self?.isOpen == false else { return }
            self?.window = nil
        }
    }
}
