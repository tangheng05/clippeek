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

    public init(id: String, url: URL, created: Date, deletesAt: Date?, thumbnail: String, kind: CaptureKind = .screenshot) {
        self.id = id
        self.url = url
        self.created = created
        self.deletesAt = deletesAt
        self.thumbnail = thumbnail
        self.kind = kind
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        url = try container.decode(URL.self, forKey: .url)
        created = try container.decode(Date.self, forKey: .created)
        deletesAt = try container.decodeIfPresent(Date.self, forKey: .deletesAt)
        thumbnail = try container.decode(String.self, forKey: .thumbnail)
        kind = try container.decodeIfPresent(CaptureKind.self, forKey: .kind) ?? .screenshot
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

    /// A missing or damaged file starts a fresh history rather than failing.
    public static func decode(_ data: Data?) -> History {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data, let history = try? decoder.decode(History.self, from: data) else { return History() }
        return history
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(self)) ?? Data()
    }
}
