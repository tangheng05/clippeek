import Foundation
import Testing
@testable import ClippeekCore

@Suite struct ZiplineTests {
    let server = ZiplineServer("https://zip.example.com")!

    @Test func normalizesServer() {
        #expect(ZiplineServer("  zip.example.com/ ")?.baseURL.absoluteString == "https://zip.example.com")
        #expect(ZiplineServer("http://192.168.1.5:3000//")?.uploadURL.absoluteString == "http://192.168.1.5:3000/api/upload")
        #expect(ZiplineServer("") == nil)
        #expect(ZiplineServer("ftp://zip.example.com") == nil)
    }

    @Test func multipartBody() {
        let body = Multipart(boundary: "b").body(field: "file", filename: "shot.png", mimeType: "image/png", data: Data("PNG".utf8))
        let expected = "--b\r\nContent-Disposition: form-data; name=\"file\"; filename=\"shot.png\"\r\n"
            + "Content-Type: image/png\r\n\r\nPNG\r\n--b--\r\n"
        #expect(String(decoding: body, as: UTF8.self) == expected)
    }

    @Test func uploadRequest() {
        let request = Zipline.uploadRequest(server: server, token: "secret", file: Data("PNG".utf8), filename: "shot.png",
                                            mimeType: "image/png", expiry: .sevenDays, multipart: Multipart(boundary: "b"))
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://zip.example.com/api/upload")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "secret")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=b")
        #expect(request.value(forHTTPHeaderField: "X-Zipline-Deletes-At") == "7d")
        let never = Zipline.uploadRequest(server: server, token: "secret", file: Data(), filename: "a.png",
                                          mimeType: "image/png", expiry: .never)
        #expect(never.value(forHTTPHeaderField: "X-Zipline-Deletes-At") == nil)
    }

    @Test func deleteRequest() {
        let request = Zipline.deleteRequest(server: server, token: "secret", id: "abc")
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.absoluteString == "https://zip.example.com/api/user/files/abc")
    }

    @Test func parsesUpload() throws {
        let json = #"{"files":[{"id":"cm1abc","name":"x.png","type":"image/png","url":"https://zip.example.com/u/x.png"}],"deletesAt":"2026-10-16T10:00:00.000Z"}"#
        let result = try Zipline.parseUpload(status: 200, data: Data(json.utf8))
        #expect(result.id == "cm1abc")
        #expect(result.url.absoluteString == "https://zip.example.com/u/x.png")
        #expect(result.deletesAt == ISO8601DateFormatter().date(from: "2026-10-16T10:00:00Z"))
    }

    /// Recorded from Zipline 4.8.0 with `X-Zipline-Deletes-At: 7d`.
    @Test func parsesRealV4Response() throws {
        let json = #"{"files":[{"id":"ivverrflcb953uilzalbqgjb","name":"kqChKl.png","type":"image/png","url":"http://localhost:3000/u/kqChKl.png"}],"deletesAt":"2026-10-16T11:20:33.555Z"}"#
        let result = try Zipline.parseUpload(status: 200, data: Data(json.utf8))
        #expect(result.id == "ivverrflcb953uilzalbqgjb")
        #expect(result.url.absoluteString == "http://localhost:3000/u/kqChKl.png")
        #expect(result.deletesAt == Date(timeIntervalSince1970: 1_792_149_633.555))
    }

    @Test func neverExpires() throws {
        let json = #"{"files":[{"id":"a","name":"a.png","type":"image/png","url":"https://z.io/u/a.png"}],"deletesAt":"never"}"#
        #expect(try Zipline.parseUpload(status: 200, data: Data(json.utf8)).deletesAt == nil)
    }

    @Test func statusErrors() {
        #expect(throws: ZiplineError.unauthorized) { try Zipline.parseUpload(status: 401, data: Data()) }
        #expect(throws: ZiplineError.unauthorized) { try Zipline.parseUpload(status: 403, data: Data()) }
        #expect(throws: ZiplineError.tooLarge) { try Zipline.parseUpload(status: 413, data: Data()) }
        #expect(throws: ZiplineError.server(502)) { try Zipline.parseUpload(status: 502, data: Data()) }
    }

    func body(_ code: Int, _ error: String, _ status: Int) -> Data {
        Data(#"{"error":"\#(error)","code":\#(code),"statusCode":\#(status)}"#.utf8)
    }

    @Test func errorCodes() {
        #expect(throws: ZiplineError.quotaFull) { try Zipline.check(413, body: body(5002, "E5002: Storage quota exceeded", 413)) }
        #expect(throws: ZiplineError.tooLarge) { try Zipline.check(413, body: body(5001, "E5001: File too large", 413)) }
        #expect(throws: ZiplineError.tooManyUploads) {
            try Zipline.check(400, body: body(1003, "E1003: Too many partial uploads", 400))
        }
        #expect(throws: ZiplineError.rejected("Invalid characters in filename")) {
            try Zipline.check(400, body: body(1004, "E1004: Invalid characters in filename", 400))
        }
        #expect(throws: ZiplineError.rejected(nil)) { try Zipline.check(400, body: Data("<html>Bad request</html>".utf8)) }
        #expect(throws: ZiplineError.server(404)) { try Zipline.check(404, body: body(4000, "E4000: Not found", 404)) }
        #expect(throws: Never.self) { try Zipline.check(200, body: body(5002, "", 200)) }
    }

    @Test func htmlIsBadResponse() {
        #expect(throws: ZiplineError.badResponse) {
            try Zipline.parseUpload(status: 200, data: Data("<html>Bad gateway</html>".utf8))
        }
        #expect(throws: ZiplineError.badResponse) { try Zipline.parseUpload(status: 200, data: Data(#"{"files":[]}"#.utf8)) }
    }
}
