import Testing
@testable import ClippeekCore

@Suite struct BackoffTests {
    let wifi = NetworkPath(satisfied: true, interface: "wifi", constrained: false)

    @Test func returnsWhenNetworkComesBack() {
        let offline = NetworkPath(satisfied: false, interface: nil, constrained: false)
        #expect(wifi.isReturn(from: offline))
        #expect(wifi.isReturn(from: nil))
        #expect(!offline.isReturn(from: wifi))
    }

    /// NWPathMonitor sends updates for the same network, e.g. when an interface's details change.
    @Test func ignoresRepeatedUpdates() {
        #expect(!wifi.isReturn(from: wifi))
    }

    @Test func returnsOnNewInterface() {
        #expect(NetworkPath(satisfied: true, interface: "wiredEthernet", constrained: false).isReturn(from: wifi))
    }

    @Test func returnsWhenLowDataModeEnds() {
        let constrained = NetworkPath(satisfied: true, interface: "wifi", constrained: true)
        #expect(wifi.isReturn(from: constrained))
        #expect(!constrained.isReturn(from: wifi))
    }
}
