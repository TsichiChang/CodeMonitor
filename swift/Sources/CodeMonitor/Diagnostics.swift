/// Command-line diagnostics, sharing the exact code paths the GUI uses.
///
/// Useful when a session isn't detected or a terminal jump lands in the wrong
/// place — it shows what the scanner sees and what the focus logic decides,
/// without having to click through the UI.
///
///     CodeMonitor --diagnose            list sessions + how each would be focused
///     CodeMonitor --focus <text>        actually jump to the matching session

import AppKit
import Foundation

enum Diagnostics {
  static let usage = """
    Code Monitor — session diagnostics

      --diagnose          List detected sessions and their resolved terminal host.
      --focus <text>      Jump to the session whose project or cwd contains <text>.
      --focus-next        Jump to whatever most deserves attention — what the
                          global shortcut does. Add --dry-run to only show the order.
      --dismiss <text>    Hide an idle session until it does something new.
      --restore           Un-hide everything hidden.
      --hooks             Show whether the reporting hook is installed per tool.
      --install-hooks     Install it (backs up each config first).
      --uninstall-hooks   Remove it, leaving other integrations untouched.
      --selftest          Check the evidence-to-state derivation table.
      --help              Show this message.

    With no arguments the app launches normally.
    """

  private static let flags: Set<String> = [
    "--diagnose", "--focus", "--focus-next", "--dismiss", "--restore", "--selftest",
    "--hooks", "--install-hooks", "--uninstall-hooks", "--help", "-h",
  ]

  /// Whether these arguments select a CLI command rather than the GUI.
  static func handles(_ arguments: [String]) -> Bool {
    arguments.count > 1 && flags.contains(arguments[1])
  }

  /// Runs the async diagnostics from synchronous top-level code.
  ///
  /// The run loop is pumped while waiting so main-actor work still gets
  /// scheduled — a bare semaphore wait would block the main thread and
  /// deadlock the moment the diagnostics touch AppKit.
  static func runBlocking(arguments: [String]) {
    let finished = DispatchSemaphore(value: 0)
    Task { @MainActor in
      await run(arguments: arguments)
      finished.signal()
    }
    while finished.wait(timeout: .now() + 0.01) == .timedOut {
      RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }
  }

  static func run(arguments: [String]) async {
    switch arguments[1] {
    case "--diagnose":
      await diagnose()
    case "--focus":
      guard arguments.count > 2 else {
        print("error: --focus needs a search string\n\n\(usage)")
        exit(2)
      }
      await focus(matching: arguments[2])
    case "--focus-next":
      await focusNext(dryRun: arguments.contains("--dry-run"))
    case "--dismiss":
      guard arguments.count > 2 else {
        print("error: --dismiss needs a search string\n\n\(usage)")
        exit(2)
      }
      await dismiss(matching: arguments[2])
    case "--restore":
      await restore()
    case "--hooks":
      reportHooks()
    case "--install-hooks":
      changeHooks(installing: true)
    case "--uninstall-hooks":
      changeHooks(installing: false)
    case "--selftest":
      print("Evidence derivation")
      // Counted by the checks themselves rather than added up here. The total
      // used to be a sum of literals — `+ 5 + 9 + 5 + 4 + …`, one per check
      // function — which is the same fact written in two places, and it went
      // stale the moment an assertion was added without anyone editing the
      // arithmetic. Nothing to keep in step now.
      let failures = EvidenceChecks.run() + EvidenceChecks.runOrderingChecks()
        + EvidenceChecks.runProcessChecks() + EvidenceChecks.runHostChecks()
        + EvidenceChecks.runGrantChecks() + EvidenceChecks.runDirectoryChecks()
        + EvidenceChecks.runHookMergeChecks() + EvidenceChecks.runSightingChecks()
        + EvidenceChecks.runVisitChecks() + EvidenceChecks.runUnreadChecks()
        + EvidenceChecks.runUsageChecks()
        + Metrics.runChecks()
      print(
        failures == 0
          ? "\nall \(EvidenceChecks.ran) checks pass" : "\n\(failures) of \(EvidenceChecks.ran) FAILED")
      exit(failures == 0 ? 0 : 1)
    default:
      print(usage)
    }
  }

  @MainActor
  private static func dismiss(matching needle: String) async {
    let monitor = SessionMonitor()
    defer { monitor.stop() }
    await monitor.refresh()

    guard let session = match(needle, in: monitor.snapshot) else { exit(1) }
    guard session.state == .idle else {
      print("\"\(session.project)\" is \(session.state.rawValue), not idle — only idle sessions can be hidden.")
      exit(1)
    }
    monitor.dismiss(session)
    print("Hidden \"\(session.project)\" (\(session.id)) until it does something new.")
  }

  /// What the global shortcut does, and — with `--dry-run` — the order it works
  /// through. The keypress and this command read the same ordering, so what a
  /// key does can be checked without pressing it.
  @MainActor
  private static func focusNext(dryRun: Bool) async {
    let monitor = SessionMonitor()
    defer { monitor.stop() }
    await monitor.refresh()

    let ordered = monitor.snapshot.byAttention
    guard let first = ordered.first else {
      print("Nothing to jump to.")
      exit(1)
    }

    if dryRun {
      print("Order the shortcut works through:")
      for (index, session) in ordered.enumerated() {
        let waited = SessionCardView.relativeTime(session.lastActivity)
        print("  \(index + 1). \(session.project)  \(session.state.rawValue)  \(waited)")
      }
      return
    }

    print("→ \(first.project) (\(first.state.rawValue))")
    await monitor.focusNext()
  }

  private static func reportHooks() {
    for target in HookInstaller.targets {
      let state: String
      switch HookInstaller.status(of: target) {
      case .installed: state = "installed"
      case .missing: state = "not installed"
      case let .partial(present, expected): state = "partial — \(present) of \(expected) events"
      }
      print("\(target.tool.label.padding(toLength: 12, withPad: " ", startingAt: 0)) \(state)")
      print("    \(target.config.path)")
    }
  }

  private static func changeHooks(installing: Bool) {
    for target in HookInstaller.targets {
      do {
        let backup = try installing
          ? HookInstaller.install(target) : HookInstaller.uninstall(target)
        print("\(installing ? "Installed" : "Removed") for \(target.tool.label)")
        if let backup { print("    backup: \(backup.lastPathComponent)") }
      } catch {
        print("\(target.tool.label): \(error.localizedDescription)")
      }
    }
  }

  @MainActor
  private static func restore() async {
    let monitor = SessionMonitor()
    defer { monitor.stop() }
    let count = monitor.dismissedCount
    monitor.restoreAllDismissed()
    print(count == 0 ? "Nothing was hidden." : "Restored \(count) hidden session(s).")
  }

  /// Resolves a search string to exactly one session, or to none.
  ///
  /// An ambiguous string is refused rather than resolved. Taking the first of
  /// several matches printed a note and carried on, which meant `--focus`
  /// jumped to a session the user had not named — and, once jumping also marked
  /// a session read, quietly cleared the unread mark on a different one. A
  /// command with side effects has no business guessing which session it was
  /// pointed at.
  private static func match(_ needle: String, in snapshot: SessionSnapshot) -> SessionInfo? {
    // A full id is unambiguous by construction, and is what `--focus-next` and
    // any script would pass.
    if let exact = snapshot.sessions.first(where: { $0.id == needle }) { return exact }

    let lowered = needle.lowercased()
    let matches = snapshot.sessions.filter {
      $0.project.lowercased().contains(lowered)
        || $0.projectPath.lowercased().contains(lowered)
    }

    switch matches.count {
    case 0:
      print("No session matching \"\(needle)\".")
      print("Known: \(snapshot.sessions.map(\.project).joined(separator: ", "))")
      return nil
    case 1:
      return matches[0]
    default:
      print("\"\(needle)\" matches \(matches.count) sessions — name one exactly:")
      for session in matches {
        print("  \(session.id)   \(session.project)  (\(session.state.rawValue))")
      }
      return nil
    }
  }

  // MARK: - Commands

  @MainActor
  private static func diagnose() async {
    // Through the monitor, not the scanner: the monitor is what the dashboard
    // shows, and it hides sessions the user has closed. Reporting the raw scan
    // would answer a question nobody asked.
    let monitor = SessionMonitor()
    defer { monitor.stop() }
    await monitor.refresh()
    let snapshot = monitor.snapshot
    if monitor.dismissedCount > 0 {
      print("(\(monitor.dismissedCount) session(s) hidden by the user)")
    }

    print("Scanned at \(snapshot.generatedAt.formatted(date: .omitted, time: .standard))")
    print("Process scan: \(snapshot.processScanOk ? "ok" : "FAILED — sessions will look stale")")
    print(
      "Sessions: \(snapshot.sessions.count)  "
        + "(\(snapshot.counts.running) running, \(snapshot.counts.waiting) waiting, "
        + "\(snapshot.counts.idle) idle)\n"
    )

    if snapshot.sessions.isEmpty {
      print("No sessions detected.\n")
    }

    for session in snapshot.sessions {
      let origin = session.evidence.source.rawValue
      // Unread decides a card's colour, which band it sorts into and whether the
      // shortcut stops there, and it was the one derived value this could not
      // show — so a session wrongly marked unread had to be diagnosed by
      // reading the source rather than by looking.
      let unread = session.isUnread ? " · unread" : ""
      print(
        "• \(session.project)  [\(session.tool.rawValue)]  "
          + "\(session.state.rawValue)\(unread) (\(origin))")
      print("    evidence: \(session.evidence.activity.rawValue), liveness \(session.evidence.liveness.rawValue)")
      if session.subagentCount > 0 { print("    sub-agents: \(session.subagentCount) running") }
      if let tab = session.tabID { print("    tab:   \(tab)") }
      if let pane = session.paneID { print("    pane:  \(pane)") }
      print("    id:    \(session.id)")
      print("    project: \(session.projectPath)")
      if session.workingDirectory != session.projectPath {
        print("    now in:  \(session.workingDirectory)   ← moved")
      }
      print("    pid:   \(session.pid.map(String.init) ?? "—")   tty: \(session.tty ?? "—")")
      if let branch = session.gitBranch { print("    branch: \(branch)") }
      if let message = session.lastMessage { print("    last:  \(message)") }

      if let pid = session.pid {
        let host = await hostDescription(pid: pid)
        print("    host:  \(host)")
      } else {
        print("    host:  — (no live process; focus would re-scan first)")
      }
      print("")
    }

    reportUsage(snapshot, now: snapshot.generatedAt)
    reportSources(now: snapshot.generatedAt)
  }

  /// What each tool's own store holds, before any filtering.
  ///
  /// A session missing from the list above is either absent from its tool's
  /// store or aged out of the active window, and those need different fixes —
  /// this separates them.
  /// Quota windows per tool, and which channel each came from.
  ///
  /// Worth printing separately from the sessions because the failure modes are
  /// different and both are silent: a Claude reading needs a line in the user's
  /// own status-line script, and a Codex one needs a rollout recent enough to
  /// still hold a `token_count` event in its tail (ADR-0023).
  private static func reportUsage(_ snapshot: SessionSnapshot, now: Date) {
    print("── Usage ──")
    if snapshot.usage.isEmpty {
      print("No tool reported a quota window.")
      print("  Claude reads \(UsageStore.claudeFile.path)")
      print("  — written by your own statusline script; see --hooks")
      print("")
      return
    }
    let columns = ToolUsage.columns(across: snapshot.usage)
    for reading in snapshot.usage.sorted(by: { $0.tool.rawValue < $1.tool.rawValue }) {
      let age = RelativeSpan.since(reading.observedAt, now: now)
      print("\(reading.tool.label)  (read \(age) ago)")
      for minutes in columns {
        let value = reading.reading(forMinutes: minutes, now: now)
        let window = usageWindowLabel(minutes: minutes)
        let clears = value.resetsInText.map { "  resets in \($0)" } ?? ""
        let note =
          switch value {
          case .spent: ""
          case .unlimited: "   ← not one of this tool's limits"
          case .unheard: "   ← window rolled over; nothing measured since"
          }
        print("    \(window.padding(toLength: 4, withPad: " ", startingAt: 0)) \(value.text)\(clears)\(note)")
      }
    }
    print("")
  }

  private static func reportSources(now: Date) {
    print("── Sources ──")

    for source in [ClaudeSource(), CodexSource(), OpenCodeSource()] as [any SessionSource] {
      let found = source.sessions(now: now)
      print("\(source.tool.rawValue): \(found.count) session(s)")
      for session in found.prefix(4) {
        let age = Int(now.timeIntervalSince(session.lastActivity) / 60)
        print("    \(session.project)  \(session.state.rawValue)  \(age)m  \(session.id)")
      }
    }
    print("")

    let rows = OpenCodeStore.sessions()
    if !FileManager.default.fileExists(atPath: OpenCodeStore.databaseURL.path) {
      print("OpenCode: no database at \(OpenCodeStore.databaseURL.path)")
    } else {
      print("OpenCode: \(rows.count) session(s) in store")
      for row in rows.prefix(5) {
        let age = now.timeIntervalSince(row.updated) / 60
        let shown = age <= 30 ? "listed" : "aged out"
        print("    \(row.directory ?? "—")  \(Int(age))m ago  (\(shown))")
        if let title = row.title { print("        \(title)") }
      }
    }
  }

  /// Goes through `SessionMonitor`, i.e. the exact path a card tap in the UI
  /// takes — including the pid re-scan for sessions the snapshot had no
  /// process for.
  @MainActor
  private static func focus(matching needle: String) async {
    let monitor = SessionMonitor()
    defer { monitor.stop() }
    await monitor.refresh()

    // Through `match`, which refuses an ambiguous string instead of taking the
    // first of several. That refusal was written for this command and then not
    // wired into it: jumping is not read-only — it marks the session read, and
    // ADR-0018 leaves nothing to undo that with but the session speaking again.
    guard let session = match(needle, in: monitor.snapshot) else { exit(1) }

    print("Focusing \"\(session.project)\" (\(session.projectPath))")
    print("  id:    \(session.id)")
    print("  route: \(route(for: session))")
    if let pid = session.pid {
      print("  host:  \(await hostDescription(pid: pid))")
    }

    let result = await monitor.focus(session)

    switch result {
    case .ok:
      print("  → ok")
    default:
      print("  → FAILED: \(result.message ?? String(describing: result))")
      exit(1)
    }
  }

  // MARK: - Helpers

  /// Which strategy the jump will actually try first, as opposed to what the
  /// host is capable of.
  private static func route(for session: SessionInfo) -> String {
    if let pane = session.paneID { return "recorded pane \(pane) (falls back if it no longer matches)" }
    if let tab = session.tabID { return "recorded tab \(tab) (falls back if it no longer matches)" }
    return "directory matching — no location recorded"
  }

  /// Describes how the focus logic identifies this session's terminal.
  private static func hostDescription(pid: Int32) async -> String {
    let termProgram = ProcessScanner.environmentValue("TERM_PROGRAM", of: pid)
    let matched = TerminalFocus.terminals.first {
      guard let expected = $0.termProgram, let actual = termProgram else { return false }
      return expected.caseInsensitiveCompare(actual) == .orderedSame
    }

    guard let matched else {
      // Not a terminal at all: an editor or desktop app launched this agent.
      if let bundleID = ProcessScanner.environmentValue("__CFBundleIdentifier", of: pid) {
        return "\(bundleID) (not a terminal) → activate that app"
      }
      return "unidentified (no TERM_PROGRAM, no launching app) — would probe terminals by tty"
    }
    let strategy =
      switch matched.kind {
      case .otty: "otty-cli (see route above)"
      case .terminal, .iterm: "AppleScript, matched by tty"
      case .generic: "activate only (no tab selection)"
      }
    return "\(matched.appName) via TERM_PROGRAM=\(termProgram ?? "?") → \(strategy)"
  }
}
