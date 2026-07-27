/// Shared model types for the Code Session Monitor.
/// Mirrors the shape the scanner produces and the views consume.

import Foundation

enum ToolKind: String, Sendable, CaseIterable, Hashable {
  case claude
  case codex
  case opencode

  var label: String {
    switch self {
    case .claude: "Claude Code"
    case .codex: "Codex"
    case .opencode: "OpenCode"
    }
  }

  /// SF Symbol used in group headers and the menu bar.
  var symbolName: String {
    switch self {
    case .claude: "brain"
    case .codex: "curlybraces"
    case .opencode: "apple.terminal"
    }
  }
}

enum SessionState: String, Sendable, Hashable {
  case running
  case waiting
  case idle

  var label: String {
    switch self {
    case .running: "Running"
    case .waiting: "Waiting approval"
    case .idle: "Idle"
    }
  }

  /// Compact label for the menu bar list.
  var shortLabel: String {
    switch self {
    case .running: "Running"
    case .waiting: "Waiting"
    case .idle: "Idle"
    }
  }

  var glyph: String {
    switch self {
    case .running: "●"
    case .waiting: "⚠"
    case .idle: "○"
    }
  }

  /// Sort weight — most urgent first.
  var order: Int {
    switch self {
    case .waiting: 0
    case .running: 1
    case .idle: 2
    }
  }
}

struct SessionInfo: Identifiable, Sendable, Hashable {
  /// Stable identifier: `tool:sessionUUID`. Never derived from a directory —
  /// a session's directories change while the session does not (ADR-0002).
  let id: String
  let tool: ToolKind
  /// OS process id when a live process was matched.
  var pid: Int32?
  /// Controlling terminal of the process (e.g. "ttys004") when known.
  var tty: String?
  /// The directory this session started in. Its Project, and the one a
  /// terminal tab was opened in — stable for the session's lifetime.
  let projectPath: String
  /// Where the session is operating now. Equal to `projectPath` until the
  /// session moves, and what a live process reports as its own cwd.
  var workingDirectory: String
  /// Human-friendly label — basename of `projectPath`.
  let project: String
  var gitBranch: String?
  var model: String?
  /// What is known about this session. Everything below is derived from it.
  var evidence: Evidence
  /// Derived from `evidence` once per scan, by the scanner. Nothing else
  /// assigns it — that is the whole point of ADR-0012.
  var state: SessionState
  /// Terminal tab hosting this session, when a hook was able to record one.
  var tabID: String?
  /// Pane within that tab. A tab can hold several sessions side by side, so
  /// this is what actually distinguishes them.
  var paneID: String?
  /// Started by a program rather than a person — an SDK-spawned agent doing a
  /// piece of someone else's task, not a session anybody is sitting in front of.
  var isDelegated = false
  /// Delegated agents currently working underneath this session.
  var subagentCount = 0
  /// When this session was last observed doing anything.
  var lastActivity: Date { evidence.at }

  /// Whether this session's state is solid enough to animate a card for.
  ///
  /// A reported block means Claude Code fired `PermissionRequest`. An inferred
  /// one means a tool call has been quiet for 45 seconds — a guess, and one
  /// that has been wrong. The cost of a wrong guess should not be a pulsing
  /// card demanding attention it has not earned (ADR-0012).
  var deservesAttention: Bool {
    state != .waiting || evidence.source == .reported
  }
  /// Short human snippet describing the latest activity.
  var lastMessage: String?
}

struct StateCounts: Sendable, Hashable {
  var running = 0
  var waiting = 0
  var idle = 0

  var total: Int { running + waiting + idle }

  subscript(state: SessionState) -> Int {
    get {
      switch state {
      case .running: running
      case .waiting: waiting
      case .idle: idle
      }
    }
    set {
      switch state {
      case .running: running = newValue
      case .waiting: waiting = newValue
      case .idle: idle = newValue
      }
    }
  }
}

struct SessionSnapshot: Sendable {
  var sessions: [SessionInfo] = []
  var counts = StateCounts()
  var generatedAt = Date()
  /// True when process scanning (ps/lsof) succeeded this cycle.
  var processScanOk = false

  static let empty = SessionSnapshot()

  /// Sessions grouped by tool, in a stable display order, skipping empty groups.
  var groupedByTool: [(tool: ToolKind, items: [SessionInfo])] {
    ToolKind.allCases.compactMap { tool in
      let items = sessions.filter { $0.tool == tool }
      return items.isEmpty ? nil : (tool, items)
    }
  }
}

/// Outcome of a "jump to the terminal hosting this session" request.
enum FocusResult: Sendable, Equatable {
  case ok
  case notFound
  case noProcess
  case unknownTerminal
  case activateFailed

  var isOK: Bool { self == .ok }

  var message: String? {
    switch self {
    case .ok: nil
    case .unknownTerminal: "Couldn't identify the terminal app for this session."
    case .notFound, .noProcess, .activateFailed:
      "Couldn't find the terminal window for this session."
    }
  }
}
