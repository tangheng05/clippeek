import Testing
@testable import ClippeekCore

@Suite struct SmokeTests {
    @Test func bundleID() {
        #expect(Clippeek.bundleID == "io.github.tangheng05.clippeek")
    }
}
