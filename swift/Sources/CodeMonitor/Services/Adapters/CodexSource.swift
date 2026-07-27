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
      evidence: Evidence(Self.activity(entry), at: mtime, source: .inferred),
      state: .idle,
      lastMessage: entry?.snippet
    )
  }

  private static func activity(_ entry: CodexEntry?) -> Activity {
    // `task_complete` is the one event Codex names that settles the question;
    // anything else trailing means the turn is still in flight.
    entry?.payloadType == "task_complete" ? .turnComplete : .turnInFlight
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
