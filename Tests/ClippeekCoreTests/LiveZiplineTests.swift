import Foundation
import Testing
@testable import ClippeekCore

private let environment = ProcessInfo.processInfo.environment

@Suite(.enabled(if: environment["ZIPLINE_URL"] != nil && environment["ZIPLINE_TOKEN"] != nil))
struct LiveZiplineTests {
    var client: ZiplineClient {
        get throws {
            ZiplineClient(server: try #require(ZiplineServer(environment["ZIPLINE_URL"] ?? "")),
                          token: environment["ZIPLINE_TOKEN"] ?? "")
        }
    }

    @Test func uploadDownloadDelete() async throws {
        let client = try client
        try await client.checkConnection()

        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="))
        let result = try await client.upload(png, filename: "clippeek-test.png", expiry: .oneDay)
        #expect(result.deletesAt != nil)

        let (downloaded, _) = try await URLSession.shared.data(from: result.url)
        #expect(downloaded == png)

        try await client.delete(id: result.id)
        try await client.delete(id: result.id)
    }

    @Test func rejectsBadToken() async throws {
        let bad = ZiplineClient(server: try client.server, token: "not-a-token")
        await #expect(throws: ZiplineError.unauthorized) { try await bad.checkConnection() }
    }

    @Test func chunkedUploadDownloadDelete() async throws {
        let client = try client
        let data = Data((0..<(3 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let file = FileManager.default.temporaryDirectory.appending(path: "clippeek-live-test.mov")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try await client.uploadFile(at: file, filename: "clippeek-live-test.mov", expiry: .oneDay,
                                                 chunkSize: 1024 * 1024)
        #expect(await client.waitUntilStored(filename: result.id) == true)
        let (downloaded, _) = try await URLSession.shared.data(from: result.url)
        #expect(downloaded == data)
        // Chunked uploads are deleted by short name, so check the lookup really finds the file.
        #expect(try await status(of: result.id, client: client) == 200)
        try await client.delete(id: result.id)
        #expect(try await status(of: result.id, client: client) == 404)
    }

    func status(of id: String, client: ZiplineClient) async throws -> Int? {
        var request = URLRequest(url: client.server.fileURL(id: id))
        request.setValue(client.token, forHTTPHeaderField: "Authorization")
        return (try await URLSession.shared.data(for: request).1 as? HTTPURLResponse)?.statusCode
    }
}
