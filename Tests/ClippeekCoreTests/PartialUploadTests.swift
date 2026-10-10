import Foundation
import Testing
@testable import ClippeekCore

@Suite struct PartialUploadTests {
    let server = ZiplineServer("https://cdn.example.com")!

    @Test func rangesSplitAtChunkSize() {
        #expect(PartialUpload.ranges(total: 10, chunkSize: 4) == [0..<4, 4..<8, 8..<10])
        #expect(PartialUpload.ranges(total: 8, chunkSize: 4) == [0..<4, 4..<8])
        #expect(PartialUpload.ranges(total: 3, chunkSize: 4) == [0..<3])
        #expect(PartialUpload.ranges(total: 0, chunkSize: 4).isEmpty)
        #expect(PartialUpload.chunkSize == 25 * 1024 * 1024)
    }

    @Test func firstChunkHeaders() {
        let request = PartialUpload.request(server: server, token: "secret", chunk: Data("abcd".utf8), range: 0..<4, total: 10,
                                            filename: "a.mov", mimeType: "video/quicktime", expiry: .sevenDays,
                                            partialToken: nil, multipart: Multipart(boundary: "b"))
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://cdn.example.com/api/upload/partial")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "secret")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=b")
        #expect(request.value(forHTTPHeaderField: "Content-Range") == "bytes 0-3/10")
        #expect(request.value(forHTTPHeaderField: "x-zipline-p-filename") == "a.mov")
        #expect(request.value(forHTTPHeaderField: "x-zipline-p-content-type") == "video/quicktime")
        #expect(request.value(forHTTPHeaderField: "x-zipline-p-content-length") == "10")
        #expect(request.value(forHTTPHeaderField: "x-zipline-p-lastchunk") == "false")
        #expect(request.value(forHTTPHeaderField: "x-zipline-p-token") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Zipline-Deletes-At") == "7d")
        #expect(!request.allowsConstrainedNetworkAccess)
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("name=\"file\"; filename=\"a.mov\"\r\nContent-Type: video/quicktime\r\n\r\nabcd\r\n"))
    }

    @Test func lastChunkHeaders() {
        let request = PartialUpload.request(server: server, token: "secret", chunk: Data("ij".utf8), range: 8..<10, total: 10,
                                            filename: "a.mov", mimeType: "video/quicktime", expiry: .never,
                                            partialToken: "tok2")
        #expect(request.value(forHTTPHeaderField: "Content-Range") == "bytes 8-9/10")
        #expect(request.value(forHTTPHeaderField: "x-zipline-p-lastchunk") == "true")
        #expect(request.value(forHTTPHeaderField: "x-zipline-p-token") == "tok2")
        #expect(request.value(forHTTPHeaderField: "X-Zipline-Deletes-At") == nil)
    }

    /// macOS puts a narrow no-break space before AM/PM; Zipline URL-decodes this header.
    @Test func encodesFilenameHeader() {
        let request = PartialUpload.request(server: server, token: "t", chunk: Data(), range: 0..<1, total: 1,
                                            filename: "Screen Recording 12.30.00\u{202F}PM.mov", mimeType: "video/quicktime",
                                            expiry: .never, partialToken: nil)
        #expect(request.value(forHTTPHeaderField: "x-zipline-p-filename") == "Screen%20Recording%2012.30.00%E2%80%AFPM.mov")
    }

    @Test func parsesIntermediateChunk() throws {
        let json = #"{"files":[],"partialSuccess":true,"partialToken":"tok1"}"#
        #expect(try PartialUpload.parse(status: 200, data: Data(json.utf8)) == .next(token: "tok1"))
    }

    /// The last chunk reports id 0 while Zipline finishes in the background; the short name stands in.
    @Test func parsesLastChunk() throws {
        let json = #"{"files":[{"id":0,"name":"Ab3.mov","type":"video/quicktime","url":"https://cdn.example.com/Ab3.mov","pending":true}],"partialSuccess":true,"partialToken":"t","deletesAt":"2026-10-17T05:00:00.000Z"}"#
        let step = try PartialUpload.parse(status: 200, data: Data(json.utf8))
        let date = try #require(ISO8601DateFormatter().date(from: "2026-10-17T05:00:00Z"))
        #expect(step == .done(UploadResult(id: "Ab3.mov", url: URL(string: "https://cdn.example.com/Ab3.mov")!, deletesAt: date)))
    }

    @Test func overTheServerLimitIsTooLarge() {
        let json = Data(#"{"error":"E5001: File too large","code":5001,"statusCode":413}"#.utf8)
        #expect(throws: ZiplineError.tooLarge) { try PartialUpload.parse(status: 413, data: json) }
        #expect(throws: ZiplineError.tooLarge) { try PartialUpload.parse(status: 400, data: json) }
        let quota = Data(#"{"error":"E5002: Quota exceeded","code":5002,"statusCode":413}"#.utf8)
        #expect(throws: ZiplineError.quotaFull) { try PartialUpload.parse(status: 413, data: quota) }
    }

    /// Recordings sent but not confirmed survive a relaunch, so they're checked instead of sent again.
    @Test func unconfirmedRoundTrips() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-10-17T05:00:00Z"))
        let unconfirmed = ["Screen Recording.mov": UploadResult(id: "Ab3.mov", url: URL(string: "https://z.io/Ab3.mov")!, deletesAt: date),
                           "b.mov": UploadResult(id: "Cd4.mov", url: URL(string: "https://z.io/Cd4.mov")!, deletesAt: nil)]
        #expect(PartialUpload.unconfirmed(from: PartialUpload.encoded(unconfirmed)) == unconfirmed)
        #expect(PartialUpload.unconfirmed(from: nil).isEmpty)
        #expect(PartialUpload.unconfirmed(from: Data("garbage".utf8)).isEmpty)
    }

    @Test func errorsAndHTML() {
        #expect(throws: ZiplineError.unauthorized) { try PartialUpload.parse(status: 401, data: Data()) }
        #expect(throws: ZiplineError.server(502)) { try PartialUpload.parse(status: 502, data: Data("<html></html>".utf8)) }
        #expect(throws: ZiplineError.badResponse) { try PartialUpload.parse(status: 200, data: Data("<html></html>".utf8)) }
        #expect(throws: ZiplineError.badResponse) { try PartialUpload.parse(status: 200, data: Data(#"{"files":[]}"#.utf8)) }
    }

    /// From `/api/user/files/incomplete`, newest first.
    @Test func readsProcessingStatus() throws {
        let json = Data(#"""
        [{"status":"PROCESSING","metadata":{"file":{"filename":"Ab3.mov","type":"video/quicktime","id":"real1"}}},
         {"status":"COMPLETE","metadata":{"file":{"filename":"Old.mov","type":"video/quicktime","id":"real0"}}},
         {"status":"FAILED","metadata":{"file":{"filename":"Bad.mov","type":"video/quicktime","id":"real2"}}}]
        """#.utf8)
        #expect(PartialUpload.status(of: "Ab3.mov", in: json) == .processing)
        #expect(PartialUpload.status(of: "Old.mov", in: json) == .complete)
        #expect(PartialUpload.status(of: "Bad.mov", in: json) == .failed)
        #expect(PartialUpload.status(of: "Missing.mov", in: json) == nil)
        #expect(PartialUpload.status(of: "Ab3.mov", in: Data("<html>".utf8)) == nil)
    }
}
