import AppKit

/// Lets files be dropped on the menu bar icon. The status item's window passes drag messages on to its delegate.
@MainActor
final class DropTarget: NSObject, NSWindowDelegate, NSDraggingDestination {
    private let onDrop: ([URL]) -> Void
    private let onHover: (Bool) -> Void

    init(window: NSWindow, onDrop: @escaping ([URL]) -> Void, onHover: @escaping (Bool) -> Void) {
        self.onDrop = onDrop
        self.onHover = onHover
        super.init()
        window.registerForDraggedTypes([.fileURL])
        window.delegate = self
    }

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !files(in: sender).isEmpty else { return [] }
        onHover(true)
        return .copy
    }

    func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onHover(false)
    }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onHover(false)
        let files = files(in: sender)
        guard !files.isEmpty else { return false }
        onDrop(files)
        return true
    }

    private func files(in info: any NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return (urls ?? []).filter { !$0.hasDirectoryPath }
    }
}

/// "Upload with clippeek" in Finder's Services menu, declared in Info.plist.
final class ServiceProvider: NSObject {
    private let onFiles: ([URL]) -> Void

    init(onFiles: @escaping ([URL]) -> Void) {
        self.onFiles = onFiles
    }

    @objc func uploadFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        onFiles(urls)
    }
}
