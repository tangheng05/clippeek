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
        guard total > 0 else { throw ZiplineError.emptyFile }
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

    /// Waits for Zipline to finish storing a chunked upload: true when stored, false when it failed,
    /// nil when it's still not done after the last delay.
    public func waitUntilStored(filename: String, delays: [Double] = [1, 2, 4, 8, 15, 30, 60, 120]) async -> Bool? {
        var request = URLRequest(url: server.baseURL.appending(path: "api/user/files/incomplete"))
        request.setValue(token, forHTTPHeaderField: "Authorization")
        for delay in delays {
            if let (body, response) = try? await session.data(for: request) {
                // Servers without this endpoint can't confirm, so the upload counts as done.
                if (response as? HTTPURLResponse)?.statusCode == 404 { return true }
                switch PartialUpload.status(of: filename, in: body) {
                case .complete: return true
                case .failed: return false
                case .processing, nil: break
                }
            }
            try? await Task.sleep(for: .seconds(delay))
        }
        return nil
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
