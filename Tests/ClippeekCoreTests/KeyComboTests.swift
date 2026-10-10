import Testing
@testable import ClippeekCore

@Suite struct KeyComboTests {
    @Test func displaysInMenuOrder() {
        let combo = KeyCombo(keyCode: 9, key: "v", command: true, option: true, control: true, shift: true)
        #expect(combo.display == "⌃⌥⇧⌘V")
        #expect(combo.carbonModifiers == 0x1B00)
    }

    @Test func needsAModifierOtherThanShift() {
        #expect(!KeyCombo(keyCode: 9, key: "v", command: false, option: false, control: false, shift: true).isValid)
        #expect(!KeyCombo(keyCode: 9, key: "", command: true, option: false, control: false, shift: false).isValid)
        #expect(KeyCombo(keyCode: 9, key: "v", command: false, option: true, control: false, shift: false).isValid)
    }
}
