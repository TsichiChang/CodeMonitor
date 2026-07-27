/// Live-process discovery through libproc, without spawning anything.
///
/// This used to shell out to `ps -axww` and one `lsof` per agent, costing about
/// 115ms of a poll. The same information comes from `proc_listpids`,
/// `KERN_PROCARGS2` and `proc_pidinfo` in roughly 4ms, so process state can be
/// read on every cycle rather than being rationed (ADR-0003).
///
/// Everything degrades quietly: reading another user's process is denied, which
/// simply means it is not one of ours.

import Darwin
import Foundation

struct LiveProcess: Sendable {
  let tool: ToolKind
  let pid: Int32
  let tty: String?
  var cwd: String?
  /// Session UUID recovered from the command line, when it is trustworthy.
  var sessionID: String?
}

enum ProcessScanner {
  /// The CLIs run either as native binaries or as wrapped scripts, so both the
  /// bare command and the package-path forms are matched.
  private static let toolPatterns: [(ToolKind, [String])] = [
    (.codex, ["(?:^|/)codex(?:\\s|$)", "codex-cli", "openai[-/].*codex"]),
    (.opencode, ["(?:^|/)opencode(?:\\s|$)", "opencode[-/]"]),
    (
      .claude,
      ["(?:^|/)claude(?:\\s|$)", "claude-code", "anthropic[-/].*claude", "\\.claude/local/"]
    ),
  ]

  /// Cheap literal that must appear before a tool's patterns are worth running.
  private static let toolHints: [(ToolKind, String)] = [
    (.codex, "codex"), (.opencode, "opencode"), (.claude, "claude"),
  ]

  static func tool(forCommand command: String) -> ToolKind? {
    // Reject on a literal substring first: almost no process mentions any of
    // these, and `.regularExpression` recompiles its pattern on every call.
    //
    // The literal test is done over raw bytes rather than with
    // `range(of:options:.caseInsensitive)`, which bridges to NSString and folds
    // case with locale awareness. Across every process on the machine that one
    // call was the single most expensive thing in a scan — about 36ms against
    // 0.6ms for the equivalent byte scan.
    for (tool, hint) in toolHints {
      guard command.containsASCIICaseInsensitive(hint) else { continue }
      guard let patterns = toolPatterns.first(where: { $0.0 == tool })?.1 else { continue }
      for pattern in patterns where command.matches(pattern) {
        return tool
      }
    }
    return nil
  }

  // MARK: - Scan

  static func scan() -> (processes: [LiveProcess], ok: Bool) {
    let pids = allPIDs()
    guard !pids.isEmpty else { return ([], false) }

    var processes: [LiveProcess] = []
    for pid in pids where pid > 0 {
      // Only the command line here. Parsing each process's environment as well
      // costs more than the `ps`/`lsof` calls this replaced — a few hundred
      // readable processes with dozens of variables each — and the environment
      // is wanted for exactly one process, at jump time.
      guard let command = commandLine(pid), let tool = tool(forCommand: command) else { continue }
      processes.append(
        LiveProcess(
          tool: tool,
          pid: pid,
          tty: tty(of: pid),
          cwd: cwd(of: pid),
          sessionID: sessionID(fromCommand: command)
        )
      )
    }
    return (processes, true)
  }

  private static func allPIDs() -> [pid_t] {
    var size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
    guard size > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.size)
    size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, size)
    guard size > 0 else { return [] }
    return Array(pids.prefix(Int(size) / MemoryLayout<pid_t>.size))
  }

  // MARK: - Per-process reads

  /// Working directory of a process.
  ///
  /// "/" is reported as unknown: processes launched by launchd rather than from
  /// a shell inherit it, so it says "not started in a project" rather than
  /// naming one, and matching sessions on it would group unrelated agents.
  static func cwd(of pid: pid_t) -> String? {
    var info = proc_vnodepathinfo()
    let size = MemoryLayout<proc_vnodepathinfo>.size
    let read = withUnsafeMutablePointer(to: &info) {
      proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0, Int32(size))
    }
    guard read == Int32(size) else { return nil }

    let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
      $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
    }
    return path.isEmpty || path == "/" ? nil : path
  }

  /// Controlling terminal of a process, e.g. "ttys004".
  static func tty(of pid: pid_t) -> String? {
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.size
    let read = withUnsafeMutablePointer(to: &info) {
      proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(size))
    }
    guard read == Int32(size), info.e_tdev != UInt32.max else { return nil }
    guard let name = devname(dev_t(info.e_tdev), S_IFCHR) else { return nil }
    let tty = String(cString: name)
    return tty.isEmpty ? nil : tty
  }

  /// Value of an environment variable in a running process.
  ///
  /// This is how the hosting terminal is identified: `TERM_PROGRAM` is exported
  /// into the session's own environment and survives any re-parenting, unlike
  /// walking the ppid chain (which never reaches terminals that spawn their
  /// shells from a daemon).
  static func environmentValue(_ key: String, of pid: pid_t) -> String? {
    guard let strings = processStrings(pid) else { return nil }
    let prefix = "\(key)="
    for entry in strings.values.dropFirst(strings.argc) where entry.hasPrefix(prefix) {
      return String(entry.dropFirst(prefix.count))
    }
    return nil
  }

  /// Parent process id and command, for terminals that export no TERM_PROGRAM.
  static func parent(of pid: pid_t) -> (ppid: pid_t, command: String)? {
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.size
    let read = withUnsafeMutablePointer(to: &info) {
      proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(size))
    }
    guard read == Int32(size) else { return nil }
    let ppid = pid_t(info.pbi_ppid)
    return (ppid, commandLine(ppid) ?? "")
  }

  // MARK: - Session id from the command line

  /// The session UUID a process was resumed with, when it identifies *this*
  /// session.
  ///
  /// `--fork-session` disqualifies it: a forked session's argv names the
  /// session it forked *from*, so using it would attach a process to somebody
  /// else's session — worse than having no id at all.
  static func sessionID(fromCommand command: String) -> String? {
    guard !command.contains("--fork-session") else { return nil }
    guard
      let range = command.range(
        of: "--resume[= ]([0-9a-fA-F-]{36})", options: .regularExpression)
    else { return nil }
    return String(command[range].suffix(36))
  }

  // MARK: - KERN_PROCARGS2

  /// The command line of a process, or nil when it is not ours to read.
  static func commandLine(_ pid: pid_t) -> String? {
    guard let strings = processStrings(pid, stoppingAfterArguments: true) else { return nil }
    return strings.values.prefix(strings.argc).joined(separator: " ")
  }

  private struct ProcStrings {
    let argc: Int
    /// `argc` arguments, then the environment as `KEY=value` entries.
    let values: [String]
  }

  /// Reads a process's argv and environment in one syscall.
  ///
  /// Layout: `argc`, the executable path, alignment padding, `argc`
  /// NUL-terminated arguments, then the environment as `KEY=value` strings.
  ///
  /// `stoppingAfterArguments` exists because the scan reads every process on
  /// the machine but wants only the command line; decoding each one's whole
  /// environment as well dominated the scan.
  private static func processStrings(
    _ pid: pid_t, stoppingAfterArguments: Bool = false
  ) -> ProcStrings? {
    var size = 0
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
      return nil
    }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

    var argc: Int32 = 0
    memcpy(&argc, buffer, MemoryLayout<Int32>.size)
    guard argc > 0 else { return nil }

    var index = MemoryLayout<Int32>.size
    while index < size, buffer[index] != 0 { index += 1 }  // executable path
    while index < size, buffer[index] == 0 { index += 1 }  // padding

    var strings: [String] = []
    var current: [CChar] = []
    while index < size {
      if buffer[index] == 0 {
        if !current.isEmpty {
          strings.append(String(decoding: current.map(UInt8.init(bitPattern:)), as: UTF8.self))
          current.removeAll(keepingCapacity: true)
          if stoppingAfterArguments, strings.count == Int(argc) { break }
        }
      } else {
        current.append(buffer[index])
      }
      index += 1
    }
    guard !strings.isEmpty else { return nil }
    return ProcStrings(argc: min(Int(argc), strings.count), values: strings)
  }
}

extension String {
  /// Case-insensitive regular-expression test.
  func matches(_ pattern: String) -> Bool {
    range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
  }

  /// Whether this string contains `needle`, comparing ASCII letters without
  /// regard to case and without bridging to NSString.
  ///
  /// `needle` must be lowercase ASCII: the fold is a single OR, which maps
  /// A–Z onto a–z and leaves anything already lowercase alone.
  func containsASCIICaseInsensitive(_ needle: String) -> Bool {
    let pattern = Array(needle.utf8)
    guard !pattern.isEmpty else { return true }
    let text = Array(utf8)
    guard text.count >= pattern.count else { return false }

    for start in 0...(text.count - pattern.count) {
      var matched = true
      for offset in 0..<pattern.count where (text[start + offset] | 0x20) != pattern[offset] {
        matched = false
        break
      }
      if matched { return true }
    }
    return false
  }
}
