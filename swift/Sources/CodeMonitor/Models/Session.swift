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

  /// Applications that host this tool, best match first. Used to show the
  /// tool's own icon on a card — a symbol has to be learned, whereas the icon
  /// is the one the user already clicks on.
  var bundleIdentifiers: [String] {
    switch self {
    case .claude: ["com.anthropic.claudefordesktop", "com.anthropic.claude"]
    case .codex: ["com.openai.codex", "com.openai.chat"]
    case .opencode: ["dev.opencode.app", "com.opencode.opencode"]
    }
  }

  /// SF Symbol used in group headers and the menu bar. Also the fallback where
  /// no application is installed — the CLIs run without one.
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

  /// The state's own name, claiming no cause.
  ///
  /// This used to read "Waiting approval", which was true while a permission
  /// prompt was the only way to reach `waiting`. A usage limit reaches it too
  /// (ADR-0024), and that card is not waiting for anybody's approval. Naming the
  /// cause is `SessionInfo.statusLabel`'s job, because the cause lives in the
  /// evidence and a state cannot see it.
  var label: String {
    switch self {
    case .running: "Running"
    case .waiting: "Waiting"
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

  /// Sort weight — most urgent first. Also the order the jump shortcut works
  /// through: whatever is blocking a person, then what is under way, then what
  /// is merely sitting there.
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
  /// Set when the session runs inside a desktop app rather than a terminal, to
  /// that app's bundle identifier.
  ///
  /// Two things follow from it, and both are corrections to an assumption this
  /// app was built on — that a session is backed by a findable process. A
  /// desktop host's processes sit at `/` and belong to the app, not the
  /// session, so their absence proves nothing and their presence identifies
  /// nothing. Jumping therefore means activating the app, and liveness has to
  /// stay `unknown` rather than decay to `absent` (ADR-0017).
  var hostBundleID: String?
  /// Started by a program rather than a person — an SDK-spawned agent doing a
  /// piece of someone else's task, not a session anybody is sitting in front of.
  var isDelegated = false
  /// Delegated agents currently working underneath this session.
  var subagentCount = 0
  /// When this session was last observed doing anything.
  var lastActivity: Date { evidence.at }

  /// When the thing the card reports began — what "5m" on a tile counts from.
  ///
  /// For `waiting` and `idle` this is just `lastActivity`: nothing writes once
  /// a session is blocked or finished, so the last write *is* the moment the
  /// state began. `running` is the exception, and the one that misled — a
  /// running session writes on every tool call, so its last write says "there
  /// was activity two seconds ago", never "this has been running two seconds".
  /// It is filled in with the start of the current turn instead.
  var stateSince: Date?

  /// How long the card's state has been going, in seconds.
  func age(at now: Date) -> TimeInterval {
    now.timeIntervalSince(stateSince ?? lastActivity)
  }

  /// The order sessions are shown in, and the order the jump shortcut walks
  /// through. One rule, so what you see and what a keypress does agree.
  ///
  /// Within a state the key has to be *stable*, which is the whole subtlety
  /// here. A running session's `lastActivity` moves on every hook event — twice
  /// per tool call — so ordering running sessions by it made two cards trade
  /// places every few seconds. That is motion carrying no information, on a
  /// display where motion is the expensive thing (ADR-0006), and it made
  /// pressing the shortcut twice land back where it started.
  static func inAttentionOrder(_ a: SessionInfo, _ b: SessionInfo) -> Bool {
    if a.attentionGroup != b.attentionGroup { return a.attentionGroup < b.attentionGroup }
    switch a.state {
    case .waiting:
      // Longest wait first: it has cost the most time. Stable, because a
      // session that is waiting is by definition producing no events.
      return a.lastActivity < b.lastActivity
    case .running:
      // Which of two running sessions called a tool most recently is not
      // something anyone acts on, so it buys nothing and costs stability.
      return (a.project, a.id) < (b.project, b.id)
    case .idle:
      // Most recent first, and stable for the same reason waiting is.
      return a.lastActivity > b.lastActivity
    }
  }

  /// Which band this session sorts into: blocked on you, working, finished but
  /// unseen, then seen. Only the last two share a `SessionState`, which is why
  /// this exists rather than the state's own `order` doing the whole job.
  var attentionGroup: Int {
    switch state {
    case .waiting: 0
    case .running: 1
    case .idle: isUnread ? 2 : 3
    }
  }

  /// Finished since the last time the user went there — so the turn ended and
  /// nobody has looked at what it said.
  ///
  /// Derived from two observations rather than stored as a flag: when the
  /// session last acted, and when it was last jumped to. A stored flag would
  /// have to be cleared by something, and every "something" is a chance to
  /// leave it set on a session that has since spoken again (ADR-0012).
  ///
  /// Only idle sessions carry it. A running one has not finished anything yet,
  /// and a waiting one is already asking louder than this ever could.
  var isUnread = false

  // `deservesAttention` used to sit here, gating the pulse on whether a
  // `waiting` had been reported or merely guessed at. It has been a constant
  // `true` since ADR-0020, and remains one — but not for the reason first
  // written here, which was that `blockedOnUser` came from the hook store alone.
  // ADR-0024 added a second reporter, so "only one source" is no longer true;
  // "only a *report*" still is, and that is what made the gate pointless.
  // Keeping it would have kept the design it encodes — that guesses exist and
  // are handled by drawing them faintly — which is the answer ADR-0020 rejected
  // in favour of not guessing at all.

  /// What the card says the session is doing.
  ///
  /// The state names itself; the activity says why, and only for `waiting`,
  /// which is the one state with two causes that ask different things of the
  /// user. A permission prompt wants an answer here; a usage limit wants time,
  /// a different model, or credits — and telling the second it is "waiting
  /// approval" is simply false (ADR-0024).
  ///
  /// Derived rather than stored, so it cannot disagree with the state it
  /// describes.
  var statusLabel: String {
    switch (state, evidence.activity) {
    case (.waiting, .blockedOnLimit): "Rate limited"
    case (.waiting, _): "Waiting approval"
    default: state.label
    }
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
  /// Derived, never stored. It was assigned in three places — the scan, the
  /// dismissal filter, and nowhere at all after sessions were withheld — and
  /// the one that was missing is the shape this codebase keeps paying for: two
  /// expressions of the same fact, drifting. A withheld session stayed in the
  /// count, so the header read `1 waiting` with no card under it and the menu
  /// bar went amber while the band stayed dark, for up to fifteen seconds
  /// (ADR-0007: everything shown is meant to deserve a look).
  var counts: StateCounts {
    var counts = StateCounts()
    for session in sessions { counts[session.state] += 1 }
    return counts
  }
  var generatedAt = Date()
  /// True when process scanning (ps/lsof) succeeded this cycle.
  var processScanOk = false
  /// What each tool last said about its own quota windows (ADR-0023).
  ///
  /// Account-level, so it sits on the snapshot rather than on any session. A
  /// tool missing from here has said nothing, which is what makes `—` mean
  /// something different from `∞`.
  var usage: [ToolUsage] = []

  static let empty = SessionSnapshot()

  /// Sessions grouped by tool, in a stable display order, skipping empty groups.
  var groupedByTool: [(tool: ToolKind, items: [SessionInfo])] {
    ToolKind.allCases.compactMap { tool in
      let items = sessions.filter { $0.tool == tool }
      return items.isEmpty ? nil : (tool, items)
    }
  }

  /// What the display animates on: which sessions exist and what state each is
  /// in. A scan lands every couple of seconds and almost always changes
  /// something (elapsed time, a message snippet); animating on the snapshot
  /// itself would keep the whole list in perpetual motion, on a display whose
  /// scarcest resource is motion (ADR-0006).
  var stateSignature: [String] {
    sessions.map { "\($0.id):\($0.state.rawValue):\($0.isUnread)" }
  }

  /// Every session in the order the jump shortcut visits them — which is also
  /// the order they are displayed in, since the scanner sorts by the same rule.
  /// `--focus-next --dry-run` therefore prints what is on screen.
  var byAttention: [SessionInfo] {
    sessions.sorted(by: SessionInfo.inAttentionOrder)
  }

  /// The next session to jump to, given the one jumped to last.
  ///
  /// Queue consumption, not selection: there is no aiming step to display, so
  /// nothing on screen has to show which session is "current" (ADR-0014).
  /// Passing the previous target advances past it; passing nil starts at the
  /// most urgent, which is what a jump after any pause should do.
  func nextToHandle(after previous: String?) -> SessionInfo? {
    let ordered = byAttention
    guard !ordered.isEmpty else { return nil }
    guard let previous, let at = ordered.firstIndex(where: { $0.id == previous }) else {
      return ordered.first
    }
    return ordered[(at + 1) % ordered.count]
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
