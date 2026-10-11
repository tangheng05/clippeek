import Foundation
import Testing
@testable import ClippeekCore

@Suite struct LinkFormatTests {
    let image = URL(string: "https://z.io/u/abc.png")!
    let video = URL(string: "https://z.io/u/rec.mov")!
    let file = URL(string: "https://z.io/u/notes.zip")!

    @Test func markdown() {
        #expect(LinkFormat.plain.text(for: image) == "https://z.io/u/abc.png")
        #expect(LinkFormat.markdown.text(for: image) == "![](https://z.io/u/abc.png)")
        #expect(LinkFormat.markdown.text(for: video) == "[rec.mov](https://z.io/u/rec.mov)")
    }

    @Test func html() {
        #expect(LinkFormat.html.text(for: image) == "<img src=\"https://z.io/u/abc.png\">")
        #expect(LinkFormat.html.text(for: video) == "<video src=\"https://z.io/u/rec.mov\" controls></video>")
        #expect(LinkFormat.html.text(for: file) == "<a href=\"https://z.io/u/notes.zip\">notes.zip</a>")
        #expect(LinkFormat.markdown.text(for: URL(string: "https://z.io/u/doc.pdf")!) == "[doc.pdf](https://z.io/u/doc.pdf)")
    }
}
