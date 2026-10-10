import Foundation
import Testing
@testable import ClippeekCore

final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        Self.lastRequest = request
        let (status, data) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct ZiplineClientTests {
    let client: ZiplineClient = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return ZiplineClient(server: ZiplineServer("zip.example.com")!, token: "secret",
                             session: URLSession(configuration: configuration))
    }()

    @Test func uploads() async throws {
        StubProtocol.handler = { _ in
            (200, Data(#"{"files":[{"id":"a","name":"a.png","type":"image/png","url":"https://z.io/u/a.png"}]}"#.utf8))
        }
        let result = try await client.upload(Data("PNG".utf8), filename: "a.png", expiry: .never)
        #expect(result.url.absoluteString == "https://z.io/u/a.png")
        #expect(StubProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == "secret")
    }

    func item(_ id: String, minutesAgo: Double) -> HistoryItem {
        HistoryItem(id: id, url: URL(string: "https://zip.example.com/\(id)")!, created: .now.addingTimeInterval(-minutesAgo * 60),
                    deletesAt: nil, thumbnail: "\(id).png")
    }

    func page(_ files: [(id: String, name: String, minutesAgo: Double)], pages: Int) -> Data {
        let formatter = ISO8601DateFormatter()
        let entries = files.map { #"{"id":"\#($0.id)","name":"\#($0.name)","createdAt":"\#(formatter.string(from: .now.addingTimeInterval(-$0.minutesAgo * 60)))"}"# }
        return Data(#"{"page":[\#(entries.joined(separator: ","))],"total":0,"pages":\#(pages)}"#.utf8)
    }

    @Test func findsFilesDeletedOnTheServer() async throws {
        // One page covers everything: "b" is gone, "c.mov" matches by name like chunked uploads.
        StubProtocol.handler = { _ in (200, self.page([("a", "a.png", 1), ("x9", "c.mov", 3)], pages: 1)) }
        let missing = try await client.missing(from: [item("a", minutesAgo: 1), item("b", minutesAgo: 2), item("c.mov", minutesAgo: 3)])
        #expect(missing == ["b"])
        #expect(StubProtocol.lastRequest?.url?.query()?.contains("sortBy=createdAt") == true)
    }

    @Test func judgesOnlyWhatThePagesCovered() async throws {
        // Two of many pages read; "old" is older than anything listed, so it isn't judged.
        StubProtocol.requests = []
        StubProtocol.handler = { request in
            request.url?.query()?.contains("page=1&") == true
                ? (200, self.page([("a", "a.png", 1)], pages: 9))
                : (200, self.page([("z", "z.png", 600)], pages: 9))
        }
        let missing = try await client.missing(from: [item("a", minutesAgo: 1), item("gone", minutesAgo: 5),
                                                       item("old", minutesAgo: 6000)], maxPages: 2)
        #expect(missing == ["gone"])
        #expect(StubProtocol.requests.count == 2)
    }

    @Test func deletingAMissingFileSucceeds() async throws {
        StubProtocol.handler = { _ in (404, Data(#"{"error":"E4000: File not found","code":4000,"statusCode":404}"#.utf8)) }
        try await client.delete(id: "gone")
        #expect(StubProtocol.lastRequest?.httpMethod == "DELETE")
    }

    @Test func badTokenThrows() async {
        StubProtocol.handler = { _ in (401, Data()) }
        await #expect(throws: ZiplineError.unauthorized) {
            try await client.upload(Data(), filename: "a.png", expiry: .never)
        }
    }

    func tenByteFile() throws -> URL {
        let file = FileManager.default.temporaryDirectory.appending(path: "clippeek-\(UUID().uuidString).mov")
        try Data("abcdefghij".utf8).write(to: file)
        return file
    }

    final class Calls: @unchecked Sendable {
        var progress: [Double] = []
        var between = 0
    }

    @Test func uploadsFileInChunks() async throws {
        StubProtocol.requests = []
        StubProtocol.handler = { request in
            if request.value(forHTTPHeaderField: "x-zipline-p-lastchunk") == "true" {
                return (200, Data(#"{"files":[{"id":0,"name":"Ab3.mov","url":"https://z.io/Ab3.mov","pending":true}],"partialToken":"x"}"#.utf8))
            }
            return (200, Data(#"{"files":[],"partialToken":"t\#(StubProtocol.requests.count)"}"#.utf8))
        }
        let calls = Calls()
        let result = try await client.uploadFile(at: try tenByteFile(), filename: "a.mov", expiry: .never, chunkSize: 4,
                                                 progress: { calls.progress.append($0) }, betweenChunks: { calls.between += 1 })
        #expect(result == UploadResult(id: "Ab3.mov", url: URL(string: "https://z.io/Ab3.mov")!, deletesAt: nil))
        #expect(StubProtocol.requests.map { $0.value(forHTTPHeaderField: "Content-Range") } ==
                ["bytes 0-3/10", "bytes 4-7/10", "bytes 8-9/10"])
        #expect(StubProtocol.requests.map { $0.value(forHTTPHeaderField: "x-zipline-p-token") } == [nil, "t1", "t2"])
        #expect(calls.progress == [0.4, 0.8, 1])
        #expect(calls.between == 2)
    }

    /// Another upload can run between chunks: Zipline keeps a partial upload for 30 minutes.
    @Test func letsOthersGoBetweenChunks() async throws {
        StubProtocol.requests = []
        StubProtocol.handler = { request in
            if request.value(forHTTPHeaderField: "x-zipline-p-lastchunk") == "true" {
                return (200, Data(#"{"files":[{"name":"v.mov","url":"https://z.io/v.mov"}]}"#.utf8))
            }
            return (200, Data(#"{"files":[],"partialToken":"t"}"#.utf8))
        }
        let calls = Calls()
        _ = try await client.uploadFile(at: try tenByteFile(), filename: "a.mov", expiry: .never, chunkSize: 8,
                                        betweenChunks: { calls.between += 1 })
        #expect(calls.between == 1)
        #expect(StubProtocol.requests.count == 2)
    }

    @Test func failedChunkThrows() async throws {
        StubProtocol.requests = []
        StubProtocol.handler = { _ in
            StubProtocol.requests.count == 1 ? (200, Data(#"{"files":[],"partialToken":"t1"}"#.utf8)) : (502, Data())
        }
        let file = try tenByteFile()
        await #expect(throws: ZiplineError.server(502)) {
            try await client.uploadFile(at: file, filename: "a.mov", expiry: .never, chunkSize: 4)
        }
    }

    /// Only the incomplete list knows the upload; the file itself isn't there.
    func statuses(_ list: [String]) -> (URLRequest) -> (Int, Data) {
        { request in
            guard request.url?.path() == "/api/user/files/incomplete" else { return (404, Data()) }
            let status = list[min(StubProtocol.requests.count, list.count) - 1]
            return (200, Data(#"[{"status":"\#(status)","metadata":{"file":{"filename":"v.mov","type":"video/quicktime","id":"r"}}}]"#.utf8))
        }
    }

    @Test func waitsUntilStored() async {
        StubProtocol.requests = []
        StubProtocol.handler = statuses(["PENDING", "PROCESSING", "COMPLETE"])
        #expect(await client.waitUntilStored(filename: "v.mov", delays: [0, 0, 0, 0]) == true)
        #expect(StubProtocol.requests.count == 3)
        #expect(StubProtocol.requests.last?.url?.path() == "/api/user/files/incomplete")
        #expect(StubProtocol.requests.last?.value(forHTTPHeaderField: "Authorization") == "secret")
    }

    @Test func reportsFailedProcessing() async {
        StubProtocol.requests = []
        StubProtocol.handler = statuses(["PROCESSING", "FAILED"])
        #expect(await client.waitUntilStored(filename: "v.mov", delays: [0, 0, 0]) == false)
    }

    @Test func givesUpWhileStillProcessing() async {
        StubProtocol.requests = []
        StubProtocol.handler = statuses(["PROCESSING"])
        #expect(await client.waitUntilStored(filename: "v.mov", delays: [0, 0]) == nil)
        #expect(StubProtocol.requests.last?.url?.path() == "/api/user/files/v.mov")
    }

    /// After the last delay, a stored file confirms the upload even if the incomplete list doesn't.
    @Test func storedFileConfirms() async {
        StubProtocol.requests = []
        StubProtocol.handler = { request in
            request.url?.path() == "/api/user/files/v.mov" ? (200, Data(#"{"id":"r","name":"v.mov"}"#.utf8)) : (200, Data("[]".utf8))
        }
        #expect(await client.waitUntilStored(filename: "v.mov", delays: [0, 0]) == true)
        #expect(StubProtocol.requests.count == 3)
    }

    @Test func refusedFileCarriesReason() async {
        StubProtocol.handler = { _ in (400, Data(#"{"error":"E1004: Invalid filename","code":1004,"statusCode":400}"#.utf8)) }
        await #expect(throws: ZiplineError.rejected("Invalid filename")) {
            try await client.upload(Data("PNG".utf8), filename: "a.png", expiry: .never)
        }
    }

    /// Byte-level progress is cut to whole percents, so the menu bar redraws at most 100 times.
    @Test func progressInWholePercents() {
        let calls = Calls()
        let reporter = ProgressReporter(total: 1000) { calls.progress.append($0) }
        for sent in [0, 3, 9, 10, 15, 8, 500, 999, 1000, 1000] { reporter.update(sent) }
        #expect(calls.progress == [0, 0.01, 0.5, 0.99, 1])
    }

    /// Servers without this endpoint can't confirm, so the upload counts as done.
    @Test func olderServerCountsAsStored() async {
        StubProtocol.handler = { _ in (404, Data()) }
        #expect(await client.waitUntilStored(filename: "v.mov", delays: [0]) == true)
    }

    @Test func emptyFileThrows() async throws {
        StubProtocol.requests = []
        let file = FileManager.default.temporaryDirectory.appending(path: "clippeek-\(UUID().uuidString).mov")
        try Data().write(to: file)
        await #expect(throws: ZiplineError.emptyFile) {
            try await client.uploadFile(at: file, filename: "a.mov", expiry: .never)
        }
        #expect(StubProtocol.requests.isEmpty)
    }
}
