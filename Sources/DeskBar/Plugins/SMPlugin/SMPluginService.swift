import AppKit
import CoreGraphics
import Foundation

enum SMAgentActivityState: String, Codable, Equatable {
    case working
    case thinking
    case idle
    case waitingPermission = "waiting_permission"
    case waitingInput = "waiting_input"
    case stopped

    init(rawValue: String) {
        switch rawValue {
        case Self.working.rawValue:
            self = .working
        case Self.thinking.rawValue:
            self = .thinking
        case Self.waitingPermission.rawValue:
            self = .waitingPermission
        case Self.waitingInput.rawValue:
            self = .waitingInput
        case Self.stopped.rawValue:
            self = .stopped
        default:
            self = .idle
        }
    }

    var badgeLabel: String {
        switch self {
        case .working:
            return "work"
        case .thinking:
            return "think"
        case .idle:
            return "idle"
        case .waitingPermission:
            return "perm"
        case .waitingInput:
            return "input"
        case .stopped:
            return "stop"
        }
    }

    var displayName: String {
        switch self {
        case .working:
            return "Working"
        case .thinking:
            return "Thinking"
        case .idle:
            return "Idle"
        case .waitingPermission:
            return "Waiting for permission"
        case .waitingInput:
            return "Waiting for input"
        case .stopped:
            return "Stopped"
        }
    }

    var color: NSColor {
        switch self {
        case .working:
            return .systemGreen
        case .thinking:
            return .systemBlue
        case .idle:
            return .secondaryLabelColor
        case .waitingPermission:
            return .systemOrange
        case .waitingInput:
            return .systemPurple
        case .stopped:
            return .systemRed
        }
    }
}

struct SMAgentWindowAnnotation: Equatable {
    let sessionID: String
    let friendlyName: String
    let workingDirectory: String
    let provider: String
    let sessionStatus: String
    let activityState: SMAgentActivityState
    let currentTask: String?
    let agentStatusText: String?
    let lastToolName: String?
    let lastActionSummary: String?
    let tokensUsed: Int?
    let tmuxSession: String
    let terminalWindowID: CGWindowID
    let terminalTTY: String
    let terminalFrame: CGRect?
    let isSelectedTerminalTab: Bool
}

struct SMSessionSnapshot: Equatable {
    let id: String
    let friendlyName: String?
    let workingDirectory: String
    let provider: String
    let status: String
    let activityState: SMAgentActivityState
    let currentTask: String?
    let agentStatusText: String?
    let lastToolName: String?
    let lastActionSummary: String?
    let tokensUsed: Int?
    let tmuxSession: String
    let tmuxSocketName: String?

    var displayName: String {
        let trimmedName = friendlyName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedName, !trimmedName.isEmpty {
            return trimmedName
        }

        return id
    }
}

struct SMTmuxClientSnapshot: Equatable {
    let tty: String
    let tmuxSession: String
}

struct SMTerminalTabSnapshot: Equatable {
    let windowID: CGWindowID
    let tty: String
    let frame: CGRect?
    let isSelected: Bool
}

private struct SMAgentTabFetchSnapshot {
    let annotations: [SMAgentWindowAnnotation]
    let liveSessionIDs: Set<String>
    let terminalTabCountByWindowID: [CGWindowID: Int]
}

enum SMPluginAgentMenuAction {
    case rename
    case openTerminalLikeThis
    case retire
    case retireAndClose
}

final class SMPluginAgentMenuCommand: NSObject {
    let action: SMPluginAgentMenuAction
    let annotation: SMAgentWindowAnnotation
    weak var presentationView: NSView?

    init(action: SMPluginAgentMenuAction, annotation: SMAgentWindowAnnotation) {
        self.action = action
        self.annotation = annotation
    }
}

enum SMPluginAgentMenuFactory {
    static func makeMenu(
        annotation: SMAgentWindowAnnotation,
        target: AnyObject?,
        action: Selector
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(metadataItem(annotation.friendlyName))
        menu.addItem(metadataItem("\(annotation.activityState.displayName) - \(annotation.provider) - \(annotation.sessionStatus)"))
        if let agentStatusText = trimmed(annotation.agentStatusText) {
            menu.addItem(metadataItem(agentStatusText))
        } else if let currentTask = trimmed(annotation.currentTask) {
            menu.addItem(metadataItem(currentTask))
        }
        if let lastActionSummary = trimmed(annotation.lastActionSummary) {
            menu.addItem(metadataItem("Last: \(lastActionSummary)"))
        } else if let lastToolName = trimmed(annotation.lastToolName) {
            menu.addItem(metadataItem("Tool: \(lastToolName)"))
        }
        if let tokensUsed = annotation.tokensUsed, tokensUsed > 0 {
            menu.addItem(metadataItem("Tokens: \(tokensUsed)"))
        }
        menu.addItem(metadataItem("Dir: \(abbreviatedPath(annotation.workingDirectory))"))
        menu.addItem(.separator())
        menu.addItem(item("Rename", .rename, annotation, target, action))
        menu.addItem(item("New Terminal Like This", .openTerminalLikeThis, annotation, target, action))
        menu.addItem(.separator())
        menu.addItem(item("Retire", .retire, annotation, target, action))
        menu.addItem(item("Retire and Close", .retireAndClose, annotation, target, action))
        return menu
    }

    private static func metadataItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func item(
        _ title: String,
        _ menuAction: SMPluginAgentMenuAction,
        _ annotation: SMAgentWindowAnnotation,
        _ target: AnyObject?,
        _ action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.representedObject = SMPluginAgentMenuCommand(action: menuAction, annotation: annotation)
        return item
    }

    private static func trimmed(_ value: String?) -> String? {
        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedValue, !trimmedValue.isEmpty else {
            return nil
        }

        return trimmedValue
    }

    private static func abbreviatedPath(_ path: String) -> String {
        let homeDirectory = NSHomeDirectory()
        guard path == homeDirectory || path.hasPrefix("\(homeDirectory)/") else {
            return path
        }

        return "~" + path.dropFirst(homeDirectory.count)
    }
}

@MainActor
final class SMPluginService: ObservableObject {
    nonisolated static let terminalBundleIdentifier = "com.apple.Terminal"
    private nonisolated static let sessionsURL = URL(string: "http://127.0.0.1:8420/sessions")!
    private nonisolated static let commandTimeout: TimeInterval = 2.0
    private nonisolated static let retireTimeout: TimeInterval = 30.0
    private nonisolated static let staleAnnotationRetention: TimeInterval = 60.0
    private nonisolated static let diagnosticLogURL = URL(fileURLWithPath: "/tmp/deskbar-sm-plugin.log")

    @Published private(set) var windowAnnotations: [CGWindowID: SMAgentWindowAnnotation] = [:]
    @Published private(set) var agentTabs: [SMAgentWindowAnnotation] = []
    @Published private(set) var terminalTabCountByWindowID: [CGWindowID: Int] = [:]

    private let pollInterval: TimeInterval
    private var pollTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var isEnabled: Bool
    private var lastObservedAgentTabAtBySessionID: [String: Date] = [:]
    private var renamePopover: NSPopover?

    init(pollInterval: TimeInterval = 2.0, isEnabled: Bool = true) {
        self.pollInterval = pollInterval
        self.isEnabled = isEnabled
        guard isEnabled else {
            return
        }

        startPolling()
    }

    deinit {
        pollTimer?.invalidate()
        refreshTask?.cancel()
    }

    func setEnabled(_ isEnabled: Bool) {
        guard self.isEnabled != isEnabled else {
            return
        }

        self.isEnabled = isEnabled
        if isEnabled {
            startPolling()
        } else {
            pollTimer?.invalidate()
            pollTimer = nil
            refreshTask?.cancel()
            refreshTask = nil
            windowAnnotations = [:]
            agentTabs = []
            terminalTabCountByWindowID = [:]
            lastObservedAgentTabAtBySessionID = [:]
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        refresh()
    }

    func refresh() {
        guard isEnabled else {
            windowAnnotations = [:]
            agentTabs = []
            terminalTabCountByWindowID = [:]
            return
        }

        guard refreshTask == nil else {
            return
        }

        guard Self.isTerminalRunning else {
            windowAnnotations = [:]
            agentTabs = []
            terminalTabCountByWindowID = [:]
            lastObservedAgentTabAtBySessionID = [:]
            return
        }

        refreshTask = Task { [weak self] in
            let snapshot = await Self.fetchAgentTabAnnotations()

            await MainActor.run {
                guard let self else {
                    return
                }

                defer {
                    self.refreshTask = nil
                }

                guard !Task.isCancelled, self.isEnabled else {
                    return
                }

                guard let snapshot else {
                    Self.writeDiagnostic("fetch failed; keeping agentTabs=\(self.agentTabs.count)")
                    return
                }

                self.applyAgentTabFetchSnapshot(snapshot)
            }
        }
    }

    private func applyAgentTabFetchSnapshot(_ snapshot: SMAgentTabFetchSnapshot) {
        let now = Date()
        let liveSessionIDs = snapshot.liveSessionIDs
        terminalTabCountByWindowID = snapshot.terminalTabCountByWindowID
        let freshAnnotationsBySessionID = Dictionary(
            uniqueKeysWithValues: snapshot.annotations.map { ($0.sessionID, $0) }
        )
        let previousAnnotationsBySessionID = Dictionary(
            uniqueKeysWithValues: agentTabs.map { ($0.sessionID, $0) }
        )

        var mergedAnnotationsBySessionID: [String: SMAgentWindowAnnotation] = [:]
        for sessionID in liveSessionIDs {
            if let freshAnnotation = freshAnnotationsBySessionID[sessionID] {
                mergedAnnotationsBySessionID[sessionID] = freshAnnotation
                lastObservedAgentTabAtBySessionID[sessionID] = now
                continue
            }

            guard
                let previousAnnotation = previousAnnotationsBySessionID[sessionID]
            else {
                continue
            }

            let lastObservedAt = lastObservedAgentTabAtBySessionID[sessionID] ?? now
            guard now.timeIntervalSince(lastObservedAt) <= Self.staleAnnotationRetention else {
                continue
            }

            mergedAnnotationsBySessionID[sessionID] = previousAnnotation
            lastObservedAgentTabAtBySessionID[sessionID] = lastObservedAt
        }

        lastObservedAgentTabAtBySessionID = lastObservedAgentTabAtBySessionID.filter { sessionID, lastObservedAt in
            liveSessionIDs.contains(sessionID) &&
                now.timeIntervalSince(lastObservedAt) <= Self.staleAnnotationRetention
        }

        let mergedAnnotations = Self.sortedAnnotations(Array(mergedAnnotationsBySessionID.values))
        agentTabs = mergedAnnotations
        windowAnnotations = Self.selectedWindowAnnotations(from: mergedAnnotations)
    }

    func activate(annotation: SMAgentWindowAnnotation) {
        Task.detached(priority: .userInitiated) {
            Self.activateTerminalTab(
                windowID: annotation.terminalWindowID,
                tty: annotation.terminalTTY
            )
        }
    }

    func openTerminalLike(annotation: SMAgentWindowAnnotation, inWorkingDirectory: Bool) {
        Task.detached(priority: .userInitiated) {
            Self.openTerminalLike(
                frame: annotation.terminalFrame,
                workingDirectory: annotation.workingDirectory,
                inWorkingDirectory: inWorkingDirectory
            )
        }
    }

    func rename(annotation: SMAgentWindowAnnotation, presentationView: NSView?) {
        renamePopover?.close()

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = SMPluginRenameViewController.preferredSize
        popover.contentViewController = SMPluginRenameViewController(
            annotation: annotation,
            onRename: { [weak self, weak popover] newName in
                popover?.close()
                self?.renamePopover = nil
                self?.submitRename(
                    annotation: annotation,
                    newName: newName
                )
            },
            onCancel: { [weak self, weak popover] in
                popover?.close()
                self?.renamePopover = nil
            }
        )

        renamePopover = popover
        NSApp.activate(ignoringOtherApps: true)

        let hostView = renamePopoverHostView(preferredView: presentationView)
        guard let hostView else {
            renamePopover = nil
            Self.presentRenameFailureAlert(message: "DeskBar could not find a window to present rename.")
            return
        }

        popover.show(
            relativeTo: hostView.bounds,
            of: hostView,
            preferredEdge: .maxY
        )
    }

    private func submitRename(annotation: SMAgentWindowAnnotation, newName: String) {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName != annotation.friendlyName else {
            return
        }

        Task.detached(priority: .userInitiated) {
            let result = await Self.renameAgentViaAPI(
                sessionID: annotation.sessionID,
                newName: trimmedName
            )

            await MainActor.run { [weak self] in
                guard result.success else {
                    Self.presentRenameFailureAlert(message: result.errorMessage)
                    return
                }

                self?.refresh()
            }
        }
    }

    private func renamePopoverHostView(preferredView: NSView?) -> NSView? {
        if let preferredView, preferredView.window != nil {
            return preferredView
        }

        if let contentView = NSApp.mainWindow?.contentView, contentView.window != nil {
            return contentView
        }

        return NSApp.windows
            .lazy
            .compactMap(\.contentView)
            .first { $0.window != nil }
    }

    func retire(annotation: SMAgentWindowAnnotation, closeTerminal: Bool) {
        Task.detached(priority: .userInitiated) {
            let didRetire = await Self.retireAgent(sessionID: annotation.sessionID)
            guard didRetire else {
                return
            }

            guard closeTerminal else {
                return
            }

            try? await Task.sleep(nanoseconds: 1_000_000_000)
            Self.closeTerminalTab(
                windowID: annotation.terminalWindowID,
                tty: annotation.terminalTTY
            )
        }
    }

    nonisolated static func makeAgentTabAnnotations(
        sessions: [SMSessionSnapshot],
        tmuxClients: [SMTmuxClientSnapshot],
        terminalTabs: [SMTerminalTabSnapshot]
    ) -> [SMAgentWindowAnnotation] {
        var sessionsByTmuxName: [String: SMSessionSnapshot] = [:]
        sessions.forEach { sessionsByTmuxName[$0.tmuxSession] = $0 }

        var tmuxSessionByTTY: [String: String] = [:]
        tmuxClients.forEach { tmuxSessionByTTY[$0.tty] = $0.tmuxSession }

        var annotationsBySessionID: [String: SMAgentWindowAnnotation] = [:]
        for terminalTab in terminalTabs {
            guard
                let tmuxSession = tmuxSessionByTTY[terminalTab.tty],
                let session = sessionsByTmuxName[tmuxSession]
            else {
                continue
            }

            let annotation = SMAgentWindowAnnotation(
                sessionID: session.id,
                friendlyName: session.displayName,
                workingDirectory: session.workingDirectory,
                provider: session.provider,
                sessionStatus: session.status,
                activityState: session.activityState,
                currentTask: session.currentTask,
                agentStatusText: session.agentStatusText,
                lastToolName: session.lastToolName,
                lastActionSummary: session.lastActionSummary,
                tokensUsed: session.tokensUsed,
                tmuxSession: session.tmuxSession,
                terminalWindowID: terminalTab.windowID,
                terminalTTY: terminalTab.tty,
                terminalFrame: terminalTab.frame,
                isSelectedTerminalTab: terminalTab.isSelected
            )

            if annotationsBySessionID[session.id]?.isSelectedTerminalTab != true {
                annotationsBySessionID[session.id] = annotation
            }
        }
        return sortedAnnotations(Array(annotationsBySessionID.values))
    }

    private nonisolated static func sortedAnnotations(
        _ annotations: [SMAgentWindowAnnotation]
    ) -> [SMAgentWindowAnnotation] {
        annotations.sorted {
            if $0.terminalWindowID != $1.terminalWindowID {
                return $0.terminalWindowID < $1.terminalWindowID
            }

            return $0.sessionID < $1.sessionID
        }
    }

    private static var isTerminalRunning: Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: terminalBundleIdentifier
        ).isEmpty
    }

    private nonisolated static func fetchAgentTabAnnotations() async -> SMAgentTabFetchSnapshot? {
        guard let sessions = await fetchSessions() else {
            writeDiagnostic("sessions fetch failed")
            return nil
        }

        guard !sessions.isEmpty else {
            return SMAgentTabFetchSnapshot(
                annotations: [],
                liveSessionIDs: [],
                terminalTabCountByWindowID: [:]
            )
        }

        return await Task.detached(priority: .utility) {
            guard let terminalTabs = fetchTerminalTabs() else {
                writeDiagnostic("terminal tabs fetch failed for sessions=\(sessions.count)")
                return nil
            }

            guard !terminalTabs.isEmpty else {
                writeDiagnostic("terminal tabs empty for live sessions=\(sessions.count); preserving previous annotations")
                return nil
            }
            let terminalTabCountByWindowID = terminalTabCountByWindowID(from: terminalTabs)

            let tmuxSessionNames = Set(sessions.map(\.tmuxSession))
            let listedClients = fetchTmuxClients(for: sessions)
            var clients = listedClients ?? []
            if clients.isEmpty {
                clients = fetchTmuxClientsFromTerminalTabs(
                    terminalTabs,
                    matching: tmuxSessionNames
                )
            }

            guard !clients.isEmpty else {
                let reason = listedClients == nil ? "fetch failed" : "empty"
                writeDiagnostic("tmux clients \(reason) for live sessions=\(sessions.count); preserving previous annotations")
                return nil
            }

            let annotations = makeAgentTabAnnotations(
                sessions: sessions,
                tmuxClients: clients,
                terminalTabs: terminalTabs
            )
            return SMAgentTabFetchSnapshot(
                annotations: annotations,
                liveSessionIDs: Set(sessions.map(\.id)),
                terminalTabCountByWindowID: terminalTabCountByWindowID
            )
        }.value
    }

    private nonisolated static func terminalTabCountByWindowID(
        from terminalTabs: [SMTerminalTabSnapshot]
    ) -> [CGWindowID: Int] {
        var tabCountByWindowID: [CGWindowID: Int] = [:]
        for terminalTab in terminalTabs {
            tabCountByWindowID[terminalTab.windowID, default: 0] += 1
        }

        return tabCountByWindowID
    }

    private nonisolated static func fetchSessions() async -> [SMSessionSnapshot]? {
        var request = URLRequest(url: sessionsURL)
        request.timeoutInterval = 0.75

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(SMSessionsResponse.self, from: data)
            return response.sessions.compactMap { session in
                guard !session.tmuxSession.isEmpty else {
                    return nil
                }

                return SMSessionSnapshot(
                    id: session.id,
                    friendlyName: session.friendlyName,
                    workingDirectory: session.workingDirectory,
                    provider: session.provider ?? "sm",
                    status: session.status,
                    activityState: SMAgentActivityState(rawValue: session.activityState),
                    currentTask: session.currentTask,
                    agentStatusText: session.agentStatusText,
                    lastToolName: session.lastToolName,
                    lastActionSummary: session.lastActionSummary,
                    tokensUsed: session.tokensUsed,
                    tmuxSession: session.tmuxSession,
                    tmuxSocketName: session.tmuxSocketName
                )
            }
        } catch {
            return nil
        }
    }

    private nonisolated static func fetchTmuxClients(for sessions: [SMSessionSnapshot]) -> [SMTmuxClientSnapshot]? {
        let tmuxSessionNames = Set(sessions.map(\.tmuxSession))
        let socketNames = Set(sessions.map(\.tmuxSocketName))
        var clients: [SMTmuxClientSnapshot] = []
        var hadCommandFailure = false
        for socketName in socketNames {
            guard let socketClients = fetchTmuxClients(socketName: socketName) else {
                hadCommandFailure = true
                continue
            }

            clients.append(contentsOf: socketClients)
        }

        let matchingClients = clients.filter { tmuxSessionNames.contains($0.tmuxSession) }
        if !matchingClients.isEmpty {
            return matchingClients
        }

        let processClients = fetchTmuxClientsFromProcessTable(matching: tmuxSessionNames)
        if !processClients.isEmpty {
            writeDiagnostic("using process-table tmux clients=\(processClients.count) after list-clients=\(clients.count)")
            return processClients
        }

        return hadCommandFailure ? nil : []
    }

    private nonisolated static func fetchTmuxClients(socketName: String?) -> [SMTmuxClientSnapshot]? {
        guard let tmuxExecutablePath = tmuxExecutablePath() else {
            return nil
        }

        var arguments: [String] = []
        if let socketName, !socketName.isEmpty {
            arguments.append(contentsOf: ["-L", socketName])
        }
        arguments.append(contentsOf: ["list-clients", "-F", "#{client_tty}\t#{client_session}"])

        guard let output = runCommand(tmuxExecutablePath, arguments: arguments) else {
            return nil
        }

        return output
            .split(separator: "\n")
            .compactMap { line in
                let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard columns.count >= 2 else {
                    return nil
                }

                let tty = String(columns[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                let tmuxSession = String(columns[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !tty.isEmpty, !tmuxSession.isEmpty else {
                    return nil
                }

                return SMTmuxClientSnapshot(tty: tty, tmuxSession: tmuxSession)
            }
    }

    private nonisolated static func tmuxExecutablePath() -> String? {
        let candidatePaths = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
            "/bin/tmux"
        ]

        return candidatePaths.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    private nonisolated static func fetchTmuxClientsFromProcessTable(
        matching tmuxSessionNames: Set<String>
    ) -> [SMTmuxClientSnapshot] {
        guard
            !tmuxSessionNames.isEmpty,
            let output = runCommand("/bin/ps", arguments: ["-axo", "tty=,command="])
        else {
            return []
        }

        var clientsByTTY: [String: SMTmuxClientSnapshot] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(
                maxSplits: 1,
                omittingEmptySubsequences: true,
                whereSeparator: { $0.isWhitespace }
            )
            guard parts.count == 2 else {
                continue
            }

            let tty = String(parts[0])
            guard tty != "??" else {
                continue
            }

            let command = String(parts[1])
            guard let tmuxSession = tmuxAttachTarget(in: command),
                  tmuxSessionNames.contains(tmuxSession)
            else {
                continue
            }

            let ttyPath = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
            clientsByTTY[ttyPath] = SMTmuxClientSnapshot(
                tty: ttyPath,
                tmuxSession: tmuxSession
            )
        }

        return clientsByTTY.values.sorted { $0.tty < $1.tty }
    }

    private nonisolated static func fetchTmuxClientsFromTerminalTabs(
        _ terminalTabs: [SMTerminalTabSnapshot],
        matching tmuxSessionNames: Set<String>
    ) -> [SMTmuxClientSnapshot] {
        guard !tmuxSessionNames.isEmpty else {
            return []
        }

        var clientsByTTY: [String: SMTmuxClientSnapshot] = [:]
        var psFailureCount = 0
        var commandLineCount = 0
        var tmuxLineCount = 0
        for terminalTab in terminalTabs {
            let ttyName = terminalTab.tty.replacingOccurrences(of: "/dev/", with: "")
            guard !ttyName.isEmpty else {
                continue
            }

            guard let output = runCommand(
                    "/bin/ps",
                    arguments: ["-t", ttyName, "-o", "command="],
                    timeout: 2.0
                  )
            else {
                psFailureCount += 1
                continue
            }

            for commandLine in output.split(separator: "\n") {
                commandLineCount += 1
                if commandLine.contains("tmux") {
                    tmuxLineCount += 1
                }
                guard let tmuxSession = tmuxAttachTarget(in: String(commandLine)),
                      tmuxSessionNames.contains(tmuxSession)
                else {
                    continue
                }

                clientsByTTY[terminalTab.tty] = SMTmuxClientSnapshot(
                    tty: terminalTab.tty,
                    tmuxSession: tmuxSession
                )
                break
            }
        }

        if clientsByTTY.isEmpty {
            writeDiagnostic(
                "tty fallback no matches tabs=\(terminalTabs.count) psFailures=\(psFailureCount) commandLines=\(commandLineCount) tmuxLines=\(tmuxLineCount)"
            )
        }

        return clientsByTTY.values.sorted { $0.tty < $1.tty }
    }

    private nonisolated static func tmuxAttachTarget(in command: String) -> String? {
        let tokens = command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard tokens.contains(where: { $0 == "tmux" || $0.hasSuffix("/tmux") }) else {
            return nil
        }

        var sawAttachCommand = false
        for index in tokens.indices {
            let token = tokens[index]
            if token == "attach" || token == "attach-session" {
                sawAttachCommand = true
                continue
            }

            guard sawAttachCommand else {
                continue
            }

            if token == "-t", tokens.indices.contains(index + 1) {
                return tokens[index + 1]
            }

            if token.hasPrefix("-t"), token.count > 2 {
                return String(token.dropFirst(2))
            }
        }

        return nil
    }

    private nonisolated static func smExecutablePath() -> String? {
        let candidatePaths = [
            "/Users/rajesh/Desktop/automation/session-manager/venv/bin/sm",
            "/opt/homebrew/bin/sm",
            "/usr/local/bin/sm",
            "/usr/bin/sm",
            "/bin/sm"
        ]

        return candidatePaths.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    private nonisolated static func fetchTerminalTabs() -> [SMTerminalTabSnapshot]? {
        let script = """
        set fieldDelimiter to ASCII character 9
        set oldDelimiters to AppleScript's text item delimiters
        set AppleScript's text item delimiters to linefeed
        set rows to {}
        tell application id "com.apple.Terminal"
            repeat with terminalWindow in windows
                try
                    set windowID to id of terminalWindow
                    set windowBounds to bounds of terminalWindow
                    repeat with terminalTab in tabs of terminalWindow
                        set tabTTY to tty of terminalTab
                        set tabSelected to selected of terminalTab
                        set end of rows to (windowID as text) & fieldDelimiter & tabTTY & fieldDelimiter & (tabSelected as text) & fieldDelimiter & (item 1 of windowBounds as text) & fieldDelimiter & (item 2 of windowBounds as text) & fieldDelimiter & (item 3 of windowBounds as text) & fieldDelimiter & (item 4 of windowBounds as text)
                    end repeat
                end try
            end repeat
        end tell
        set renderedRows to rows as text
        set AppleScript's text item delimiters to oldDelimiters
        return renderedRows
        """

        guard let output = runCommand("/usr/bin/osascript", arguments: ["-e", script]) else {
            return nil
        }

        return output
            .split(separator: "\n")
            .compactMap { line in
                let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard columns.count >= 7,
                      let windowID = CGWindowID(String(columns[0]).trimmingCharacters(in: .whitespacesAndNewlines))
                else {
                    return nil
                }

                let tty = String(columns[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !tty.isEmpty else {
                    return nil
                }

                let isSelected = String(columns[2])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare("true") == .orderedSame

                let frame = terminalFrame(
                    left: String(columns[3]),
                    top: String(columns[4]),
                    right: String(columns[5]),
                    bottom: String(columns[6])
                )

                return SMTerminalTabSnapshot(
                    windowID: windowID,
                    tty: tty,
                    frame: frame,
                    isSelected: isSelected
                )
            }
    }

    private nonisolated static func terminalFrame(
        left: String,
        top: String,
        right: String,
        bottom: String
    ) -> CGRect? {
        guard
            let left = Double(left.trimmingCharacters(in: .whitespacesAndNewlines)),
            let top = Double(top.trimmingCharacters(in: .whitespacesAndNewlines)),
            let right = Double(right.trimmingCharacters(in: .whitespacesAndNewlines)),
            let bottom = Double(bottom.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return nil
        }

        let width = right - left
        let height = bottom - top
        guard width > 0, height > 0 else {
            return nil
        }

        return CGRect(x: left, y: top, width: width, height: height)
    }

    private nonisolated static func selectedWindowAnnotations(
        from annotations: [SMAgentWindowAnnotation]
    ) -> [CGWindowID: SMAgentWindowAnnotation] {
        var selectedAnnotations: [CGWindowID: SMAgentWindowAnnotation] = [:]
        for annotation in annotations where annotation.isSelectedTerminalTab {
            selectedAnnotations[annotation.terminalWindowID] = annotation
        }
        return selectedAnnotations
    }

    private nonisolated static func activateTerminalTab(windowID: CGWindowID, tty: String) {
        let escapedTTY = tty.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        set targetWindowID to \(windowID)
        set targetTTY to "\(escapedTTY)"
        tell application id "com.apple.Terminal"
            repeat with terminalWindow in windows
                if id of terminalWindow is targetWindowID then
                    repeat with terminalTab in tabs of terminalWindow
                        if tty of terminalTab is targetTTY then
                            set selected tab of terminalWindow to terminalTab
                            set index of terminalWindow to 1
                            activate
                            return
                        end if
                    end repeat
                end if
            end repeat
        end tell
        """

        _ = runCommand("/usr/bin/osascript", arguments: ["-e", script])
    }

    private nonisolated static func openTerminalLike(
        frame: CGRect?,
        workingDirectory: String,
        inWorkingDirectory: Bool
    ) {
        let workingDirectoryLiteral = appleScriptStringLiteral(workingDirectory)
        let shouldChangeDirectory = inWorkingDirectory ? "true" : "false"
        let boundsScript: String
        if let frame {
            let left = Int(frame.minX.rounded())
            let top = Int(frame.minY.rounded())
            let right = Int(frame.maxX.rounded())
            let bottom = Int(frame.maxY.rounded())
            boundsScript = "set bounds of front window to {\(left), \(top), \(right), \(bottom)}"
        } else {
            boundsScript = ""
        }

        let script = """
        set targetDirectory to \(workingDirectoryLiteral)
        set shouldChangeDirectory to \(shouldChangeDirectory)
        tell application id "com.apple.Terminal"
            activate
            set newTab to do script ""
            delay 0.05
            try
                \(boundsScript)
            end try
            if shouldChangeDirectory then
                do script "cd " & quoted form of targetDirectory & "; clear" in newTab
            end if
        end tell
        """

        _ = runCommand("/usr/bin/osascript", arguments: ["-e", script])
    }

    private nonisolated static func retireAgent(sessionID: String) async -> Bool {
        if await retireAgentViaAPI(sessionID: sessionID) {
            return true
        }

        guard let smExecutablePath = smExecutablePath() else {
            return false
        }

        return runCommand(
            smExecutablePath,
            arguments: ["retire", sessionID],
            timeout: retireTimeout
        ) != nil
    }

    private nonisolated static func renameAgentViaAPI(
        sessionID: String,
        newName: String
    ) async -> (success: Bool, errorMessage: String?) {
        guard
            let encodedSessionID = sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let renameURL = URL(string: "http://127.0.0.1:8420/sessions/\(encodedSessionID)")
        else {
            return (false, "Invalid session id.")
        }

        var request = URLRequest(url: renameURL)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["friendly_name": newName])
        request.timeoutInterval = retireTimeout

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return (false, "No response from Session Manager.")
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                return (false, apiErrorMessage(from: data) ?? "Session Manager returned \(httpResponse.statusCode).")
            }

            return (true, nil)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    private nonisolated static func apiErrorMessage(from data: Data) -> String? {
        guard
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let detail = payload["detail"]
        else {
            return nil
        }

        if let message = detail as? String {
            return message
        }

        if let detailPayload = detail as? [String: Any],
           let message = detailPayload["message"] as? String {
            return message
        }

        return nil
    }

    @MainActor
    private static func presentRenameFailureAlert(message: String?) {
        let alert = NSAlert()
        alert.messageText = "Rename Failed"
        alert.informativeText = message ?? "DeskBar could not rename this session."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private nonisolated static func retireAgentViaAPI(sessionID: String) async -> Bool {
        guard
            let encodedSessionID = sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let retireURL = URL(string: "http://127.0.0.1:8420/sessions/\(encodedSessionID)/kill")
        else {
            return false
        }

        var request = URLRequest(url: retireURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = retireTimeout

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return false
            }

            guard
                let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                payload["error"] == nil
            else {
                return false
            }

            return payload["status"] as? String == "killed"
        } catch {
            return false
        }
    }

    private nonisolated static func closeTerminalTab(windowID: CGWindowID, tty: String) {
        let escapedTTY = tty.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        set targetWindowID to \(windowID)
        set targetTTY to "\(escapedTTY)"
        set shouldCreateReplacementTab to false
        set didSelectTargetTab to false
        set targetBounds to missing value

        tell application id "com.apple.Terminal"
            repeat with terminalWindow in windows
                if id of terminalWindow is targetWindowID then
                    set shouldCreateReplacementTab to ((count of tabs of terminalWindow) is less than or equal to 1)
                    set targetBounds to bounds of terminalWindow
                    repeat with terminalTab in tabs of terminalWindow
                        if tty of terminalTab is targetTTY then
                            set selected tab of terminalWindow to terminalTab
                            set index of terminalWindow to 1
                            activate
                            set didSelectTargetTab to true
                            exit repeat
                        end if
                    end repeat
                    exit repeat
                end if
            end repeat
        end tell

        if didSelectTargetTab is false then
            return "not-found"
        end if

        delay 0.1

        if shouldCreateReplacementTab then
            tell application "System Events" to tell process "Terminal"
                keystroke "t" using command down
            end tell
            delay 0.3

            tell application id "com.apple.Terminal"
                repeat with terminalWindow in windows
                    if id of terminalWindow is targetWindowID then
                        repeat with terminalTab in tabs of terminalWindow
                            if tty of terminalTab is targetTTY then
                                set selected tab of terminalWindow to terminalTab
                                set index of terminalWindow to 1
                                activate
                                exit repeat
                            end if
                        end repeat
                        exit repeat
                    end if
                end repeat
            end tell
            delay 0.1
        end if

        set didConfirmTerminate to false
        tell application "System Events" to tell process "Terminal"
            keystroke "w" using command down
            repeat 30 times
                delay 0.1
                if (count of windows) > 0 and (count of sheets of window 1) > 0 then
                    set confirmationSheet to sheet 1 of window 1
                    if exists button "Terminate" of confirmationSheet then
                        click button "Terminate" of confirmationSheet
                        set didConfirmTerminate to true
                        exit repeat
                    end if
                end if
            end repeat
        end tell

        if shouldCreateReplacementTab and targetBounds is not missing value then
            delay 0.1
            tell application id "com.apple.Terminal"
                try
                    set bounds of front window to targetBounds
                end try
            end tell
        end if

        if didConfirmTerminate then
            return "terminated"
        end if

        return "closed"
        """

        _ = runCommand("/usr/bin/osascript", arguments: ["-e", script], timeout: 6.0)
    }

    private nonisolated static func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private nonisolated static func runCommand(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval = commandTimeout
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        if process.isRunning {
            process.terminate()
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private nonisolated static func writeDiagnostic(_ message: String) {
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else {
            return
        }

        if FileManager.default.fileExists(atPath: diagnosticLogURL.path) {
            guard let handle = try? FileHandle(forWritingTo: diagnosticLogURL) else {
                return
            }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: diagnosticLogURL)
        }
    }
}

private final class SMPluginRenameViewController: NSViewController, NSTextFieldDelegate {
    static let preferredSize = NSSize(width: 360, height: 166)

    private let annotation: SMAgentWindowAnnotation
    private let onRename: (String) -> Void
    private let onCancel: () -> Void
    private let nameField = NSTextField()
    private let renameButton = NSButton(title: "Rename", target: nil, action: nil)

    init(
        annotation: SMAgentWindowAnnotation,
        onRename: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.annotation = annotation
        self.onRename = onRename
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = Self.preferredSize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = NSView(frame: NSRect(origin: .zero, size: Self.preferredSize))
        rootView.translatesAutoresizingMaskIntoConstraints = true

        let titleLabel = NSTextField(labelWithString: "Rename Agent")
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let sessionLabel = NSTextField(labelWithString: annotation.sessionID)
        sessionLabel.textColor = .secondaryLabelColor
        sessionLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        sessionLabel.translatesAutoresizingMaskIntoConstraints = false

        nameField.stringValue = annotation.friendlyName
        nameField.delegate = self
        nameField.target = self
        nameField.action = #selector(rename(_:))
        nameField.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        renameButton.target = self
        renameButton.action = #selector(rename(_:))
        renameButton.keyEquivalent = "\r"
        renameButton.translatesAutoresizingMaskIntoConstraints = false

        let buttonStack = NSStackView(views: [cancelButton, renameButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        [titleLabel, sessionLabel, nameField, buttonStack].forEach(rootView.addSubview)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: rootView.trailingAnchor, constant: -18),

            sessionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            sessionLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            sessionLabel.trailingAnchor.constraint(lessThanOrEqualTo: rootView.trailingAnchor, constant: -18),

            nameField.topAnchor.constraint(equalTo: sessionLabel.bottomAnchor, constant: 14),
            nameField.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            nameField.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -18),
            nameField.heightAnchor.constraint(equalToConstant: 28),

            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 78),
            renameButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 88),

            buttonStack.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 16),
            buttonStack.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            buttonStack.bottomAnchor.constraint(lessThanOrEqualTo: rootView.bottomAnchor, constant: -18)
        ])

        view = rootView
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nameField)
        nameField.selectText(nil)
        updateRenameButton()
    }

    func controlTextDidChange(_ notification: Notification) {
        updateRenameButton()
    }

    private func updateRenameButton() {
        let proposedName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        renameButton.isEnabled = !proposedName.isEmpty && proposedName != annotation.friendlyName
    }

    @objc
    private func rename(_ sender: Any?) {
        let proposedName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !proposedName.isEmpty, proposedName != annotation.friendlyName else {
            return
        }

        onRename(proposedName)
    }

    @objc
    private func cancel(_ sender: Any?) {
        onCancel()
    }
}

private struct SMSessionsResponse: Decodable {
    let sessions: [SMAPISession]
}

private struct SMAPISession: Decodable {
    let id: String
    let friendlyName: String?
    let workingDirectory: String
    let provider: String?
    let status: String
    let activityState: String
    let currentTask: String?
    let agentStatusText: String?
    let lastToolName: String?
    let lastActionSummary: String?
    let tokensUsed: Int?
    let tmuxSession: String
    let tmuxSocketName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case friendlyName = "friendly_name"
        case workingDirectory = "working_dir"
        case provider
        case status
        case activityState = "activity_state"
        case currentTask = "current_task"
        case agentStatusText = "agent_status_text"
        case lastToolName = "last_tool_name"
        case lastActionSummary = "last_action_summary"
        case tokensUsed = "tokens_used"
        case tmuxSession = "tmux_session"
        case tmuxSocketName = "tmux_socket_name"
    }
}
