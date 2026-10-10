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

/// Zipline re-encodes images on upload; the Mac keeps the original.
public struct ImageCompression: Codable, Equatable, Sendable {
    public enum Format: String, Codable, CaseIterable, Sendable {
        case webp, jpeg
    }

    public var format: Format
    /// 0…100.
    public var quality: Int

    public init(format: Format, quality: Int) {
        self.format = format
        self.quality = quality
    }
}

public struct UploadResult: Codable, Equatable, Sendable {
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
    case unauthorized, tooLarge, quotaFull, tooManyUploads, rejected(String?), server(Int), badResponse, emptyFile, notStored
}

public enum Zipline {
    public static func uploadRequest(server: ZiplineServer, token: String, file: Data, filename: String,
                                     mimeType: String, expiry: Expiry, compression: ImageCompression? = nil,
                                     multipart: Multipart = Multipart()) -> URLRequest {
        var request = authorized(server.uploadURL, token: token, method: "POST")
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        if expiry != .never { request.setValue(expiry.rawValue, forHTTPHeaderField: "X-Zipline-Deletes-At") }
        if let compression {
            request.setValue(compression.format.rawValue, forHTTPHeaderField: "X-Zipline-Image-Compression-Type")
            request.setValue(String(min(max(compression.quality, 0), 100)), forHTTPHeaderField: "X-Zipline-Image-Compression-Percent")
        }
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
        try check(status, body: data)
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

    /// Zipline's error bodies carry a code: 1xxx come with 400, 5xxx with 413.
    public static func check(_ status: Int, body: Data = Data()) throws {
        guard !(200..<300).contains(status) else { return }
        struct Failure: Decodable {
            let error: String?
            let code: Int?
        }
        let failure = try? JSONDecoder().decode(Failure.self, from: body)
        switch (status, failure?.code) {
        case (_, 5002): throw ZiplineError.quotaFull
        case (_, 5001), (413, _): throw ZiplineError.tooLarge
        case (401, _), (403, _): throw ZiplineError.unauthorized
        // E1003: too many unfinished chunked uploads; they time out after 30 minutes.
        case (400, 1003): throw ZiplineError.tooManyUploads
        case (400, _): throw ZiplineError.rejected(failure?.error.flatMap(reason))
        default: throw ZiplineError.server(status)
        }
    }

    /// "E1004: Invalid filename" reads as "Invalid filename".
    private static func reason(_ error: String) -> String? {
        let text = error.replacing(/^E\d+:\s*/, with: "").trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
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
