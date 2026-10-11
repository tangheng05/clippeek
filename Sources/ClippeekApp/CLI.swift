import AppKit
import ClippeekCore

extension Notification.Name {
    /// Posted by `clippeek upload` after it wrote history.json, so a running app reloads it.
    static let clippeekUploaded = Notification.Name("io.github.tangheng05.clippeek.uploaded")
}

/// `clippeek upload <file>…`: the app's own binary, so it reads the same Keychain item.
enum CLI {
    static let bundleID = "io.github.tangheng05.clippeek"

    /// True when the binary was started as the command rather than as the app. The app itself only ever
    /// gets dashed flags (its own, or ones like `-NSDocumentRevisionsDebugMode`), never a bare word.
    static func isInvoked(_ arguments: [String]) -> Bool {
        let name = URL(fileURLWithPath: arguments.first ?? "").lastPathComponent
        guard let first = arguments.dropFirst().first else { return name == "clippeek" }
        return name == "clippeek" || !first.hasPrefix("-") || ["-h", "--help", "-v", "--version"].contains(first)
    }

    static func run(_ arguments: [String]) -> Never {
        let command: CLICommand
        do {
            command = try CLICommand.parse(arguments)
        } catch {
            fail(error.message + "\n\n" + CLICommand.usage, code: 2)
        }
        switch command {
        case .help:
            print(CLICommand.usage)
            exit(0)
        case .version:
            print("clippeek \(appBundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
            exit(0)
        case .upload(let files, let expiry, let copy):
            Task {
                exit(await upload(files.map { URL(fileURLWithPath: $0) }, expiry: expiry, copy: copy))
            }
            dispatchMain()
        }
    }

    private static func upload(_ files: [URL], expiry: Expiry?, copy: Bool) async -> Int32 {
        guard let server = ZiplineServer(preference("server") ?? "") else {
            fail("clippeek isn't connected to a Zipline server yet. Open clippeek and set it up first.", code: 1)
        }
        guard let token = Keychain.token() else {
            fail("No Zipline token found. Paste one in clippeek's Settings first.", code: 1)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let client = ZiplineClient(server: server, token: token, session: URLSession(configuration: configuration))
        var links: [String] = []
        var failed = false
        for file in files {
            do {
                let result = try await send(file, client: client, expiry: expiry)
                print(result.url.absoluteString)
                links.append(result.url.absoluteString)
                await remember(result, file: file)
            } catch {
                failed = true
                FileHandle.standardError.write(Data("\(file.lastPathComponent): \(message(for: error))\n".utf8))
            }
        }
        if copy, !links.isEmpty {
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
            }
        }
        return failed ? 1 : 0
    }

    private static func send(_ file: URL, client: ZiplineClient, expiry: Expiry?) async throws -> UploadResult {
        let name = file.lastPathComponent
        let kind = Inbox.kind(of: name)
        let expiry = expiry ?? preference(kind == .video ? "expiryVideo" : "expiry").flatMap(Expiry.init) ?? .never
        let compression = preferenceData("compression").flatMap { try? JSONDecoder().decode(ImageCompression.self, from: $0) }
        let showProgress = isatty(STDERR_FILENO) != 0
        let result = try await client.send(file, expiry: expiry, compression: compression) { value in
            if showProgress { FileHandle.standardError.write(Data("\r\(name): \(Int(value * 100))%".utf8)) }
        }
        if showProgress { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
        return result
    }

    /// Images and videos join the menu bar history, through the running app when there is one.
    private static func remember(_ result: UploadResult, file: URL) async {
        guard let kind = Inbox.kind(of: file.lastPathComponent) else { return }
        let folders = Folders.standard
        let thumbnailName = "\(result.id).png"
        let thumbnail = switch kind {
        case .screenshot: (try? Data(contentsOf: file)).flatMap { Thumbnail.make(from: $0) }
        case .video: await Thumbnail.make(fromVideo: file)
        }
        try? FileManager.default.createDirectory(at: folders.thumbnails, withIntermediateDirectories: true)
        try? thumbnail?.write(to: folders.thumbnails.appending(path: thumbnailName))
        let item = HistoryItem(id: result.id, url: result.url, created: .now, deletesAt: result.deletesAt,
                               thumbnail: thumbnailName, kind: kind, localFile: file)
        var history = History.load(from: folders.historyFile)
        for dropped in history.add(item) {
            try? FileManager.default.removeItem(at: folders.thumbnails.appending(path: URL(fileURLWithPath: dropped.thumbnail).lastPathComponent))
        }
        try? history.encoded().write(to: folders.historyFile, options: .atomic)
        // Carries nothing, so no other process can hand the app items; it just re-reads its own file.
        DistributedNotificationCenter.default().postNotificationName(.clippeekUploaded, object: nil, userInfo: nil,
                                                                     deliverImmediately: true)
    }

    /// Through Homebrew's symlink `Bundle.main` is the link's folder, so follow it to Clippeek.app.
    private static var appBundle: Bundle? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        return Bundle(url: executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
    }

    /// Read straight from the app's domain, which works however the binary was started.
    private static func preference(_ key: String) -> String? {
        CFPreferencesCopyAppValue(key as CFString, bundleID as CFString) as? String
    }

    private static func preferenceData(_ key: String) -> Data? {
        CFPreferencesCopyAppValue(key as CFString, bundleID as CFString) as? Data
    }

    static func message(for error: any Error) -> String {
        switch error {
        case ZiplineError.unauthorized: "Zipline didn't accept the token. Paste a new one in clippeek's Settings."
        case ZiplineError.tooLarge: "Too large for your Zipline. Raise \"Max file size\" in Zipline's admin settings."
        case ZiplineError.quotaFull: "Your Zipline storage quota is full."
        case ZiplineError.rejected(let reason): reason.map { "Zipline refused this file: \($0)" } ?? "Zipline refused this file."
        case ZiplineError.emptyFile: "The file is empty."
        case ZiplineError.tooManyUploads: "Zipline has too many unfinished uploads. Try again in a few minutes."
        case ZiplineError.server(let status): "Zipline answered with an error (\(status))."
        case ZiplineError.badResponse: "The server didn't answer like Zipline. Check the address in clippeek's Settings."
        case ZiplineError.notStored: "Zipline couldn't finish saving it."
        case let error as CocoaError where error.code == .fileReadNoSuchFile: "No such file."
        case let error as URLError where error.networkUnavailableReason == .constrained:
            "Low Data Mode is on, so large files and videos wait. Turn it off and try again."
        default: error.localizedDescription
        }
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(code)
    }
}
