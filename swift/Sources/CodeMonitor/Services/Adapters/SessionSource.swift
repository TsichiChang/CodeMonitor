/// A source of sessions for one tool (ADR-0004).
///
/// Each tool exposes its sessions differently — JSONL transcripts for Claude
/// Code and Codex, a SQLite index for OpenCode — and a shared scanner could
/// only ever read them at the fidelity of the weakest one. A source reads its
/// tool's own store and yields Sessions.
///
/// Sources are reference types holding their own caches, and are only ever
/// touched from inside `SessionScanner`'s isolation.

import Foundation

protocol SessionSource: AnyObject {
  var tool: ToolKind { get }

  /// Sessions this tool considers current, unsorted.
  /// `now` is passed in so every source in one scan shares a clock.
  func sessions(now: Date) -> [SessionInfo]
}

// MARK: - Shared thresholds

/// How sessions age, in seconds. Shared by the sources that infer state from
/// timestamps rather than being told it (ADR-0001).
enum Aging {
  /// Store touched this recently ⇒ actively working.
  static let writing: TimeInterval = 4
  /// A tool call unanswered this long is likely blocked on approval.
  static let approvalSuspect: TimeInterval = 45
  /// A model may think or stream this long after a prompt or tool result.
  static let generatingMax: TimeInterval = 3 * 60
  /// Beyond this, a stalled tool call is treated as abandoned.
  static let waitingMax: TimeInterval = 10 * 60
  /// How long a session stays listed after its last activity.
  ///
  /// `waiting` never expires: a session blocked on approval is the one thing
  /// the user must not miss, and it is motionless by definition, so aging it
  /// out would hide it exactly when it matters (ADR-0005).
  ///
  /// Applied by the scanner rather than by a source, because it has to run
  /// *after* live processes are attached — a session backed by a running
  /// process is still open no matter how long its store has been quiet.
  static func window(for state: SessionState) -> TimeInterval {
    switch state {
    case .waiting: .infinity
    case .running: 30 * 60
    case .idle: 10 * 60
    }
  }

  /// How long a session with no live process stays listed, whatever its state.
  ///
  /// Short, because "no process" is the closest thing to proof that a session
  /// is over. Long enough that a scan which momentarily fails to match a
  /// process does not wipe the list.
  static let windowWithoutProcess: TimeInterval = 5 * 60

  /// How far back a source bothers reading. Not a lifecycle rule — that is the
  /// scanner's — just a bound on how much history is worth parsing.
  ///
  /// Generous on purpose: a session can sit quiet for hours with its agent
  /// alive and waiting, and a source that had already skipped it leaves the
  /// scanner nothing to keep. On this machine it is the difference between
  /// reading 1 transcript and 5, against 284 on disk, and parses are cached by
  /// modification time so old files are read at most once.
  static let readHorizon: TimeInterval = 24 * 60 * 60
}

// MARK: - Shared helpers

extension SessionSource {
  /// Whether a directory can stand as a session's Project.
  ///
  /// "/" cannot. It arrives from a transcript that recorded it literally or a
  /// project directory named "-", and a card labelled "/" says nothing a reader
  /// can act on — costly where every row is contested (ADR-0006).
  func isUsableProject(_ path: String) -> Bool {
    path != "/" && !path.isEmpty
  }

  func label(for path: String) -> String {
    let name = URL(fileURLWithPath: path).lastPathComponent
    return name.isEmpty ? path : name
  }

  func modificationDate(of url: URL) -> Date? {
    try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
  }
}
