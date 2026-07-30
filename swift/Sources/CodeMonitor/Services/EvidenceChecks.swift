/// Table of what evidence should derive to, exercised by `--selftest`.
///
/// Every case here is a defect that shipped. They were all found by running the
/// app and noticing something wrong on screen; each one now costs a line to
/// state and milliseconds to check, which is the concrete payoff of deriving
/// from evidence rather than storing a state (ADR-0012).

import Foundation

enum EvidenceChecks {
  /// How many assertions actually ran.
  ///
  /// The `--selftest` total used to be a sum of literals in `Diagnostics` — one
  /// per check function — which is the same fact written twice and went stale
  /// the first time an assertion was added without editing the arithmetic.
  /// Everything that prints a ✓ or a ✗ passes through `report` or bumps this, so
  /// the number cannot disagree with what was run.
  private nonisolated(unsafe) static var ranCount = 0
  static var ran: Int { ranCount }

  /// One assertion's result: printed, counted, and worth 1 failure or 0.
  static func report(_ name: String, _ passed: Bool) -> Int {
    ranCount += 1
    if passed {
      print("  ✓ \(name)")
      return 0
    }
    print("  ✗ \(name)")
    return 1
  }

  /// Counts a check whose own output is more detailed than `report` prints.
  private static func counted() { ranCount += 1 }

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
    .init(
      // Same state, different remedy. Before ADR-0024 this read `idle`: a card
      // folded to a dim line about a turn that had stopped mid-task.
      name: "a usage limit blocks just as hard",
      evidence: Evidence(.blockedOnLimit, at: .distantPast, source: .reported, liveness: .alive),
      age: 60, expectedState: .waiting, expectedCurrent: true),
    .init(
      // Lifetime follows liveness alone, so a limit stall outlasts its window
      // for the same reason a permission prompt outlasts a long build.
      name: "and keeps its card for as long as the agent is alive",
      evidence: Evidence(.blockedOnLimit, at: .distantPast, source: .reported, liveness: .alive),
      age: 6 * 60 * 60, expectedState: .waiting, expectedCurrent: true),

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
      // Was a suspected block. Guessing `waiting` off silence is exactly the
      // error the display can least afford, and it only ever applied where
      // hooks were absent — which installing them removed (ADR-0020).
      name: "a quiet inferred turn is still just running",
      evidence: Evidence(.turnInFlight, at: .distantPast, source: .inferred, liveness: .alive),
      age: 120, expectedState: .running, expectedCurrent: true),
    .init(
      name: "waiting is only ever something a tool reported",
      evidence: Evidence(.blockedOnUser, at: .distantPast, source: .reported, liveness: .alive),
      age: 5 * 60, expectedState: .waiting, expectedCurrent: true),
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
    // A usage limit, in the three shapes the corpus actually holds. All were
    // read as `turnComplete` before ADR-0024 — a card folded to a dim line
    // saying "nothing to do here" about a turn cut off mid-task.
    (
      "the five-hour limit stops the turn, it does not finish it",
      #"""
      {"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","model":"<synthetic>","stop_reason":"stop_sequence","content":[{"type":"text","text":"You've hit your session limit · resets 8:20pm (Asia/Shanghai)"}]}}
      """#,
      .blockedOnLimit
    ),
    (
      "so does a model limit, which names no reset time",
      #"""
      {"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","model":"<synthetic>","stop_reason":"stop_sequence","content":[{"type":"text","text":"You've reached your Fable 5 limit. Run /usage-credits to continue or switch models with /model."}]}}
      """#,
      .blockedOnLimit
    ),
    (
      // 85 of the 124 flagged records here are one of these. A dropped
      // connection retries itself and a login failure needs a different
      // remedy, so neither is a session to wait out.
      "an authentication failure carries the same flag and is not a limit",
      #"""
      {"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","stop_reason":"stop_sequence","content":[{"type":"text","text":"Failed to authenticate. API Error: 401 Invalid bearer token"}]}}
      """#,
      .turnComplete
    ),
    (
      // The text without the flag, which is how the message appears in nine
      // records here. Detecting on words alone would let a conversation *about*
      // usage limits set a session's state — and this repository has had exactly
      // that conversation.
      "the same words in a user record are not evidence of anything",
      #"""
      {"type":"user","message":{"role":"user","content":[{"type":"text","text":"You've hit your session limit · resets 8:20pm (Asia/Shanghai)"}]}}
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

  /// Codex rollout events, which name their conditions with codes rather than
  /// prose — so this table needs no wording to stay true (ADR-0024).
  ///
  /// The corpora are the mirror image of the detectors and it is worth stating
  /// where the assertions live: two `usage_limit_exceeded` records exist on this
  /// machine against forty-two on the Claude side, so the robust detector is the
  /// one with almost nothing to check it against.
  static let codexCases: [(name: String, line: String, expected: Activity)] = [
    (
      "a usage limit stops the turn, by code rather than by wording",
      #"""
      {"payload":{"type":"error","message":"You've hit your usage limit. Upgrade to Plus to continue using Codex, or try again at Apr 18th, 2026 3:03 PM.","codex_error_info":"usage_limit_exceeded"}}
      """#,
      .blockedOnLimit
    ),
    (
      "an error with any other code is not a limit",
      #"""
      {"payload":{"type":"error","message":"stream disconnected before completion","codex_error_info":"stream_error"}}
      """#,
      .turnInFlight
    ),
    (
      "task_complete still ends the turn",
      #"{"payload":{"type":"task_complete","last_agent_message":"done"}}"#,
      .turnComplete
    ),
  ]

  /// Everything `--selftest` checks: derivation, hook events, transcript records.
  static var count: Int {
    cases.count + hookEvents.count + transcriptCases.count + codexCases.count
  }

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
      failures += Self.report(name, passed)
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

    // Reading one idle session must not disturb the order of the others.
    func idle(_ name: String, ago: TimeInterval, unread: Bool) -> SessionInfo {
      var s = session(name, .idle, agoSeconds: ago)
      s.isUnread = unread
      return s
    }
    let beforeRead = [idle("a", ago: 30, unread: true),
                      idle("b", ago: 60, unread: true),
                      idle("c", ago: 90, unread: true)]
      .sorted(by: SessionInfo.inAttentionOrder).map(\.project)
    check("unread idle sessions run newest first", beforeRead == ["a", "b", "c"])

    let afterRead = [idle("a", ago: 30, unread: true),
                     idle("b", ago: 60, unread: false),   // the one just visited
                     idle("c", ago: 90, unread: true)]
      .sorted(by: SessionInfo.inAttentionOrder).map(\.project)
    check("reading the middle one drops it below the rest", afterRead == ["a", "c", "b"])

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
      counted()
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
      failures += Self.report(name, passed)
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

  /// What survives folding a hook's report into a session it already knows.
  ///
  /// The precedence half has cost two defects; the carry-over half cost a
  /// third, which is the reason this table exists at all. A hook's pid was
  /// being dropped, so a reported session had to win the directory competition
  /// it was supposed to be exempt from (ADR-0005), and a blocked session that
  /// lost it aged out in five minutes with the ambient band going dark on it.
  static func runHookMergeChecks() -> Int {
    let now = Date()
    func hook(_ activity: Activity, ago: TimeInterval, pid: Int32? = 4242) -> HookState {
      HookState(
        tool: .claude, sessionID: "s", activity: activity, pid: pid, tty: "/dev/ttys009",
        cwd: "/tmp/p", termProgram: "otty", tabID: "t_1", paneID: "p_1",
        updated: now.addingTimeInterval(-ago))
    }
    func session(_ activity: Activity, ago: TimeInterval) -> SessionInfo {
      SessionInfo(
        id: "claude:s", tool: .claude, projectPath: "/tmp/p", workingDirectory: "/tmp/p",
        project: "p", evidence: Evidence(activity, at: now.addingTimeInterval(-ago),
                                         source: .inferred),
        state: .idle)
    }

    var failures = 0
    func check(_ name: String, _ passed: Bool) {
      failures += Self.report(name, passed)
    }

    check(
      "a hook's pid is taken, not guessed at from a directory",
      SessionScanner.applying(hook(.blockedOnUser, ago: 10), to: session(.turnInFlight, ago: 60))
        .pid == 4242)
    check(
      // The pid is an observation from inside the session, not a claim about
      // what it is doing, so losing on freshness must not cost it.
      "a hook that loses on freshness still hands over its pid",
      SessionScanner.applying(hook(.turnInFlight, ago: 600), to: session(.turnComplete, ago: 1))
        .pid == 4242)
    check(
      "the pane a hook recorded comes across",
      SessionScanner.applying(hook(.turnComplete, ago: 10), to: session(.unknown, ago: 10))
        .paneID == "p_1")
    check(
      // Esc: the transcript is later and says something, so it keeps the turn.
      "a later transcript that says something keeps its own word",
      SessionScanner.applying(hook(.turnInFlight, ago: 600), to: session(.turnComplete, ago: 1))
        .evidence.activity == .turnComplete)
    check(
      // `! nvim`: later, but saying nothing, so the hook's Stop stands.
      "a later `unknown` does not displace a hook's Stop",
      SessionScanner.applying(hook(.turnComplete, ago: 600), to: session(.unknown, ago: 1))
        .evidence.activity == .turnComplete)
    return failures
  }

  /// A session has to be seen twice before it is shown.
  static func runSightingChecks() -> Int {
    func s(_ id: String) -> SessionInfo {
      SessionInfo(
        id: id, tool: .claude, projectPath: "/tmp/\(id)", workingDirectory: "/tmp/\(id)",
        project: id, evidence: Evidence(.turnInFlight, at: Date(), source: .reported),
        state: .running)
    }
    var failures = 0
    func check(_ name: String, _ passed: Bool) {
      failures += Self.report(name, passed)
    }

    check(
      "the first scan of a launch shows everything",
      SessionMonitor.withholdingFirstSightings([s("a"), s("b")], seenBefore: nil).count == 2)
    check(
      "a session appearing for the first time is held back",
      SessionMonitor.withholdingFirstSightings([s("a"), s("new")], seenBefore: ["a"])
        .map(\.id) == ["a"])
    check(
      "and shown once it is seen again",
      SessionMonitor.withholdingFirstSightings([s("a"), s("new")], seenBefore: ["a", "new"])
        .map(\.id) == ["a", "new"])
    return failures
  }

  /// Which evidence can leave something unread.
  ///
  /// `/clear` and `/compact` both report `SessionStart`, and a session that has
  /// only been opened went straight to idle-and-unread: a blue card, newest on
  /// screen so ahead of every genuinely unread session, for a session the user
  /// was sitting in front of when they typed the command.
  static func runUnreadChecks() -> Int {
    var failures = 0
    func check(_ name: String, _ passed: Bool) {
      failures += Self.report(name, passed)
    }
    func evidence(_ activity: Activity, _ source: EvidenceSource = .reported) -> Evidence {
      Evidence(activity, at: Date(), source: source)
    }

    check(
      "a session that has only been opened has nothing to be behind on",
      !evidence(.opened).mayLeaveSomethingUnread)
    check(
      "a finished turn does",
      evidence(.turnComplete).mayLeaveSomethingUnread)
    check(
      // OpenCode's store gives a timestamp and nothing else. It may or may not
      // have left something; ADR-0018 says hiding finished work is the worse
      // error, so the ambiguous case counts.
      "a store that says only that something changed still counts",
      evidence(.unknown, .inferred).mayLeaveSomethingUnread)
    check(
      "so does a turn that stalled and aged out",
      evidence(.turnInFlight, .inferred).mayLeaveSomethingUnread)
    return failures
  }

  /// A visit is forgotten by age, never because a scan missed its session.
  ///
  /// ADR-0021 guarantees a returning session is absent for at least one scan,
  /// so pruning on absence marked every one of them unread again — and jumping
  /// is the only thing that clears that (ADR-0018).
  static func runVisitChecks() -> Int {
    let now = Date()
    var failures = 0
    func check(_ name: String, _ passed: Bool) {
      failures += Self.report(name, passed)
    }

    // The session these belong to is deliberately not passed — the function
    // takes no session list, which is what makes pruning on absence
    // unexpressible rather than merely avoided.
    let visits = [
      "claude:gone-from-this-scan": now.addingTimeInterval(-60),
      "claude:read-last-week": now.addingTimeInterval(-8 * 24 * 60 * 60),
    ]
    let kept = SessionMonitor.retainedVisits(visits, now: now)

    check("a visit survives the session vanishing from a scan",
          kept["claude:gone-from-this-scan"] != nil)
    check("a visit is forgotten once it is older than the window",
          kept["claude:read-last-week"] == nil)
    return failures
  }

  /// Directories that cannot title a card.
  static func runDirectoryChecks() -> Int {
    let home = "/Users/someone"
    let cases: [(String, String, Bool)] = [
      ("a project directory names one", "/Users/someone/Repos/thing", false),
      ("the home folder does not", home, true),
      ("nor does the root", "/", true),
      ("nor does nothing at all", "", true),
      ("a directory inside home still does", "/Users/someone/Repos", false),
    ]
    var failures = 0
    for (name, path, expected) in cases {
      counted()
      if SessionScanner.namesNoProject(path, home: home) == expected {
        print("  ✓ \(name)")
      } else {
        failures += 1
        print("  ✗ \(name)")
      }
    }
    return failures
  }

  /// A permission prompt is only still a prompt until something starts running.
  static func runGrantChecks() -> Int {
    let now = Date()
    let prompt = Evidence(
      .blockedOnUser, at: now.addingTimeInterval(-60), source: .reported, liveness: .alive)
    var failures = 0
    func check(_ name: String, _ passed: Bool) {
      failures += Self.report(name, passed)
    }

    check(
      "a prompt with nothing running is still a prompt",
      prompt.resolvingGrant(newestChildStart: nil).activity == .blockedOnUser)
    check(
      "an MCP server started before the prompt proves nothing",
      prompt.resolvingGrant(newestChildStart: now.addingTimeInterval(-600))
        .activity == .blockedOnUser)
    check(
      "work started after the prompt means it was answered",
      prompt.resolvingGrant(newestChildStart: now.addingTimeInterval(-10))
        .activity == .turnInFlight)
    check(
      "a running turn is left alone",
      Evidence(.turnInFlight, at: now, source: .reported)
        .resolvingGrant(newestChildStart: now).activity == .turnInFlight)

    // The rule this whole mechanism must not overreach into. A child process
    // dates a *permission answer*; nothing local clears a quota, so an MCP
    // server restarting must not flip a stalled card back to `running` — and
    // because the retraction also rewrites `at`, it would reset the elapsed
    // time with it (ADR-0024).
    //
    // Belt and braces: the guard reads `== .blockedOnUser`, so a distinct
    // activity makes this unwritable rather than merely wrong. The assertion is
    // here because that guard is one word away from being "any block".
    let limited = Evidence(
      .blockedOnLimit, at: now.addingTimeInterval(-60), source: .reported, liveness: .alive)
    check(
      "work starting after a usage limit does not clear it",
      limited.resolvingGrant(newestChildStart: now).activity == .blockedOnLimit)
    check(
      "and its elapsed time is not rewritten either",
      limited.resolvingGrant(newestChildStart: now).at == limited.at)
    return failures
  }

  /// Runs the tables. Returns the number of failures.
  static func run() -> Int {
    let now = Date()
    var failures = 0

    for testCase in cases {
      counted()
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
      counted()
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
      counted()
      let actual = ClaudeSource.activity(TranscriptReader.parseClaudeTail(line))
      if actual == expected {
        print("  ✓ \(name)")
      } else {
        failures += 1
        print("  ✗ \(name) → expected \(expected.rawValue), got \(actual.rawValue)")
      }
    }

    for (name, line, expected) in codexCases {
      counted()
      let actual = CodexSource.activity(TranscriptReader.parseCodexTail(line))
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
