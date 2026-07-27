/// OpenCode sessions, read from its SQLite store.
///
/// The one tool that indexes its own sessions, so nothing is inferred from file
/// layout or timestamps on disk — only from what the store records.

import Foundation

final class OpenCodeSource: SessionSource {
  let tool: ToolKind = .opencode

  func sessions(now: Date) -> [SessionInfo] {
    OpenCodeStore.sessions().compactMap { row -> SessionInfo? in
      let origin = row.directory ?? "unknown"
      guard isUsableProject(origin) else { return nil }

      guard now.timeIntervalSince(row.updated) <= Aging.readHorizon else { return nil }

      return SessionInfo(
        id: "opencode:\(row.id)",
        tool: .opencode,
        projectPath: origin,
        workingDirectory: origin,
        project: origin == "unknown" ? "OpenCode session" : label(for: origin),
        model: row.model,
        // The store records when a session last changed and not what changed,
        // so `unknown` is the honest reading rather than a failure.
        evidence: Evidence(.unknown, at: row.updated, source: .inferred),
        state: .idle,
        lastMessage: row.title
      )
    }
  }
}
