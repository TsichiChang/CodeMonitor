/// Table of what evidence should derive to, exercised by `--selftest`.
///
/// Every case here is a defect that shipped. They were all found by running the
/// app and noticing something wrong on screen; each one now costs a line to
/// state and milliseconds to check, which is the concrete payoff of deriving
/// from evidence rather than storing a state (ADR-0012).

import Foundation

enum EvidenceChecks {
  struct Case {
    let name: String
    let evidence: Evidence
    let age: TimeInterval
    let expectedState: SessionState
    let expectedCurrent: Bool
  }

  static let cases: [Case] = [
    // Reported events map to what they actually mean.
    .init(
      name: "SessionStart is not activity",
      evidence: Evidence(.opened, at: .distantPast, source: .reported, liveness: .alive),
      age: 90 * 60, expectedState: .idle, expectedCurrent: true),
    .init(
      name: "an idle_prompt notification ends the turn",
      evidence: Evidence(.turnComplete, at: .distantPast, source: .reported, liveness: .alive),
      age: 60, expectedState: .idle, expectedCurrent: true),
    .init(
      name: "a permission prompt blocks",
      evidence: Evidence(.blockedOnUser, at: .distantPast, source: .reported, liveness: .alive),
      age: 60, expectedState: .waiting, expectedCurrent: true),

    // A reported turn does not decay into a guessed block: a hook would have
    // said so. A long tool call is still running.
    .init(
      name: "a reported turn stays running while a tool takes its time",
      evidence: Evidence(.turnInFlight, at: .distantPast, source: .reported, liveness: .alive),
      age: 10 * 60, expectedState: .running, expectedCurrent: true),

    // Inference may guess, within limits.
    .init(
      name: "a fresh inferred turn is running",
      evidence: Evidence(.turnInFlight, at: .distantPast, source: .inferred, liveness: .alive),
      age: 10, expectedState: .running, expectedCurrent: true),
    .init(
      name: "a quiet inferred turn is a suspected block",
      evidence: Evidence(.turnInFlight, at: .distantPast, source: .inferred, liveness: .alive),
      age: 120, expectedState: .waiting, expectedCurrent: true),
    .init(
      name: "an abandoned inferred turn is neither",
      evidence: Evidence(.turnInFlight, at: .distantPast, source: .inferred, liveness: .alive),
      age: 30 * 60, expectedState: .idle, expectedCurrent: true),

    // Lifetime follows liveness, never state — this is what made a mistaken
    // `waiting` immortal.
    .init(
      name: "a blocked session with no process does not linger",
      evidence: Evidence(.blockedOnUser, at: .distantPast, source: .reported, liveness: .absent),
      age: 10 * 60, expectedState: .waiting, expectedCurrent: false),
    .init(
      name: "a blocked session with a process stays as long as it takes",
      evidence: Evidence(.blockedOnUser, at: .distantPast, source: .reported, liveness: .alive),
      age: 8 * 60 * 60, expectedState: .waiting, expectedCurrent: true),

    // A scan that could not run says nothing, and must not clear the display.
    .init(
      name: "unknown liveness keeps a session rather than dropping it",
      evidence: Evidence(.turnInFlight, at: .distantPast, source: .reported, liveness: .unknown),
      age: 10 * 60, expectedState: .running, expectedCurrent: true),

    // A process and nothing else. Claiming activity here pinned the app at full
    // poll rate for as long as the process lived.
    .init(
      name: "a bare process is not evidence of work",
      evidence: Evidence(.unknown, at: .distantPast, source: .inferred, liveness: .alive),
      age: 60, expectedState: .idle, expectedCurrent: true),
    .init(
      name: "a store touched this second is",
      evidence: Evidence(.unknown, at: .distantPast, source: .inferred, liveness: .alive),
      age: 1, expectedState: .running, expectedCurrent: true),
  ]

  /// Runs the table. Returns the number of failures.
  static func run() -> Int {
    let now = Date()
    var failures = 0

    for testCase in cases {
      var evidence = testCase.evidence
      evidence.at = now.addingTimeInterval(-testCase.age)

      let state = evidence.state(now: now)
      let current = evidence.isCurrent(now: now)
      let ok = state == testCase.expectedState && current == testCase.expectedCurrent

      if ok {
        print("  ✓ \(testCase.name)")
      } else {
        failures += 1
        print("  ✗ \(testCase.name)")
        if state != testCase.expectedState {
          print("      state: expected \(testCase.expectedState.rawValue), got \(state.rawValue)")
        }
        if current != testCase.expectedCurrent {
          print("      listed: expected \(testCase.expectedCurrent), got \(current)")
        }
      }
    }

    // The hook reports event names; the mapping from those is the other half of
    // what used to live in the user's settings file.
    let events: [(String?, Activity)] = [
      ("SessionStart", .opened),
      ("PermissionRequest", .blockedOnUser),
      ("Notification:permission_prompt", .blockedOnUser),
      ("Notification:idle_prompt", .turnComplete),
      ("Stop", .turnComplete),
      ("Stop:subagent-running", .turnInFlight),
      ("PostToolUse", .turnInFlight),
      (nil, .unknown),
    ]
    for (event, expected) in events {
      let actual = HookStateStore.activity(forEvent: event)
      if actual == expected {
        print("  ✓ \(event ?? "(no event)") → \(expected.rawValue)")
      } else {
        failures += 1
        print("  ✗ \(event ?? "(no event)") → expected \(expected.rawValue), got \(actual.rawValue)")
      }
    }

    return failures
  }
}
