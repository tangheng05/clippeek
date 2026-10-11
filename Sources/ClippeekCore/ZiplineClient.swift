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

    public func upload(_ data: Data, filename: String, expiry: Expiry, compression: ImageCompression? = nil) async throws -> UploadResult {
        let request = Zipline.uploadRequest(server: server, token: token, file: data, filename: filename,
                                            mimeType: Inbox.mimeType(for: filename), expiry: expiry, compression: compression)
        let (body, response) = try await session.data(for: request)
        do {
            return try Zipline.parseUpload(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: body)
        } catch ZiplineError.rejected(let reason) where compression != nil && reason?.lowercased().contains("compression") == true {
            // A server without that encoder still gets the file, just uncompressed.
            return try await upload(data, filename: filename, expiry: expiry)
        }
    }

    /// Any file: small ones in one request, videos and large files in chunks, waiting until Zipline has stored them.
    public func send(_ file: URL, expiry: Expiry, compression: ImageCompression? = nil,
                     progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> UploadResult {
        let name = file.lastPathComponent
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard Inbox.kind(of: name) == .video || size > PartialUpload.chunkSize else {
            return try await upload(try Data(contentsOf: file), filename: name, expiry: expiry,
                                    compression: Inbox.isCompressible(name) ? compression : nil)
        }
        let result = try await uploadFile(at: file, filename: name, expiry: expiry, progress: progress)
        if await waitUntilStored(filename: result.id) == false { throw ZiplineError.notStored }
        return result
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
            // The chunk is read straight into the body, so only one 25 MB copy is held while it sends.
            var request = PartialUpload.request(server: server, token: token, chunk: try handle.read(upToCount: range.count) ?? Data(),
                                                range: range, total: total, filename: filename,
                                                mimeType: Inbox.mimeType(for: filename), expiry: expiry, partialToken: partialToken)
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
                case .processing: break
                // No record, e.g. cleared in Zipline or checked again after a relaunch: the file itself is proof enough.
                case nil: if await isStored(filename) { return true }
                }
            }
            try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(delay / 10))
        }
        return await isStored(filename) ? true : nil
    }

    private func isStored(_ filename: String) async -> Bool {
        var file = URLRequest(url: server.fileURL(id: filename))
        file.setValue(token, forHTTPHeaderField: "Authorization")
        let response = try? await session.data(for: file).1
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Which of these history items Zipline no longer has. Reads newest first only until it has passed the oldest
    /// one, and judges nothing it didn't cover, so a partial read never removes a file that still exists.
    public func missing(from items: [HistoryItem], maxPages: Int = 5) async throws -> Set<String> {
        guard let oldest = items.map(\.created).min() else { return [] }
        var keys: Set<String> = []
        var coveredSince: Date?
        for page in 1...maxPages {
            let (body, response) = try await session.data(for: Zipline.filesRequest(server: server, token: token, page: page))
            let files = try Zipline.parseFiles(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: body)
            keys.formUnion(files.keys)
            coveredSince = files.oldest
            if page >= files.pages { coveredSince = .distantPast; break }
            if let reached = files.oldest, reached < oldest.addingTimeInterval(-300) { break }
        }
        guard let coveredSince else { return [] }
        // A minute of slack for the clock difference between this Mac and the server.
        return Set(items.filter { $0.created > coveredSince.addingTimeInterval(60) && !keys.contains($0.id) }.map(\.id))
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
