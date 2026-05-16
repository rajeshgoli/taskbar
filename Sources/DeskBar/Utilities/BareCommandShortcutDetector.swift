import CoreGraphics

struct BareCommandShortcutDetector {
    private(set) var isTrackingCommandTap = false
    private var isCommandDown = false

    mutating func handleFlagsChanged(_ flags: CGEventFlags) -> Bool {
        let commandIsDown = flags.contains(.maskCommand)
        let hasOtherModifier =
            flags.contains(.maskAlternate) ||
            flags.contains(.maskControl) ||
            flags.contains(.maskShift)

        if commandIsDown {
            if !isCommandDown {
                isTrackingCommandTap = !hasOtherModifier
            } else if hasOtherModifier {
                isTrackingCommandTap = false
            }
            isCommandDown = true
            return false
        }

        defer {
            isTrackingCommandTap = false
            isCommandDown = false
        }

        return isCommandDown && isTrackingCommandTap && !hasOtherModifier
    }

    mutating func handleKeyDown() {
        isTrackingCommandTap = false
    }

    mutating func cancel() {
        isTrackingCommandTap = false
        isCommandDown = false
    }
}
