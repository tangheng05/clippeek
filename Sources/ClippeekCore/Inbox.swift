import Foundation

public enum CaptureKind: String, Codable, CodingKeyRepresentable, Sendable, CaseIterable {
    case screenshot, video
}

public enum Inbox {
    private static let types: [String: (kind: CaptureKind, mime: String)] = [
        "png": (.screenshot, "image/png"), "jpg": (.screenshot, "image/jpeg"), "jpeg": (.screenshot, "image/jpeg"),
        "heic": (.screenshot, "image/heic"), "tiff": (.screenshot, "image/tiff"),
        "mov": (.video, "video/quicktime"), "mp4": (.video, "video/mp4"),
    ]

    /// screencaptureui writes to a hidden temporary name, then renames it; those are ignored.
    public static func kind(of name: String) -> CaptureKind? {
        name.hasPrefix(".") ? nil : types[(name as NSString).pathExtension.lowercased()]?.kind
    }

    public static func newCaptures(in listing: [String], handled: Set<String>) -> [String] {
        listing.filter { kind(of: $0) != nil && !handled.contains($0) }.sorted()
    }

    /// A file of a kind that isn't switched on goes back to the user instead of uploading.
    public static func shouldUpload(_ name: String, capturing: Set<CaptureKind>) -> Bool {
        kind(of: name).map(capturing.contains) ?? false
    }

    /// Screenshots first, so a long video never holds one up.
    public static func next(in waiting: [String]) -> String? {
        let sorted = waiting.sorted()
        return sorted.first { kind(of: $0) == .screenshot } ?? sorted.first
    }

    /// Files left from before launch still upload, but only fresh ones replace the clipboard.
    public static func isRecent(created: Date, now: Date) -> Bool {
        now.timeIntervalSince(created) < 15
    }

    public static func mimeType(for name: String) -> String {
        types[(name as NSString).pathExtension.lowercased()]?.mime ?? "application/octet-stream"
    }
}
