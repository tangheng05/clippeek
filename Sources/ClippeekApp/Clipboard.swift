import AppKit

@MainActor
enum Clipboard {
    /// Kept alive while the image is on the clipboard, in case an app asks for TIFF.
    private static var provider: TIFFProvider?

    /// PNG for apps like Claude Code; TIFF for older ones, made only if one asks for it.
    static func put(image data: Data) {
        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        let provider = TIFFProvider(png: data)
        item.setDataProvider(provider, forTypes: [.tiff])
        self.provider = provider
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([item])
    }

    static func put(link: URL) {
        provider = nil
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.absoluteString, forType: .string)
    }
}

private final class TIFFProvider: NSObject, NSPasteboardItemDataProvider {
    let png: Data

    init(png: Data) {
        self.png = png
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        if let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
    }
}
