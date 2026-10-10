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
        #expect(Inbox.kind(of: "a.pdf") == .screenshot)
        #expect(Inbox.kind(of: "a.gif") == .screenshot)
        #expect(Inbox.kind(of: "a.BMP") == .screenshot)
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
        let date = Date(timeIntervalSince1970: 1000)
        #expect(Inbox.next(in: [("a.mov", date), ("c.png", date), ("b.png", date)]) == "b.png")
        #expect(Inbox.next(in: [("b.mov", date), ("a.mov", date)]) == "a.mov")
        #expect(Inbox.next(in: [("a.mov", date), ("b.png", date.addingTimeInterval(60))]) == "b.png")
        #expect(Inbox.next(in: []) == nil)
    }

    /// "1.05" sorts before "9.15" by name, though it was taken hours later.
    @Test func oldestGoesFirst() {
        let morning = Date(timeIntervalSince1970: 1000)
        var waiting = [
            ("Screenshot 2026-10-10 at 1.05.00\u{202F}PM.png", morning.addingTimeInterval(4 * 3600)),
            ("Screenshot 2026-10-10 at 10.30.00\u{202F}AM.png", morning.addingTimeInterval(3600)),
            ("Screenshot 2026-10-10 at 9.15.00\u{202F}AM.png", morning),
        ]
        var order: [String] = []
        while let next = Inbox.next(in: waiting.map { (name: $0.0, created: $0.1) }) {
            order.append(next)
            waiting.removeAll { $0.0 == next }
        }
        #expect(order == ["Screenshot 2026-10-10 at 9.15.00\u{202F}AM.png", "Screenshot 2026-10-10 at 10.30.00\u{202F}AM.png",
                          "Screenshot 2026-10-10 at 1.05.00\u{202F}PM.png"])
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
        #expect(Inbox.mimeType(for: "a.pdf") == "application/pdf")
        #expect(Inbox.mimeType(for: "a.gif") == "image/gif")
        #expect(Inbox.mimeType(for: "a.bmp") == "image/bmp")
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

    /// A file of a kind that isn't switched on goes back to the user instead of uploading.
    @Test func uploadsOnlyKindsBeingSent() {
        #expect(Inbox.shouldUpload("a.mov", capturing: [.screenshot, .video]))
        #expect(!Inbox.shouldUpload("a.mov", capturing: [.screenshot]))
        #expect(Inbox.shouldUpload("a.png", capturing: [.screenshot]))
        #expect(!Inbox.shouldUpload("a.png", capturing: []))
    }
}
