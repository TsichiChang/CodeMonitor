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
      state: Self.classify(entry, age: age),
      // `sdk-*` entrypoints are agents a program started. Claude Code gives each
      // one its own transcript, so a single batch job can mint dozens of them —
      // 26 in one project here, against 9 sessions actually opened by hand.
      isDelegated: entry?.entrypoint?.hasPrefix("sdk") == true,
      live: false,
      lastActivity: mtime,
      lastMessage: entry?.snippet
    )
  }

  /// Infers state from the trailing conversation entry.
  ///
  /// This is the weaker kind of state — a hook reporting `PermissionRequest`
  /// says the session is blocked; a timestamp only suggests it.
  private static func classify(_ entry: ClaudeEntry?, age: TimeInterval) -> SessionState {
    guard let entry else { return age < Aging.writing ? .running : .idle }

    switch entry.role {
    case "assistant":
      // A dispatched tool call with no result yet: either the tool is running,
      // or the CLI is sitting on a permission prompt.
      if entry.hasToolUse || entry.stopReason == "tool_use" {
        if age < Aging.approvalSuspect { return .running }
        if age < Aging.waitingMax { return .waiting }
        return .idle
      }
      if let reason = entry.stopReason,
        ["end_turn", "stop_sequence", "max_tokens"].contains(reason)
      {
        return .idle  // turn complete, awaiting the user
      }
      return age < Aging.approvalSuspect ? .running : .idle  // still streaming

    case "user":
      // A prompt or a tool result just landed; the model owns the next turn.
      return age < Aging.generatingMax ? .running : .idle

    default:
      return age < Aging.writing ? .running : .idle
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
