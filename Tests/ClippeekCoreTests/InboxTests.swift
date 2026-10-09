import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ClippeekCore

@Suite struct InboxTests {
    @Test func onlyFinishedImages() {
        #expect(Inbox.isScreenshot("Screenshot 2026-10-09 at 15.00.00.png"))
        #expect(!Inbox.isScreenshot(".Screenshot 2026-10-09 at 15.00.00.png"))
        #expect(!Inbox.isScreenshot("notes.txt"))
        #expect(!Inbox.isScreenshot(".DS_Store"))
    }

    /// The name macOS 27 writes to before renaming, seen in the inbox.
    @Test func ignoresTemporaryFile() {
        #expect(!Inbox.isScreenshot("..Screenshot 2026-10-09 at 6.29.36 PM.png-hOKjYG"))
    }

    @Test func newScreenshotsSkipHandled() {
        let listing = ["b.png", ".tmp.png", "a.png", "c.png"]
        #expect(Inbox.newScreenshots(in: listing, handled: ["c.png"]) == ["a.png", "b.png"])
    }

    @Test func onlyRecentGoToClipboard() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(Inbox.isRecent(created: now.addingTimeInterval(-3), now: now))
        #expect(!Inbox.isRecent(created: now.addingTimeInterval(-60), now: now))
    }

    @Test func mimeTypes() {
        #expect(Inbox.mimeType(for: "a.png") == "image/png")
        #expect(Inbox.mimeType(for: "a.JPG") == "image/jpeg")
    }

    @Test func thumbnailIsSmall() throws {
        let context = try #require(CGContext(data: nil, width: 2000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))

        let thumbnail = try #require(Thumbnail.make(from: data as Data))
        let source = try #require(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        let size = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(size[kCGImagePropertyPixelWidth] as? Int == 256)
        #expect(size[kCGImagePropertyPixelHeight] as? Int == 128)
    }
}
