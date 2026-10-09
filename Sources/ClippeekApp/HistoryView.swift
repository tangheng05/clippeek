import AppKit
import ClippeekCore
import SwiftUI

struct HistoryView: View {
    let model: AppModel
    let openSettings: () -> Void
    private let columns = Array(repeating: GridItem(.fixed(96), spacing: 8), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let problem = model.problem {
                HStack {
                    Text(problem).foregroundStyle(.orange)
                    Spacer()
                    Button("Retry") { model.dismissProblem() }
                }
            }
            let failed = model.pending.filter { if case .failed = $0.value { true } else { false } }.keys.sorted()
            if !failed.isEmpty {
                HStack {
                    Text(failed.count == 1 ? "1 screenshot couldn't upload" : "\(failed.count) screenshots couldn't upload")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(failed.map { model.folders.inbox.appending(path: $0) })
                    }
                }
            }
            let waiting = model.pending.count - failed.count
            if waiting > 0 {
                Text(waiting == 1 ? "1 screenshot waiting to upload" : "\(waiting) screenshots waiting to upload")
                    .foregroundStyle(.secondary)
            }
            if model.history.items.isEmpty {
                Text("Take a screenshot with ⇧⌘4. It goes to your clipboard and to Zipline.")
                    .foregroundStyle(.secondary)
                    .frame(width: 304, alignment: .leading)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(model.history.items) { item in
                            thumbnail(item)
                        }
                    }
                }
                .frame(width: 304, height: 320)
            }
            HStack {
                Button("Settings…", action: openSettings)
                Spacer()
                Button("Quit clippeek") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
    }

    private func thumbnail(_ item: HistoryItem) -> some View {
        Button {
            if NSEvent.modifierFlags.contains(.option) {
                model.copyLink(item)
            } else {
                Task { await model.copyImage(item) }
            }
        } label: {
            Image(nsImage: NSImage(contentsOf: model.folders.thumbnails.appending(path: item.thumbnail)) ?? NSImage())
                .resizable()
                .scaledToFill()
                .frame(width: 96, height: 64)
                .clipShape(.rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("Click to copy the image, ⌥-click to copy the link")
        .contextMenu {
            Button("Copy Image") { Task { await model.copyImage(item) } }
            Button("Copy Link") { model.copyLink(item) }
            Button("Open in Browser") { NSWorkspace.shared.open(item.url) }
            Divider()
            Button("Delete from Zipline", role: .destructive) { Task { await model.deleteFromServer(item) } }
        }
    }
}
