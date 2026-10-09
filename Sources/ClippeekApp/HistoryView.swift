import AppKit
import ClippeekCore
import SwiftUI

struct HistoryView: View {
    static let width: CGFloat = 320
    private static let tileHeight: CGFloat = 64
    private static let spacing: CGFloat = 8
    private static let visibleRows = 4

    let model: AppModel
    /// False while closed, so nothing inside keeps re-rendering in the background.
    let visible: Bool
    var openSettings: () -> Void = {}
    var close: () -> Void = {}
    var onResize: ((CGFloat) -> Void)?

    @State private var copying: String?
    @State private var copied: Copied?

    private struct Copied: Equatable {
        let id: String
        let text: String
        let symbol: String
    }

    var body: some View {
        if visible {
            VStack(alignment: .leading, spacing: 12) {
                header
                notices
                if model.history.items.isEmpty { emptyState } else { grid }
                Divider()
                footer
            }
            .padding(14)
            .frame(width: Self.width)
            // Report the natural height even while the popover is still at its old size.
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { onResize?($0) }
        } else {
            Color.clear.frame(width: Self.width, height: 1)
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("clippeek").font(.headline)
            Spacer()
            if model.pending.values.contains(.uploading) {
                ProgressView().controlSize(.mini)
                Text("Uploading…").font(.callout).foregroundStyle(.secondary)
            } else if waiting > 0 {
                Text(waiting == 1 ? "1 waiting to upload" : "\(waiting) waiting to upload")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var notices: some View {
        if !model.captureOn {
            Notice(symbol: "camera.viewfinder", tint: .secondary,
                   text: "Screenshots are saved as usual, not sent to clippeek.") {
                Button("Turn On") { model.setCapture(true) }
            }
        } else if ZiplineServer(model.serverText) == nil || model.token == nil {
            Notice(symbol: "server.rack", tint: .orange, text: "Add your Zipline server and token to start uploading.") {
                Button("Settings…", action: openSettings)
            }
        }
        if let problem = model.problem {
            Notice(symbol: "exclamationmark.triangle.fill", tint: .orange, text: problem) {
                Button("Retry") { model.dismissProblem() }
            }
        }
        if !failed.isEmpty {
            Notice(symbol: "exclamationmark.triangle.fill", tint: .orange,
                   text: failed.count == 1 ? "1 screenshot couldn't upload." : "\(failed.count) screenshots couldn't upload.") {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(failed.map { model.folders.inbox.appending(path: $0) })
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No screenshots yet").font(.callout.weight(.medium))
            Text("Press ⇧⌘4. The screenshot goes to your clipboard and to Zipline.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: 3),
                          spacing: Self.spacing) {
                    ForEach(model.history.items) { tile($0) }
                }
            }
            .frame(height: gridHeight)
            .scrollIndicators(.automatic)
            Text("Click to copy the image, ⌥-click to copy the link.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var footer: some View {
        HStack {
            Button("Settings…", action: openSettings)
                .keyboardShortcut(",")
            Spacer()
            Button("Quit clippeek") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
    }

    private func tile(_ item: HistoryItem) -> some View {
        Button {
            activate(item, link: NSEvent.modifierFlags.contains(.option))
        } label: {
            // Filling a fixed box keeps odd-shaped screenshots from stretching the grid.
            Color.clear
                .frame(height: Self.tileHeight)
                .overlay {
                    if let image = ThumbnailCache.image(at: model.folders.thumbnails.appending(path: item.thumbnail)) {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo").foregroundStyle(.tertiary)
                    }
                }
                .clipShape(.rect(cornerRadius: 6))
                .overlay { overlay(for: item) }
                .contentShape(.rect(cornerRadius: 6))
        }
        .buttonStyle(TileStyle())
        .help("\(item.created.formatted(.relative(presentation: .named))). Click to copy, ⌥-click to copy the link.")
        .contextMenu {
            Button("Copy Image") { activate(item, link: false) }
            Button("Copy Link") { activate(item, link: true) }
            Button("Open in Browser") { NSWorkspace.shared.open(item.url) }
            Divider()
            Button("Delete from Zipline", role: .destructive) { Task { await model.deleteFromServer(item) } }
        }
    }

    @ViewBuilder
    private func overlay(for item: HistoryItem) -> some View {
        if copying == item.id {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.45))
                ProgressView().controlSize(.small).tint(.white)
            }
        } else if let copied, copied.id == item.id {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.55))
                Label(copied.text, systemImage: copied.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .transition(.opacity)
        }
    }

    // MARK: Actions

    private func activate(_ item: HistoryItem, link: Bool) {
        guard copying == nil else { return }
        if link {
            model.copyLink(item)
            confirm(Copied(id: item.id, text: "Link Copied", symbol: "link"))
            return
        }
        copying = item.id
        Task {
            let ok = await model.copyImage(item)
            copying = nil
            if ok { confirm(Copied(id: item.id, text: "Copied", symbol: "checkmark")) }
        }
    }

    /// Shows the confirmation briefly, then gets out of the way so the user can paste.
    private func confirm(_ value: Copied) {
        withAnimation(.easeOut(duration: 0.15)) { copied = value }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            close()
            copied = nil
        }
    }

    // MARK: Derived

    private var failed: [String] {
        model.pending.filter { if case .failed = $0.value { true } else { false } }.keys.sorted()
    }

    private var waiting: Int {
        model.pending.values.filter { $0 == .waiting }.count
    }

    /// Shows half of the next row when there's more, so it's clear the grid scrolls.
    private var gridHeight: CGFloat {
        let rows = (model.history.items.count + 2) / 3
        let shown = rows > Self.visibleRows ? Double(Self.visibleRows) + 0.5 : Double(rows)
        return shown * Self.tileHeight + (shown.rounded(.up) - 1) * Self.spacing
    }
}

private struct Notice<Action: View>: View {
    let symbol: String
    let tint: Color
    let text: String
    @ViewBuilder let action: Action

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            action.controlSize(.small)
        }
        .padding(10)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 8))
    }
}

private struct TileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Tile(configuration: configuration)
    }

    private struct Tile: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(hovering ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: hovering ? 2 : 1)
                }
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

/// Thumbnails are named after their Zipline id and never change, so they're read from disk once.
@MainActor
private enum ThumbnailCache {
    static let cache = NSCache<NSURL, NSImage>()

    static func image(at url: URL) -> NSImage? {
        if let image = cache.object(forKey: url as NSURL) { return image }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}
