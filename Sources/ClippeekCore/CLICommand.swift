import Foundation

/// What `clippeek <arguments>` asks for.
public enum CLICommand: Equatable, Sendable {
    case upload(files: [String], expiry: Expiry?, copy: Bool)
    case help, version

    public static let usage = """
        Usage: clippeek upload <file>... [--expiry never|1d|7d|30d] [--copy]

        Uploads files to your Zipline server and prints each link.
          --expiry  When Zipline deletes them (default: your setting in clippeek)
          --copy    Also copy the links to the clipboard
        """

    /// Throws a message for the user when the arguments don't make sense.
    public static func parse(_ arguments: [String]) throws(UsageError) -> CLICommand {
        guard let first = arguments.first else { return .help }
        switch first {
        case "-h", "--help", "help": return .help
        case "-v", "--version", "version": return .version
        case "upload": break
        default: throw UsageError("Unknown command \"\(first)\".")
        }
        var files: [String] = []
        var expiry: Expiry?
        var copy = false
        var options = true
        var rest = arguments.dropFirst()
        while let argument = rest.popFirst() {
            switch argument {
            case "--" where options: options = false
            case "--copy" where options: copy = true
            case "--expiry" where options:
                guard let value = rest.popFirst() else { throw UsageError("--expiry needs a value.") }
                guard let parsed = Expiry(rawValue: value) else {
                    throw UsageError("--expiry must be never, 1d, 7d or 30d, not \"\(value)\".")
                }
                expiry = parsed
            case _ where options && argument.hasPrefix("-") && argument != "-":
                throw UsageError("Unknown option \"\(argument)\".")
            default: files.append(argument)
            }
        }
        guard !files.isEmpty else { throw UsageError("Name at least one file to upload.") }
        return .upload(files: files, expiry: expiry, copy: copy)
    }

    public struct UsageError: Error, Equatable {
        public let message: String

        public init(_ message: String) {
            self.message = message
        }
    }
}
