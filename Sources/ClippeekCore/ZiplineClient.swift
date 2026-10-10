import Foundation

public struct ZiplineClient: Sendable {
    public var server: ZiplineServer
    public var token: String
    public var session: URLSession

    public init(server: ZiplineServer, token: String, session: URLSession = .shared) {
        self.server = server
        self.token = token
        self.session = session
    }

    public func upload(_ data: Data, filename: String, expiry: Expiry) async throws -> UploadResult {
        let request = Zipline.uploadRequest(server: server, token: token, file: data, filename: filename,
                                            mimeType: Inbox.mimeType(for: filename), expiry: expiry)
        let (body, response) = try await session.data(for: request)
        return try Zipline.parseUpload(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: body)
    }

    /// Sends a file in chunks read from disk, so a large video never sits in memory.
    public func uploadFile(at file: URL, filename: String, expiry: Expiry, chunkSize: Int = PartialUpload.chunkSize,
                           progress: @Sendable (Double) -> Void = { _ in },
                           betweenChunks: @Sendable () async -> Void = {}) async throws -> UploadResult {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let total = Int(try handle.seekToEnd())
        var partialToken: String?
        for range in PartialUpload.ranges(total: total, chunkSize: chunkSize) {
            try handle.seek(toOffset: UInt64(range.lowerBound))
            let chunk = try handle.read(upToCount: range.count) ?? Data()
            let request = PartialUpload.request(server: server, token: token, chunk: chunk, range: range, total: total,
                                                filename: filename, mimeType: Inbox.mimeType(for: filename),
                                                expiry: expiry, partialToken: partialToken)
            let (body, response) = try await session.data(for: request)
            switch try PartialUpload.parse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: body) {
            case .next(let token):
                partialToken = token
                progress(Double(range.upperBound) / Double(total))
                await betweenChunks()
            case .done(let result):
                progress(1)
                return result
            }
        }
        throw ZiplineError.badResponse
    }

    public func delete(id: String) async throws {
        let (_, response) = try await session.data(for: Zipline.deleteRequest(server: server, token: token, id: id))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Already gone, e.g. expired or deleted in Zipline's web UI.
        if status == 404 { return }
        try Zipline.check(status)
    }

    public func checkConnection() async throws {
        let (_, response) = try await session.data(for: Zipline.userRequest(server: server, token: token))
        try Zipline.check((response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
