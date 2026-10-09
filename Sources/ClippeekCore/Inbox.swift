import Foundation

public enum Inbox {
    private static let types = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
                                "heic": "image/heic", "tiff": "image/tiff"]

    /// screencaptureui writes to a hidden temporary name, then renames it.
    public static func isScreenshot(_ name: String) -> Bool {
        !name.hasPrefix(".") && types[(name as NSString).pathExtension.lowercased()] != nil
    }

    public static func newScreenshots(in listing: [String], handled: Set<String>) -> [String] {
        listing.filter { isScreenshot($0) && !handled.contains($0) }.sorted()
    }

    /// Files left from before launch still upload, but only fresh ones replace the clipboard.
    public static func isRecent(created: Date, now: Date) -> Bool {
        now.timeIntervalSince(created) < 15
    }

    public static func mimeType(for name: String) -> String {
        types[(name as NSString).pathExtension.lowercased()] ?? "application/octet-stream"
    }
}
