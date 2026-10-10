import CoreFoundation
import Foundation

/// A value in `com.apple.screencapture`.
public enum PreferenceValue: Codable, Equatable, Sendable {
    case string(String), bool(Bool)
}

/// Some keys of a preferences domain; a key missing here isn't set.
public typealias Preferences = [String: PreferenceValue]

/// Every key listed is set to its value, or removed when it has none.
public struct PreferenceChange: Equatable, Sendable {
    public var keys: [String]
    public var values: Preferences

    public init(keys: [String], values: Preferences) {
        self.keys = keys
        self.values = values
    }
}

public enum SystemPreferences {
    public static let screencapture = "com.apple.screencapture"

    public static func read(_ keys: [String], domain: String = screencapture) -> Preferences {
        var result: Preferences = [:]
        for key in keys {
            switch CFPreferencesCopyAppValue(key as CFString, domain as CFString) {
            case let text as String: result[key] = .string(text)
            case let flag as Bool: result[key] = .bool(flag)
            default: break
            }
        }
        return result
    }

    public static func apply(_ change: PreferenceChange, domain: String = screencapture) {
        for key in change.keys {
            let value: AnyObject? = switch change.values[key] {
            case .string(let text): text as NSString
            case .bool(let flag): NSNumber(value: flag)
            case nil: nil
            }
            CFPreferencesSetAppValue(key as CFString, value, domain as CFString)
        }
        CFPreferencesAppSynchronize(domain as CFString)
    }
}

/// What clippeek changed in the system capture settings, so it can put them back.
public struct CaptureState: Codable, Equatable, Sendable {
    public static let thumbnailKey = "show-thumbnail"
    public static let allKeys = keys(for: .screenshot) + keys(for: .video) + [thumbnailKey]

    /// The user's values from before each kind was turned on; a kind is on while it has an entry.
    private var previous: [CaptureKind: Preferences] = [:]
    /// `show-thumbnail` from before the first kind was turned on; the floating thumbnail delays saving.
    private var previousThumbnail: Preferences = [:]

    public init() {}

    /// macOS 27 reads the `-screenshot`/`-screenrecording` keys; older versions `location` and `target`.
    public static func keys(for kind: CaptureKind) -> [String] {
        switch kind {
        case .screenshot: ["location-screenshot", "target-screenshot", "location", "target"]
        case .video: ["location-screenrecording", "target-screenrecording"]
        }
    }

    public func isOn(_ kind: CaptureKind) -> Bool {
        previous[kind] != nil
    }

    /// Returns what to write, or nil when nothing changes. `current` holds the system's present values.
    public mutating func set(_ kind: CaptureKind, on: Bool, current: Preferences, inbox: URL) -> PreferenceChange? {
        guard on != isOn(kind) else { return nil }
        let kindKeys = Self.keys(for: kind)
        if on {
            if previous.isEmpty { previousThumbnail = current.filter { $0.key == Self.thumbnailKey } }
            previous[kind] = current.filter { kindKeys.contains($0.key) }
            return PreferenceChange(keys: kindKeys + [Self.thumbnailKey],
                                    values: Self.capturing(kind, into: inbox).merging([Self.thumbnailKey: .bool(false)]) { $1 })
        }
        var keys = kindKeys
        var values = previous.removeValue(forKey: kind) ?? [:]
        if previous.isEmpty {
            keys.append(Self.thumbnailKey)
            values.merge(previousThumbnail) { $1 }
            previousThumbnail = [:]
        }
        return PreferenceChange(keys: keys, values: values)
    }

    /// Puts the inbox back for every kind that's on, e.g. after something else changed the location.
    public func reapply(inbox: URL) -> PreferenceChange? {
        guard !previous.isEmpty else { return nil }
        var change = PreferenceChange(keys: [Self.thumbnailKey], values: [Self.thumbnailKey: .bool(false)])
        for kind in CaptureKind.allCases where isOn(kind) {
            change.keys += Self.keys(for: kind)
            change.values.merge(Self.capturing(kind, into: inbox)) { $1 }
        }
        return change
    }

    /// The build before recordings saved only the screenshot settings, as `previousScreenshotSettings`.
    public static func migrating(legacy data: Data) -> CaptureState? {
        struct Legacy: Decodable {
            var location, target, legacyLocation, legacyTarget: String?
            var showThumbnail: Bool?
        }
        guard let legacy = try? JSONDecoder().decode(Legacy.self, from: data) else { return nil }
        var screenshot: Preferences = [:]
        screenshot["location-screenshot"] = legacy.location.map(PreferenceValue.string)
        screenshot["target-screenshot"] = legacy.target.map(PreferenceValue.string)
        screenshot["location"] = legacy.legacyLocation.map(PreferenceValue.string)
        screenshot["target"] = legacy.legacyTarget.map(PreferenceValue.string)
        var state = CaptureState()
        state.previous[.screenshot] = screenshot
        state.previousThumbnail = legacy.showThumbnail.map { [thumbnailKey: .bool($0)] } ?? [:]
        return state
    }

    private static func capturing(_ kind: CaptureKind, into inbox: URL) -> Preferences {
        Dictionary(uniqueKeysWithValues: keys(for: kind).map { key in
            (key, key.hasPrefix("location") ? .string(inbox.path) : .string("file"))
        })
    }
}
