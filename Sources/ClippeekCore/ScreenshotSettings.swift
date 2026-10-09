import CoreFoundation
import Foundation

/// The parts of the system screenshot settings clippeek changes. Nil means the key isn't set.
public struct ScreenshotSettings: Codable, Equatable, Sendable {
    /// `location-screenshot`, read by macOS 27.
    public var location: String?
    /// `target-screenshot`: "file", "clipboard", "preview"…
    public var target: String?
    public var showThumbnail: Bool?
    /// `location` and `target`, read by older macOS versions.
    public var legacyLocation: String?
    public var legacyTarget: String?

    public static let systemDomain = "com.apple.screencapture"

    public init(location: String?, target: String?, showThumbnail: Bool?,
                legacyLocation: String? = nil, legacyTarget: String? = nil) {
        self.location = location
        self.target = target
        self.showThumbnail = showThumbnail
        self.legacyLocation = legacyLocation
        self.legacyTarget = legacyTarget
    }

    /// The floating thumbnail delays saving by about 5 s, so it's turned off.
    public static func capturing(into inbox: URL) -> ScreenshotSettings {
        ScreenshotSettings(location: inbox.path, target: "file", showThumbnail: false,
                           legacyLocation: inbox.path, legacyTarget: "file")
    }

    public static func read(domain: String = systemDomain) -> ScreenshotSettings {
        func value(_ key: String) -> Any? { CFPreferencesCopyAppValue(key as CFString, domain as CFString) }
        return ScreenshotSettings(location: value("location-screenshot") as? String,
                                  target: value("target-screenshot") as? String,
                                  showThumbnail: value("show-thumbnail") as? Bool,
                                  legacyLocation: value("location") as? String,
                                  legacyTarget: value("target") as? String)
    }

    public func write(domain: String = Self.systemDomain) {
        func set(_ key: String, _ value: Any?) {
            CFPreferencesSetAppValue(key as CFString, value.map { $0 as AnyObject }, domain as CFString)
        }
        set("location-screenshot", location)
        set("target-screenshot", target)
        set("show-thumbnail", showThumbnail)
        set("location", legacyLocation)
        set("target", legacyTarget)
        CFPreferencesAppSynchronize(domain as CFString)
    }
}
