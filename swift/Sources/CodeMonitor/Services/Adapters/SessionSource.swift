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
  /// Beyond this, a turn that has produced nothing is treated as abandoned
  /// rather than still running. Nothing is claimed about *why* it stopped —
  /// that guess was `approvalSuspect`, and it is gone (ADR-0020).
  static let abandoned: TimeInterval = 10 * 60

  // A per-state window used to live here — `waiting` never expiring, `running`
  // getting a generous one, `idle` a short one. It is gone rather than merely
  // unused: lifetime follows liveness and never state, which is the whole of
  // ADR-0012 and what stopped a mistaken `waiting` from being immortal. Left in
  // place it was a working implementation of the repealed rule, sitting one
  // autocomplete away from whoever next edits a lifetime.

  /// How long a session with no live process stays listed, whatever its state.
  ///
  /// Short, because "no process" is the closest thing to proof that a session
  /// is over. Long enough that a scan which momentarily fails to match a
  /// process does not wipe the list.
  static let windowWithoutProcess: TimeInterval = 5 * 60

  /// How long a session stays listed when liveness could not be determined.
  /// Generous on purpose — this is the failure case, and dropping sessions
  /// because a scan did not run would be the worse outcome.
  static let windowWithUnknownLiveness: TimeInterval = 30 * 60

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
