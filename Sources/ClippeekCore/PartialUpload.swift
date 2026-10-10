import Foundation

/// Zipline's chunked upload, for files that don't fit in one request.
public enum PartialUpload {
    /// What Zipline's own uploader uses; far below Cloudflare's 100 MB request limit.
    public static let chunkSize = 25 * 1024 * 1024

    public enum Step: Equatable, Sendable {
        case next(token: String)
        case done(UploadResult)
    }

    /// Zipline finishes a chunked upload in the background and reports its progress.
    public enum ProcessingStatus: Equatable, Sendable {
        case processing, complete, failed
    }

    public static func ranges(total: Int, chunkSize: Int = chunkSize) -> [Range<Int>] {
        guard total > 0 else { return [] }
        return stride(from: 0, to: total, by: chunkSize).map { $0..<min($0 + chunkSize, total) }
    }

    public static func request(server: ZiplineServer, token: String, chunk: Data, range: Range<Int>, total: Int,
                               filename: String, mimeType: String, expiry: Expiry, partialToken: String?,
                               multipart: Multipart = Multipart()) -> URLRequest {
        var request = URLRequest(url: server.baseURL.appending(path: "api/upload/partial"))
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("bytes \(range.lowerBound)-\(range.upperBound - 1)/\(total)", forHTTPHeaderField: "Content-Range")
        request.setValue(encoded(filename), forHTTPHeaderField: "x-zipline-p-filename")
        request.setValue(mimeType, forHTTPHeaderField: "x-zipline-p-content-type")
        request.setValue(String(total), forHTTPHeaderField: "x-zipline-p-content-length")
        request.setValue(range.upperBound == total ? "true" : "false", forHTTPHeaderField: "x-zipline-p-lastchunk")
        if let partialToken { request.setValue(partialToken, forHTTPHeaderField: "x-zipline-p-token") }
        if expiry != .never { request.setValue(expiry.rawValue, forHTTPHeaderField: "X-Zipline-Deletes-At") }
        request.httpBody = multipart.body(field: "file", filename: filename, mimeType: mimeType, data: chunk)
        return request
    }

    public static func parse(status: Int, data: Data) throws -> Step {
        struct Response: Decodable {
            struct File: Decodable {
                let name: String?
                let url: URL
            }
            let files: [File]?
            let partialToken: String?
            let deletesAt: String?
            let code: Int?
        }
        let response = try? JSONDecoder().decode(Response.self, from: data)
        // Zipline's error 5001 means the whole file is over its max file size.
        if response?.code == 5001 { throw ZiplineError.tooLarge }
        try Zipline.check(status)
        guard let response else { throw ZiplineError.badResponse }
        if let file = response.files?.first {
            return .done(UploadResult(id: file.name ?? file.url.lastPathComponent, url: file.url,
                                      deletesAt: response.deletesAt.flatMap(Zipline.date)))
        }
        guard let token = response.partialToken else { throw ZiplineError.badResponse }
        return .next(token: token)
    }

    /// Reads `/api/user/files/incomplete` for the stored file name; nil when it isn't listed.
    public static func status(of filename: String, in data: Data) -> ProcessingStatus? {
        struct Record: Decodable {
            struct Metadata: Decodable {
                struct File: Decodable { let filename: String }
                let file: File
            }
            let status: String
            let metadata: Metadata
        }
        guard let records = try? JSONDecoder().decode([Record].self, from: data),
              let record = records.first(where: { $0.metadata.file.filename == filename }) else { return nil }
        switch record.status {
        case "COMPLETE": return .complete
        case "FAILED": return .failed
        default: return .processing
        }
    }

    /// Header values must be ASCII; Zipline URL-decodes this one.
    private static func encoded(_ filename: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return filename.addingPercentEncoding(withAllowedCharacters: unreserved) ?? filename
    }
}
