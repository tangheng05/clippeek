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
}
