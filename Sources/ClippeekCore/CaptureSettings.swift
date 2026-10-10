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
    /// Before macOS 27, `location` and `target` cover both kinds; the floating thumbnail always does.
    public static let sharedKeys = ["show-thumbnail", "location", "target"]
    public static let allKeys = keys(for: .screenshot) + keys(for: .video) + sharedKeys

    /// The user's values from before each kind was turned on; a kind is on while it has an entry.
    private var previous: [CaptureKind: Preferences] = [:]
    /// The shared keys as they were before the first kind was turned on.
    private var previousShared: Preferences = [:]

    public init() {}

    public static func keys(for kind: CaptureKind) -> [String] {
        switch kind {
        case .screenshot: ["location-screenshot", "target-screenshot"]
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
            let saved = Self.userValues(current, inbox: inbox)
            if previous.isEmpty { previousShared = saved.filter { Self.sharedKeys.contains($0.key) } }
            previous[kind] = saved.filter { kindKeys.contains($0.key) }
            return PreferenceChange(keys: kindKeys + Self.sharedKeys,
                                    values: Self.capturing(kind, into: inbox).merging(Self.shared(into: inbox)) { $1 })
        }
        var keys = kindKeys
        var values = previous.removeValue(forKey: kind) ?? [:]
        if previous.isEmpty {
            keys += Self.sharedKeys
            values.merge(previousShared) { $1 }
            previousShared = [:]
        }
        return PreferenceChange(keys: keys, values: values)
    }

    /// Puts the inbox back for every kind that's on. Values something else set meanwhile are the user's
    /// new choice, so they become what turning off restores.
    public mutating func reapply(current: Preferences, inbox: URL) -> PreferenceChange? {
        guard !previous.isEmpty else { return nil }
        let shared = Self.shared(into: inbox)
        if !Self.unchanged(current, ours: shared, inbox: inbox) {
            previousShared = Self.userValues(current, inbox: inbox).filter { Self.sharedKeys.contains($0.key) }
        }
        var change = PreferenceChange(keys: Self.sharedKeys, values: shared)
        for kind in CaptureKind.allCases where isOn(kind) {
            let kindKeys = Self.keys(for: kind)
            let capturing = Self.capturing(kind, into: inbox)
            if !Self.unchanged(current, ours: capturing, inbox: inbox) {
                previous[kind] = Self.userValues(current, inbox: inbox).filter { kindKeys.contains($0.key) }
            }
            change.keys += kindKeys
            change.values.merge(capturing) { $1 }
        }
        return change
    }

    /// What turning off every kind that's on would write, e.g. before the app is removed.
    public func restoreChange() -> PreferenceChange? {
        guard !previous.isEmpty else { return nil }
        var change = PreferenceChange(keys: [], values: previousShared)
        for kind in CaptureKind.allCases {
            guard let values = previous[kind] else { continue }
            change.keys += Self.keys(for: kind)
            change.values.merge(values) { $1 }
        }
        change.keys += Self.sharedKeys
        return change
    }

    /// Where a file of a kind that isn't being sent belongs: the user's own folder for it, else the Desktop.
    public func userFolder(for kind: CaptureKind, current: Preferences, inbox: URL, home: URL) -> URL {
        let locationKey = kind == .screenshot ? "location-screenshot" : "location-screenrecording"
        for value in [current[locationKey], previousShared["location"], current["location"]] {
            if case .string(let path)? = value, !Self.points(value, at: inbox) { return URL(fileURLWithPath: path) }
        }
        return home.appending(path: "Desktop")
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
        var state = CaptureState()
        state.previous[.screenshot] = screenshot
        state.previousShared["location"] = legacy.legacyLocation.map(PreferenceValue.string)
        state.previousShared["target"] = legacy.legacyTarget.map(PreferenceValue.string)
        state.previousShared["show-thumbnail"] = legacy.showThumbnail.map(PreferenceValue.bool)
        return state
    }

    private enum CodingKeys: String, CodingKey {
        case previous, previousShared, previousThumbnail
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        previous = try container.decodeIfPresent([CaptureKind: Preferences].self, forKey: .previous) ?? [:]
        if let shared = try container.decodeIfPresent(Preferences.self, forKey: .previousShared) {
            previousShared = shared
        } else {
            // The first recordings build kept `location`/`target` with screenshots.
            previousShared = try container.decodeIfPresent(Preferences.self, forKey: .previousThumbnail) ?? [:]
            for key in ["location", "target"] {
                if let value = previous[.screenshot]?.removeValue(forKey: key) { previousShared[key] = value }
            }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(previous, forKey: .previous)
        try container.encode(previousShared, forKey: .previousShared)
    }

    private static func capturing(_ kind: CaptureKind, into inbox: URL) -> Preferences {
        Dictionary(uniqueKeysWithValues: keys(for: kind).map { key in
            (key, key.hasPrefix("location") ? .string(inbox.path) : .string("file"))
        })
    }

    /// The inbox is never the user's own choice, so it and its "file" target aren't kept to restore.
    private static func userValues(_ values: Preferences, inbox: URL) -> Preferences {
        var result = values
        for (key, value) in values where points(value, at: inbox) {
            result[key] = nil
            let target = key.replacingOccurrences(of: "location", with: "target")
            if result[target] == .string("file") { result[target] = nil }
        }
        return result
    }

    private static func unchanged(_ current: Preferences, ours: Preferences, inbox: URL) -> Bool {
        ours.allSatisfy { key, value in
            current[key] == value || (points(value, at: inbox) && points(current[key], at: inbox))
        }
    }

    private static func points(_ value: PreferenceValue?, at inbox: URL) -> Bool {
        guard case .string(let path)? = value else { return false }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
            == inbox.standardizedFileURL.path
    }

    /// The floating thumbnail delays saving by about 5 s, so it's turned off.
    private static func shared(into inbox: URL) -> Preferences {
        ["show-thumbnail": .bool(false), "location": .string(inbox.path), "target": .string("file")]
    }
}
