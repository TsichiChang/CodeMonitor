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

extension Evidence {
  /// Resolves a permission prompt that has since been answered.
  ///
  /// Claude Code fires `PermissionRequest` when the prompt appears and nothing
  /// at all when it is granted, so the last word from any hook stays "blocked
  /// on the user" for as long as the approved tool then takes to run. A build
  /// read as a minute of waiting for approval that had already been given.
  ///
  /// The grant is unobservable; the work that follows it is not. A child
  /// process started *after* the prompt cannot have been started by a user who
  /// had not answered yet — so it dates the answer, and is a later observation
  /// than the prompt it supersedes. Children that predate the prompt say
  /// nothing: an agent keeps MCP servers alive for its whole session.
  ///
  /// Deliberately not a new `Activity`. "Approved and now working" is what
  /// `turnInFlight` already means; a fourth value would have to be given a
  /// meaning everywhere activities are read, to describe a state nothing else
  /// distinguishes.
  func resolvingGrant(newestChildStart: Date?) -> Evidence {
    guard activity == .blockedOnUser, let started = newestChildStart, started > at else {
      return self
    }
    var resolved = self
    resolved.activity = .turnInFlight
    resolved.at = started
    return resolved
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
      // A tool said it is working, so it is working, however long that takes —
      // a hook would have reported a block if there were one.
      if source == .reported { return .running }
      // An inferred turn is a guess about a store that went quiet, and it now
      // guesses only between "still running" and "abandoned".
      //
      // It used to have a third answer: quiet for 45 seconds meant a *suspected
      // block*. That existed for sessions with no hook, where silence was the
      // only hint that something might be waiting on the user — and it guessed
      // at the single state this app must not get wrong. Hooks are installed
      // now rather than hand-registered (ADR-0020), so the only sessions left
      // without one are those where reporting has broken, and there a wrong
      // `waiting` costs more than a missing one.
      //
      // What it detected has not become invisible: the card shows how long the
      // current state has run, so a genuinely stuck turn reads as `running
      // 12m` — a fact, rather than a guess demanding attention.
      return age < Aging.abandoned ? .running : .idle
    }
  }

  /// Whether this session could have left anything a person is behind on.
  ///
  /// Unread means *finished work nobody has looked at* (ADR-0018), and `opened`
  /// is the one activity that says the opposite outright: the session exists and
  /// nothing has happened in it yet. Both `/clear` and `/compact` report
  /// `SessionStart`, so both minted a blue card — for a session the user was
  /// sitting in front of at that exact moment, with no output to read. Being the
  /// newest thing on screen, it then outranked every session that really was
  /// unread, and the shortcut stopped there first.
  ///
  /// Everything else counts, including the ambiguous cases. A turn that stalled
  /// and aged out, or a store that offers only a timestamp, may or may not have
  /// left something worth reading — and ADR-0018 exists because *hiding*
  /// finished work is the more expensive mistake, so they stay in.
  var mayLeaveSomethingUnread: Bool { activity != .opened }

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
