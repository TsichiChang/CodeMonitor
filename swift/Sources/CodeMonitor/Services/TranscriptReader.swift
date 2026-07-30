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
  /// A user record that no person typed: a slash command, a `!` shell command,
  /// its output, or an injected reminder. Says nothing about whose turn it is.
  var synthetic = false
  /// The turn was cut off by a usage limit (ADR-0024).
  ///
  /// Requires the record-level `isApiErrorMessage` flag *and* the text, because
  /// the flag alone covers 401s, 403s, "Not logged in" and dropped connections —
  /// 85 of the 124 flagged records on this machine are one of those, and none of
  /// them is a session the user has to wait out. Against that corpus the flag
  /// plus "your" plus "limit" separates the two perfectly: 42 limits matched, no
  /// false positives, none missed.
  ///
  /// The flag is what keeps this safe. Matching text alone would let prose in a
  /// conversation set a session's state — and a conversation *about* usage
  /// limits is exactly the kind that would.
  var limitReached = false
  var cwd: String?
  var gitBranch: String?
  var model: String?
  var snippet: String?
}

/// The trailing event of a Codex rollout.
struct CodexEntry: Sendable {
  var payloadType: String?
  /// Codex's own error code, e.g. `usage_limit_exceeded` (ADR-0024).
  ///
  /// The discriminator Claude does not have: a code rather than prose, so the
  /// same decision is robustly detectable here and fragilely there. Worth
  /// noticing that the corpora are the mirror image — two records exist on this
  /// machine to test this against, and forty-two on the Claude side.
  var errorCode: String?
  var snippet: String?
}

/// The `session_meta` record at the head of a Codex rollout.
struct CodexMeta: Sendable {
  var cwd: String?
  var id: String?
  var model: String?
  var gitBranch: String?
  /// What launched the session — `Codex Desktop`, a CLI, an editor extension.
  /// The one field that says whether a process will ever back this session.
  var originator: String?
  /// What kind of thread this is: `subagent` for one a program spawned, `user`
  /// for one a person opened, absent on older or CLI-started sessions.
  ///
  /// Read in preference to the neighbouring `source`, which says the same thing
  /// and cannot be scanned for: it is a *string* on human sessions (`"cli"`,
  /// `"vscode"`) and an *object* on delegated ones
  /// (`{"subagent": {"other": "guardian"}}`), so a reader expecting either shape
  /// gets the other exactly when the answer matters (ADR-0025).
  var threadSource: String?
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
    entry.synthetic = isSynthetic(message: message, content: content)
    entry.limitReached =
      raw["isApiErrorMessage"] as? Bool == true
      && isLimitText(message: message, content: content)
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

  /// Records Claude Code writes as the user without a user having written them.
  ///
  /// Running `! nvim` or a slash command puts one of these in the transcript,
  /// and the caveat spells out what it is — "DO NOT respond to these messages".
  /// Read as an ordinary prompt they claim the model just took the turn, which
  /// is the opposite of what they mean, and a turn that then goes quiet gets
  /// read as a suspected block. They carry no claim about whose turn it is, so
  /// the honest reading is `unknown`.
  private static let syntheticMarkers = [
    "<local-command-", "<command-name>", "<command-message>", "<command-args>",
    "<bash-input>", "<bash-stdout>", "<bash-stderr>", "<system-reminder>",
  ]

  /// Whether a flagged API error is a usage limit rather than one of the others.
  ///
  /// Two words instead of the two full sentences observed, because the sentences
  /// carry a reset time and a model name that vary — "hit your session limit ·
  /// resets 8:20pm" and "reached your Fable 5 limit" — while every non-limit
  /// flagged error on this machine (401, 403, "Not logged in", connection
  /// closed, `ECONNRESET`) contains neither word. Checked against all 124: 42
  /// matched, nothing else did.
  private static func isLimitText(message: [String: Any], content: [Any]) -> Bool {
    func limits(_ text: String?) -> Bool {
      guard let lowered = text?.lowercased() else { return false }
      return lowered.contains("your") && lowered.contains("limit")
    }
    if limits(str(message["content"])) { return true }
    return content.contains { limits(str(dict($0)["text"])) }
  }

  private static func isSynthetic(message: [String: Any], content: [Any]) -> Bool {
    func marked(_ text: String?) -> Bool {
      guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
      return syntheticMarkers.contains { text.hasPrefix($0) }
    }
    if marked(str(message["content"])) { return true }
    return content.contains { marked(str(dict($0)["text"])) }
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
    entry.errorCode = str(payload["codex_error_info"])
    if let message = str(payload["last_agent_message"]) {
      entry.snippet = truncate(message)
    } else if let type = entry.payloadType {
      entry.snippet = truncate(type.replacingOccurrences(of: "_", with: " "))
    }
    return entry
  }

  /// The newest quota reading in a rollout tail (ADR-0023).
  ///
  /// Scanned backwards for the last `rate_limits` rather than read off the final
  /// line, because the final line is usually a message or a tool call — the
  /// limits ride on `token_count` events, which are frequent but not last.
  ///
  /// The slots are positional and their names lie about their contents: on this
  /// machine `primary` was the seven-day window 3,799 times and the five-hour
  /// window 307, so only `window_minutes` says which is which. Both are read and
  /// keyed by length; a slot without a length is dropped rather than guessed at.
  static func parseCodexRateLimits(_ text: String) -> [UsageWindow]? {
    for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
      guard line.contains("\"rate_limits\""), let obj = parseObject(line) else { continue }
      let limits = dict(dict(obj["payload"])["rate_limits"])
      guard !limits.isEmpty else { continue }
      let windows = ["primary", "secondary"].compactMap { slot -> UsageWindow? in
        guard let values = limits[slot] as? [String: Any] else { return nil }
        return UsageStore.window(from: values, percentKey: "used_percent", minutes: nil)
      }
      if !windows.isEmpty { return windows }
    }
    return nil
  }

  /// Codex's `session_meta` cannot be parsed as JSON from a head window, so its
  /// fields are lifted out textually.
  ///
  /// The record carries the agent's entire system prompt in
  /// `base_instructions` — 43 KB in the largest one here, p50 14 KB — against a
  /// 16 KB head. Every larger session therefore produced a truncated object,
  /// `JSONSerialization` refused all of it, and the session lost its cwd: that
  /// is why Codex sessions all showed up as "Codex session" with no project.
  ///
  /// Everything needed sits in the first 400 bytes, before that field starts.
  /// `git` and `model` do not — they follow the prompt — so a Codex session
  /// shows no branch. Reading 43 KB per session per scan to recover a subtitle
  /// is not a trade worth making; the project name is identity, a branch is
  /// decoration.
  static func parseCodexMeta(_ text: String) -> CodexMeta? {
    // Everything past the prompt is arbitrary text that can contain anything
    // shaped like a field, including the words this scans for.
    let head =
      text.range(of: "\"base_instructions\"")
      .map { String(text[text.startIndex..<$0.lowerBound]) } ?? text

    guard let cwd = quotedField("cwd", in: head) else { return nil }
    return CodexMeta(
      cwd: cwd,
      id: quotedField("id", in: head),
      model: quotedField("model_provider", in: head),
      // Present in the record, unreachable at this cost. See above.
      gitBranch: nil,
      originator: quotedField("originator", in: head),
      // Sits before `base_instructions` in the record, so it survives the cut
      // above — everything needed is still in the first few hundred bytes.
      threadSource: quotedField("thread_source", in: head)
    )
  }

  /// Value of `"name": "…"`, scanned rather than parsed.
  private static func quotedField(_ name: String, in text: String) -> String? {
    guard let key = text.range(of: "\"\(name)\"") else { return nil }
    var index = key.upperBound
    while index < text.endIndex, text[index] == " " || text[index] == ":" {
      index = text.index(after: index)
    }
    guard index < text.endIndex, text[index] == "\"" else { return nil }
    index = text.index(after: index)

    var value = ""
    while index < text.endIndex, text[index] != "\"" {
      if text[index] == "\\" {
        index = text.index(after: index)
        guard index < text.endIndex else { break }
      }
      value.append(text[index])
      index = text.index(after: index)
    }
    return value.isEmpty ? nil : value
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
