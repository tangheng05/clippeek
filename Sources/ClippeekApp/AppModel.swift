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
    private(set) var captureOn: Bool

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
        captureOn = defaults.data(forKey: "previousScreenshotSettings") != nil
    }

    func start() {
        let files = FileManager.default
        try? files.createDirectory(at: folders.inbox, withIntermediateDirectories: true)
        try? files.createDirectory(at: folders.thumbnails, withIntermediateDirectories: true)
        token = Keychain.token()
        // Puts back the inbox if something else changed the screenshot location meanwhile.
        if captureOn { ScreenshotSettings.capturing(into: folders.inbox).write() }
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

    // MARK: Inbox

    private func scan() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folders.inbox.path)) ?? []
        for name in Inbox.newScreenshots(in: names, handled: Set(pending.keys)) {
            pending[name] = .waiting
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
              let name = pending.filter({ $0.value == .waiting }).keys.sorted().first else { return }
        uploading = true
        pending[name] = .uploading
        Task {
            await upload(name: name, file: folders.inbox.appending(path: name), client: client)
            uploading = false
            uploadNext()
        }
    }

    private func upload(name: String, file: URL, client: ZiplineClient) async {
        guard let data = try? Data(contentsOf: file) else {
            pending[name] = nil
            return
        }
        do {
            let result = try await client.upload(data, filename: name, expiry: expiry)
            finish(name: name, file: file, data: data, result: result)
            attempt = 0
            problem = nil
        } catch ZiplineError.unauthorized {
            pending[name] = .waiting
            tokenRejected = true
            problem = "Zipline rejected the token. Check it in Settings."
        } catch ZiplineError.tooLarge {
            pending[name] = .failed("Too large for the server")
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

    private func finish(name: String, file: URL, data: Data, result: UploadResult) {
        let thumbnailName = "\(result.id).png"
        if let thumbnail = Thumbnail.make(from: data) {
            try? thumbnail.write(to: folders.thumbnails.appending(path: thumbnailName))
        }
        let item = HistoryItem(id: result.id, url: result.url, created: .now, deletesAt: result.deletesAt,
                               thumbnail: thumbnailName)
        for dropped in history.add(item) { removeThumbnail(dropped) }
        saveHistory()
        try? FileManager.default.removeItem(at: file)
        pending[name] = nil
        if copyLinkAfterUpload { Clipboard.put(link: result.url) }
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
        uploadNext()
    }

    func testConnection() async -> ConnectionStatus {
        guard ZiplineServer(serverText) != nil else { return ConnectionStatus(ok: false, message: "Enter the server address.") }
        guard let client else { return ConnectionStatus(ok: false, message: "Paste your Zipline token.") }
        do {
            try await client.checkConnection()
            tokenRejected = false
            problem = nil
            uploadNext()
            return ConnectionStatus(ok: true, message: "Connected")
        } catch ZiplineError.unauthorized {
            return ConnectionStatus(ok: false, message: "The server rejected the token.")
        } catch ZiplineError.server(let status) {
            return ConnectionStatus(ok: false, message: "The server answered with an error (\(status)).")
        } catch {
            return ConnectionStatus(ok: false, message: "Couldn't reach the server.")
        }
    }

    func setCapture(_ on: Bool) {
        // Turning it on twice would save clippeek's own settings as the ones to restore.
        guard on != captureOn else { return }
        let defaults = UserDefaults.standard
        if on {
            let previous = ScreenshotSettings.read()
            defaults.set(try? JSONEncoder().encode(previous), forKey: "previousScreenshotSettings")
            ScreenshotSettings.capturing(into: folders.inbox).write()
        } else if let data = defaults.data(forKey: "previousScreenshotSettings"),
                  let previous = try? JSONDecoder().decode(ScreenshotSettings.self, from: data) {
            previous.write()
            defaults.removeObject(forKey: "previousScreenshotSettings")
        }
        captureOn = on
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
    func loadSample(items count: Int, waiting: Int = 0, problem: String? = nil, captureOn: Bool = true) {
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
                                    created: .now.addingTimeInterval(Double(-index * 900)), deletesAt: nil, thumbnail: name))
        }
        self.history = history
        pending = Dictionary(uniqueKeysWithValues: (0..<waiting).map { ("Screenshot \($0).png", PendingState.waiting) })
        self.problem = problem
        self.captureOn = captureOn
    }
}
#endif
