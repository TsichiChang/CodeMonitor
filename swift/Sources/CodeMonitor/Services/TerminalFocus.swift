/// Focus the terminal window/tab hosting a coding-agent session.
///
/// Identifying the host is done via the session's own `TERM_PROGRAM`
/// environment variable rather than by walking the process tree. Terminals
/// like Otty spawn shells from a daemon/CLI layer that is re-parented away from
/// the GUI process, so the ppid chain never reaches them — but the exported
/// environment always travels with the session.
///
/// Per-host tab selection:
///  - Otty:              `otty-cli tab focus` over its control socket.
///                       Otty's AppleScript dictionary declares a `tty` property
///                       but returns an empty string for it, so tty-based tab
///                       matching can never succeed there — the CLI is the only
///                       working path. It also needs no Automation permission.
///  - Terminal.app/iTerm: AppleScript, matching the tab whose tty equals ours
///                       (prompts for Automation permission the first time).
///  - Anything else:      bring the app to the front via `open -b`.

import AppKit
import Foundation

enum TerminalFocus {
  // MARK: - Known terminals

  struct TerminalApp: Sendable {
    /// Tested against the full `ps` command line (case-insensitive regex).
    let commandPattern: String
    /// Value this terminal exports as TERM_PROGRAM, when it sets one.
    let termProgram: String?
    /// AppleScript application name.
    let appName: String
    let bundleID: String
    let kind: Kind

    enum Kind: Sendable {
      case terminal
      case iterm
      case otty
      case generic
    }
  }

  /// Ordered most-specific first.
  static let terminals: [TerminalApp] = [
    .init(
      commandPattern: "iTerm\\.app|iTerm2", termProgram: "iTerm.app",
      appName: "iTerm", bundleID: "com.googlecode.iterm2", kind: .iterm),
    .init(
      commandPattern: "Terminal\\.app", termProgram: "Apple_Terminal",
      appName: "Terminal", bundleID: "com.apple.Terminal", kind: .terminal),
    .init(
      commandPattern: "[/\\s]Otty(\\s|$)", termProgram: "otty",
      appName: "Otty", bundleID: "io.appmakes.otty", kind: .otty),
    .init(
      commandPattern: "WezTerm|wezterm", termProgram: "WezTerm",
      appName: "WezTerm", bundleID: "com.github.wez.wezterm", kind: .generic),
    .init(
      commandPattern: "Ghostty", termProgram: "ghostty",
      appName: "Ghostty", bundleID: "com.mitchellh.ghostty", kind: .generic),
    .init(
      commandPattern: "kitty", termProgram: nil,
      appName: "kitty", bundleID: "net.kovidgoyal.kitty", kind: .generic),
    .init(
      commandPattern: "Alacritty", termProgram: nil,
      appName: "Alacritty", bundleID: "org.alacritty", kind: .generic),
    .init(
      commandPattern: "Warp\\.app|stable/warp", termProgram: "WarpTerminal",
      appName: "Warp", bundleID: "dev.warp.Warp-Stable", kind: .generic),
    .init(
      commandPattern: "Hyper\\.app", termProgram: "Hyper",
      appName: "Hyper", bundleID: "co.zeit.hyper", kind: .generic),
    .init(
      commandPattern: "Visual Studio Code|Code Helper|/Code\\.app", termProgram: "vscode",
      appName: "Visual Studio Code", bundleID: "com.microsoft.VSCode", kind: .generic),
  ]

  // MARK: - Entry point

  static func focus(pid: Int32?, ttyHint: String?, cwd: String) async -> FocusResult {
    guard let pid else { return .noProcess }

    var tty = ttyHint
    if tty == nil { tty = ProcessScanner.tty(of: pid) }
    let devTTY = normalizeTTY(tty)

    // With a known host we address it directly — no probing other terminals,
    // which would other­wise trigger their Automation permission prompts for
    // nothing.
    if let host = await identifyHost(pid: pid) {
      switch host.kind {
      case .otty:
        if await focusOttyTab(cwd: cwd) { return .ok }
      case .terminal, .iterm:
        if let devTTY, let script = selectionScript(for: host.kind, devTTY: devTTY),
          await runAppleScript(script) == "matched"
        {
          return .ok
        }
      case .generic:
        break  // no scripting support — activation is the best we can do
      }
      // Precise selection unavailable (or permission denied): at least raise
      // the hosting app.
      return await activate(bundleID: host.bundleID) ? .ok : .activateFailed
    }

    // Host unknown (a terminal exporting no TERM_PROGRAM and hidden from the
    // process tree): fall back to asking each scriptable terminal whether it
    // owns a tab with this tty. tty is unique, so non-hosts answer "nomatch"
    // without activating.
    if let devTTY {
      for candidate in terminals where selectionScript(for: candidate.kind, devTTY: devTTY) != nil {
        guard await isRunning(bundleID: candidate.bundleID),
          let script = selectionScript(for: candidate.kind, devTTY: devTTY)
        else { continue }
        if await runAppleScript(script) == "matched" { return .ok }
      }
    }
    return .unknownTerminal
  }

  // MARK: - Host identification

  /// Identifies the hosting terminal, preferring the session's exported
  /// `TERM_PROGRAM` and falling back to a ppid walk for terminals that set none.
  private static func identifyHost(pid: Int32) async -> TerminalApp? {
    if let termProgram = ProcessScanner.environmentValue("TERM_PROGRAM", of: pid),
      let match = terminals.first(where: {
        $0.termProgram?.caseInsensitiveCompare(termProgram) == .orderedSame
      })
    {
      return match
    }
    return await findHostByProcessTree(pid: pid)
  }

  private static func findHostByProcessTree(pid: Int32) async -> TerminalApp? {
    var current = pid
    for _ in 0..<12 where current > 1 {
      guard let (ppid, command) = ProcessScanner.parent(of: current) else { return nil }
      if let match = terminals.first(where: { command.matches($0.commandPattern) }) {
        return match
      }
      guard ppid > 1 else { return nil }
      current = ppid
    }
    return nil
  }

  // MARK: - Otty (control socket)

  private static let ottyBundleID = "io.appmakes.otty"

  private struct OttyTab: Decodable {
    let id: String
    let cwd: String?
    let active: Bool?
    let index: Int?
    let title: String?
  }

  private struct OttyResponse: Decodable {
    let ok: Bool?
    let data: [OttyTab]?
  }

  /// Path to the `otty-cli` shipped inside Otty.app, wherever it is installed.
  private static func ottyCLIPath() async -> String? {
    guard
      let appURL = await MainActor.run(body: {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: ottyBundleID)
      })
    else { return nil }
    let cli = appURL.appending(path: "Contents/MacOS/otty-cli")
    return FileManager.default.isExecutableFile(atPath: cli.path) ? cli.path : nil
  }

  /// Selects the Otty tab whose shell sits in `cwd`, then brings Otty forward.
  ///
  /// Matching is by working directory: Otty exposes no per-tab tty or pid, and
  /// its AppleScript `tty` property — the one thing that would disambiguate —
  /// always returns an empty string. A single cwd match is exact, which covers
  /// the normal case of one agent per project.
  private static func focusOttyTab(cwd: String) async -> Bool {
    guard await isRunning(bundleID: ottyBundleID), let cli = await ottyCLIPath() else {
      return false
    }
    guard
      let listed = await Shell.run(cli, ["tab", "list", "--json"], timeout: 5),
      listed.succeeded,
      let data = listed.stdout.data(using: .utf8),
      let response = try? JSONDecoder().decode(OttyResponse.self, from: data),
      let tabs = response.data,
      let target = pickOttyTab(from: tabs, cwd: cwd)
    else { return false }

    guard
      let focused = await Shell.run(cli, ["tab", "focus", "--tab", target.id], timeout: 5),
      focused.succeeded
    else { return false }

    return await activate(bundleID: ottyBundleID)
  }

  /// Chooses the best tab for `cwd`: exact matches first, then a tab sitting in
  /// a subdirectory of it.
  ///
  /// When several tabs share a cwd they are genuinely indistinguishable over
  /// the CLI, so we prefer one carrying a title — Otty's agent integration
  /// badges tabs running an agent, making a titled tab the likelier host — and
  /// fall back to the lowest index. Worst case we land on the right project in
  /// the wrong tab, rather than not moving at all.
  private static func pickOttyTab(from tabs: [OttyTab], cwd: String) -> OttyTab? {
    var candidates = tabs.filter { $0.cwd == cwd }
    if candidates.isEmpty {
      candidates = tabs.filter { $0.cwd?.hasPrefix(cwd + "/") == true }
    }
    guard candidates.count > 1 else { return candidates.first }

    return candidates.min { lhs, rhs in
      let lhsTitled = !(lhs.title ?? "").trimmingCharacters(in: .whitespaces).isEmpty
      let rhsTitled = !(rhs.title ?? "").trimmingCharacters(in: .whitespaces).isEmpty
      if lhsTitled != rhsTitled { return lhsTitled }
      return (lhs.index ?? .max) < (rhs.index ?? .max)
    }
  }

  // MARK: - AppleScript tab selection

  private static func selectionScript(for kind: TerminalApp.Kind, devTTY: String) -> String? {
    switch kind {
    case .terminal:
      """
      tell application "Terminal"
        repeat with w in windows
          repeat with t in tabs of w
            try
              if (tty of t) is "\(devTTY)" then
                set selected tab of w to t
                try
                  set index of w to 1
                end try
                activate
                return "matched"
              end if
            end try
          end repeat
        end repeat
      end tell
      return "nomatch"
      """
    case .iterm:
      """
      tell application "iTerm"
        repeat with w in windows
          repeat with t in tabs of w
            repeat with s in sessions of t
              try
                if (tty of s) is "\(devTTY)" then
                  select s
                  select t
                  tell w to select
                  activate
                  return "matched"
                end if
              end try
            end repeat
          end repeat
        end repeat
      end tell
      return "nomatch"
      """
    // Otty declares a `tty` property but always returns "", so AppleScript tab
    // matching is impossible; it is handled through otty-cli instead.
    case .otty, .generic:
      nil
    }
  }

  private static func runAppleScript(_ script: String) async -> String? {
    guard let output = await Shell.run("/usr/bin/osascript", ["-e", script], timeout: 10),
      output.succeeded
    else { return nil }
    return output.trimmed
  }

  // MARK: - App activation

  private static func isRunning(bundleID: String) async -> Bool {
    await MainActor.run {
      !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
  }

  @discardableResult
  private static func activate(bundleID: String) async -> Bool {
    let activated = await MainActor.run {
      NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .first?
        .activate(options: [.activateAllWindows]) ?? false
    }
    if activated { return true }
    let output = await Shell.run("/usr/bin/open", ["-b", bundleID], timeout: 10)
    return output?.succeeded ?? false
  }

  private static func normalizeTTY(_ tty: String?) -> String? {
    guard let tty, !tty.isEmpty else { return nil }
    return tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
  }
}
