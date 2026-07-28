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
  /// When the process was launched.
  ///
  /// The only honest timestamp available for a session known solely by its
  /// process. Using "now" instead made such a card permanently fresh: it could
  /// never age out, and dismissing it undid itself on the next scan, because
  /// the card looked like it had just acted.
  var started: Date
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

  /// Interpreters that run an agent as a script, so the name lands one word
  /// later. Matching stops after these two positions either way.
  private static let interpreters = ["node", "bun", "deno", "python", "python3", "sh", "zsh", "bash"]

  /// The part of an argument vector allowed to identify a tool: the executable,
  /// and the script after it when the executable is an interpreter.
  ///
  /// The rest is excluded, and that is the whole point. Tested against the
  /// whole line, any process merely *mentioning* an agent became one — Claude
  /// Code's own Bash tool spawns a shell per command, in the session's current
  /// directory, so `ls /tmp/claude` in this repo minted a card titled `swift`
  /// that lived as long as the command (ADR-0016).
  static func identifyingPrefix(of arguments: [String]) -> String {
    guard let first = arguments.first else { return "" }
    let name = first.split(separator: "/").last.map(String.init) ?? first
    guard interpreters.contains(name), arguments.count > 1 else { return first }
    return "\(first) \(arguments[1])"
  }

  static func tool(forArguments arguments: [String]) -> ToolKind? {
    let command = identifyingPrefix(of: arguments)
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
      guard let argv = arguments(pid), let tool = tool(forArguments: argv) else { continue }
      processes.append(
        LiveProcess(
          tool: tool,
          pid: pid,
          tty: tty(of: pid),
          cwd: cwd(of: pid),
          started: startTime(of: pid) ?? Date()
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

  /// Whether a pid names a process that still exists.
  static func isRunning(_ pid: pid_t) -> Bool {
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.size
    let read = withUnsafeMutablePointer(to: &info) {
      proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(size))
    }
    return read == Int32(size)
  }

  /// When a process was launched.
  static func startTime(of pid: pid_t) -> Date? {
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.size
    let read = withUnsafeMutablePointer(to: &info) {
      proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(size))
    }
    guard read == Int32(size), info.pbi_start_tvsec > 0 else { return nil }
    return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec))
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

  // A process's command line does *not* identify its session, however much the
  // `--resume <uuid>` argument looks like it does. Resuming starts a new
  // session whose transcript is a new file; the uuid in argv names the one it
  // continued from. Observed directly: a process running `--resume f720c441…`
  // was reported by its own hook as session 78c0e05f…, and the f720c441
  // transcript had been untouched for seventeen hours while 78c0e05f grew to
  // 1373 lines. Matching on argv attached the live pid to the dead session,
  // which then never aged out.
  //
  // Only a hook can say which session a process is running (ADR-0010).

  // MARK: - KERN_PROCARGS2

  /// The command line of a process, or nil when it is not ours to read.
  static func commandLine(_ pid: pid_t) -> String? {
    arguments(pid)?.joined(separator: " ")
  }

  /// The real argument vector, with its boundaries intact.
  ///
  /// Identification must use this rather than the joined string: an executable
  /// path may contain spaces, and Claude Desktop's does —
  /// `…/Library/Application Support/Claude/…/claude`. Splitting the joined form
  /// on spaces cut `argv[0]` at `…/Library/Application`, and the session
  /// stopped being recognised at all.
  static func arguments(_ pid: pid_t) -> [String]? {
    guard let strings = processStrings(pid, stoppingAfterArguments: true) else { return nil }
    return Array(strings.values.prefix(strings.argc))
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
