import CoreGraphics
import Testing
@testable import DeskBar

@Test
func bareCommandOpensOnCommandRelease() {
    var detector = BareCommandShortcutDetector()

    #expect(detector.handleFlagsChanged(.maskCommand) == false)
    #expect(detector.handleFlagsChanged([]) == true)
}

@Test
func bareCommandIgnoresCommandShortcuts() {
    var detector = BareCommandShortcutDetector()

    #expect(detector.handleFlagsChanged(.maskCommand) == false)
    detector.handleKeyDown()
    #expect(detector.handleFlagsChanged([]) == false)
}

@Test
func bareCommandIgnoresChordedModifiers() {
    var detector = BareCommandShortcutDetector()

    #expect(detector.handleFlagsChanged([.maskCommand, .maskShift]) == false)
    #expect(detector.handleFlagsChanged([]) == false)
}

@Test
func bareCommandIgnoresModifierPressedDuringCommandTap() {
    var detector = BareCommandShortcutDetector()

    #expect(detector.handleFlagsChanged(.maskCommand) == false)
    #expect(detector.handleFlagsChanged([.maskCommand, .maskShift]) == false)
    #expect(detector.handleFlagsChanged(.maskCommand) == false)
    #expect(detector.handleFlagsChanged([]) == false)
}
