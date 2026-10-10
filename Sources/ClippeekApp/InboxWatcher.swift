import Foundation

/// Fires when entries in the inbox change. A directory vnode source: no polling.
@MainActor
final class InboxWatcher {
    private let folder: URL
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?

    init?(folder: URL, onChange: @escaping @MainActor () -> Void) {
        self.folder = folder
        self.onChange = onChange
        guard watch() else { return nil }
    }

    private func watch() -> Bool {
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.source?.data.isDisjoint(with: [.delete, .rename]) == false { self.recreate() }
                self.onChange()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        return true
    }

    /// The inbox was deleted or moved away; screenshots still go to its path, so it comes back.
    private func recreate() {
        source?.cancel()
        source = nil
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = watch()
    }

    isolated deinit { source?.cancel() }
}
