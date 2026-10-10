import Testing
@testable import ClippeekCore

@Suite struct CLICommandTests {
    @Test func parsesUpload() throws {
        #expect(try CLICommand.parse(["upload", "a.png", "--expiry", "7d", "b.mov", "--copy"])
            == .upload(files: ["a.png", "b.mov"], expiry: .sevenDays, copy: true))
        #expect(try CLICommand.parse(["upload", "--", "--odd name.png"]) == .upload(files: ["--odd name.png"], expiry: nil, copy: false))
    }

    @Test func helpAndVersion() throws {
        #expect(try CLICommand.parse([]) == .help)
        #expect(try CLICommand.parse(["--help"]) == .help)
        #expect(try CLICommand.parse(["--version"]) == .version)
    }

    @Test func rejectsBadInput() {
        #expect(throws: CLICommand.UsageError.self) { try CLICommand.parse(["upload"]) }
        #expect(throws: CLICommand.UsageError.self) { try CLICommand.parse(["upload", "a.png", "--expiry"]) }
        #expect(throws: CLICommand.UsageError.self) { try CLICommand.parse(["upload", "a.png", "--expiry", "2d"]) }
        #expect(throws: CLICommand.UsageError.self) { try CLICommand.parse(["upload", "-x", "a.png"]) }
        #expect(throws: CLICommand.UsageError.self) { try CLICommand.parse(["send", "a.png"]) }
    }
}
