/// Reads the state files agent hooks leave behind (ADR-0010).
///
/// A hook fires whether or not this app is running, so it reports through the
/// filesystem rather than to a listener: state accumulated while the app was
/// closed is still here when it opens. Each file is one session, replaced in
/// place by its hook.
///
/// What arrives here is *authoritative* — the tool said so — as opposed to the
/// state a source infers from timestamps.

import Foundation

struct HookState: Sendable {
  let tool: ToolKind
  let sessionID: String
  /// What the tool said happened, not what it means. The hook reports its event
  /// name; deciding what that implies is the derivation's job (ADR-0012), which
  /// is why fixing a mis-reading no longer means editing the user's settings.
  let activity: Activity
  let pid: Int32?
  let tty: String?
  let cwd: String
  let termProgram: String?
  /// Terminal tab this session was last observed in, when the hook could
  /// determine one (ADR-0009).
  let tabID: String?
  /// Pane within that tab — what separates sessions sharing a tab.
  let paneID: String?
  let updated: Date

  /// Key shared with `SessionInfo.id`, so the two join without a mapping.
  var sessionKey: String { "\(tool.rawValue):\(sessionID)" }
}

enum HookStateStore {
  static let directory: URL = {
    if let override = ProcessInfo.processInfo.environment["CODEMONITOR_STATE_DIR"] {
      return URL(fileURLWithPath: override)
    }
    return FileManager.default
      .homeDirectoryForCurrentUser
      .appending(path: ".local/state/codemonitor/sessions")
  }()

  /// Every reported state, keyed by `tool:sessionID`.
  ///
  /// No staleness rule is applied here. A file says what the session was last
  /// reported doing; how long that stays believable is the lifecycle's business
  /// (ADR-0005), and it already distinguishes a `waiting` session — which is
  /// motionless by definition and must not expire — from a `running` one that
  /// has gone quiet for half an hour.
  static func states() -> [String: HookState] {
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else { return [:] }

    var result: [String: HookState] = [:]
    for file in files where file.pathExtension == "json" {
      guard let state = parse(file) else { continue }
      result[state.sessionKey] = state
    }
    return result
  }

  /// Discards reports left behind by sessions that never got to say goodbye.
  ///
  /// A hook removes its own file on `SessionEnd`, so anything still here after
  /// a week belongs to a session that was killed or crashed. Run once at
  /// launch: these files are tiny and the cost of keeping one an extra day is
  /// nothing, while deleting one that is still in use would silently drop a
  /// session's reported state.
  static func pruneAbandoned(olderThan age: TimeInterval = 7 * 24 * 60 * 60) {
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return }

    let cutoff = Date().addingTimeInterval(-age)
    for file in files where file.pathExtension == "json" {
      guard
        let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate,
        modified < cutoff
      else { continue }
      try? FileManager.default.removeItem(at: file)
    }
  }

  // MARK: - Dismissals

  private static let dismissalsKey = "dismissedSessions"

  /// Session ids the user has closed, mapped to how recent that session was at
  /// the time — the mark a later activity has to pass to bring it back.
  static func loadDismissals() -> [String: Date] {
    let stored = UserDefaults.standard.dictionary(forKey: dismissalsKey) ?? [:]
    return stored.compactMapValues { value in
      (value as? Double).map { Date(timeIntervalSince1970: $0) }
    }
  }

  static func saveDismissals(_ dismissals: [String: Date]) {
    let encoded = dismissals.mapValues { $0.timeIntervalSince1970 }
    UserDefaults.standard.set(encoded, forKey: dismissalsKey)
    // Defaults are written back lazily, which is fine for the app and not for
    // the CLI: `--dismiss` exits immediately afterwards and the write was being
    // discarded with the process.
    UserDefaults.standard.synchronize()
  }

  // MARK: - Visits

  private static let visitsKey = "visitedSessions"

  /// When each session was last jumped to. Paired with its last activity this
  /// is the whole of "have I seen this yet" — nothing stores a read flag, so
  /// nothing can leave one set after the session speaks again (ADR-0012).
  static func loadVisits() -> [String: Date] {
    let stored = UserDefaults.standard.dictionary(forKey: visitsKey) ?? [:]
    return stored.compactMapValues { value in
      (value as? Double).map { Date(timeIntervalSince1970: $0) }
    }
  }

  static func saveVisits(_ visits: [String: Date]) {
    UserDefaults.standard.set(visits.mapValues(\.timeIntervalSince1970), forKey: visitsKey)
    UserDefaults.standard.synchronize()
  }

  private struct Payload: Decodable {
    let tool: String
    let sessionId: String
    let event: String?
    let pid: Int32?
    let tty: String?
    let cwd: String?
    let termProgram: String?
    let tabId: String?
    let paneId: String?
    let updatedAt: Double
  }

  /// Maps a hook's event name onto what it says about the session.
  ///
  /// Two entries here were once encoded as arguments in the user's
  /// `settings.json`, and both were wrong: `Notification` covers several
  /// unrelated things, and `SessionStart` is not activity — a new session is
  /// waiting for its first instruction. Correcting either meant editing a file
  /// this app does not own. They are ordinary lines of Swift now.
  static func activity(forEvent event: String?) -> Activity {
    switch event {
    case "PermissionRequest", "Notification:permission_prompt":
      return .blockedOnUser
    case "Stop", "StopFailure", "SubagentStop", "Notification:idle_prompt":
      // `StopFailure` is the turn ending without finishing. However it ended,
      // the session is back to waiting on the user, which is the only thing
      // this has to get right.
      return .turnComplete
    case "SessionStart":
      return .opened
    case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PreCompact",
      "Stop:subagent-running":
      // A Stop fired while a Task sub-agent is still working is not the end of
      // the turn — the main agent merely yielded.
      return .turnInFlight
    default:
      return .unknown
    }
  }

  private static func parse(_ url: URL) -> HookState? {
    guard let data = try? Data(contentsOf: url),
      let payload = try? JSONDecoder().decode(Payload.self, from: data),
      let tool = ToolKind(rawValue: payload.tool)
    else { return nil }

    return HookState(
      tool: tool,
      sessionID: payload.sessionId,
      activity: Self.activity(forEvent: payload.event),
      pid: payload.pid.flatMap { $0 > 0 ? $0 : nil },
      tty: payload.tty.flatMap { $0.isEmpty ? nil : $0 },
      cwd: payload.cwd ?? "",
      termProgram: payload.termProgram.flatMap { $0.isEmpty ? nil : $0 },
      tabId: payload.tabId.flatMap { $0.isEmpty ? nil : $0 },
      paneId: payload.paneId.flatMap { $0.isEmpty ? nil : $0 },
      updated: Date(timeIntervalSince1970: payload.updatedAt)
    )
  }
}

extension HookState {
  /// Bridges the file's snake-ish key names onto the model's.
  fileprivate init(
    tool: ToolKind, sessionID: String, activity: Activity, pid: Int32?, tty: String?,
    cwd: String, termProgram: String?, tabId: String?, paneId: String?, updated: Date
  ) {
    self.init(
      tool: tool, sessionID: sessionID, activity: activity, pid: pid, tty: tty, cwd: cwd,
      termProgram: termProgram, tabID: tabId, paneID: paneId, updated: updated)
  }
}
