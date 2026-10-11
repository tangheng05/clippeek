import Foundation
import Testing
@testable import ClippeekCore

@Suite struct HistoryTests {
    func item(_ id: String, deletesAt: Date? = nil) -> HistoryItem {
        HistoryItem(id: id, url: URL(string: "https://z.io/u/\(id).png")!, created: Date(timeIntervalSince1970: 0),
                    deletesAt: deletesAt, thumbnail: "\(id).png")
    }

    @Test func newestFirstAndCapped() {
        var history = History()
        var dropped: [HistoryItem] = []
        for index in 0..<(History.limit + 2) { dropped += history.add(item("\(index)")) }
        #expect(history.items.count == History.limit)
        #expect(history.items.first?.id == "\(History.limit + 1)")
        #expect(dropped.map(\.id) == ["0", "1"])
    }

    @Test func removesExpired() {
        var history = History(items: [item("a", deletesAt: Date(timeIntervalSince1970: 10)), item("b")])
        let expired = history.removeExpired(now: Date(timeIntervalSince1970: 20))
        #expect(expired.map(\.id) == ["a"])
        #expect(history.items.map(\.id) == ["b"])
    }

    @Test func timeLeft() {
        let now = Date(timeIntervalSince1970: 0)
        let left = { (seconds: Double) in self.item("a", deletesAt: now.addingTimeInterval(seconds)).timeLeft(now: now) }
        #expect(item("a").timeLeft(now: now) == nil)
        #expect(left(30) == "<1m left")
        #expect(left(12 * 60 + 59) == "12m left")
        #expect(left(5 * 3600 + 120) == "5h left")
        #expect(left(6 * 86400 + 3600) == "6d left")
    }

    @Test func roundTrips() {
        let history = History(items: [item("a", deletesAt: Date(timeIntervalSince1970: 10))])
        #expect(History.decode(history.encoded()) == history)
    }

    @Test func corruptHistoryIsNil() {
        #expect(History.decode(Data("{not json".utf8)) == nil)
        #expect(History.decode(Data(#"{"items":3}"#.utf8)) == nil)
    }

    /// An item this build can't read, e.g. a kind from a newer one, doesn't take the rest with it.
    @Test func skipsBadItems() {
        let json = #"{"items":[{"id":"a","url":"https://z.io/u/a.png","created":"2026-10-09T10:00:00Z","thumbnail":"a.png"},"#
            + #"{"id":"b","url":"https://z.io/u/b.gif","created":"2026-10-09T10:00:00Z","thumbnail":"b.png","kind":"gif"}]}"#
        #expect(History.decode(Data(json.utf8))?.items.map(\.id) == ["a"])
    }

    @Test func loadKeepsADamagedFile() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "history.json")
        #expect(History.load(from: file).items.isEmpty)
        try Data("{not json".utf8).write(to: file)
        #expect(History.load(from: file).items.isEmpty)
        #expect(try Data(contentsOf: folder.appending(path: "history.json.bad")) == Data("{not json".utf8))
        let history = History(items: [item("a")])
        try history.encoded().write(to: file)
        #expect(History.load(from: file) == history)
    }

    @Test func backoffSteps() {
        #expect(Backoff.delay(attempt: 0) == 5)
        #expect(Backoff.delay(attempt: 3) == 600)
        #expect(Backoff.delay(attempt: 4) == 1800)
        #expect(Backoff.delay(attempt: 40) == 1800)
        #expect(Backoff.isPastSteps(4) && !Backoff.isPastSteps(3))
    }

    /// history.json written before videos existed has no `kind`.
    @Test func decodesItemsWithoutKind() {
        let json = #"{"items":[{"id":"a","url":"https://z.io/u/a.png","created":"2026-10-09T10:00:00Z","thumbnail":"a.png"}]}"#
        #expect(History.decode(Data(json.utf8))?.items.first?.kind == .screenshot)
    }

    @Test func keepsVideoKind() {
        var video = item("v")
        video.kind = .video
        let history = History(items: [video])
        #expect(History.decode(history.encoded())?.items.first?.kind == .video)
    }
}
