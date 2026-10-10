import Foundation
import Testing
@testable import ClippeekCore

@Suite(.serialized) struct CaptureSettingsTests {
    let inbox = URL(fileURLWithPath: "/tmp/inbox")
    let domain = "io.github.tangheng05.clippeek.tests.capture"
    let original: Preferences = ["target-screenshot": .string("clipboard"), "location-screenrecording": .string("/Users/me/Movies"),
                                 "show-thumbnail": .bool(true)]

    @Test func turningScreenshotsOnPointsThemAtTheInbox() {
        var state = CaptureState()
        let change = state.set(.screenshot, on: true, current: original, inbox: inbox)
        #expect(change == PreferenceChange(
            keys: ["location-screenshot", "target-screenshot", "show-thumbnail", "location", "target"],
            values: ["location-screenshot": .string("/tmp/inbox"), "target-screenshot": .string("file"),
                     "location": .string("/tmp/inbox"), "target": .string("file"), "show-thumbnail": .bool(false)]))
        #expect(state.isOn(.screenshot))
        #expect(!state.isOn(.video))
    }

    @Test func turningOnTwiceChangesNothing() {
        var state = CaptureState()
        _ = state.set(.video, on: true, current: original, inbox: inbox)
        #expect(state.set(.video, on: true, current: [:], inbox: inbox) == nil)
        #expect(state.set(.screenshot, on: false, current: [:], inbox: inbox) == nil)
    }

    @Test func turningOneOffRestoresOnlyItsKeys() {
        var state = CaptureState()
        _ = state.set(.screenshot, on: true, current: original, inbox: inbox)
        _ = state.set(.video, on: true, current: original, inbox: inbox)
        let change = state.set(.video, on: false, current: [:], inbox: inbox)
        #expect(change == PreferenceChange(keys: ["location-screenrecording", "target-screenrecording"],
                                           values: ["location-screenrecording": .string("/Users/me/Movies")]))
    }

    /// The floating thumbnail is shared, so it comes back only when both kinds are off.
    @Test func thumbnailComesBackWhenBothAreOff() {
        for order in [[CaptureKind.screenshot, .video], [.video, .screenshot]] {
            var state = CaptureState()
            _ = state.set(order[0], on: true, current: original, inbox: inbox)
            _ = state.set(order[1], on: true, current: ["show-thumbnail": .bool(false)], inbox: inbox)
            let first = state.set(order[0], on: false, current: [:], inbox: inbox)
            #expect(first?.keys.contains("show-thumbnail") == false)
            let last = state.set(order[1], on: false, current: [:], inbox: inbox)
            #expect(last?.keys.contains("show-thumbnail") == true)
            #expect(last?.values["show-thumbnail"] == .bool(true))
        }
        var single = CaptureState()
        _ = single.set(.screenshot, on: true, current: original, inbox: inbox)
        #expect(single.set(.screenshot, on: false, current: [:], inbox: inbox)?.values["show-thumbnail"] == .bool(true))
    }

    @Test func reapplyCoversEveryKindThatIsOn() {
        var state = CaptureState()
        #expect(state.reapply(inbox: inbox) == nil)
        _ = state.set(.video, on: true, current: [:], inbox: inbox)
        #expect(state.reapply(inbox: inbox) == PreferenceChange(
            keys: ["show-thumbnail", "location", "target", "location-screenrecording", "target-screenrecording"],
            values: ["show-thumbnail": .bool(false), "location": .string("/tmp/inbox"), "target": .string("file"),
                     "location-screenrecording": .string("/tmp/inbox"), "target-screenrecording": .string("file")]))
    }

    @Test func roundTripsThroughJSON() throws {
        var state = CaptureState()
        _ = state.set(.screenshot, on: true, current: original, inbox: inbox)
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(CaptureState.self, from: data) == state)
    }

    /// The build before recordings saved only screenshot settings, as `previousScreenshotSettings`.
    @Test func migratesCurrentBuild() throws {
        let json = #"{"location":"/Users/me/Desktop","target":"file","showThumbnail":true,"legacyTarget":"clipboard"}"#
        let state = try #require(CaptureState.migrating(legacy: Data(json.utf8)))
        #expect(state.isOn(.screenshot))
        #expect(!state.isOn(.video))
        var restore = state
        #expect(restore.set(.screenshot, on: false, current: [:], inbox: inbox)?.values ==
                ["location-screenshot": .string("/Users/me/Desktop"), "target-screenshot": .string("file"),
                 "target": .string("clipboard"), "show-thumbnail": .bool(true)])
        #expect(CaptureState.migrating(legacy: Data(#"{"target":"file"}"#.utf8))?.isOn(.screenshot) == true)
    }

    @Test func writesAndRemovesSystemKeys() {
        SystemPreferences.apply(PreferenceChange(keys: ["location-screenrecording", "show-thumbnail"],
                                                 values: ["location-screenrecording": .string("/tmp/inbox"),
                                                          "show-thumbnail": .bool(false)]), domain: domain)
        #expect(SystemPreferences.read(["location-screenrecording", "show-thumbnail", "target"], domain: domain) ==
                ["location-screenrecording": .string("/tmp/inbox"), "show-thumbnail": .bool(false)])
        SystemPreferences.apply(PreferenceChange(keys: ["location-screenrecording", "show-thumbnail"], values: [:]),
                                domain: domain)
        #expect(SystemPreferences.read(["location-screenrecording", "show-thumbnail"], domain: domain).isEmpty)
    }

    /// Before macOS 27 one `location`/`target` covers screenshots and recordings alike.
    @Test func olderKeysFollowEitherKind() {
        var state = CaptureState()
        let on = state.set(.video, on: true, current: ["location": .string("/Users/me/Shots")], inbox: inbox)
        #expect(on?.values["location"] == .string("/tmp/inbox"))
        #expect(on?.values["target"] == .string("file"))
        _ = state.set(.screenshot, on: true, current: [:], inbox: inbox)
        #expect(state.set(.video, on: false, current: [:], inbox: inbox)?.keys.contains("location") == false)
        let off = state.set(.screenshot, on: false, current: [:], inbox: inbox)
        #expect(off?.values["location"] == .string("/Users/me/Shots"))
        #expect(off?.keys.contains("target") == true)
    }

    /// The first recordings build kept `location`/`target` with screenshots and called the shared part `previousThumbnail`.
    @Test func migratesEarlierCaptureState() throws {
        let json = #"{"previous":{"screenshot":{"target-screenshot":{"string":{"_0":"file"}},"location":{"string":{"_0":"/Users/me/Desktop"}}}},"previousThumbnail":{"show-thumbnail":{"bool":{"_0":true}}}}"#
        var state = try JSONDecoder().decode(CaptureState.self, from: Data(json.utf8))
        #expect(state.isOn(.screenshot))
        #expect(state.set(.screenshot, on: false, current: [:], inbox: inbox)?.values ==
                ["target-screenshot": .string("file"), "location": .string("/Users/me/Desktop"), "show-thumbnail": .bool(true)])
    }

    /// A file of a kind that isn't being sent goes back where the user keeps those.
    @Test func userFolderForAKindThatIsOff() {
        let home = URL(fileURLWithPath: "/Users/me")
        var state = CaptureState()
        _ = state.set(.screenshot, on: true, current: ["location": .string("/Users/me/Shots")], inbox: inbox)
        #expect(state.userFolder(for: .video, current: ["location-screenrecording": .string("/Users/me/Movies")],
                                 inbox: inbox, home: home).path == "/Users/me/Movies")
        #expect(state.userFolder(for: .video, current: ["location": .string("/tmp/inbox")], inbox: inbox, home: home).path ==
                "/Users/me/Shots")
        #expect(CaptureState().userFolder(for: .video, current: [:], inbox: inbox, home: home).path == "/Users/me/Desktop")
    }
}
