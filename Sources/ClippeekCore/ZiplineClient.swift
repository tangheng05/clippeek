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
