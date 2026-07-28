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

  /// Hook event names, the other half of what used to live in the user's
  /// settings file.
  static let hookEvents: [(event: String?, expected: Activity)] = [
    ("SessionStart", .opened),
    ("PermissionRequest", .blockedOnUser),
    ("Notification:permission_prompt", .blockedOnUser),
    ("Notification:idle_prompt", .turnComplete),
    ("Stop", .turnComplete),
    ("StopFailure", .turnComplete),
    ("Stop:subagent-running", .turnInFlight),
    ("PostToolUse", .turnInFlight),
    (nil, .unknown),
  ]

  /// Claude transcript records, as they appear on disk, and what each says.
  static let transcriptCases: [(name: String, line: String, expected: Activity)] = [
    (
      "a prompt hands the turn to the model",
      #"{"type":"user","message":{"role":"user","content":"carry on"}}"#,
      .turnInFlight
    ),
    (
      "Esc takes the turn back rather than handing it over",
      #"{"type":"user","message":{"role":"user","content":"[Request interrupted by user]"}}"#,
      .turnComplete
    ),
    (
      "Esc during a tool call reads the same",
      #"""
      {"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}
      """#,
      .turnComplete
    ),
    (
      "`! nvim` and its caveat are not a prompt",
      #"""
      {"type":"user","message":{"role":"user","content":"<local-command-caveat>Caveat: The messages below were generated by the user while running local commands.</local-command-caveat>"}}
      """#,
      .unknown
    ),
    (
      "a slash command is not a prompt either",
      #"""
      {"type":"user","message":{"role":"user","content":[{"type":"text","text":"<command-name>/recap</command-name>"}]}}
      """#,
      .unknown
    ),
    (
      "a dispatched tool is a turn in flight",
      #"""
      {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash"}]}}
      """#,
      .turnInFlight
    ),
    (
      "end_turn completes the turn",
      #"""
      {"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}}
      """#,
      .turnComplete
    ),
  ]

  /// Everything `--selftest` checks: derivation, hook events, transcript records.
  static var count: Int { cases.count + hookEvents.count + transcriptCases.count }

  /// Ordering has to be stable within a state, or cards trade places on their
  /// own. Two running sessions whose last activity differs — and moves, as a
  /// running session's does on every tool call — must still sort the same way.
  static func runOrderingChecks() -> Int {
    let now = Date()
    func session(_ project: String, _ state: SessionState, agoSeconds: TimeInterval)
      -> SessionInfo
    {
      SessionInfo(
        id: "claude:\(project)", tool: .claude, projectPath: "/tmp/\(project)",
        workingDirectory: "/tmp/\(project)", project: project,
        evidence: Evidence(
          .turnInFlight, at: now.addingTimeInterval(-agoSeconds), source: .reported),
        state: state)
    }

    var failures = 0
    func check(_ name: String, _ passed: Bool) {
      if passed { print("  ✓ \(name)") } else { failures += 1; print("  ✗ \(name)") }
    }

    let freshFirst = [session("alpha", .running, agoSeconds: 1),
                      session("beta", .running, agoSeconds: 90)]
    let staleFirst = [session("alpha", .running, agoSeconds: 90),
                      session("beta", .running, agoSeconds: 1)]
    check(
      "two running sessions keep their order when one acts",
      freshFirst.sorted(by: SessionInfo.inAttentionOrder).map(\.project)
        == staleFirst.sorted(by: SessionInfo.inAttentionOrder).map(\.project))

    var unread = session("idle-unread", .idle, agoSeconds: 1200)
    unread.isUnread = true
    let banded = ([unread] + [session("idle-seen", .idle, agoSeconds: 60)])
      .sorted(by: SessionInfo.inAttentionOrder)
    check(
      "unseen idle outranks idle already read, however old",
      banded.map(\.project) == ["idle-unread", "idle-seen"])

    let mixed = [session("idle-old", .idle, agoSeconds: 600),
                 session("running", .running, agoSeconds: 300),
                 session("waiting-new", .waiting, agoSeconds: 10),
                 session("waiting-old", .waiting, agoSeconds: 900)]
      .sorted(by: SessionInfo.inAttentionOrder)
    check(
      "longest wait comes first, then running, then idle",
      mixed.map(\.project) == ["waiting-old", "waiting-new", "running", "idle-old"])

    return failures
  }

  /// A process is what it *is*, not what it was asked to operate on. Every
  /// negative here was a card that appeared on screen (ADR-0016).
  static func runProcessChecks() -> Int {
    // Real argument vectors, because that is what the scanner sees. The one
    // with spaces in its path is the regression that made this matter: split on
    // spaces, its argv[0] became `/Users/x/Library/Application` and Claude
    // Desktop stopped being recognised at all.
    let cases: [(name: String, argv: [String], expected: ToolKind?)] = [
      ("a bare agent", ["claude"], .claude),
      ("an agent with arguments", ["/Users/x/.local/bin/claude", "--resume", "abc"], .claude),
      ("an agent run as a script", ["node", "/opt/claude-code/cli.js", "--print"], .claude),
      (
        "an executable path containing spaces",
        ["/Users/x/Library/Application Support/Claude/claude-code/2.1/claude.app/Contents/MacOS/claude",
         "--output-format", "stream-json"],
        .claude
      ),
      ("codex", ["/opt/homebrew/bin/codex"], .codex),
      ("opencode", ["opencode", "run"], .opencode),
      ("a shell that merely mentions one", ["zsh", "-c", "sleep 9; ls /tmp/claude "], nil),
      ("a grep over the agent's own directory", ["grep", "-r", "/Users/x/.claude/projects"], nil),
      ("this app's own diagnostics", ["/Applications/Code Monitor.app/…", "--focus", "claude"], nil),
    ]

    var failures = 0
    for testCase in cases {
      let actual = ProcessScanner.tool(forArguments: testCase.argv)
      if actual == testCase.expected {
        print("  ✓ \(testCase.name)")
      } else {
        failures += 1
        print("  ✗ \(testCase.name): expected \(testCase.expected?.rawValue ?? "none"), "
          + "got \(actual?.rawValue ?? "none")")
      }
    }
    return failures
  }

  /// A session hosted by a desktop app has no process to find, so a scan that
  /// finds none has observed nothing — and `unknown` is what keeps it listed
  /// through a long turn instead of expiring at five minutes (ADR-0017).
  static func runHostChecks() -> Int {
    var failures = 0
    func check(_ name: String, _ passed: Bool) {
      if passed { print("  ✓ \(name)") } else { failures += 1; print("  ✗ \(name)") }
    }

    check(
      "Codex Desktop is a desktop host",
      CodexSource.hostBundleID(for: "Codex Desktop") == "com.openai.codex")
    check(
      "a CLI session has no desktop host",
      CodexSource.hostBundleID(for: "codex_cli_rs") == nil)
    check("a session with no originator has none", CodexSource.hostBundleID(for: nil) == nil)

    // The lifetime consequence, which is the whole reason the field exists.
    let desktop = Evidence(.turnInFlight, at: .distantPast, source: .inferred, liveness: .unknown)
    let terminal = Evidence(.turnInFlight, at: .distantPast, source: .inferred, liveness: .absent)
    let now = Date()
    var aged = desktop
    aged.at = now.addingTimeInterval(-10 * 60)
    var agedTerminal = terminal
    agedTerminal.at = now.addingTimeInterval(-10 * 60)
    check("a desktop session survives a ten-minute turn", aged.isCurrent(now: now))
    check("a terminal session with no process does not", !agedTerminal.isCurrent(now: now))

    return failures
  }

  /// Runs the tables. Returns the number of failures.
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

    for (event, expected) in hookEvents {
      let actual = HookStateStore.activity(forEvent: event)
      if actual == expected {
        print("  ✓ \(event ?? "(no event)") → \(expected.rawValue)")
      } else {
        failures += 1
        print("  ✗ \(event ?? "(no event)") → expected \(expected.rawValue), got \(actual.rawValue)")
      }
    }

    // And a transcript record, which is all a session without a hook is judged
    // on. Parsed rather than constructed, because the misreading that put an
    // interrupted session in the waiting column was as much about the shape of
    // the record as about the rule applied to it.
    for (name, line, expected) in transcriptCases {
      let actual = ClaudeSource.activity(TranscriptReader.parseClaudeTail(line))
      if actual == expected {
        print("  ✓ \(name)")
      } else {
        failures += 1
        print("  ✗ \(name) → expected \(expected.rawValue), got \(actual.rawValue)")
      }
    }

    return failures
  }
}
