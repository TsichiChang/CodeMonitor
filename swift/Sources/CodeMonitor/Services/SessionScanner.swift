/// Collects sessions from every tool and merges them into one snapshot.
///
/// Reading each tool's store is the sources' job (ADR-0004); this type decides
/// what the set of them adds up to. It gathers evidence — what each source saw,
/// what any hook reported, whether a process is alive — and derives state from
/// it exactly once, at the end (ADR-0012).
///
/// Being an `actor` both protects the sources' caches and serialises scans, so
/// a slow cycle can never overlap the next.

import Foundation

actor SessionScanner {
  private let sources: [any SessionSource] = [
    ClaudeSource(), CodexSource(), OpenCodeSource(),
  ]

  func scan() async -> SessionSnapshot {
    let now = Date()
    let (processes, scanOK) = ProcessScanner.scan()

    var sessions = sources.flatMap { $0.sessions(now: now) }
    applyReports(to: &sessions)
    applyLiveness(processes, scanSucceeded: scanOK, to: &sessions)
    sessions = sessions.filter { $0.evidence.isCurrent(now: now) }
    sessions += unmatchedProcesses(processes, sessions: sessions, scanSucceeded: scanOK)
    sessions = foldDelegated(sessions)

    // A prompt that has since been answered. Checked only for sessions actually
    // showing as blocked — one `proc_listchildpids` each, and there is rarely
    // more than one (ADR-0019).
    for index in sessions.indices where sessions[index].evidence.activity == .blockedOnUser {
      guard let pid = sessions[index].pid else { continue }
      sessions[index].evidence = sessions[index].evidence.resolvingGrant(
        newestChildStart: ProcessScanner.newestChildStart(of: pid))
    }

    // The single derivation. Nothing above this line decides a state, and
    // nothing below it changes evidence.
    for index in sessions.indices {
      sessions[index].state = sessions[index].evidence.state(now: now)
    }

    sessions.sort(by: SessionInfo.inAttentionOrder)

    return SessionSnapshot(
      sessions: sessions,
      generatedAt: now,
      processScanOk: scanOK,
      // Two small file reads, and neither is on the poll's critical path: one is
      // a 1.3 KB snapshot, the other a 64 KB tail that is already being read for
      // the newest rollout's session state.
      usage: UsageStore.readings(now: now)
    )
  }

  /// Directories that name no project, so a session known only by one has
  /// nothing worth showing.
  ///
  /// The home folder is where an agent waits before a project is chosen — a
  /// desktop app opens there, and restoring several sessions produces several
  /// cards all titled with the user's own account name. That names no project
  /// and costs a row on a display where rows are contested (ADR-0006, ADR-0016).
  ///
  /// Shared by the two places that mint a session from a directory alone. The
  /// first of them was fixed on its own, and the second went on producing the
  /// same phantom — which is the argument for this being one function rather
  /// than two conditions.
  static func namesNoProject(_ path: String, home: String) -> Bool {
    path.isEmpty || path == "/" || path == home
  }

  // MARK: - Reported evidence

  /// How far behind a hook's timestamp may be and still count as current.
  ///
  /// The hook script stamps whole seconds (`date +%s`) while a transcript's
  /// mtime is sub-second, so a hook that fired *after* a write can still read
  /// as up to a second earlier. Without this slack the ordinary case — a tool
  /// call writing to the transcript and firing `PostToolUse` — would flip a
  /// coin between the two sources.
  private static let hookClockSlack: TimeInterval = 2

  /// Folds one hook's report into the session it belongs to.
  ///
  /// Pure and separate from the loop below so the rule can be asserted
  /// directly. Two defects have landed in it, both about which source wins and
  /// what survives the merge, and neither was reachable from a check table
  /// while this was five lines in the middle of a scan.
  ///
  /// **Precedence.** The hook wins unless the transcript is both later *and*
  /// saying something.
  ///
  /// A hook fires on events no transcript write follows, so it is usually the
  /// fresher of the two. But not always, and that exception was a defect:
  /// pressing Esc writes `[Request interrupted by user]` into the transcript
  /// and fires no hook at all — not even `StopFailure`. The hook's last word
  /// stays `PreToolUse`, and a *reported* turnInFlight never decays, so an
  /// interrupted session claimed to be running for as long as its process
  /// lived. Taking the hook's activity while taking the transcript's newer
  /// timestamp was the worst of both: it dated a stale event to the moment of a
  /// write that contradicted it.
  ///
  /// "Saying something" is the other half, and going without it was its own
  /// defect. A transcript is also written by things that are not turns at all —
  /// a slash command, `! nvim`, an injected reminder — and those read as
  /// `unknown`. Letting a later `unknown` displace a hook's `Stop` threw away
  /// the one source that actually knew the turn had ended.
  ///
  /// **What is taken regardless.** Terminal context and the pid are facts the
  /// hook observed from inside the session, not claims about what it is doing,
  /// so losing the precedence contest does not cost them.
  nonisolated static func applying(_ hook: HookState, to session: SessionInfo) -> SessionInfo {
    var merged = session

    let inferred = session.evidence
    let transcriptIsLater =
      inferred.activity != .unknown
      && inferred.at > hook.updated.addingTimeInterval(hookClockSlack)
    if !transcriptIsLater {
      merged.evidence = Evidence(
        hook.activity, at: max(inferred.at, hook.updated), source: .reported)
    }

    // The hook names its own pid, which is the one thing no amount of scanning
    // can establish (ADR-0003). Taking it is what exempts a reported session
    // from the directory competition in `applyLiveness` — ADR-0005's amendment
    // rests on that exemption, and this line going missing is what took it
    // away: a blocked session sharing a directory with an active one lost the
    // match it never had to enter, aged out at five minutes, and took the
    // ambient band down with it.
    if let pid = hook.pid { merged.pid = pid }
    merged.tabID = hook.tabID
    merged.paneID = hook.paneID
    if let tty = hook.tty { merged.tty = tty }
    return merged
  }

  /// Replaces inferred evidence with what a tool said about itself (ADR-0010).
  ///
  /// A hook also knows things no amount of scanning can recover: the pane its
  /// session lives in, and its pid without a directory guess.
  private func applyReports(to sessions: inout [SessionInfo]) {
    let reported = HookStateStore.states()
    guard !reported.isEmpty else { return }

    var unclaimed = reported
    for index in sessions.indices {
      guard let hook = unclaimed.removeValue(forKey: sessions[index].id) else { continue }
      sessions[index] = Self.applying(hook, to: sessions[index])
    }

    // A report with no matching session is still a session. Its store may be
    // older than a source is willing to read — an agent left open for days,
    // quiet until it hits a permission prompt — and that is exactly the case
    // where the report carries more than the transcript would.
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    for hook in unclaimed.values where !Self.namesNoProject(hook.cwd, home: home) {
      sessions.append(
        SessionInfo(
          id: hook.sessionKey,
          tool: hook.tool,
          pid: hook.pid,
          tty: hook.tty,
          projectPath: hook.cwd,
          workingDirectory: hook.cwd,
          project: URL(fileURLWithPath: hook.cwd).lastPathComponent,
          evidence: Evidence(hook.activity, at: hook.updated, source: .reported),
          state: .idle,
          tabID: hook.tabID,
          paneID: hook.paneID
        )
      )
    }
  }

  // MARK: - Liveness

  /// Records whether a process backs each session.
  ///
  /// Matching is on the Project, not the working directory. An agent process
  /// keeps the directory it was launched in — it does not follow the session
  /// when the session moves — so its cwd is the Project even for a session
  /// whose transcript now reports somewhere else.
  ///
  /// A process is never proof of *which* session it is (ADR-0002), so this is
  /// a decoration and a lifetime signal, never an identity.
  private func applyLiveness(
    _ processes: [LiveProcess], scanSucceeded: Bool, to sessions: inout [SessionInfo]
  ) {
    guard scanSucceeded else {
      // Nothing was observed, which is not the same as observing nothing.
      for index in sessions.indices { sessions[index].evidence.liveness = .unknown }
      return
    }
    // Absent is a claim, and it is only earned where a process could have been
    // found. A session hosted by a desktop app has none to find: that app's
    // processes sit at `/` and belong to the app, not to any one session, so a
    // scan that finds nothing has observed nothing about it. `unknown` is the
    // honest reading, and it is what keeps such a session listed instead of
    // expiring five minutes into a long turn (ADR-0012, ADR-0017).
    for index in sessions.indices {
      sessions[index].evidence.liveness =
        sessions[index].hostBundleID == nil ? .absent : .unknown
    }

    // A pid a hook named is checked directly — no guessing needed, and no other
    // session may then claim it.
    var spokenFor = Set<Int32>()
    for index in sessions.indices {
      guard sessions[index].evidence.source == .reported,
        let pid = sessions[index].pid, ProcessScanner.isRunning(pid)
      else { continue }
      sessions[index].evidence.liveness = .alive
      spokenFor.insert(pid)
    }

    var byDirectory: [ToolKind: [String: LiveProcess]] = [:]
    for process in processes where !spokenFor.contains(process.pid) {
      guard let cwd = process.cwd else { continue }
      byDirectory[process.tool, default: [:]][cwd] = process
    }

    // One process backs at most one session. A directory often holds several
    // transcripts — one project here had three — and giving the process to all
    // of them would keep every past session in that directory on screen for as
    // long as any agent ran there. The most recently active one is the best
    // available guess.
    var bestIndex: [String: Int] = [:]
    for index in sessions.indices where sessions[index].evidence.liveness != .alive {
      let session = sessions[index]
      guard byDirectory[session.tool]?[session.projectPath] != nil else { continue }
      let key = "\(session.tool.rawValue):\(session.projectPath)"
      if let current = bestIndex[key],
        sessions[current].lastActivity >= session.lastActivity
      {
        continue
      }
      bestIndex[key] = index
    }

    for index in bestIndex.values {
      guard let match = byDirectory[sessions[index].tool]?[sessions[index].projectPath] else {
        continue
      }
      sessions[index].pid = match.pid
      sessions[index].tty = match.tty
      sessions[index].evidence.liveness = .alive
    }
  }

  // MARK: - Processes with no session

  /// Live processes no session accounts for — an agent that has started but not
  /// yet written its first record.
  ///
  /// Coverage is per tool *and directory*, not per process: one session spawns
  /// several processes (helpers, MCP servers), and keying on pid would give
  /// each of them its own card. Processes sharing a directory are likewise
  /// collapsed, since nothing here can tell whether they are one session or
  /// several — and claiming several would be the worse guess.
  private func unmatchedProcesses(
    _ processes: [LiveProcess], sessions: [SessionInfo], scanSucceeded: Bool
  ) -> [SessionInfo] {
    guard scanSucceeded else { return [] }
    let covered = Set(sessions.map { "\($0.tool.rawValue):\($0.projectPath)" })
    var emitted = Set<String>()

    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return processes.compactMap { process -> SessionInfo? in
      guard let cwd = process.cwd, !Self.namesNoProject(cwd, home: home) else { return nil }
      let key = "\(process.tool.rawValue):\(cwd)"
      guard !covered.contains(key), emitted.insert(key).inserted else { return nil }

      return SessionInfo(
        id: "\(process.tool.rawValue):pid-\(process.pid)",
        tool: process.tool,
        pid: process.pid,
        tty: process.tty,
        projectPath: cwd,
        workingDirectory: cwd,
        project: URL(fileURLWithPath: cwd).lastPathComponent,
        // An agent is here and nothing says what it is doing. `unknown` is the
        // whole of what is known; the process's start time is the only honest
        // timestamp, and claiming activity instead once pinned the app at full
        // poll rate for as long as the process lived.
        evidence: Evidence(
          .unknown, at: process.started, source: .inferred, liveness: .alive),
        state: .idle
      )
    }
  }

  // MARK: - Sub-agents

  /// Replaces delegated agents with a count on the session they belong to.
  ///
  /// A program that farms work out to sub-agents produces one transcript per
  /// agent, and each of those looks exactly like a session: 26 of them appeared
  /// under one project here against 9 sessions actually opened by hand. Listing
  /// them individually buries the sessions a person is actually sitting in
  /// front of, which is the one thing this display must not do (ADR-0007).
  ///
  /// They are attributed by project directory. Nothing in a transcript names
  /// the session that spawned it, and the directory is the only thing they
  /// demonstrably share.
  private func foldDelegated(_ sessions: [SessionInfo]) -> [SessionInfo] {
    Self.folding(
      sessions,
      showDelegated: UserDefaults.standard.bool(forKey: "showDelegatedSessions"))
  }

  /// The rule, with the setting passed in rather than read.
  ///
  /// Split out so `--selftest` can assert on it: the behaviour worth pinning is
  /// which sessions survive, and reaching that through `UserDefaults` would make
  /// the assertion depend on the machine it runs on. Same reason
  /// `retainedVisits` and `applying(_:to:)` are shaped this way.
  nonisolated static func folding(
    _ sessions: [SessionInfo], showDelegated: Bool
  ) -> [SessionInfo] {
    guard !showDelegated else { return sessions }
    let delegated = sessions.filter(\.isDelegated)
    guard !delegated.isEmpty else { return sessions }

    var workingByProject: [String: Int] = [:]
    for agent in delegated where agent.evidence.activity == .turnInFlight {
      workingByProject[agent.projectPath, default: 0] += 1
    }

    var kept = sessions.filter { !$0.isDelegated }
    for index in kept.indices {
      kept[index].subagentCount = workingByProject[kept[index].projectPath] ?? 0
    }

    // A batch *currently working* with no session of its own to hang off still
    // deserves to be visible: its parent may have aged out, or may be an
    // orchestrator this machine never saw.
    //
    // Not "otherwise the work would vanish", which is what this said and was
    // wrong — it iterates `workingByProject`, so a batch whose agents have all
    // finished is never adopted and does vanish. That is correct (a finished
    // sub-agent leaves nothing to act on; the display is not a log), but it is
    // not what the sentence claimed (ADR-0026).
    let adopted = Set(kept.map(\.projectPath))
    for (project, count) in workingByProject where !adopted.contains(project) {
      guard var orphan = delegated.first(where: { $0.projectPath == project }) else { continue }
      orphan.subagentCount = count
      orphan.isDelegated = false
      kept.append(orphan)
    }
    return kept
  }
}
