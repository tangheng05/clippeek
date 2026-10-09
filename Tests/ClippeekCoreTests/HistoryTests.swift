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

    @Test func roundTrips() {
        let history = History(items: [item("a", deletesAt: Date(timeIntervalSince1970: 10))])
        #expect(History.decode(history.encoded()) == history)
    }

    @Test func corruptHistoryIsEmpty() {
        #expect(History.decode(nil).items.isEmpty)
        #expect(History.decode(Data("{not json".utf8)).items.isEmpty)
    }

    @Test func backoffSteps() {
        #expect(Backoff.delay(attempt: 0) == 5)
        #expect(Backoff.delay(attempt: 3) == 600)
        #expect(Backoff.delay(attempt: 4) == nil)
    }
}
