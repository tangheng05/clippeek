import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ClippeekCore

@Suite struct InboxTests {
    @Test func classifiesByExtension() {
        #expect(Inbox.kind(of: "Screenshot 2026-10-09 at 15.00.00.png") == .screenshot)
        #expect(Inbox.kind(of: "a.JPG") == .screenshot)
        #expect(Inbox.kind(of: "Screen Recording 2026-10-10 at 12.30.00\u{202F}PM.mov") == .video)
        #expect(Inbox.kind(of: "clip.mp4") == .video)
        #expect(Inbox.kind(of: "notes.txt") == nil)
        #expect(Inbox.kind(of: ".DS_Store") == nil)
    }

    /// The names macOS writes to before renaming, seen in the inbox.
    @Test func ignoresTemporaryFiles() {
        #expect(Inbox.kind(of: "..Screenshot 2026-10-09 at 6.29.36 PM.png-hOKjYG") == nil)
        #expect(Inbox.kind(of: ".Screen Recording 2026-10-10 at 12.30.00 PM.mov") == nil)
    }

    @Test func newCapturesSkipHandled() {
        let listing = ["b.png", ".tmp.png", "a.mov", "c.png", "notes.txt"]
        #expect(Inbox.newCaptures(in: listing, handled: ["c.png"]) == ["a.mov", "b.png"])
    }

    @Test func screenshotsGoBeforeVideos() {
        #expect(Inbox.next(in: ["a.mov", "c.png", "b.png"]) == "b.png")
        #expect(Inbox.next(in: ["b.mov", "a.mov"]) == "a.mov")
        #expect(Inbox.next(in: []) == nil)
    }

    @Test func onlyRecentGoToClipboard() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(Inbox.isRecent(created: now.addingTimeInterval(-3), now: now))
        #expect(!Inbox.isRecent(created: now.addingTimeInterval(-60), now: now))
    }

    @Test func mimeTypes() {
        #expect(Inbox.mimeType(for: "a.png") == "image/png")
        #expect(Inbox.mimeType(for: "a.JPG") == "image/jpeg")
        #expect(Inbox.mimeType(for: "a.mov") == "video/quicktime")
        #expect(Inbox.mimeType(for: "a.mp4") == "video/mp4")
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
