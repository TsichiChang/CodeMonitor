/// OpenCode sessions, read from its SQLite store.
///
/// The one tool that indexes its own sessions, so nothing is inferred from file
/// layout or timestamps on disk — only from what the store records.

import Foundation

final class OpenCodeSource: SessionSource {
  let tool: ToolKind = .opencode

  func sessions(now: Date) -> [SessionInfo] {
    OpenCodeStore.sessions().compactMap { row in
      let origin = row.directory ?? "unknown"
      guard isUsableProject(origin) else { return nil }

      let age = now.timeIntervalSince(row.updated)
      // OpenCode exposes no signal for a session blocked on approval, so
      // `waiting` is currently unreachable here and the window is the shorter
      // of the two.
      let state: SessionState = age < Aging.writing ? .running : .idle
      guard age <= Aging.readHorizon else { return nil }

      return SessionInfo(
        id: "opencode:\(row.id)",
        tool: .opencode,
        projectPath: origin,
        workingDirectory: origin,
        project: origin == "unknown" ? "OpenCode session" : label(for: origin),
        model: row.model,
        state: state,
        live: false,
        lastActivity: row.updated,
        lastMessage: row.title
      )
    }
  }
}
