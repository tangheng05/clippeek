import AppKit

@MainActor
enum Clipboard {
    /// PNG for apps like Claude Code, TIFF for older ones.
    static func put(image data: Data) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(data, forType: .png)
        if let tiff = NSImage(data: data)?.tiffRepresentation { board.setData(tiff, forType: .tiff) }
    }

    static func put(link: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.absoluteString, forType: .string)
    }
}
