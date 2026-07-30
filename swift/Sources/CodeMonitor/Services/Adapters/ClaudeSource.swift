/// Claude Code sessions, read from the JSONL transcripts under
/// `~/.claude/projects/<encoded-path>/<session-uuid>.jsonl`.
///
/// The filename is the session UUID, which is this source's identity and the
/// same value a hook reports as `session_id` — so the two agree without a
/// mapping (ADR-0002).

import Foundation

final class ClaudeSource: SessionSource {
  let tool: ToolKind = .claude

  private let root = FileManager.default
    .homeDirectoryForCurrentUser
    .appending(path: ".claude/projects")

  /// A session's origin directory never changes, so this is keyed by path alone.
  private var originCache: [String: String?] = [:]
  /// Tail parses keyed by path + mtime, invalidated when the file grows.
  private var tailCache: [String: (mtime: Date, entry: ClaudeEntry?)] = [:]

  func sessions(now: Date) -> [SessionInfo] {
    guard
      let directories = try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.isDirectoryKey])
    else { return [] }

    var out: [SessionInfo] = []
    for directory in directories {
      guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
        let files = try? FileManager.default.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
      else { continue }

      // Every transcript is considered, not just the newest in its directory:
      // with identity on the UUID, two sessions open in one project are two
      // sessions. The age window below is what keeps the list short.
      for file in files where file.pathExtension == "jsonl" {
        guard let mtime = modificationDate(of: file) else { continue }
        let age = now.timeIntervalSince(mtime)
        guard age <= Aging.readHorizon else { continue }

        guard let session = session(file: file, mtime: mtime, age: age) else { continue }
        out.append(session)
      }
    }
    return out
  }

  private func session(file: URL, mtime: Date, age: TimeInterval) -> SessionInfo? {
    let entry = cachedTail(at: file, mtime: mtime)
    guard let origin = cachedOrigin(at: file) ?? entry?.cwd, isUsableProject(origin) else {
      return nil
    }

    return SessionInfo(
      id: "claude:\(file.deletingPathExtension().lastPathComponent)",
      tool: .claude,
      projectPath: origin,
      // The tail records where the session is *now*, which is what a live
      // process reports — and what makes them matchable at all.
      workingDirectory: entry?.cwd ?? origin,
      project: label(for: origin),
      gitBranch: entry?.gitBranch,
      model: entry?.model,
      evidence: Self.evidence(entry, at: mtime),
      state: .idle,
      // `sdk-*` entrypoints are agents a program started. Claude Code gives each
      // one its own transcript, so a single batch job can mint dozens of them —
      // 26 in one project here, against 9 sessions actually opened by hand.
      isDelegated: entry?.entrypoint?.hasPrefix("sdk") == true,
      lastMessage: entry?.snippet
    )
  }

  /// What the trailing record says, and how much that is worth.
  ///
  /// One function rather than two reads of the same entry, because the strength
  /// follows from *which* activity was recognised: a flagged limit stall is the
  /// tool stating it outright, so it carries `reported` weight even though it
  /// arrived by transcript (ADR-0024). Everything else here is a guess about the
  /// shape of a file, which is what `inferred` means.
  static func evidence(_ entry: ClaudeEntry?, at observed: Date) -> Evidence {
    let activity = Self.activity(entry)
    return Evidence(
      activity, at: observed, source: activity == .blockedOnLimit ? .reported : .inferred)
  }

  /// Reads what last happened from the trailing conversation entry.
  ///
  /// Only the observation — how long ago it was, and what that means, is the
  /// derivation's business (ADR-0012).
  ///
  /// Not private so `--selftest` can run records through it: this is the whole
  /// of what a session without a hook is judged on.
  static func activity(_ entry: ClaudeEntry?) -> Activity {
    guard let entry else { return .unknown }

    // Before the role switch, because a limit stall arrives as an assistant
    // record with `stop_reason: stop_sequence` and would otherwise read as a
    // finished turn — folding a card that stopped mid-task into a dim line
    // saying "nothing to do here" (ADR-0024).
    if entry.limitReached { return .blockedOnLimit }

    switch entry.role {
    case "assistant":
      // A dispatched tool with no result yet, or a response still streaming.
      if entry.hasToolUse || entry.stopReason == "tool_use" { return .turnInFlight }
      if let reason = entry.stopReason,
        ["end_turn", "stop_sequence", "max_tokens"].contains(reason)
      {
        return .turnComplete
      }
      return .turnInFlight
    case "user":
      // Esc is written as a user record too, and reading it as a handover is
      // backwards: the turn ended and the session is waiting for whatever is
      // typed next. Left as a turn in flight it went quiet instead, and a quiet
      // inferred turn is read as a suspected block — so an interrupted session
      // spent ten minutes claiming to want approval for something.
      if entry.interrupted { return .turnComplete }
      // A slash command, a `!` shell command, or an injected reminder. Written
      // as the user, typed by nobody, and answered by nobody — so it says
      // nothing about whose turn it is.
      if entry.synthetic { return .unknown }
      // A prompt or a tool result just landed; the model owns the next turn.
      return .turnInFlight
    default:
      return .unknown
    }
  }

  // MARK: - Caches

  private func cachedOrigin(at url: URL) -> String? {
    let key = url.path
    if let hit = originCache[key] { return hit }
    let origin = TranscriptReader.readHead(url).flatMap(TranscriptReader.parseClaudeOrigin)
    originCache[key] = origin
    if originCache.count > 500 { originCache.removeAll() }
    return origin
  }

  private func cachedTail(at url: URL, mtime: Date) -> ClaudeEntry? {
    let key = url.path
    if let hit = tailCache[key], hit.mtime == mtime { return hit.entry }
    let entry = TranscriptReader.readTail(url).flatMap(TranscriptReader.parseClaudeTail)
    tailCache[key] = (mtime, entry)
    if tailCache.count > 500 { tailCache.removeAll() }
    return entry
  }
}
