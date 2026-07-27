/// Best-effort live-process discovery via `ps` / `lsof`.
///
/// Live processes confirm a transcript-derived session is still open, supply
/// its pid/tty for terminal jumping, and let us trust a long-lived "waiting"
/// state. Everything here degrades gracefully: a denied or missing tool just
/// means fewer confirmed sessions, never a failed poll.

import Foundation

struct LiveProcess: Sendable {
  let tool: ToolKind
  let pid: Int32
  let tty: String?
  var cwd: String?
}

enum ProcessScanner {
  /// The CLIs run either as native binaries (`codex`) or node/bun-wrapped
  /// scripts (`node …/claude-code/cli.js`), so match both the bare command and
  /// the package-path forms.
  private static let toolPatterns: [(ToolKind, [String])] = [
    (.codex, ["(?:^|/)codex(?:\\s|$)", "codex-cli", "openai[-/].*codex"]),
    (.opencode, ["(?:^|/)opencode(?:\\s|$)", "opencode[-/]"]),
    (
      .claude,
      [
        "(?:^|/)claude(?:\\s|$)", "claude-code", "anthropic[-/].*claude",
        "\\.claude/local/",
      ]
    ),
  ]

  /// Cheap literal that must appear before a tool's patterns are worth running.
  private static let toolHints: [(ToolKind, String)] = [
    (.codex, "codex"), (.opencode, "opencode"), (.claude, "claude"),
  ]

  static func tool(forCommand command: String) -> ToolKind? {
    // Reject on a literal substring first. Nearly every process on the machine
    // mentions none of these, and `range(of:options:.regularExpression)`
    // recompiles its pattern on each call — running the full pattern set against
    // every one of ~700 command lines was by far the costliest thing per scan.
    for (tool, hint) in toolHints {
      guard command.range(of: hint, options: .caseInsensitive) != nil else { continue }
      guard let patterns = toolPatterns.first(where: { $0.0 == tool })?.1 else { continue }
      for pattern in patterns where command.matches(pattern) {
        return tool
      }
    }
    return nil
  }

  /// Scans every process for a known agent CLI, resolving each match's cwd.
  static func scan() async -> (processes: [LiveProcess], ok: Bool) {
    guard
      let output = await Shell.run("/bin/ps", ["-axww", "-o", "pid=,tty=,command="], timeout: 8),
      output.succeeded
    else {
      return ([], false)
    }

    var matched: [(pid: Int32, tty: String?, tool: ToolKind)] = []
    for line in output.stdout.split(separator: "\n") {
      // pid  tty  command…   (tty is "??" for processes with no controlling terminal)
      let fields = line.trimmingCharacters(in: .whitespaces)
        .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
      guard fields.count == 3, let pid = Int32(fields[0]) else { continue }
      let tty = fields[1] == "??" ? nil : String(fields[1])
      // `ps` pads its columns, so the command still carries leading spaces —
      // which would break the `^` anchor in the tool patterns.
      let command = fields[2].trimmingCharacters(in: .whitespaces)
      guard let tool = tool(forCommand: command) else { continue }
      matched.append((pid, tty, tool))
    }

    // Resolve cwds concurrently — each is an independent `lsof` call.
    var processes: [LiveProcess] = []
    await withTaskGroup(of: LiveProcess.self) { group in
      for match in matched {
        group.addTask {
          LiveProcess(
            tool: match.tool,
            pid: match.pid,
            tty: match.tty,
            cwd: await cwd(of: match.pid)
          )
        }
      }
      for await process in group { processes.append(process) }
    }
    return (processes, true)
  }

  /// Working directory of a process, or nil when lsof is unavailable/denied.
  ///
  /// A cwd of "/" is reported as unknown. Processes launched by launchd rather
  /// than from a shell inherit it, so it says "this was not started in a
  /// project" rather than naming one — and matching sessions on it groups
  /// unrelated agents together under a session labelled "/".
  static func cwd(of pid: Int32) async -> String? {
    guard
      let output = await Shell.run(
        "/usr/sbin/lsof",
        ["-a", "-p", String(pid), "-d", "cwd", "-Fn"],
        timeout: 8
      )
    else { return nil }

    for line in output.stdout.split(separator: "\n") where line.hasPrefix("n") {
      let path = line.dropFirst().trimmingCharacters(in: .whitespaces)
      if !path.isEmpty { return path == "/" ? nil : path }
    }
    return nil
  }

  /// Controlling terminal of a process, e.g. "ttys004".
  static func tty(of pid: Int32) async -> String? {
    guard let output = await Shell.run("/bin/ps", ["-o", "tty=", "-p", String(pid)], timeout: 5)
    else { return nil }
    let tty = output.trimmed
    return tty.isEmpty || tty == "??" ? nil : tty
  }

  /// Value of an environment variable in a *running* process, read via `ps -E`.
  ///
  /// This is how we identify the hosting terminal: `TERM_PROGRAM` is exported
  /// into the session's own environment and survives any process re-parenting,
  /// unlike walking the ppid chain.
  static func environmentValue(_ key: String, of pid: Int32) async -> String? {
    guard let output = await Shell.run("/bin/ps", ["-Eww", "-o", "command=", "-p", String(pid)], timeout: 5)
    else { return nil }

    // The environment is appended as space-separated KEY=value pairs.
    guard
      let range = output.stdout.range(
        of: "\(NSRegularExpression.escapedPattern(for: key))=([^\\s]*)",
        options: .regularExpression
      )
    else { return nil }

    let pair = output.stdout[range]
    guard let equals = pair.firstIndex(of: "=") else { return nil }
    let value = String(pair[pair.index(after: equals)...])
    return value.isEmpty ? nil : value
  }

  /// Parent process id, used to walk up toward a hosting terminal.
  static func parent(of pid: Int32) async -> (ppid: Int32, command: String)? {
    guard
      let output = await Shell.run("/bin/ps", ["-o", "ppid=,command=", "-p", String(pid)], timeout: 5)
    else { return nil }

    let fields = output.trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
    guard fields.count == 2, let ppid = Int32(fields[0]) else { return nil }
    return (ppid, fields[1].trimmingCharacters(in: .whitespaces))
  }
}

extension String {
  /// Case-insensitive regular-expression test.
  func matches(_ pattern: String) -> Bool {
    range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
  }
}
