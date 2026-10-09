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
}
