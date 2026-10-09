import Foundation
import Testing
@testable import ClippeekCore

final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
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

    @Test func badTokenThrows() async {
        StubProtocol.handler = { _ in (401, Data()) }
        await #expect(throws: ZiplineError.unauthorized) {
            try await client.upload(Data(), filename: "a.png", expiry: .never)
        }
    }
}
