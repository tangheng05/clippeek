import CoreFoundation
import Foundation

/// The parts of the system screenshot settings clippeek changes. Nil means the key isn't set.
public struct ScreenshotSettings: Codable, Equatable, Sendable {
    public var location: String?
    /// `target-screenshot`: "file", "clipboard", "preview"…
    public var target: String?
    public var showThumbnail: Bool?

    public static let systemDomain = "com.apple.screencapture"

    public init(location: String?, target: String?, showThumbnail: Bool?) {
        self.location = location
        self.target = target
        self.showThumbnail = showThumbnail
    }

    /// The floating thumbnail delays saving by about 5 s, so it's turned off.
    public static func capturing(into inbox: URL) -> ScreenshotSettings {
        ScreenshotSettings(location: inbox.path, target: "file", showThumbnail: false)
    }

    public static func read(domain: String = systemDomain) -> ScreenshotSettings {
        func value(_ key: String) -> Any? { CFPreferencesCopyAppValue(key as CFString, domain as CFString) }
        return ScreenshotSettings(location: value("location") as? String, target: value("target-screenshot") as? String,
                                  showThumbnail: value("show-thumbnail") as? Bool)
    }

    public func write(domain: String = Self.systemDomain) {
        func set(_ key: String, _ value: Any?) {
            CFPreferencesSetAppValue(key as CFString, value.map { $0 as AnyObject }, domain as CFString)
        }
        set("location", location)
        set("target-screenshot", target)
        set("show-thumbnail", showThumbnail)
        CFPreferencesAppSynchronize(domain as CFString)
    }
}
