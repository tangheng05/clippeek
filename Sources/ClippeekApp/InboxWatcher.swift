import Foundation

/// Fires when entries in the inbox change. A directory vnode source: no polling.
@MainActor
final class InboxWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(folder: URL, onChange: @escaping @MainActor () -> Void) {
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { onChange() } }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit { source.cancel() }
}
