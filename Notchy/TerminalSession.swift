import Foundation

enum TerminalStatus: Equatable {
    /// Default — no special activity detected
    case idle
    /// Claude is working (status line matches token counter pattern)
    case working
    /// Claude is waiting for user input ("Esc to cancel")
    case waitingForInput
    /// Claude was interrupted by the user (Esc pressed)
    case interrupted
    /// Claude finished a task (confirmed via idle timer line after working)
    case taskCompleted
}

struct TerminalSession: Identifiable {
    let id: UUID
    var projectName: String
    var projectPath: String?
    var workingDirectory: String
    var hasStarted: Bool
    var terminalStatus: TerminalStatus
    var generation: Int
    /// Whether the user has ever manually selected this tab
    var hasBeenSelected: Bool
    let createdAt: Date
    /// When the session most recently entered the .working state
    var workingStartedAt: Date?
    /// Whether this session's name was auto-generated (true) or manually set (false)
    var isAutoNamed: Bool
    /// The prompt text that generated the current auto-name, used for topic shift detection
    var lastAutoNamePrompt: String?

    init(projectName: String, projectPath: String? = nil, workingDirectory: String? = nil, started: Bool = false) {
        self.id = UUID()
        self.projectName = projectName
        self.projectPath = projectPath
        self.workingDirectory = workingDirectory ?? projectPath ?? (NSHomeDirectory() as NSString).appendingPathComponent("Agents")
        self.hasStarted = started
        self.terminalStatus = .idle
        self.generation = 0
        self.hasBeenSelected = started // if started immediately (e.g. "+" button), mark as selected
        self.createdAt = Date()
        // Plain terminals (no project) are auto-named; Xcode project sessions keep their project name
        self.isAutoNamed = projectPath == nil
        self.lastAutoNamePrompt = nil
    }

    /// Restore a session from persisted data
    init(persisted: PersistedSession) {
        self.id = persisted.id
        self.projectName = persisted.projectName
        self.projectPath = persisted.projectPath
        self.workingDirectory = persisted.workingDirectory
        self.hasStarted = false
        self.terminalStatus = .idle
        self.generation = 0
        self.hasBeenSelected = false
        self.createdAt = Date()
        // Restored sessions are always Xcode projects, so not auto-named
        self.isAutoNamed = false
        self.lastAutoNamePrompt = nil
    }
}

/// Lightweight Codable representation for UserDefaults persistence
struct PersistedSession: Codable {
    let id: UUID
    let projectName: String
    let projectPath: String?
    let workingDirectory: String
}
