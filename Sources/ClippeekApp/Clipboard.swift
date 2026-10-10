import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum Clipboard {
    /// Kept alive while the image is on the clipboard, in case an app asks for TIFF.
    private static var provider: TIFFProvider?

    /// PNG for apps like Claude Code; TIFF for older ones, made only if one asks for it.
    /// Other formats also go on as PNG, next to the original; PDFs stay PDFs.
    static func put(image data: Data) {
        let item = NSPasteboardItem()
        if data.starts(with: Data("%PDF".utf8)) {
            item.setData(data, forType: .pdf)
            provider = nil
        } else {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let type = CGImageSourceGetType(source) as String?,
                  let png = type == UTType.png.identifier ? data : pngData(from: source) else { return }
            item.setData(png, forType: .png)
            if type != UTType.png.identifier { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            if type == UTType.tiff.identifier {
                provider = nil
            } else {
                let provider = TIFFProvider(png: png)
                item.setDataProvider(provider, forTypes: [.tiff])
                self.provider = provider
            }
        }
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([item])
    }

    static func put(link: URL) {
        put(text: link.absoluteString)
    }

    static func put(text: String) {
        provider = nil
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func pngData(from source: CGImageSource) -> Data? {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
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
