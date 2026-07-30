/// Reads what each tool says about its own quotas (ADR-0023).
///
/// Two tools, two channels, and the difference is the whole reason this file
/// exists rather than a field on either adapter. Codex writes its limits into
/// the rollout it is already writing, so they are simply there. Claude pushes
/// them to whatever command `statusLine` names and stores them nowhere — so a
/// reading exists only if the user's own status-line script was asked to keep
/// one, which this app must not install for them: `statusLine` holds a single
/// command, not an array, so registering ours would evict theirs.
///
/// Both readers therefore return nothing rather than something approximate when
/// the channel is quiet. `—` on screen is an honest answer; a stale percentage
/// is not.

import Foundation

enum UsageStore {
  /// Where the status-line snapshot lands. Matches the line the user adds to
  /// their own script, and honours the same override so a test can point
  /// elsewhere.
  static var claudeFile: URL {
    if let override = ProcessInfo.processInfo.environment["CODEMONITOR_USAGE_FILE"] {
      return URL(fileURLWithPath: override)
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".local/state/codemonitor/usage.json")
  }

  /// Every tool that has said something, newest reading each.
  static func readings(now: Date = Date()) -> [ToolUsage] {
    [claude(), codex()].compactMap { $0 }
  }

  // MARK: - Claude

  /// Claude names its windows, so the slots need no interpretation.
  ///
  /// Only `rate_limits` is read out of this file even though it carries far more.
  /// The payload describes **whichever session redrew last**, so `session_id`,
  /// `cwd`, `cost` and `context_window` all belong to an arbitrary writer —
  /// attributing them to a named session would be a value standing in for an
  /// identity it does not have (ADR-0002). Quotas are the account's, so they are
  /// the same whoever wrote them.
  static func claude(file: URL? = nil) -> ToolUsage? {
    let url = file ?? claudeFile
    guard let data = try? Data(contentsOf: url),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let limits = object["rate_limits"] as? [String: Any]
    else { return nil }

    let named: [(String, Int)] = [("five_hour", 300), ("seven_day", 10_080)]
    let windows = named.compactMap { key, minutes -> UsageWindow? in
      guard let slot = limits[key] as? [String: Any] else { return nil }
      return window(from: slot, percentKey: "used_percentage", minutes: minutes)
    }
    guard !windows.isEmpty else { return nil }

    let modified =
      (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
      .contentModificationDate ?? Date()
    return ToolUsage(tool: .claude, windows: windows, observedAt: modified)
  }

  // MARK: - Codex

  /// Codex writes its limits into the rollout, so the newest rollout holds the
  /// newest reading — the figures climb through a day, which is what makes
  /// "newest file" the right choice rather than "any file".
  ///
  /// Read from the tail rather than the whole file: `token_count` events carry
  /// the limits and land dozens of times per session, so the last 64 KB holds one
  /// even in a 1.5 MB rollout. Checked against the six most recent here, all of
  /// which had one.
  static func codex(root: URL? = nil) -> ToolUsage? {
    let base = root ?? FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".codex/sessions")
    guard let newest = newestRollout(under: base) else { return nil }
    guard let text = TranscriptReader.readTail(newest.url),
      let windows = TranscriptReader.parseCodexRateLimits(text), !windows.isEmpty
    else { return nil }
    return ToolUsage(tool: .codex, windows: windows, observedAt: newest.modified)
  }

  /// Newest rollout by modification time, without walking the whole tree twice.
  private static func newestRollout(under base: URL) -> (url: URL, modified: Date)? {
    guard
      let walker = FileManager.default.enumerator(
        at: base, includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles])
    else { return nil }

    var best: (url: URL, modified: Date)?
    for case let url as URL in walker where url.lastPathComponent.hasPrefix("rollout-") {
      guard
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate
      else { continue }
      if best == nil || modified > best!.modified { best = (url, modified) }
    }
    return best
  }

  // MARK: - Shared

  /// One slot, whichever vendor's spelling of "percent" it uses.
  static func window(from slot: [String: Any], percentKey: String, minutes: Int?)
    -> UsageWindow?
  {
    guard let percent = (slot[percentKey] as? NSNumber)?.doubleValue,
      let resets = (slot["resets_at"] as? NSNumber)?.doubleValue
    else { return nil }
    // Codex states the length; Claude implies it in the key name.
    let length = (slot["window_minutes"] as? NSNumber)?.intValue ?? minutes
    guard let length else { return nil }
    return UsageWindow(
      minutes: length, usedPercent: percent,
      resetsAt: Date(timeIntervalSince1970: resets))
  }
}
