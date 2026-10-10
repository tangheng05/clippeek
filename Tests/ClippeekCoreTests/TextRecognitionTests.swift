import AppKit
import Testing
@testable import ClippeekCore

@Suite struct TextRecognitionTests {
    @Test func readsRenderedText() async throws {
        let image = NSImage(size: NSSize(width: 600, height: 120), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            NSAttributedString(string: "Hello clippeek", attributes: [.font: NSFont.systemFont(ofSize: 48)])
                .draw(at: NSPoint(x: 20, y: 30))
            return true
        }
        let png = try #require(image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) })
        #expect(await TextRecognition.text(in: png) == "Hello clippeek")
    }

    @Test func blankImageHasNoText() async throws {
        let image = NSImage(size: NSSize(width: 50, height: 50), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let png = try #require(image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) })
        #expect(await TextRecognition.text(in: png) == nil)
    }
}
