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
  /// Stopped by a usage limit (ADR-0024).
  ///
  /// Also blocked on the user, and deliberately *not* folded into
  /// `blockedOnUser`, because one thing must treat the two differently: the
  /// grant retraction below asks "did a child process start after the block",
  /// which dates a permission answer and says nothing at all about a quota. A
  /// separate value makes that misfire impossible rather than guarded — the
  /// guard already reads `== .blockedOnUser` and so cannot reach this.
  ///
  /// ADR-0019 refused a fourth value on the grounds that it would "describe a
  /// condition nothing else distinguishes". Two things distinguish this one: the
  /// retraction, and the card's label.
  case blockedOnLimit
  /// The turn ended; the session is waiting for whatever the user says next.
  case turnComplete
  /// The session exists and nothing has happened in it yet.
  case opened
  /// Something changed, and the source cannot say what.
  case unknown
}

/// How much weight the observation carries.
///
/// Strength, not channel. The distinction stopped being academic when a usage
/// limit turned out to be reported *in the transcript* — `isApiErrorMessage`
/// with text saying the model refused (ADR-0024). Read as "where did this come
/// from", that record is `inferred`, which would let inference produce `waiting`
/// and collapse ADR-0012's rule that the two are not shown alike. Read as "how
/// much is it worth", it is exactly what `reported` means.
enum EvidenceSource: String, Sendable, Hashable {
  /// We guessed what a file implies — from timestamps, or from the shape of the
  /// last record. Guesses have been wrong.
  case inferred
  /// The tool stated it: usually through a hook, and through a transcript record
  /// flagged as an API error where no hook event exists.
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
  ///
  /// The guard is `== .blockedOnUser` and not "any block", which is now
  /// load-bearing rather than incidental: a usage limit is `blockedOnLimit`
  /// (ADR-0024) and nothing a local process does clears one, so this must not
  /// reach it. An MCP server restarting would otherwise flip a stalled card back
  /// to `running` and rewrite `at` with it, resetting the elapsed time too.
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
    case .blockedOnUser, .blockedOnLimit:
      // Both are the agent stopped with work outstanding, which is what the
      // display means by `waiting`. What differs is how the user unblocks it,
      // and that is the label's business, not the state's (ADR-0024).
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
