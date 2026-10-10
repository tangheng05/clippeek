import Foundation

public struct ZiplineServer: Equatable, Sendable {
    public var baseURL: URL

    /// Accepts what people paste: "zip.example.com", "https://zip.example.com/", with spaces.
    public init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme),
              url.host() != nil else { return nil }
        baseURL = url
    }

    public var uploadURL: URL { baseURL.appending(path: "api/upload") }
    public var userURL: URL { baseURL.appending(path: "api/user") }
    public func fileURL(id: String) -> URL { baseURL.appending(path: "api/user/files/\(id)") }
}

public enum Expiry: String, CaseIterable, Codable, Sendable {
    case never, oneDay = "1d", sevenDays = "7d", thirtyDays = "30d"
}

public struct UploadResult: Equatable, Sendable {
    public var id: String
    public var url: URL
    public var deletesAt: Date?

    public init(id: String, url: URL, deletesAt: Date?) {
        self.id = id
        self.url = url
        self.deletesAt = deletesAt
    }
}

public enum ZiplineError: Error, Equatable, Sendable {
    case unauthorized, tooLarge, server(Int), badResponse
}

public enum Zipline {
    public static func uploadRequest(server: ZiplineServer, token: String, file: Data, filename: String,
                                     mimeType: String, expiry: Expiry, multipart: Multipart = Multipart()) -> URLRequest {
        var request = authorized(server.uploadURL, token: token, method: "POST")
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        if expiry != .never { request.setValue(expiry.rawValue, forHTTPHeaderField: "X-Zipline-Deletes-At") }
        request.httpBody = multipart.body(field: "file", filename: filename, mimeType: mimeType, data: file)
        return request
    }

    public static func deleteRequest(server: ZiplineServer, token: String, id: String) -> URLRequest {
        authorized(server.fileURL(id: id), token: token, method: "DELETE")
    }

    /// Used to test a server and token from Settings.
    public static func userRequest(server: ZiplineServer, token: String) -> URLRequest {
        authorized(server.userURL, token: token, method: "GET")
    }

    public static func parseUpload(status: Int, data: Data) throws -> UploadResult {
        try check(status)
        struct Response: Decodable {
            struct File: Decodable {
                let id: String
                let url: URL
            }
            let files: [File]
            let deletesAt: String?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), let file = response.files.first else {
            throw ZiplineError.badResponse
        }
        return UploadResult(id: file.id, url: file.url, deletesAt: response.deletesAt.flatMap(date))
    }

    public static func check(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 401, 403: throw ZiplineError.unauthorized
        case 413: throw ZiplineError.tooLarge
        default: throw ZiplineError.server(status)
        }
    }

    private static func authorized(_ url: URL, token: String, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(token, forHTTPHeaderField: "Authorization")
        return request
    }

    /// "never" and anything unparseable mean no expiry.
    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
