import AppKit
import SwiftUI

@MainActor
final class StatusItemController {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var settings: AppWindow?

    init(model: AppModel) {
        self.model = model
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: HistoryView(model: model) { [weak self] in
            self?.openSettings()
        })
        item.button?.target = self
        item.button?.action = #selector(toggle)
        observe()
        if model.serverText.isEmpty || !model.captureOn { openSettings() }
    }

    /// The icon shows a warning while there's a problem or uploads are stuck.
    private func observe() {
        withObservationTracking {
            let warning = model.problem != nil || model.pending.values.contains { if case .failed = $0 { true } else { false } }
            item.button?.image = NSImage(systemSymbolName: warning ? "exclamationmark.triangle" : "camera.viewfinder",
                                         accessibilityDescription: "clippeek")
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    @objc private func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func openSettings() {
        popover.performClose(nil)
        if settings == nil { settings = AppWindow(title: "clippeek Settings") { SettingsView(model: self.model) } }
        settings?.show()
    }
}
