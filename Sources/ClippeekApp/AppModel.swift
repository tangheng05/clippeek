import AppKit
import ClippeekCore
import Network
import Observation

enum PendingState: Equatable {
    case waiting, uploading, failed(String)
}

struct ConnectionStatus: Equatable {
    let ok: Bool
    let message: String
}

struct Folders {
    let inbox: URL
    let thumbnails: URL
    let historyFile: URL

    static let standard: Folders = {
        let base = URL.applicationSupportDirectory.appending(path: "clippeek")
        return Folders(inbox: base.appending(path: "Inbox"), thumbnails: base.appending(path: "Thumbnails"),
                       historyFile: base.appending(path: "history.json"))
    }()
}

@MainActor
@Observable
final class AppModel {
    private(set) var history = History()
    /// Inbox file name to its upload state.
    private(set) var pending: [String: PendingState] = [:]
    /// Shown in the popover and as a warning icon, e.g. a rejected token.
    private(set) var problem: String?

    var serverText: String { didSet { UserDefaults.standard.set(serverText, forKey: "server") } }
    var expiry: Expiry { didSet { UserDefaults.standard.set(expiry.rawValue, forKey: "expiry") } }
    var copyLinkAfterUpload: Bool { didSet { UserDefaults.standard.set(copyLinkAfterUpload, forKey: "copyLink") } }
    var expiryVideo: Expiry { didSet { UserDefaults.standard.set(expiryVideo.rawValue, forKey: "expiryVideo") } }
    var copyLinkVideo: Bool { didSet { UserDefaults.standard.set(copyLinkVideo, forKey: "copyLinkVideo") } }
    var notifyVideo: Bool {
        didSet {
            UserDefaults.standard.set(notifyVideo, forKey: "notifyVideo")
            if notifyVideo { Notifier.shared.requestPermission() }
        }
    }
    /// 0…1 while a video uploads.
    private(set) var videoProgress: Double?
    private(set) var captureState: CaptureState

    let folders: Folders
    @ObservationIgnored private var watcher: InboxWatcher?
    @ObservationIgnored private let path = NWPathMonitor()
    @ObservationIgnored private var uploading = false
    /// Set after a network error until the backoff timer or a network change.
    @ObservationIgnored private var waitingForRetry = false
    /// Only a rejected token stops uploads; other problems are just shown.
    @ObservationIgnored private var tokenRejected = false
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var retry: Task<Void, Never>?
    /// Read once: each Keychain read can ask for the login password after an app update.
    private(set) var token: String?

    init(folders: Folders = .standard) {
        self.folders = folders
        let defaults = UserDefaults.standard
        serverText = defaults.string(forKey: "server") ?? ""
        expiry = Expiry(rawValue: defaults.string(forKey: "expiry") ?? "") ?? .never
        copyLinkAfterUpload = defaults.bool(forKey: "copyLink")
        expiryVideo = Expiry(rawValue: defaults.string(forKey: "expiryVideo") ?? "") ?? .never
        copyLinkVideo = defaults.object(forKey: "copyLinkVideo") as? Bool ?? true
        notifyVideo = defaults.object(forKey: "notifyVideo") as? Bool ?? true
        if let data = defaults.data(forKey: "captureState"), let state = try? JSONDecoder().decode(CaptureState.self, from: data) {
            captureState = state
        } else if let legacy = defaults.data(forKey: "previousScreenshotSettings"), let state = CaptureState.migrating(legacy: legacy) {
            captureState = state
            defaults.set(try? JSONEncoder().encode(state), forKey: "captureState")
            defaults.removeObject(forKey: "previousScreenshotSettings")
        } else {
            captureState = CaptureState()
        }
    }

    func start() {
        let files = FileManager.default
        try? files.createDirectory(at: folders.inbox, withIntermediateDirectories: true)
        try? files.createDirectory(at: folders.thumbnails, withIntermediateDirectories: true)
        // Puts back the inbox if something else changed a capture location meanwhile.
        if let change = captureState.reapply(inbox: folders.inbox) { SystemPreferences.apply(change) }
        history = History.decode(try? Data(contentsOf: folders.historyFile))
        removeExpired()
        watcher = InboxWatcher(folder: folders.inbox) { [weak self] in self?.scan() }
        path.pathUpdateHandler = { [weak self] update in
            guard update.status == .satisfied else { return }
            Task { @MainActor in self?.networkReturned() }
        }
        path.start(queue: .main)
        scan()
    }

    /// Off the main thread: after an update macOS may ask for the password before releasing it.
    func loadToken() async {
        token = await Task.detached(priority: .userInitiated) { Keychain.token() }.value
        uploadNext()
    }

    // MARK: Inbox

    private func scan() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folders.inbox.path)) ?? []
        for name in Inbox.newCaptures(in: names, handled: Set(pending.keys)) {
            pending[name] = .waiting
            guard Inbox.kind(of: name) == .screenshot else { continue }
            let file = folders.inbox.appending(path: name)
            let created = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if Inbox.isRecent(created: created, now: .now), let data = try? Data(contentsOf: file) {
                Clipboard.put(image: data)
            }
        }
        // Files deleted by hand drop out of the queue.
        for name in pending.keys where !names.contains(name) { pending[name] = nil }
        uploadNext()
    }

    // MARK: Uploads

    private var client: ZiplineClient? {
        guard let server = ZiplineServer(serverText), let token else { return nil }
        return ZiplineClient(server: server, token: token)
    }

    private func uploadNext() {
        guard !uploading, !waitingForRetry, !tokenRejected, let client,
              let name = Inbox.next(in: pending.filter { $0.value == .waiting }.map(\.key)) else { return }
        uploading = true
        pending[name] = .uploading
        Task {
            await upload(name: name, file: folders.inbox.appending(path: name), client: client)
            uploading = false
            uploadNext()
        }
    }

    private func upload(name: String, file: URL, client: ZiplineClient) async {
        guard FileManager.default.fileExists(atPath: file.path) else {
            pending[name] = nil
            return
        }
        let kind = Inbox.kind(of: name) ?? .screenshot
        do {
            let result: UploadResult
            let thumbnail: Data?
            switch kind {
            case .screenshot:
                guard let data = try? Data(contentsOf: file) else {
                    pending[name] = nil
                    return
                }
                result = try await client.upload(data, filename: name, expiry: expiry)
                // Decoding a full-size screenshot on the main thread would hitch the UI.
                thumbnail = await Task.detached(priority: .utility) { Thumbnail.make(from: data) }.value
            case .video:
                videoProgress = 0
                defer { videoProgress = nil }
                result = try await client.uploadFile(
                    at: file, filename: name, expiry: expiryVideo,
                    progress: { [weak self] value in
                        Task { @MainActor in
                            if self?.videoProgress != nil { self?.videoProgress = value }
                        }
                    },
                    betweenChunks: { [weak self] in await self?.uploadWaitingScreenshots(client: client) })
                thumbnail = await Thumbnail.make(fromVideo: file)
            }
            finish(name: name, file: file, kind: kind, thumbnail: thumbnail, result: result)
            attempt = 0
            problem = nil
        } catch ZiplineError.unauthorized {
            pending[name] = .waiting
            tokenRejected = true
            problem = "Zipline rejected the token. Check it in Settings."
        } catch ZiplineError.tooLarge {
            pending[name] = .failed(kind == .video
                ? "Too large for your Zipline. Raise \"Max file size\" in Zipline's admin settings."
                : "Too large for the server")
        } catch ZiplineError.server(let status) {
            pending[name] = .waiting
            problem = "Zipline returned an error (\(status)). Retrying."
            scheduleRetry()
        } catch ZiplineError.badResponse {
            pending[name] = .waiting
            problem = "The server didn't answer like Zipline. Check the address in Settings."
            scheduleRetry()
        } catch {
            pending[name] = .waiting
            scheduleRetry()
        }
    }

    /// Runs between a video's chunks, so screenshots taken meanwhile don't wait for the whole video.
    private func uploadWaitingScreenshots(client: ZiplineClient) async {
        while !waitingForRetry, !tokenRejected,
              let name = pending.filter({ $0.value == .waiting && Inbox.kind(of: $0.key) == .screenshot }).keys.sorted().first {
            pending[name] = .uploading
            await upload(name: name, file: folders.inbox.appending(path: name), client: client)
        }
    }

    private func finish(name: String, file: URL, kind: CaptureKind, thumbnail: Data?, result: UploadResult) {
        let thumbnailName = "\(result.id).png"
        try? thumbnail?.write(to: folders.thumbnails.appending(path: thumbnailName))
        let item = HistoryItem(id: result.id, url: result.url, created: .now, deletesAt: result.deletesAt,
                               thumbnail: thumbnailName, kind: kind)
        for dropped in history.add(item) { removeThumbnail(dropped) }
        saveHistory()
        try? FileManager.default.removeItem(at: file)
        pending[name] = nil
        switch kind {
        case .screenshot:
            if copyLinkAfterUpload { Clipboard.put(link: result.url) }
        case .video:
            if copyLinkVideo { Clipboard.put(link: result.url) }
            if notifyVideo { Notifier.shared.uploaded(result.url, linkCopied: copyLinkVideo) }
        }
    }

    /// After the last step only a network change retries.
    private func scheduleRetry() {
        retry?.cancel()
        waitingForRetry = true
        guard let delay = Backoff.delay(attempt: attempt) else { return }
        attempt += 1
        retry = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            waitingForRetry = false
            uploadNext()
        }
    }

    private func networkReturned() {
        retry?.cancel()
        waitingForRetry = false
        attempt = 0
        uploadNext()
    }

    // MARK: History actions

    /// Expired items are gone from Zipline, so they leave the history too.
    func removeExpired() {
        let expired = history.removeExpired(now: .now)
        guard !expired.isEmpty else { return }
        for item in expired { removeThumbnail(item) }
        saveHistory()
    }

    @discardableResult
    func copyImage(_ item: HistoryItem) async -> Bool {
        guard let (data, response) = try? await URLSession.shared.data(from: item.url),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            problem = "Couldn't download that screenshot from Zipline."
            return false
        }
        Clipboard.put(image: data)
        return true
    }

    func copyLink(_ item: HistoryItem) {
        Clipboard.put(link: item.url)
    }

    func deleteFromServer(_ item: HistoryItem) async {
        guard let client else { return }
        do {
            try await client.delete(id: item.id)
            if let removed = history.remove(id: item.id) { removeThumbnail(removed) }
            saveHistory()
        } catch {
            problem = "Couldn't delete it from Zipline."
        }
    }

    // MARK: Settings

    func saveToken(_ token: String) {
        Keychain.setToken(token)
        self.token = token.isEmpty ? nil : token
        tokenRejected = false
        problem = nil
        networkReturned()
    }

    func testConnection() async -> ConnectionStatus {
        guard ZiplineServer(serverText) != nil else { return ConnectionStatus(ok: false, message: "Enter the server address.") }
        guard let client else { return ConnectionStatus(ok: false, message: "Paste your Zipline token.") }
        do {
            try await client.checkConnection()
            tokenRejected = false
            problem = nil
            // A fixed address or token shouldn't wait out the backoff.
            networkReturned()
            return ConnectionStatus(ok: true, message: "Connected")
        } catch ZiplineError.unauthorized {
            return ConnectionStatus(ok: false, message: "The server rejected the token.")
        } catch ZiplineError.server(let status) {
            return ConnectionStatus(ok: false, message: "The server answered with an error (\(status)).")
        } catch {
            return ConnectionStatus(ok: false, message: "Couldn't reach the server.")
        }
    }

    func isCapturing(_ kind: CaptureKind) -> Bool {
        captureState.isOn(kind)
    }

    func setCapture(_ kind: CaptureKind, _ on: Bool) {
        let current = SystemPreferences.read(CaptureState.allKeys)
        guard let change = captureState.set(kind, on: on, current: current, inbox: folders.inbox) else { return }
        SystemPreferences.apply(change)
        UserDefaults.standard.set(try? JSONEncoder().encode(captureState), forKey: "captureState")
        if kind == .video, on, notifyVideo { Notifier.shared.requestPermission() }
    }

    func dismissProblem() {
        tokenRejected = false
        problem = nil
        networkReturned()
    }

    private func saveHistory() {
        try? history.encoded().write(to: folders.historyFile, options: .atomic)
    }

    private func removeThumbnail(_ item: HistoryItem) {
        try? FileManager.default.removeItem(at: folders.thumbnails.appending(path: item.thumbnail))
    }
}

#if DEBUG
extension AppModel {
    /// Fake state for `--snapshots`; thumbnails go into this model's own folders.
    func loadSample(items count: Int, waiting: Int = 0, problem: String? = nil, capturing: Set<CaptureKind> = [.screenshot],
                    videos: Int = 0, videoProgress: Double? = nil) {
        try? FileManager.default.createDirectory(at: folders.thumbnails, withIntermediateDirectories: true)
        let colors: [NSColor] = [.systemBlue, .systemTeal, .systemIndigo, .systemOrange, .systemPink, .systemGreen]
        var history = History()
        for index in (0..<count).reversed() {
            let name = "sample-\(index).png"
            let size = NSSize(width: index % 3 == 0 ? 180 : 320, height: index % 4 == 0 ? 320 : 200)
            let image = NSImage(size: size, flipped: false) { rect in
                colors[index % colors.count].setFill()
                rect.fill()
                NSColor.white.withAlphaComponent(0.7).setFill()
                NSRect(x: 16, y: rect.height - 40, width: rect.width * 0.6, height: 14).fill()
                return true
            }
            if let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: folders.thumbnails.appending(path: name))
            }
            history.add(HistoryItem(id: "\(index)", url: URL(string: "https://zip.example.com/u/\(index).png")!,
                                    created: .now.addingTimeInterval(Double(-index * 900)), deletesAt: nil, thumbnail: name,
                                    kind: index < videos ? .video : .screenshot))
        }
        self.history = history
        pending = Dictionary(uniqueKeysWithValues: (0..<waiting).map { ("Screenshot \($0).png", PendingState.waiting) })
        self.problem = problem
        captureState = CaptureState()
        for kind in capturing { _ = captureState.set(kind, on: true, current: [:], inbox: folders.inbox) }
        self.videoProgress = videoProgress
    }
}
#endif
