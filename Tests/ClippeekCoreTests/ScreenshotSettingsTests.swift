import Foundation
import Testing
@testable import ClippeekCore

@Suite(.serialized) struct ScreenshotSettingsTests {
    let domain = "io.github.tangheng05.clippeek.tests.screencapture"

    @Test func capturingSettings() {
        let settings = ScreenshotSettings.capturing(into: URL(fileURLWithPath: "/tmp/inbox"))
        #expect(settings == ScreenshotSettings(location: "/tmp/inbox", target: "file", showThumbnail: false))
    }

    @Test func writesAndRestores() {
        let previous = ScreenshotSettings(location: "/Users/me/Desktop", target: "clipboard", showThumbnail: nil)
        previous.write(domain: domain)
        #expect(ScreenshotSettings.read(domain: domain) == previous)
        ScreenshotSettings(location: nil, target: nil, showThumbnail: nil).write(domain: domain)
        #expect(ScreenshotSettings.read(domain: domain) == ScreenshotSettings(location: nil, target: nil, showThumbnail: nil))
    }
}
