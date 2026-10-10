import Foundation

public struct HistoryItem: Codable, Equatable, Identifiable, Sendable {
    /// Zipline's file id, or the file's short name for chunked uploads.
    public var id: String
    public var url: URL
    public var created: Date
    public var deletesAt: Date?
    /// File name in the thumbnails folder.
    public var thumbnail: String
    public var kind: CaptureKind
    /// Where a copy stays on this Mac, if one does.
    public var localFile: URL?

    public init(id: String, url: URL, created: Date, deletesAt: Date?, thumbnail: String, kind: CaptureKind = .screenshot,
                localFile: URL? = nil) {
        self.id = id
        self.url = url
        self.created = created
        self.deletesAt = deletesAt
        self.thumbnail = thumbnail
        self.kind = kind
        self.localFile = localFile
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        url = try container.decode(URL.self, forKey: .url)
        created = try container.decode(Date.self, forKey: .created)
        deletesAt = try container.decodeIfPresent(Date.self, forKey: .deletesAt)
        thumbnail = try container.decode(String.self, forKey: .thumbnail)
        kind = try container.decodeIfPresent(CaptureKind.self, forKey: .kind) ?? .screenshot
        localFile = try container.decodeIfPresent(URL.self, forKey: .localFile)
    }

    /// "6d left", rounded down; nil when Zipline keeps the file.
    public func timeLeft(now: Date) -> String? {
        guard let deletesAt else { return nil }
        let minutes = Int(deletesAt.timeIntervalSince(now) / 60)
        switch minutes {
        case ..<1: return "<1m left"
        case ..<60: return "\(minutes)m left"
        case ..<(24 * 60): return "\(minutes / 60)h left"
        default: return "\(minutes / (24 * 60))d left"
        }
    }
}

public struct History: Codable, Equatable, Sendable {
    public static let limit = 50
    /// Newest first.
    public private(set) var items: [HistoryItem]

    public init(items: [HistoryItem] = []) {
        self.items = items
    }

    /// Returns what fell off the end, so its thumbnails can be deleted.
    @discardableResult
    public mutating func add(_ item: HistoryItem) -> [HistoryItem] {
        items.insert(item, at: 0)
        guard items.count > Self.limit else { return [] }
        let dropped = Array(items[Self.limit...])
        items.removeLast(items.count - Self.limit)
        return dropped
    }

    public mutating func removeExpired(now: Date) -> [HistoryItem] {
        let isExpired: (HistoryItem) -> Bool = { $0.deletesAt.map { $0 <= now } ?? false }
        let expired = items.filter(isExpired)
        items.removeAll(where: isExpired)
        return expired
    }

    public mutating func remove(id: String) -> HistoryItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    /// Nil when the file can't be read at all; single bad items, e.g. from a newer build, are skipped.
    public static func decode(_ data: Data) -> History? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(History.self, from: data)
    }

    /// A missing file starts a fresh history; a damaged one is kept beside it as `.bad` first.
    public static func load(from file: URL) -> History {
        guard let data = try? Data(contentsOf: file) else { return History() }
        if let history = decode(data) { return history }
        try? data.write(to: file.appendingPathExtension("bad"), options: .withoutOverwriting)
        return History()
    }

    private struct Lenient: Decodable {
        let item: HistoryItem?

        init(from decoder: any Decoder) throws {
            item = try? HistoryItem(from: decoder)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case items
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([Lenient].self, forKey: .items).compactMap(\.item)
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(self)) ?? Data()
    }
}
