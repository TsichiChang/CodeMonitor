/// Collects sessions from every tool and merges them into one snapshot.
///
/// Reading each tool's store is the sources' job (ADR-0004); this type decides
/// what the set of them adds up to — attaching live processes, ordering by
/// urgency, and counting.
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
    attachLiveProcesses(processes, to: &sessions)
    sessions = sessions.filter { stillCurrent($0, now: now) }
    sessions += unmatchedProcesses(processes, sessions: sessions, now: now)

    sessions.sort { lhs, rhs in
      lhs.state.order != rhs.state.order
        ? lhs.state.order < rhs.state.order
        : lhs.lastActivity > rhs.lastActivity
    }

    var counts = StateCounts()
    for session in sessions { counts[session.state] += 1 }

    return SessionSnapshot(
      sessions: sessions,
      counts: counts,
      generatedAt: now,
      processScanOk: scanOK
    )
  }

  /// Whether a session still belongs on screen (ADR-0005).
  ///
  /// A live process overrides the clock entirely: a store can be quiet for
  /// hours while its agent sits there perfectly alive, and dropping such a
  /// session would replace a card carrying its branch, model and last action
  /// with nothing at all.
  private func stillCurrent(_ session: SessionInfo, now: Date) -> Bool {
    if session.live { return true }
    return now.timeIntervalSince(session.lastActivity) <= Aging.window(for: session.state)
  }

  /// Attaches a live process to each session it plausibly belongs to.
  ///
  /// Matching is on the Project, not the working directory. An agent process
  /// keeps the directory it was launched in — it does not follow the session
  /// when the session moves — so its cwd is the Project even for a session
  /// whose transcript now reports somewhere else.
  ///
  /// A process is never proof of *which* session it is (ADR-0002) — several
  /// sessions can share a directory — so this is a decoration, not an identity.
  private func attachLiveProcesses(_ processes: [LiveProcess], to sessions: inout [SessionInfo]) {
    var remaining = processes
    var claimed = Set<Int>()

    // A process resumed with an explicit session id needs no guessing at all.
    var indexByID: [String: Int] = [:]
    for (index, session) in sessions.enumerated() { indexByID[session.id] = index }

    remaining.removeAll { process in
      guard let sessionID = process.sessionID,
        let index = indexByID["\(process.tool.rawValue):\(sessionID)"]
      else { return false }
      sessions[index].pid = process.pid
      sessions[index].tty = process.tty
      sessions[index].live = true
      claimed.insert(index)
      return true
    }

    var byDirectory: [ToolKind: [String: LiveProcess]] = [:]
    for process in remaining {
      guard let cwd = process.cwd else { continue }
      byDirectory[process.tool, default: [:]][cwd] = process
    }

    // One process backs at most one session. A directory often holds several
    // transcripts — one project here had three — and attaching the process to
    // all of them would both claim a pid that is not theirs and, because a live
    // session never ages out, keep every past session in that directory on
    // screen forever. The most recently active one is the best available guess.
    var bestIndex: [String: Int] = [:]
    for index in sessions.indices where !claimed.contains(index) {
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
      sessions[index].live = true
    }
  }

  /// Live processes no session accounts for — an agent that has started but not
  /// yet written its first record.
  ///
  /// Coverage is per tool *and directory*, not per process: one session spawns
  /// several processes (helpers, MCP servers), and keying on pid would give
  /// each of them its own card. Processes sharing a directory are likewise
  /// collapsed, since nothing here can tell whether they are one session or
  /// several — and claiming several would be the worse guess.
  private func unmatchedProcesses(
    _ processes: [LiveProcess], sessions: [SessionInfo], now: Date
  ) -> [SessionInfo] {
    let covered = Set(sessions.map { "\($0.tool.rawValue):\($0.projectPath)" })
    var emitted = Set<String>()

    return processes.compactMap { process in
      guard let cwd = process.cwd, cwd != "/" else { return nil }
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
        state: .running,
        live: true,
        lastActivity: now
      )
    }
  }
}
