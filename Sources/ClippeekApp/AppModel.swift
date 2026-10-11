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

    /// Recordings sent but not yet confirmed by Zipline, so they aren't sent twice.
    var unconfirmedFile: URL { historyFile.deletingLastPathComponent().appending(path: "unconfirmed.json") }

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
    var problem: String? {
        issue ?? (waitingForLowData ? "Waiting — Low Data Mode is on. Recordings upload when it's off." : nil)
    }
    private var issue: String?

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
    /// How links go on the clipboard after an upload or a click.
    var linkFormat: LinkFormat { didSet { UserDefaults.standard.set(linkFormat.rawValue, forKey: "linkFormat") } }
    /// Nil sends screenshots as they are.
    var compression: ImageCompression? {
        didSet { UserDefaults.standard.set(compression.flatMap { try? JSONEncoder().encode($0) }, forKey: "compression") }
    }
    var keepScreenshots: Bool { didSet { UserDefaults.standard.set(keepScreenshots, forKey: "keepScreenshots") } }
    var keepVideos: Bool { didSet { UserDefaults.standard.set(keepVideos, forKey: "keepVideos") } }
    /// Chosen folders for kept copies; nil means ~/Pictures/clippeek or ~/Movies/clippeek.
    var keepFolders: [CaptureKind: URL] {
        didSet { UserDefaults.standard.set(keepFolders.mapValues(\.path).reduce(into: [String: String]()) { $0[$1.key.rawValue] = $1.value },
                                           forKey: "keepFolders") }
    }
    /// Files dropped on the icon or sent from Finder that are still going up.
    private(set) var sending = 0
    /// Opens the history from anywhere; nil means off.
    var shortcut: KeyCombo? {
        didSet {
            let stored = shortcut.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
            UserDefaults.standard.set(stored ?? "off", forKey: "keyCombo")
        }
    }
    var shortcutTaken = false
    var recordingShortcut = false
    /// 0…1 while a large dropped file uploads.
    private(set) var sendProgress: Double?
    /// 0…1 while a video uploads.
    private(set) var videoProgress: Double?
    /// When the last upload finished, for the menu bar's check mark.
    private(set) var lastFinished: Date?
    private(set) var captureState: CaptureState

    let folders: Folders
    @ObservationIgnored private var watcher: InboxWatcher?
    @ObservationIgnored private let path = NWPathMonitor()
    @ObservationIgnored private var network: NetworkPath?
    @ObservationIgnored private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
    @ObservationIgnored private var uploading = false
    /// Keeps App Nap from stretching an upload while the queue runs.
    @ObservationIgnored private var activity: (any NSObjectProtocol)?
    /// Set after a network error until the backoff timer, a network change or a new capture.
    private(set) var waitingForRetry = false
    /// Recordings wait while Low Data Mode is on; screenshots still go.
    private(set) var waitingForLowData = false
    /// Only a rejected token stops uploads; other problems are just shown.
    private(set) var tokenRejected = false
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var retry: Task<Void, Never>?
    /// The clipboard's change count when each capture landed, so a link never replaces something copied since.
    @ObservationIgnored private var clipboardMarks: [String: Int] = [:]
    @ObservationIgnored private var unconfirmed: [String: UploadResult] = [:]
    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var lastSync = Date.distantPast
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
        linkFormat = LinkFormat(rawValue: defaults.string(forKey: "linkFormat") ?? "") ?? .plain
        compression = defaults.data(forKey: "compression").flatMap { try? JSONDecoder().decode(ImageCompression.self, from: $0) }
        keepScreenshots = defaults.bool(forKey: "keepScreenshots")
        keepVideos = defaults.bool(forKey: "keepVideos")
        let folders = defaults.dictionary(forKey: "keepFolders") as? [String: String] ?? [:]
        keepFolders = folders.reduce(into: [:]) { result, entry in
            if let kind = CaptureKind(rawValue: entry.key) { result[kind] = URL(fileURLWithPath: entry.value) }
        }
        shortcut = defaults.string(forKey: "keyCombo").flatMap { try? JSONDecoder().decode(KeyCombo.self, from: Data($0.utf8)) }
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
        if let change = captureState.reapply(current: SystemPreferences.read(CaptureState.allKeys), inbox: folders.inbox) {
            SystemPreferences.apply(change)
            UserDefaults.standard.set(try? JSONEncoder().encode(captureState), forKey: "captureState")
        }
        history = History.load(from: folders.historyFile)
        removeExpired()
        unconfirmed = PartialUpload.unconfirmed(from: try? Data(contentsOf: folders.unconfirmedFile))
        watcher = InboxWatcher(folder: folders.inbox) { [weak self] in self?.scan() }
        path.pathUpdateHandler = { [weak self] update in
            let current = NetworkPath(satisfied: update.status == .satisfied,
                                      interface: update.availableInterfaces.first.map { "\($0.type)" },
                                      constrained: update.isConstrained)
            Task { @MainActor in self?.pathChanged(current) }
        }
        path.start(queue: .main)
        DistributedNotificationCenter.default().addObserver(forName: .clippeekUploaded, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadHistory() }
        }
        scan()
    }

    /// `clippeek upload` adds to history.json itself.
    private func reloadHistory() {
        history = History.load(from: folders.historyFile)
        lastFinished = .now
    }

    /// Off the main thread: after an update macOS may ask for the password before releasing it.
    func loadToken() async {
        token = await Task.detached(priority: .userInitiated) { Keychain.token() }.value
        uploadNext()
    }

    // MARK: Inbox

    private func scan() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folders.inbox.path)) ?? []
        let capturing = Set(CaptureKind.allCases.filter(isCapturing))
        var added = false
        for name in Inbox.newCaptures(in: names, handled: Set(pending.keys)) {
            guard let kind = Inbox.kind(of: name) else { continue }
            guard Inbox.shouldUpload(name, capturing: capturing) else {
                returnToUser(name, kind: kind)
                continue
            }
            pending[name] = .waiting
            added = true
            if kind == .screenshot, Inbox.isRecent(created: created(name), now: .now),
               let data = try? Data(contentsOf: folders.inbox.appending(path: name)) {
                Clipboard.put(image: data)
            }
            clipboardMarks[name] = NSPasteboard.general.changeCount
        }
        // Files deleted by hand drop out of the queue.
        for name in pending.keys where !names.contains(name) {
            pending[name] = nil
            clipboardMarks[name] = nil
        }
        for name in unconfirmed.keys where !names.contains(name) { setUnconfirmed(name, nil) }
        // Past the last backoff step, a new capture gets one fresh attempt.
        if added, waitingForRetry, Backoff.isPastSteps(attempt) { waitingForRetry = false }
        uploadNext()
    }

    private func created(_ name: String) -> Date {
        (try? folders.inbox.appending(path: name).resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    /// Puts a file of a kind that's switched off back where the user keeps those, instead of uploading it.
    private func returnToUser(_ name: String, kind: CaptureKind) {
        let folder = captureState.userFolder(for: kind, current: SystemPreferences.read(CaptureState.allKeys),
                                             inbox: folders.inbox, home: FileManager.default.homeDirectoryForCurrentUser)
        let source = folders.inbox.appending(path: name)
        do {
            try FileManager.default.moveItem(at: source, to: unused(name, in: folder))
        } catch {
            try? FileManager.default.moveItem(at: source, to: unused(name, in: .desktopDirectory))
        }
    }

    private func unused(_ name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var destination = folder.appending(path: name)
        var copy = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appending(path: "\(base) \(copy).\(ext)")
            copy += 1
        }
        return destination
    }

    // MARK: Uploads

    private var client: ZiplineClient? {
        guard let server = ZiplineServer(serverText), let token else { return nil }
        return ZiplineClient(server: server, token: token, session: session)
    }

    private func nextWaiting(screenshotsOnly: Bool = false) -> String? {
        let names = pending.filter { name, state in
            guard state == .waiting else { return false }
            return Inbox.kind(of: name) == .screenshot || !(screenshotsOnly || waitingForLowData)
        }.keys
        return Inbox.next(in: names.map { ($0, created($0)) })
    }

    private func uploadNext() {
        guard !uploading else { return }
        guard !waitingForRetry, !tokenRejected, let client, let name = nextWaiting() else {
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
            return
        }
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "Uploading captures")
        }
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
            setUnconfirmed(name, nil)
            return
        }
        let kind = Inbox.kind(of: name) ?? .screenshot
        if kind == .video, let result = unconfirmed[name] {
            Task { await confirm(name: name, file: file, client: client, result: result) }
            return
        }
        do {
            let result: UploadResult
            let thumbnail: Data?
            switch kind {
            case .screenshot:
                guard let data = try? Data(contentsOf: file) else {
                    pending[name] = nil
                    return
                }
                result = try await client.upload(data, filename: name, expiry: expiry,
                                                 compression: Inbox.isCompressible(name) ? compression : nil)
                // Decoding a full-size screenshot on the main thread would hitch the UI.
                thumbnail = await Task.detached(priority: .utility) { Thumbnail.make(from: data) }.value
            case .video:
                videoProgress = 0
                defer { videoProgress = nil }
                let uploaded = try await client.uploadFile(
                    at: file, filename: name, expiry: expiryVideo,
                    progress: { [weak self] value in
                        Task { @MainActor in
                            if self?.videoProgress != nil { self?.videoProgress = value }
                        }
                    },
                    betweenChunks: { [weak self] in await self?.uploadWaitingScreenshots(client: client) })
                attempt = 0
                issue = nil
                // Zipline assembles the chunks in the background; the recording stays until it confirms.
                setUnconfirmed(name, uploaded)
                Task { await confirm(name: name, file: file, client: client, result: uploaded) }
                return
            }
            finish(name: name, file: file, kind: kind, thumbnail: thumbnail, result: result)
            attempt = 0
            issue = nil
        } catch ZiplineError.unauthorized {
            pending[name] = .waiting
            tokenRejected = true
            issue = "Zipline didn't accept your token. Paste a new one in Settings."
        } catch ZiplineError.tooLarge {
            fail(name, "Too large for your Zipline. Raise \"Max file size\" in Zipline's admin settings.")
        } catch ZiplineError.quotaFull {
            fail(name, "Your Zipline storage quota is full.")
        } catch ZiplineError.rejected(let reason) {
            fail(name, reason.map { "Zipline refused this file: \($0)" } ?? "Zipline refused this file.")
        } catch ZiplineError.emptyFile {
            fail(name, "This file is empty, so there's nothing to upload.")
        } catch ZiplineError.tooManyUploads {
            pending[name] = .waiting
            issue = "Zipline has too many unfinished uploads. Retrying automatically."
            scheduleRetry()
        } catch ZiplineError.server(let status) {
            pending[name] = .waiting
            issue = "Zipline answered with an error (\(status)). Retrying automatically."
            scheduleRetry()
        } catch ZiplineError.badResponse {
            pending[name] = .waiting
            issue = "The server didn't answer like Zipline. Check the address in Settings."
            scheduleRetry()
        } catch let error as URLError where error.networkUnavailableReason == .constrained {
            pending[name] = .waiting
            waitingForLowData = true
        } catch {
            pending[name] = .waiting
            scheduleRetry()
        }
    }

    /// Keeps the recording until Zipline has stored it, so a failure on the server doesn't lose it.
    private func confirm(name: String, file: URL, client: ZiplineClient, result: UploadResult) async {
        let stored = await client.waitUntilStored(filename: result.id)
        // Deleted from the inbox meanwhile: nothing left to finish or fail.
        guard pending[name] != nil else { return }
        switch stored {
        case true?:
            let thumbnail = await Thumbnail.make(fromVideo: file)
            finish(name: name, file: file, kind: .video, thumbnail: thumbnail, result: result)
        case false?:
            setUnconfirmed(name, nil)
            fail(name, "Zipline couldn't finish saving this recording. It's still on your Mac.")
        case nil:
            // Stays unconfirmed, so Retry checks again instead of sending it twice.
            fail(name, "Zipline hasn't confirmed this recording yet. It stays on your Mac until you delete it.")
        }
    }

    private func fail(_ name: String, _ reason: String) {
        pending[name] = .failed(reason)
        if Inbox.kind(of: name) == .video, notifyVideo {
            Notifier.shared.failed(folders.inbox.appending(path: name), reason: reason)
        }
    }

    private func setUnconfirmed(_ name: String, _ result: UploadResult?) {
        guard unconfirmed[name] != result else { return }
        unconfirmed[name] = result
        try? PartialUpload.encoded(unconfirmed).write(to: folders.unconfirmedFile, options: .atomic)
    }

    /// Runs between a video's chunks, so screenshots taken meanwhile don't wait for the whole video.
    private func uploadWaitingScreenshots(client: ZiplineClient) async {
        while !waitingForRetry, !tokenRejected, let name = nextWaiting(screenshotsOnly: true) {
            pending[name] = .uploading
            await upload(name: name, file: folders.inbox.appending(path: name), client: client)
        }
    }

    private func finish(name: String, file: URL, kind: CaptureKind, thumbnail: Data?, result: UploadResult) {
        let kept = keep(file, kind: kind)
        if kept == nil { try? FileManager.default.removeItem(at: file) }
        remember(result, kind: kind, thumbnail: thumbnail, localFile: kept)
        pending[name] = nil
        setUnconfirmed(name, nil)
        lastFinished = .now
        let unchanged = clipboardMarks.removeValue(forKey: name) == NSPasteboard.general.changeCount
        switch kind {
        case .screenshot:
            if copyLinkAfterUpload, unchanged { Clipboard.put(text: linkFormat.text(for: result.url)) }
        case .video:
            let copy = copyLinkVideo && unchanged
            if copy { Clipboard.put(text: linkFormat.text(for: result.url)) }
            if notifyVideo { Notifier.shared.uploaded(result.url, linkCopied: copy) }
        }
    }

    private func remember(_ result: UploadResult, kind: CaptureKind, thumbnail: Data?, localFile: URL?) {
        let thumbnailName = "\(result.id).png"
        try? thumbnail?.write(to: folders.thumbnails.appending(path: thumbnailName))
        let item = HistoryItem(id: result.id, url: result.url, created: .now, deletesAt: result.deletesAt,
                               thumbnail: thumbnailName, kind: kind, localFile: localFile)
        for dropped in history.add(item) { removeThumbnail(dropped) }
        saveHistory()
    }

    /// Moves an uploaded capture to the user's folder when they keep copies; nil when it isn't kept.
    private func keep(_ file: URL, kind: CaptureKind) -> URL? {
        guard kind == .screenshot ? keepScreenshots : keepVideos, FileManager.default.fileExists(atPath: file.path) else { return nil }
        // A missing or unwritable folder falls back, so a kept file is never deleted instead.
        for folder in [keepFolder(for: kind), defaultKeepFolder(for: kind), URL.desktopDirectory] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = unused(file.lastPathComponent, in: folder)
            if (try? FileManager.default.moveItem(at: file, to: destination)) != nil { return destination }
        }
        return file
    }

    /// Defaults to Pictures or Movies, not the Desktop the app keeps clear.
    func keepFolder(for kind: CaptureKind) -> URL {
        keepFolders[kind] ?? defaultKeepFolder(for: kind)
    }

    private func defaultKeepFolder(for kind: CaptureKind) -> URL {
        (kind == .screenshot ? URL.picturesDirectory : URL.moviesDirectory).appending(path: "clippeek")
    }

    // MARK: Sending files

    /// Files dropped on the icon or picked in Finder; they stay where they are.
    func send(_ files: [URL]) {
        let files = files.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        guard !files.isEmpty else { return }
        guard let client else {
            issue = "Connect your Zipline server in Settings first."
            return
        }
        sending += files.count
        let mark = NSPasteboard.general.changeCount
        Task {
            var links: [String] = []
            for file in files {
                let kind = Inbox.kind(of: file.lastPathComponent)
                do {
                    let result = try await client.send(file, expiry: kind == .video ? expiryVideo : expiry,
                                                       compression: compression) { value in
                        Task { @MainActor in self.sendProgress = value < 1 ? value : nil }
                    }
                    sendProgress = nil
                    links.append(linkFormat.text(for: result.url))
                    if let kind {
                        let thumbnail = await Self.thumbnail(of: file, kind: kind)
                        remember(result, kind: kind, thumbnail: thumbnail, localFile: file)
                    }
                    lastFinished = .now
                } catch {
                    sendProgress = nil
                    issue = "Couldn't upload \(file.lastPathComponent): \(CLI.message(for: error))"
                }
                sending -= 1
            }
            // Not over something the user copied while these were uploading.
            let current = NSPasteboard.general.changeCount
            if !links.isEmpty, current == mark || current == Clipboard.lastLinkWrite {
                Clipboard.put(text: links.joined(separator: "\n"))
            }
        }
    }

    private nonisolated static func thumbnail(of file: URL, kind: CaptureKind) async -> Data? {
        switch kind {
        case .screenshot: (try? Data(contentsOf: file)).flatMap { Thumbnail.make(from: $0) }
        case .video: await Thumbnail.make(fromVideo: file)
        }
    }

    /// After the last step only a network change, a new capture or the user retries.
    private func scheduleRetry() {
        // Another upload already failed and started the wait; one outage counts once.
        guard !waitingForRetry else { return }
        retry?.cancel()
        waitingForRetry = true
        let delay = Backoff.delay(attempt: attempt)
        attempt += 1
        retry = Task {
            try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(delay / 10))
            guard !Task.isCancelled else { return }
            waitingForRetry = false
            uploadNext()
        }
    }

    private func pathChanged(_ current: NetworkPath) {
        defer { network = current }
        guard current.isReturn(from: network) else { return }
        if waitingForLowData, !current.constrained {
            waitingForLowData = false
            uploadNext()
        }
        if waitingForRetry { networkReturned() }
    }

    private func networkReturned() {
        retry?.cancel()
        waitingForRetry = false
        attempt = 0
        uploadNext()
    }

    // MARK: History actions

    /// Drops tiles whose file was deleted on Zipline, e.g. in its dashboard. Runs when the history opens,
    /// at most once a minute, never in the background.
    func syncWithServer() {
        guard let client, !syncing, Date.now.timeIntervalSince(lastSync) > 60,
              let host = ZiplineServer(serverText)?.baseURL.host() else { return }
        // Items from another server can't be checked here.
        let items = history.items.filter { $0.url.host() == host }
        guard !items.isEmpty else { return }
        syncing = true
        // Set first, so an unreachable server isn't asked again on every open.
        lastSync = .now
        Task {
            defer { syncing = false }
            guard let missing = try? await client.missing(from: items) else { return }
            forget(missing)
        }
    }

    private func forget(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for id in ids { if let removed = history.remove(id: id) { removeThumbnail(removed) } }
        saveHistory()
    }

    /// Expired items are gone from Zipline, so they leave the history too.
    func removeExpired() {
        let expired = history.removeExpired(now: .now)
        guard !expired.isEmpty else { return }
        for item in expired { removeThumbnail(item) }
        saveHistory()
    }

    enum CopyResult { case copied, gone, failed }

    @discardableResult
    func copyImage(_ item: HistoryItem) async -> CopyResult {
        if let data = item.localFile.flatMap({ try? Data(contentsOf: $0) }), Clipboard.put(image: data) {
            return .copied
        }
        guard let (data, response) = try? await session.data(from: item.url) else { return .failed }
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200:
            // A proxy's HTML page also answers 200; only a real image counts.
            return Clipboard.put(image: data) ? .copied : .failed
        case 404:
            forget([item.id])
            return .gone
        default:
            return .failed
        }
    }

    func copyLink(_ item: HistoryItem, format: LinkFormat? = nil) {
        Clipboard.put(text: (format ?? linkFormat).text(for: item.url))
    }

    enum TextResult { case copied, none, failed }

    /// Reads the screenshot's text on this Mac, from the kept copy when there is one.
    func copyText(_ item: HistoryItem) async -> TextResult {
        var data = item.localFile.flatMap { try? Data(contentsOf: $0) }
        if data == nil, let (body, response) = try? await session.data(from: item.url),
           (response as? HTTPURLResponse)?.statusCode == 200 {
            data = body
        }
        guard let data else { return .failed }
        guard let text = await TextRecognition.text(in: data) else { return .none }
        Clipboard.put(text: text)
        return .copied
    }

    func deleteFromServer(_ item: HistoryItem) async {
        guard let client else {
            issue = "Connect your Zipline server in Settings first."
            return
        }
        // Otherwise the current server would answer "not found" and the tile would vanish while the file stays.
        guard item.url.host() == ZiplineServer(serverText)?.baseURL.host() else {
            issue = "That file is on a different Zipline server than the one in Settings."
            return
        }
        do {
            try await client.delete(id: item.id)
            if let removed = history.remove(id: item.id) { removeThumbnail(removed) }
            saveHistory()
        } catch {
            issue = "Couldn't delete that file from Zipline. Try again in a moment."
        }
    }

    // MARK: Settings

    func saveToken(_ token: String) {
        Keychain.setToken(token)
        self.token = token.isEmpty ? nil : token
        tokenRejected = false
        issue = nil
        networkReturned()
    }

    /// Saves the token, then checks it against the server.
    func connect(token: String) async -> ConnectionStatus {
        saveToken(token)
        return await testConnection()
    }

    func testConnection() async -> ConnectionStatus {
        guard ZiplineServer(serverText) != nil else { return ConnectionStatus(ok: false, message: "Enter the server address.") }
        guard let client else { return ConnectionStatus(ok: false, message: "Paste your Zipline token.") }
        do {
            try await client.checkConnection()
            tokenRejected = false
            issue = nil
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

    /// Sends failed files again, e.g. after the user raised Zipline's max file size.
    func retryFailed() {
        for (name, state) in pending { if case .failed = state { pending[name] = .waiting } }
        networkReturned()
    }

    func dismissProblem() {
        tokenRejected = false
        issue = nil
        waitingForLowData = false
        networkReturned()
    }

    private func saveHistory() {
        try? history.encoded().write(to: folders.historyFile, options: .atomic)
    }

    private func removeThumbnail(_ item: HistoryItem) {
        try? FileManager.default.removeItem(at: folders.thumbnails.appending(path: URL(fileURLWithPath: item.thumbnail).lastPathComponent))
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
            // A window on a coloured desktop, so README screenshots look like real captures.
            let image = NSImage(size: size, flipped: false) { rect in
                colors[index % colors.count].setFill()
                rect.fill()
                let window = rect.insetBy(dx: rect.width * 0.12, dy: rect.height * 0.14)
                NSColor(white: index % 3 == 1 ? 0.16 : 0.98, alpha: 1).setFill()
                NSBezierPath(roundedRect: window, xRadius: 9, yRadius: 9).fill()
                for (dot, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                    color.setFill()
                    NSBezierPath(ovalIn: NSRect(x: window.minX + 10 + CGFloat(dot) * 12, y: window.maxY - 16, width: 7, height: 7)).fill()
                }
                NSColor(white: 0.5, alpha: 0.35).setFill()
                for (line, width) in [0.7, 0.5, 0.62, 0.38].enumerated() {
                    let y = window.maxY - 36 - CGFloat(line) * 16
                    guard y > window.minY + 8 else { break }
                    NSBezierPath(roundedRect: NSRect(x: window.minX + 12, y: y, width: (window.width - 24) * width, height: 7),
                                 xRadius: 3.5, yRadius: 3.5).fill()
                }
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
        issue = problem
        captureState = CaptureState()
        for kind in capturing { _ = captureState.set(kind, on: true, current: [:], inbox: folders.inbox) }
        self.videoProgress = videoProgress
        token = "sample"
    }
}
#endif
