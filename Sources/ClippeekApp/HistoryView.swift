import AppKit
import ClippeekCore
import SwiftUI

struct HistoryView: View {
    static let width: CGFloat = 320
    private static let tileHeight: CGFloat = 64
    private static let spacing: CGFloat = 8
    private static let scrollerGutter: CGFloat = 12
    private static let visibleRows = 4

    let model: AppModel
    /// False while closed, so nothing inside keeps re-rendering in the background.
    let visible: Bool
    var openSettings: (SettingsTabs.Pane) -> Void = { _ in }
    var close: () -> Void = {}
    var onResize: ((CGFloat) -> Void)?

    @State private var copying: String?
    @State private var copied: CopyFeedback?
    @State private var selection: String?
    @State private var deleting: HistoryItem?
    @FocusState private var gridFocused: Bool

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
            status
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private var status: some View {
        if let progress = model.videoProgress ?? model.sendProgress {
            HStack(spacing: 6) {
                if progress > 0 {
                    ProgressView(value: progress).frame(width: 54).controlSize(.mini)
                    Text("Uploading video \(Int(progress * 100))%")
                } else {
                    ProgressView().controlSize(.mini)
                    Text("Uploading video…")
                }
            }
        } else if model.pending.values.contains(.uploading) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Uploading…")
            }
        } else if waiting > 0 {
            Text(model.waitingForRetry ? "\(waiting) waiting, will retry" : "\(waiting) waiting")
        } else if !failed.isEmpty {
            Text("\(failed.count) not uploaded")
        } else if !model.history.items.isEmpty {
            Text("All uploaded")
        }
    }

    @ViewBuilder
    private var notices: some View {
        if ZiplineServer(model.serverText) == nil || model.token == nil {
            Notice(symbol: "server.rack", tint: .orange, text: "Connect your Zipline server to start uploading.") {
                Button("Set Up…") { openSettings(.server) }
            }
        } else if !model.isCapturing(.screenshot) && !model.isCapturing(.video) {
            Notice(symbol: "camera.viewfinder", tint: .secondary, text: "clippeek is off. Captures stay on your Mac.") {
                Button("Turn On") { model.setCapture(.screenshot, true) }
            }
        }
        if let problem = model.problem {
            Notice(symbol: "exclamationmark.triangle.fill", tint: .orange, text: problem) {
                if model.tokenRejected || model.token == nil {
                    Button("Open Settings…") { openSettings(.server) }
                } else {
                    Button("Dismiss") { model.dismissProblem() }
                }
            }
        }
        if !failed.isEmpty {
            Notice(symbol: "exclamationmark.triangle.fill", tint: .orange,
                   text: failed.count == 1 ? failed[0].reason : "\(failed.count) files couldn't upload.") {
                VStack(alignment: .trailing, spacing: 4) {
                    Button("Retry") { model.retryFailed() }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(failed.map { model.folders.inbox.appending(path: $0.name) })
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("Nothing uploaded yet").font(.callout.weight(.medium))
            Text("Press ⇧⌘4 for a screenshot or ⇧⌘5 to record.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: 3),
                              spacing: Self.spacing) {
                        ForEach(model.history.items) { item in
                            HistoryTile(item: item,
                                        image: ThumbnailCache.image(at: model.folders.thumbnails.appending(path: item.thumbnail)),
                                        height: Self.tileHeight, selected: selection == item.id,
                                        copying: copying == item.id, copied: copied?.id == item.id ? copied : nil) { link in
                                activate(item, link: link)
                            }
                            .accessibilityAction(named: "Copy as Markdown") { copyLink(item, .markdown) }
                            .accessibilityAction(named: "Copy Text") { copyText(item) }
                            .id(item.id)
                            .contextMenu { menu(for: item) }
                        }
                    }
                    .padding(.horizontal, Self.scrollerGutter)
                }
                // Widens the scroll view into the margin, so the scroller sits beside the tiles, not on them.
                .padding(.horizontal, -Self.scrollerGutter)
                .frame(height: gridHeight)
                .scrollIndicators(.automatic)
                .focusable()
                .focusEffectDisabled()
                .focused($gridFocused)
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return]) { press in
                    handle(press.key, proxy: proxy)
                }
                .onAppear { gridFocused = true }
            }
            .confirmationDialog("Delete this file from Zipline?", isPresented: deleteDialog, presenting: deleting) { item in
                Button("Delete", role: .destructive) { Task { await model.deleteFromServer(item) } }
            } message: { _ in
                Text("The link will stop working.")
            }
            Text("Click to copy. ⌥-click copies the link.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func menu(for item: HistoryItem) -> some View {
        if item.kind == .screenshot { Button("Copy Image") { activate(item, link: false) } }
        Button("Copy Link") { copyLink(item, .plain) }
        Button("Copy as Markdown") { copyLink(item, .markdown) }
        Button("Copy as HTML") { copyLink(item, .html) }
        if item.kind == .screenshot { Button("Copy Text") { copyText(item) } }
        Divider()
        Button("Open in Browser") { NSWorkspace.shared.open(item.url) }
        if let file = item.localFile, FileManager.default.fileExists(atPath: file.path) {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        }
        if let deletesAt = item.deletesAt {
            Text("Deletes \(deletesAt.formatted(.relative(presentation: .named)))")
        }
        Divider()
        Button("Delete from Zipline", role: .destructive) { deleting = item }
    }

    private var footer: some View {
        HStack {
            Button("Settings…") { openSettings(.general) }
                .keyboardShortcut(",")
            Spacer()
            Button("Quit clippeek") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
    }

    // MARK: Actions

    /// Arrow keys move the selection, clamped to the grid; Return copies it.
    private func handle(_ key: KeyEquivalent, proxy: ScrollViewProxy) -> KeyPress.Result {
        let items = model.history.items
        guard !items.isEmpty else { return .ignored }
        if key == .return {
            guard let item = items.first(where: { $0.id == selection }) else { return .ignored }
            activate(item, link: item.kind == .video || NSEvent.modifierFlags.contains(.option))
            return .handled
        }
        let step = switch key {
        case .leftArrow: -1
        case .rightArrow: 1
        case .upArrow: -3
        default: 3
        }
        let current = items.firstIndex { $0.id == selection }
        let next = current.map { min(max($0 + step, 0), items.count - 1) } ?? 0
        selection = items[next].id
        proxy.scrollTo(items[next].id)
        return .handled
    }

    private func activate(_ item: HistoryItem, link: Bool) {
        guard copying == nil else { return }
        if link {
            model.copyLink(item)
            confirm(CopyFeedback(id: item.id, text: "Link Copied", symbol: "link"))
            return
        }
        copying = item.id
        Task {
            let ok = await model.copyImage(item)
            copying = nil
            if ok {
                confirm(CopyFeedback(id: item.id, text: "Copied", symbol: "checkmark"))
            } else {
                confirm(CopyFeedback(id: item.id, text: "Couldn't Copy", symbol: "xmark"), thenClose: false)
            }
        }
    }

    private func copyLink(_ item: HistoryItem, _ format: LinkFormat) {
        model.copyLink(item, format: format)
        let text = switch format {
        case .plain: "Link Copied"
        case .markdown: "Markdown Copied"
        case .html: "HTML Copied"
        }
        confirm(CopyFeedback(id: item.id, text: text, symbol: "link"))
    }

    private func copyText(_ item: HistoryItem) {
        guard copying == nil else { return }
        copying = item.id
        Task {
            let result = await model.copyText(item)
            copying = nil
            switch result {
            case .copied: confirm(CopyFeedback(id: item.id, text: "Text Copied", symbol: "text.viewfinder"))
            case .none: confirm(CopyFeedback(id: item.id, text: "No Text Found", symbol: "magnifyingglass"), thenClose: false)
            case .failed: confirm(CopyFeedback(id: item.id, text: "Couldn't Copy", symbol: "xmark"), thenClose: false)
            }
        }
    }

    /// Shows the confirmation briefly, then gets out of the way so the user can paste.
    private func confirm(_ value: CopyFeedback, thenClose: Bool = true) {
        withAnimation(.easeOut(duration: 0.15)) { copied = value }
        Task {
            try? await Task.sleep(for: .milliseconds(thenClose ? 600 : 1500))
            if thenClose { close() }
            withAnimation(.easeOut(duration: 0.15)) { if copied == value { copied = nil } }
        }
    }

    // MARK: Derived

    private var failed: [(name: String, reason: String)] {
        model.pending.compactMap { name, state in
            if case .failed(let reason) = state { (name, reason) } else { nil }
        }
        .sorted { $0.name < $1.name }
    }

    private var deleteDialog: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
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

private struct CopyFeedback: Equatable {
    let id: String
    let text: String
    let symbol: String
}

private struct HistoryTile: View {
    let item: HistoryItem
    let image: NSImage?
    let height: CGFloat
    let selected: Bool
    let copying: Bool
    let copied: CopyFeedback?
    let action: (_ link: Bool) -> Void
    @State private var hovering = false

    var body: some View {
        // Filling a fixed box keeps odd-shaped screenshots from stretching the grid.
        Color.clear
            .frame(height: height)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(.tertiary)
                }
            }
            .clipShape(.rect(cornerRadius: 6))
            .overlay(alignment: .bottomLeading) {
                if item.kind == .video {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.black.opacity(0.55), in: .circle)
                        .padding(5)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if hovering && copied == nil && !copying {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(age)
                        if let left = item.timeLeft(now: .now) { Text(left).foregroundStyle(.white.opacity(0.75)) }
                    }
                    .font(.caption2.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: .rect(cornerRadius: 5))
                    .padding(5)
                }
            }
            .overlay { feedback }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(hovering || selected ? Color.accentColor : Color.primary.opacity(0.12),
                                  lineWidth: hovering || selected ? 2 : 1)
            }
            .contentShape(.rect(cornerRadius: 6))
            .onHover { hovering = $0 }
            .onTapGesture { action(item.kind == .video || NSEvent.modifierFlags.contains(.option)) }
            .help((item.kind == .video ? "Click to copy the link." : "Click to copy, ⌥-click to copy the link.")
                  + (deletes.map { " Deletes \($0)." } ?? ""))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(item.kind == .video ? "Screen recording" : "Screenshot"), \(item.created.formatted(.relative(presentation: .named)))\(deletes.map { ", deletes \($0)" } ?? "")")
            .accessibilityHint(item.kind == .video ? "Copies the link" : "Copies the image")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { action(item.kind == .video) }
            .accessibilityAction(named: "Copy Link") { action(true) }
    }

    private var age: String {
        item.created.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    /// "in 6 days", or nil when Zipline keeps the file.
    private var deletes: String? {
        item.deletesAt?.formatted(.relative(presentation: .named))
    }

    @ViewBuilder
    private var feedback: some View {
        if copying {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.45))
                ProgressView().controlSize(.small).tint(.white)
            }
        } else if let copied {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.55))
                Label(copied.text, systemImage: copied.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .transition(.opacity)
        }
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
