import Foundation
import Synchronization

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
                           progress: @escaping @Sendable (Double) -> Void = { _ in },
                           betweenChunks: @Sendable () async -> Void = {}) async throws -> UploadResult {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let total = Int(try handle.seekToEnd())
        guard total > 0 else { throw ZiplineError.emptyFile }
        let reporter = ProgressReporter(total: total, report: progress)
        var partialToken: String?
        for range in PartialUpload.ranges(total: total, chunkSize: chunkSize) {
            try handle.seek(toOffset: UInt64(range.lowerBound))
            let chunk = try handle.read(upToCount: range.count) ?? Data()
            var request = PartialUpload.request(server: server, token: token, chunk: chunk, range: range, total: total,
                                                filename: filename, mimeType: Inbox.mimeType(for: filename),
                                                expiry: expiry, partialToken: partialToken)
            let upload = request.httpBody ?? Data()
            request.httpBody = nil
            let sent = SentBytes { sent, expected in
                guard expected > 0 else { return }
                reporter.update(range.lowerBound + Int(Double(range.count) * Double(min(sent, expected)) / Double(expected)))
            }
            let (body, response) = try await session.upload(for: request, from: upload, delegate: sent)
            switch try PartialUpload.parse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: body) {
            case .next(let token):
                partialToken = token
                reporter.update(range.upperBound)
                await betweenChunks()
            case .done(let result):
                reporter.update(total)
                return result
            }
        }
        throw ZiplineError.badResponse
    }

    /// Waits for Zipline to finish storing a chunked upload: true when stored, false when it failed,
    /// nil when it's still not done after the last delay. Large recordings can take minutes to assemble.
    public func waitUntilStored(filename: String, delays: [Double] = [1, 2, 4, 8, 15, 30, 60, 120, 300, 600]) async -> Bool? {
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
        // The record of the upload can be gone, e.g. cleared in Zipline; the file itself is proof enough.
        var file = URLRequest(url: server.fileURL(id: filename))
        file.setValue(token, forHTTPHeaderField: "Authorization")
        let response = try? await session.data(for: file).1
        return (response as? HTTPURLResponse)?.statusCode == 200 ? true : nil
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

/// Reports progress in whole percents, so the menu bar doesn't redraw for every packet sent.
final class ProgressReporter: Sendable {
    private let total: Int
    private let report: @Sendable (Double) -> Void
    private let last = Mutex(-1)

    init(total: Int, report: @escaping @Sendable (Double) -> Void) {
        self.total = total
        self.report = report
    }

    func update(_ sent: Int) {
        let percent = min(sent, total) * 100 / total
        let changed = last.withLock { last in
            guard percent > last else { return false }
            last = percent
            return true
        }
        if changed { report(Double(percent) / 100) }
    }
}

private final class SentBytes: NSObject, URLSessionTaskDelegate, Sendable {
    let update: @Sendable (Int64, Int64) -> Void

    init(update: @escaping @Sendable (Int64, Int64) -> Void) {
        self.update = update
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        update(totalBytesSent, totalBytesExpectedToSend)
    }
}
