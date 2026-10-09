import AppKit
import SwiftUI

@MainActor
final class StatusItemController {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let hosting: NSHostingController<HistoryView>
    private var outsideClickMonitor: Any?
    private var lastClosed = Date.distantPast
    private var settings: AppWindow?

    init(model: AppModel) {
        self.model = model
        hosting = NSHostingController(rootView: HistoryView(model: model, visible: false))
        // The popover gets its size from us before it shows, so it never opens at a stale size.
        hosting.sizingOptions = []
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = hosting
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: popover,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lastClosed = .now
                self?.stopWatchingOutsideClicks()
                self?.setPopoverContent(visible: false)
            }
        }
        observe()
        if model.serverText.isEmpty || !model.captureOn {
            DispatchQueue.main.async { self.openSettings() }
        }
    }

    private func observe() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func render() {
        guard let button = item.button else { return }
        let failed = model.pending.values.contains { if case .failed = $0 { true } else { false } }
        let warning = model.problem != nil || failed
        button.image = NSImage(systemSymbolName: warning ? "exclamationmark.triangle" : "camera.viewfinder",
                               accessibilityDescription: "clippeek")
        button.appearsDisabled = !model.captureOn
        button.toolTip = model.captureOn ? "clippeek" : "clippeek (screenshots aren't being sent)"
    }

    @objc private func clicked() {
        guard let event = NSApp.currentEvent else { return toggle() }
        let control = event.type == .leftMouseUp && event.modifierFlags.contains(.control)
        event.type == .rightMouseUp || control ? showMenu() : toggle()
    }

    private func showMenu() {
        popover.performClose(nil)
        let menu = NSMenu()
        menu.addItem(withTitle: "Open clippeek", action: #selector(toggle), keyEquivalent: "").target = self
        let capture = menu.addItem(withTitle: "Send Screenshots to clippeek", action: #selector(toggleCapture), keyEquivalent: "")
        capture.target = self
        capture.state = model.captureOn ? .on : .off
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit clippeek", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // Setting the menu only for this click keeps a left click opening the popover.
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func toggleCapture() {
        model.setCapture(!model.captureOn)
    }

    @objc private func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // A click on the icon first closes the popover (it's outside it), then fires this
            // action; reopening right away would make it flicker, so treat it as the close.
            guard Date.now.timeIntervalSince(lastClosed) > 0.3 else { return }
            model.removeExpired()
            setPopoverContent(visible: true)
            resizePopover(height: hosting.sizeThatFits(in: NSSize(width: HistoryView.width, height: 10_000)).height)
            // Without this the first click inside the popover only activates the app.
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            watchOutsideClicks()
        }
    }

    private func resizePopover(height: CGFloat) {
        let size = NSSize(width: HistoryView.width, height: height.rounded(.up))
        if popover.contentSize != size { popover.contentSize = size }
    }

    /// Set on the hosting view directly, so the next measurement already sees the new content.
    private func setPopoverContent(visible: Bool) {
        guard hosting.rootView.visible != visible else { return }
        hosting.rootView = HistoryView(model: model, visible: visible,
                                       openSettings: { [weak self] in self?.openSettings() },
                                       close: { [weak self] in self?.popover.performClose(nil) },
                                       // Resizing inside SwiftUI's layout pass makes AppKit lay out re-entrantly.
                                       onResize: { [weak self] height in
                                           DispatchQueue.main.async { self?.resizePopover(height: height) }
                                       })
    }

    /// An accessory app doesn't hear clicks in other apps, so `.transient` alone misses them.
    private func watchOutsideClicks() {
        stopWatchingOutsideClicks()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        }
    }

    private func stopWatchingOutsideClicks() {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
    }

    @objc private func openSettings() {
        popover.performClose(nil)
        if settings == nil { settings = AppWindow(title: "clippeek Settings") { SettingsView(model: self.model) } }
        settings?.show()
    }
}
