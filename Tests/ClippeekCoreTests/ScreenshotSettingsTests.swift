import Foundation
import Testing
@testable import ClippeekCore

@Suite(.serialized) struct ScreenshotSettingsTests {
    let domain = "io.github.tangheng05.clippeek.tests.screencapture"
    let empty = ScreenshotSettings(location: nil, target: nil, showThumbnail: nil)

    func raw(_ key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, domain as CFString)
    }

    @Test func capturingSettings() {
        let settings = ScreenshotSettings.capturing(into: URL(fileURLWithPath: "/tmp/inbox"))
        #expect(settings == ScreenshotSettings(location: "/tmp/inbox", target: "file", showThumbnail: false,
                                               legacyLocation: "/tmp/inbox", legacyTarget: "file"))
    }

    /// macOS 27 reads `location-screenshot` and `target-screenshot`; older versions `location` and `target`.
    @Test func writesCurrentAndLegacyKeys() {
        ScreenshotSettings.capturing(into: URL(fileURLWithPath: "/tmp/inbox")).write(domain: domain)
        #expect(raw("location-screenshot") as? String == "/tmp/inbox")
        #expect(raw("target-screenshot") as? String == "file")
        #expect(raw("location") as? String == "/tmp/inbox")
        #expect(raw("target") as? String == "file")
        #expect(raw("show-thumbnail") as? Bool == false)
        empty.write(domain: domain)
        #expect(raw("location-screenshot") == nil)
        #expect(raw("location") == nil)
    }

    @Test func writesAndRestores() {
        let previous = ScreenshotSettings(location: "/Users/me/Desktop", target: "clipboard", showThumbnail: nil,
                                          legacyLocation: "/Users/me/Old", legacyTarget: nil)
        previous.write(domain: domain)
        #expect(ScreenshotSettings.read(domain: domain) == previous)
        empty.write(domain: domain)
        #expect(ScreenshotSettings.read(domain: domain) == empty)
    }

    /// Settings saved by the first build only had the three original fields.
    @Test func decodesOlderSavedSettings() throws {
        let saved = try JSONDecoder().decode(ScreenshotSettings.self, from: Data(#"{"target":"file"}"#.utf8))
        #expect(saved == ScreenshotSettings(location: nil, target: "file", showThumbnail: nil))
    }
}
