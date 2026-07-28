/// Bounded JSONL transcript reading + parsing.
///
/// Transcripts grow without limit, so we only ever read a window: the tail for
/// "what happened last", the head for the session metadata record. Parsing
/// extracts concrete `Sendable` values immediately — raw `[String: Any]` never
/// escapes this file, which keeps the scanner free of concurrency hazards.

import Foundation

// MARK: - Extracted entry shapes

/// The trailing conversation entry of a Claude transcript.
struct ClaudeEntry: Sendable {
  var role: String?
  /// How the session was started — `cli`, `claude-desktop`, `sdk-cli`, …
  /// Present on every conversation record, so the tail carries it.
  var entrypoint: String?
  var stopReason: String?
  var hasToolUse = false
  /// The user took the turn back — Claude Code's own marker for Esc, written as
  /// a user record even though no prompt was submitted.
  var interrupted = false
  var cwd: String?
  var gitBranch: String?
  var model: String?
  var snippet: String?
}

/// The trailing event of a Codex rollout.
struct CodexEntry: Sendable {
  var payloadType: String?
  var snippet: String?
}

/// The `session_meta` record at the head of a Codex rollout.
struct CodexMeta: Sendable {
  var cwd: String?
  var id: String?
  var model: String?
  var gitBranch: String?
}

// MARK: - Reader

enum TranscriptReader {
  static let tailBytes = 64 * 1024
  static let headBytes = 16 * 1024

  /// Last `maxBytes` of a file, decoded as UTF-8.
  static func readTail(_ url: URL, maxBytes: Int = tailBytes) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return nil }
    let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
    guard (try? handle.seek(toOffset: start)) != nil else { return nil }
    guard let data = try? handle.readToEnd() else { return nil }
    return String(decoding: data, as: UTF8.self)
  }

  /// First `maxBytes` of a file, decoded as UTF-8.
  static func readHead(_ url: URL, maxBytes: Int = headBytes) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: maxBytes) else { return nil }
    return String(decoding: data, as: UTF8.self)
  }

  // MARK: - Claude

  /// The directory a session started in, read from the head of its transcript.
  ///
  /// This is the session's Project. It cannot be recovered from the enclosing
  /// project-directory name, which encodes the path with `/` replaced by `-`
  /// and so cannot be decoded back once the path itself contains a hyphen
  /// (`…-Repos-oversea-fop`).
  static func parseClaudeOrigin(_ text: String) -> String? {
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let obj = parseObject(line), let cwd = str(obj["cwd"]) else { continue }
      return cwd
    }
    return nil
  }

  /// Parses the newest conversation entry from a transcript tail.
  ///
  /// Claude transcripts interleave bookkeeping records ("last-prompt", "mode",
  /// "system", …) after the real turn, so we scan backwards for the newest
  /// "assistant"/"user" record — those are the only ones carrying a message.
  static func parseClaudeTail(_ text: String) -> ClaudeEntry? {
    guard
      let raw = lastJSONObject(in: text, where: { obj in
        let type = str(obj["type"])
        return type == "assistant" || type == "user"
      })
    else { return nil }

    let message = dict(raw["message"])
    let content = array(message["content"])

    var entry = ClaudeEntry()
    entry.role = str(message["role"]) ?? str(raw["role"])
    entry.stopReason = str(message["stop_reason"])
    entry.hasToolUse = content.contains { str(dict($0)["type"]) == "tool_use" }
    entry.interrupted = isInterrupt(message: message, content: content)
    entry.entrypoint = str(raw["entrypoint"])
    entry.cwd = str(raw["cwd"])
    entry.gitBranch = str(raw["gitBranch"])
    entry.model = str(message["model"])
    entry.snippet = claudeSnippet(message: message, content: content)
    return entry
  }

  /// Whether this record is Claude Code's note that the user pressed Esc.
  ///
  /// It is written as a user record, which otherwise means a prompt was
  /// submitted and the model now owns the turn. Here the opposite happened. The
  /// marker carries a suffix when the interrupt landed mid-tool-call
  /// (`… by user for tool use`), so only the stem is matched, and it arrives
  /// either as a bare string or as a text block depending on where it was
  /// raised.
  private static func isInterrupt(message: [String: Any], content: [Any]) -> Bool {
    let marker = "[Request interrupted"
    if str(message["content"])?.hasPrefix(marker) == true { return true }
    return content.contains { block in
      str(dict(block)["text"])?.hasPrefix(marker) == true
    }
  }

  private static func claudeSnippet(message: [String: Any], content: [Any]) -> String? {
    for item in content {
      let block = dict(item)
      switch str(block["type"]) {
      case "text":
        if let text = str(block["text"]) { return truncate(text) }
      case "tool_use":
        return truncate("Using \(str(block["name"]) ?? "tool")")
      case "tool_result":
        return "Tool finished"
      default:
        continue
      }
    }
    // A user turn can carry its prompt as a bare string instead of blocks.
    if str(message["role"]) == "user", let text = str(message["content"]) {
      return truncate(text)
    }
    return nil
  }

  // MARK: - Codex

  static func parseCodexTail(_ text: String) -> CodexEntry? {
    guard let raw = lastJSONObject(in: text, where: { _ in true }) else { return nil }
    let payload = dict(raw["payload"])

    var entry = CodexEntry()
    entry.payloadType = str(payload["type"]) ?? str(raw["type"])
    if let message = str(payload["last_agent_message"]) {
      entry.snippet = truncate(message)
    } else if let type = entry.payloadType {
      entry.snippet = truncate(type.replacingOccurrences(of: "_", with: " "))
    }
    return entry
  }

  static func parseCodexMeta(_ text: String) -> CodexMeta? {
    guard let raw = firstJSONObject(in: text) else { return nil }
    let payload = dict(raw["payload"])
    let git = dict(payload["git"])

    return CodexMeta(
      cwd: str(payload["cwd"]),
      id: str(payload["id"]),
      model: str(payload["model"]) ?? str(payload["model_provider"]),
      gitBranch: str(git["branch"])
    )
  }

  // MARK: - JSONL helpers

  /// Newest matching JSON object in a text window, scanning backwards.
  /// The first line of a tail window is often truncated mid-record — such lines
  /// simply fail to parse and are skipped.
  private static func lastJSONObject(
    in text: String,
    where predicate: ([String: Any]) -> Bool
  ) -> [String: Any]? {
    for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
      guard let obj = parseObject(line) else { continue }
      if predicate(obj) { return obj }
    }
    return nil
  }

  private static func firstJSONObject(in text: String) -> [String: Any]? {
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let obj = parseObject(line) else { return nil }
      return obj
    }
    return nil
  }

  private static func parseObject(_ line: Substring) -> [String: Any]? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  private static func dict(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
  private static func str(_ value: Any?) -> String? { value as? String }
  private static func array(_ value: Any?) -> [Any] { value as? [Any] ?? [] }
}

/// Collapses whitespace and clips to `max` characters with an ellipsis.
func truncate(_ text: String?, max: Int = 100) -> String? {
  guard let text else { return nil }
  let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  guard !clean.isEmpty else { return nil }
  guard clean.count > max else { return clean }
  return clean.prefix(max - 1) + "…"
}
