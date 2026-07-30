/// Codex sessions, read from the rollout files under
/// `~/.codex/sessions/<year>/<month>/<day>/rollout-*.jsonl`.
///
/// Codex keeps SQLite stores of its own, but they are not a usable index:
/// `state_5.sqlite`'s `threads` table stopped being written long before this
/// was investigated and covers none of the recent rollouts. The files are the
/// only trustworthy source (ADR-0004).

import Foundation

final class CodexSource: SessionSource {
  let tool: ToolKind = .codex

  private let root = FileManager.default
    .homeDirectoryForCurrentUser
    .appending(path: ".codex/sessions")

  /// `session_meta` is the first record and never changes.
  private var metaCache: [String: CodexMeta?] = [:]
  private var tailCache: [String: (mtime: Date, entry: CodexEntry?)] = [:]

  func sessions(now: Date) -> [SessionInfo] {
    var out: [SessionInfo] = []

    // A session that started yesterday and is still going writes to yesterday's
    // directory, so both days are scanned.
    for day in [now, now.addingTimeInterval(-24 * 60 * 60)] {
      guard
        let files = try? FileManager.default.contentsOfDirectory(
          at: dayDirectory(day), includingPropertiesForKeys: [.contentModificationDateKey])
      else { continue }

      for file in files {
        let name = file.lastPathComponent
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"),
          let mtime = modificationDate(of: file)
        else { continue }

        let age = now.timeIntervalSince(mtime)
        guard age <= Aging.readHorizon else { continue }
        guard let session = session(file: file, mtime: mtime, age: age) else { continue }
        out.append(session)
      }
    }
    return out
  }

  private func session(file: URL, mtime: Date, age: TimeInterval) -> SessionInfo? {
    let meta = cachedMeta(at: file)
    let origin = meta?.cwd ?? "unknown"
    guard isUsableProject(origin) else { return nil }

    let entry = cachedTail(at: file, mtime: mtime)
    return SessionInfo(
      id: "codex:\(meta?.id ?? file.deletingPathExtension().lastPathComponent)",
      tool: .codex,
      projectPath: origin,
      // Rollouts record the cwd once, at the top, so a Codex session has no
      // observable current directory distinct from where it began.
      workingDirectory: origin,
      project: origin == "unknown" ? "Codex session" : label(for: origin),
      gitBranch: meta?.gitBranch,
      model: meta?.model,
      evidence: Self.evidence(entry, at: mtime),
      state: .idle,
      hostBundleID: Self.hostBundleID(for: meta?.originator),
      isDelegated: Self.isDelegated(threadSource: meta?.threadSource),
      lastMessage: entry?.snippet
    )
  }

  /// The desktop app a session belongs to, or nil when a terminal runs it.
  ///
  /// `originator` is the only field that tells them apart, and the difference
  /// is not cosmetic: a desktop session has no process to find. Every Codex
  /// process on this machine belongs to the app itself and sits at `/`, so
  /// their absence proves nothing about any one session and their presence
  /// identifies none — which is why liveness has to stay `unknown` for these,
  /// and why jumping means activating the app (ADR-0017).
  static func hostBundleID(for originator: String?) -> String? {
    guard let key = originator?.lowercased() else { return nil }
    let desktopHosts = ["codex desktop": "com.openai.codex", "chatgpt": "com.openai.codex"]
    return desktopHosts.first { key.contains($0.key) }?.value
  }

  /// Whether a program spawned this session rather than a person (ADR-0025).
  ///
  /// 87 of 109 rollouts on this machine are sub-agents, and every Codex card on
  /// the dashboard was one of them — three of those sitting in the jump queue,
  /// which exists to walk what deserves a person's attention.
  ///
  /// Keyed on `thread_source` alone, though `parent_thread_id` and `source` agree
  /// on all 87. `source` cannot be read the same way — it is a string on human
  /// sessions and an object on delegated ones — and `parent_thread_id` says the
  /// same thing indirectly.
  ///
  /// Only the exact value counts. `thread_source` has been observed here as
  /// `subagent` and `user` and absent, and nothing promises a future value would
  /// still say `subagent`; treating anything else as human under-reports
  /// delegation, which shows one card too many rather than hiding one.
  static func isDelegated(threadSource: String?) -> Bool {
    threadSource?.lowercased() == "subagent"
  }

  /// Not private, so `--selftest` can run real rollout records through it.
  static func activity(_ entry: CodexEntry?) -> Activity {
    // A code, not prose. Claude needs its flag *and* its wording matched
    // because one flag covers limits, 401s and dropped connections alike; Codex
    // names the condition, so this cannot rot when a message is reworded
    // (ADR-0024).
    if entry?.errorCode == "usage_limit_exceeded" { return .blockedOnLimit }
    // `task_complete` is the one event Codex names that settles the question;
    // anything else trailing means the turn is still in flight.
    return entry?.payloadType == "task_complete" ? .turnComplete : .turnInFlight
  }

  /// What the trailing event says, and how much that is worth — see
  /// `ClaudeSource.evidence` for why the two are decided together.
  static func evidence(_ entry: CodexEntry?, at observed: Date) -> Evidence {
    let activity = Self.activity(entry)
    return Evidence(
      activity, at: observed, source: activity == .blockedOnLimit ? .reported : .inferred)
  }

  // MARK: - Layout

  private func dayDirectory(_ date: Date) -> URL {
    let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
    let year = String(parts.year ?? 0)
    let month = String(format: "%02d", parts.month ?? 0)
    let day = String(format: "%02d", parts.day ?? 0)
    return root.appending(path: "\(year)/\(month)/\(day)")
  }

  // MARK: - Caches

  private func cachedMeta(at url: URL) -> CodexMeta? {
    let key = url.path
    if let hit = metaCache[key] { return hit }
    let meta = TranscriptReader.readHead(url).flatMap(TranscriptReader.parseCodexMeta)
    metaCache[key] = meta
    if metaCache.count > 500 { metaCache.removeAll() }
    return meta
  }

  private func cachedTail(at url: URL, mtime: Date) -> CodexEntry? {
    let key = url.path
    if let hit = tailCache[key], hit.mtime == mtime { return hit.entry }
    let entry = TranscriptReader.readTail(url).flatMap(TranscriptReader.parseCodexTail)
    tailCache[key] = (mtime, entry)
    if tailCache.count > 500 { tailCache.removeAll() }
    return entry
  }
}
