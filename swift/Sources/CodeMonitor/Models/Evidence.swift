/// What is actually known about a session, as opposed to what is shown about it.
///
/// A session stores only this. Its state, how long it stays listed, and how the
/// card looks are all derived from it, each in one place, and none of them from
/// each other (ADR-0012).

import Foundation

/// The last thing a source could honestly say happened.
///
/// This is the common denominator of four very unequal sources: a Claude hook
/// names a precise event, a transcript supports a guess, a Codex rollout says
/// `task_complete` or nothing, and OpenCode's store offers a timestamp alone —
/// which is what `unknown` is for.
enum Activity: String, Sendable, Hashable {
  /// The model owns the turn: streaming, or a dispatched tool with no result.
  case turnInFlight
  /// Stopped and unable to continue without the user — a permission prompt.
  case blockedOnUser
  /// The turn ended; the session is waiting for whatever the user says next.
  case turnComplete
  /// The session exists and nothing has happened in it yet.
  case opened
  /// Something changed, and the source cannot say what.
  case unknown
}

/// How much weight the observation carries.
enum EvidenceSource: String, Sendable, Hashable {
  /// Read off timestamps and file contents. A guess, and guesses have been wrong.
  case inferred
  /// The tool said so itself.
  case reported
}

/// Whether a process backs the session.
///
/// Three values, not two. `Bool` conflated "confirmed absent" with "could not
/// tell", and each confusion produced a defect at an opposite extreme: a dead
/// session treated as alive never expired, and a process scan that failed
/// entirely would have marked every session absent and emptied the display.
enum Liveness: String, Sendable, Hashable {
  case alive
  case absent
  case unknown
}

struct Evidence: Sendable, Hashable {
  var activity: Activity
  /// When the observation was made.
  var at: Date
  var source: EvidenceSource
  var liveness: Liveness = .unknown

  init(_ activity: Activity, at: Date, source: EvidenceSource, liveness: Liveness = .unknown) {
    self.activity = activity
    self.at = at
    self.source = source
    self.liveness = liveness
  }
}

// MARK: - Derivation

extension Evidence {
  /// The one place a session's state is decided.
  func state(now: Date) -> SessionState {
    let age = now.timeIntervalSince(at)

    switch activity {
    case .blockedOnUser:
      return .waiting

    case .turnComplete, .opened:
      // A session that has just been opened is not working — it is waiting for
      // its first instruction. Reporting that as activity showed an untouched
      // session as running for an hour and a half.
      return .idle

    case .unknown:
      // Only a timestamp to go on, so the only claim available is "something
      // happened just now".
      return age < Aging.writing ? .running : .idle

    case .turnInFlight:
      if age < Aging.approvalSuspect { return .running }
      // A dispatched tool that has gone quiet is either still working or
      // blocked on a prompt, and only inference has to guess between them: a
      // hook would have reported the block. So a reported turn stays running
      // however long the tool takes, and an inferred one becomes a suspected
      // block, then eventually nothing.
      if source == .reported { return .running }
      return age < Aging.waitingMax ? .waiting : .idle
    }
  }

  /// Whether the session still belongs on screen (ADR-0005).
  func isCurrent(now: Date) -> Bool {
    let age = now.timeIntervalSince(at)
    switch liveness {
    case .alive:
      // A store can be quiet for hours while its agent sits there alive.
      return true
    case .absent:
      // No process: the closest thing to proof that a session is over. Even a
      // blocked session goes, since nothing remains to act on an answer.
      return age <= Aging.windowWithoutProcess
    case .unknown:
      // We could not look. Keeping things is the safe failure: treating this as
      // absence would clear the display on any scan that failed to run.
      return age <= Aging.windowWithUnknownLiveness
    }
  }

}
