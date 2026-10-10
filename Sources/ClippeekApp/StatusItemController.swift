import AppKit
import ClippeekCore
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
    private var settingsPane: SettingsTabs.Pane = .general
    private var welcome: AppWindow?
    private var uploading = false
    private var problem = false
    private var showingDone = false
    private var rise: CGFloat = 0
    private var lastFinished: Date?
    private var shownCenter: MenuBarIcon.Center?

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
    }

    /// First run: a short setup instead of the full Settings.
    func openWelcomeIfNeeded() {
        guard ZiplineServer(model.serverText) == nil || model.token == nil else { return }
        let window = AppWindow(title: "Welcome to clippeek", plainTitlebar: true) { [unowned self] in
            WelcomeView(model: model) { [weak self] in self?.welcome?.close() }
        }
        welcome = window
        window.show()
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
        problem = model.problem != nil || failed
        let nowUploading = model.videoProgress != nil || model.pending.values.contains(.uploading)
        if nowUploading && !uploading { playRise() }
        uploading = nowUploading
        if let finished = model.lastFinished, finished != lastFinished {
            lastFinished = finished
            showDone()
        }
        button.appearsDisabled = !model.isCapturing(.screenshot) && !model.isCapturing(.video)
        button.toolTip = button.appearsDisabled ? "clippeek (nothing is being sent)" : "clippeek"
        button.setAccessibilityLabel("clippeek")
        button.setAccessibilityValue(problem ? "Needs attention" : uploading ? "Uploading" : "Ready")
        applyIcon()
    }

    /// Problems win over uploading, uploading over the brief check.
    private func applyIcon() {
        let center: MenuBarIcon.Center = problem ? .exclamation : uploading ? .arrow(rise: rise) : showingDone ? .check : .none
        guard center != shownCenter else { return }
        shownCenter = center
        item.button?.image = MenuBarIcon.image(center)
    }

    /// The arrow lifts into place once when an upload starts.
    private func playRise() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        Task {
            for step in stride(from: -3.0, through: 0, by: 0.5) {
                rise = step
                applyIcon()
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
    }

    private func showDone() {
        showingDone = true
        applyIcon()
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            showingDone = false
            applyIcon()
        }
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
        capture.state = model.isCapturing(.screenshot) ? .on : .off
        let recordings = menu.addItem(withTitle: "Send Screen Recordings to clippeek", action: #selector(toggleRecordings), keyEquivalent: "")
        recordings.target = self
        recordings.state = model.isCapturing(.video) ? .on : .off
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit clippeek", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // Setting the menu only for this click keeps a left click opening the popover.
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func toggleCapture() {
        model.setCapture(.screenshot, !model.isCapturing(.screenshot))
    }

    @objc private func toggleRecordings() {
        model.setCapture(.video, !model.isCapturing(.video))
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
                                       openSettings: { [weak self] pane in self?.openSettings(pane) },
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

    @objc private func openSettingsFromMenu() {
        openSettings(.general)
    }

    func openSettings(_ pane: SettingsTabs.Pane) {
        popover.performClose(nil)
        settingsPane = pane
        if settings == nil {
            settings = AppWindow(title: "clippeek Settings", controller: { [unowned self] in
                SettingsTabs.controller(model: model, select: settingsPane)
            })
        }
        settings?.show()
        (settings?.contentController as? NSTabViewController)?.selectedTabViewItemIndex =
            SettingsTabs.Pane.allCases.firstIndex(of: pane) ?? 0
    }
}
