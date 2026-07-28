/// Installs and removes the reporting hook in each tool's own configuration.
///
/// ADR-0001 dropped the zero-setup constraint to read these authoritative
/// channels, and the setup it bought was left as a manual edit — copy a script,
/// hand-append JSON to eight event arrays, twice over for two tools. That is a
/// lot of chances to get one array wrong, and it has to be redone whenever the
/// script grows a field.
///
/// The files belong to the user and hold other integrations' hooks, so every
/// rule here is about not damaging them: back up before writing, append to the
/// arrays rather than replacing them, tag the entries so they can be found
/// again, and treat installing twice as a no-op.

import Foundation

enum HookInstaller {
  /// Marks entries as ours, so removal never has to guess and installing twice
  /// updates in place. Claude's schema tolerates unknown keys; for Codex the
  /// same job is done by the marker in the command string, since its schema is
  /// stricter about what an entry may carry.
  static let marker = "_codemonitor"

  enum Status: Equatable {
    case installed
    case missing
    /// Present on some events but not all — an interrupted install, or a
    /// version that reported fewer events.
    case partial(present: Int, expected: Int)

    var isInstalled: Bool { self == .installed }
  }

  struct Target {
    let tool: ToolKind
    let config: URL
    /// Events to register on, and whether each takes the `locate` argument that
    /// records the terminal pane (ADR-0009).
    let events: [(name: String, locate: Bool)]
    /// Codex has no session-end event, so nothing removes its state file; the
    /// `ended` argument is only meaningful where such an event exists.
    let endEvent: String?
  }

  static var targets: [Target] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return [
      Target(
        tool: .claude,
        config: home.appending(path: ".claude/settings.json"),
        events: [
          ("SessionStart", true), ("UserPromptSubmit", true), ("PreToolUse", false),
          ("PostToolUse", false), ("PermissionRequest", false), ("Notification", false),
          ("Stop", false), ("StopFailure", false), ("SessionEnd", false),
        ],
        endEvent: "SessionEnd"),
      Target(
        tool: .codex,
        config: home.appending(path: ".codex/hooks.json"),
        // Codex fires no per-tool events, and its `SessionStart` cannot record a
        // pane: it has no terminal to ask (ADR-0017).
        events: [
          ("SessionStart", false), ("UserPromptSubmit", false),
          ("PermissionRequest", false), ("Stop", false),
        ],
        endEvent: nil),
    ]
  }

  /// Where the hook is installed to. Inside the user's own directory rather
  /// than referenced inside the app bundle, so that moving or replacing the app
  /// cannot silently break every registered hook.
  static var scriptURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".claude/hooks/codemonitor-hook.sh")
  }

  /// The copy shipped inside the app.
  static var bundledScriptURL: URL? {
    Bundle.main.url(forResource: "codemonitor-hook", withExtension: "sh")
  }

  // MARK: - Status

  static func status(of target: Target) -> Status {
    guard FileManager.default.fileExists(atPath: scriptURL.path),
      let root = readJSON(target.config),
      let hooks = root["hooks"] as? [String: Any]
    else { return .missing }

    let present = target.events.filter { event in
      guard let groups = hooks[event.name] as? [[String: Any]] else { return false }
      return groups.contains { isOurs($0) }
    }.count

    if present == 0 { return .missing }
    return present == target.events.count ? .installed : .partial(
      present: present, expected: target.events.count)
  }

  // MARK: - Install

  @discardableResult
  static func install(_ target: Target) throws -> URL? {
    try installScript()

    var root = readJSON(target.config) ?? [:]
    var hooks = root["hooks"] as? [String: Any] ?? [:]

    for event in target.events {
      var groups = hooks[event.name] as? [[String: Any]] ?? []
      groups.removeAll(where: isOurs)   // re-installing updates rather than duplicates
      groups.append(entry(for: event, in: target))
      hooks[event.name] = groups
    }
    root["hooks"] = hooks

    let backup = try backUp(target.config)
    try writeJSON(root, to: target.config)
    return backup
  }

  @discardableResult
  static func uninstall(_ target: Target) throws -> URL? {
    guard var root = readJSON(target.config),
      var hooks = root["hooks"] as? [String: Any]
    else { return nil }

    for event in target.events {
      guard var groups = hooks[event.name] as? [[String: Any]] else { continue }
      groups.removeAll(where: isOurs)
      // An empty array is left rather than removed: the key existing is what
      // other tools' installers look at, and this one did not create it.
      hooks[event.name] = groups
    }
    root["hooks"] = hooks

    let backup = try backUp(target.config)
    try writeJSON(root, to: target.config)
    return backup
  }

  // MARK: - Pieces

  private static func entry(for event: (name: String, locate: Bool), in target: Target)
    -> [String: Any]
  {
    var command = "'\(scriptURL.path)'"
    if target.tool != .claude { command = "CODEMONITOR_TOOL=\(target.tool.rawValue) " + command }
    // Only `ended` is read; every other event passes a placeholder (ADR-0012).
    command += event.name == target.endEvent ? " ended" : " -"
    command += " \"$PPID\""
    if event.locate { command += " locate" }

    return [
      marker: true,
      "hooks": [["type": "command", "command": command]],
    ]
  }

  private static func isOurs(_ group: [String: Any]) -> Bool {
    if group[marker] as? Bool == true { return true }
    // Fallback for entries written by hand, or by a version predating the tag.
    let commands = (group["hooks"] as? [[String: Any]] ?? []).compactMap {
      $0["command"] as? String
    }
    return commands.contains { $0.contains("codemonitor-hook.sh") }
  }

  private static func installScript() throws {
    guard let source = bundledScriptURL else {
      throw Failure("The hook script is missing from the app bundle.")
    }
    try FileManager.default.createDirectory(
      at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: scriptURL.path) {
      try FileManager.default.removeItem(at: scriptURL)
    }
    try FileManager.default.copyItem(at: source, to: scriptURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
  }

  /// Keeps a dated copy beside the original. These files hold other tools'
  /// integrations, and this is the only thing standing between a bad write and
  /// a configuration the user has to reconstruct by hand.
  private static func backUp(_ url: URL) throws -> URL? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let stamp = ISO8601DateFormatter().string(from: Date())
      .replacingOccurrences(of: ":", with: "-")
    let backup = url.appendingPathExtension("codemonitor-\(stamp)")
    try FileManager.default.copyItem(at: url, to: backup)
    return backup
  }

  private static func readJSON(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return object
  }

  private static func writeJSON(_ object: [String: Any], to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONSerialization.data(
      withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    // Replaced by rename so a reader never sees a half-written file — the same
    // reason the hook itself writes that way.
    let temporary = url.appendingPathExtension("codemonitor-tmp")
    try data.write(to: temporary)
    _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
  }

  struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}
