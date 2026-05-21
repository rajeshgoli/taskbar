import AppKit
import CoreGraphics
import Testing
@testable import DeskBar

@Test
func smAgentMenuIncludesCopySessionIDCommand() {
    let annotation = SMAgentWindowAnnotation(
        sessionID: "session-123",
        friendlyName: "Session 123",
        workingDirectory: "/tmp",
        provider: "codex",
        sessionStatus: "running",
        activityState: .working,
        currentTask: nil,
        agentStatusText: nil,
        lastToolName: nil,
        lastActionSummary: nil,
        tokensUsed: nil,
        tmuxSession: "session-123",
        terminalWindowID: 42,
        terminalTTY: "/dev/ttys001",
        terminalFrame: nil,
        isSelectedTerminalTab: true
    )

    let menu = SMPluginAgentMenuFactory.makeMenu(
        annotation: annotation,
        target: nil,
        action: Selector(("performMenuCommand:"))
    )

    let copyItem = menu.items.first { $0.title == "Copy SM ID" }
    let command = copyItem?.representedObject as? SMPluginAgentMenuCommand

    #expect(command?.action == .copySessionID)
    #expect(command?.annotation.sessionID == "session-123")
}
