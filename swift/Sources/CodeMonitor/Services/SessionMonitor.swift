/// Observable session state driving both the dashboard and the menu bar.
///
/// A single background poll feeds every view: the scanner refreshes on its own
/// cadence and publishes straight into SwiftUI, so nothing has to poll for a
/// snapshot the way the old renderer did.

import Foundation
import Observation

@MainActor
@Observable
final class SessionMonitor {
  private(set) var snapshot = SessionSnapshot.empty
  /// Set while a jump-to-terminal request is in flight, keyed by session id.
  private(set) var focusing: String?
  /// Surfaced to the UI when a jump fails; cleared on the next attempt.
  var focusError: String?

  @ObservationIgnored private let scanner = SessionScanner()
  @ObservationIgnored private var pollTask: Task<Void, Never>?
  @ObservationIgnored private var interval: TimeInterval = 2

  var refreshInterval: TimeInterval {
    get { interval }
    set {
      let clamped = min(max(newValue, 0.5), 60)
      guard clamped != interval else { return }
      interval = clamped
      UserDefaults.standard.set(clamped, forKey: "refreshInterval")
      if pollTask != nil { start() }
    }
  }

  init() {
    let stored = UserDefaults.standard.double(forKey: "refreshInterval")
    if stored >= 0.5, stored <= 60 { interval = stored }
    start()
  }

  func start() {
    pollTask?.cancel()
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.refresh()
        try? await Task.sleep(for: .seconds(self.interval))
      }
    }
  }

  func stop() {
    pollTask?.cancel()
    pollTask = nil
  }

  func refresh() async {
    snapshot = await scanner.scan()
  }

  /// Brings the terminal hosting a session to the front.
  ///
  /// Resolves the session's live process first, re-scanning when the cached
  /// snapshot carries no pid (a transcript-only session that has since gained a
  /// process, or one whose pid we never resolved).
  @discardableResult
  func focus(_ session: SessionInfo) async -> FocusResult {
    focusing = session.id
    focusError = nil
    defer { focusing = nil }

    var pid = session.pid
    var tty = session.tty
    if pid == nil {
      // Matched on the Project: an agent process stays in the directory it was
      // launched in even after the session moves elsewhere (ADR-0002).
      let (processes, _) = await ProcessScanner.scan()
      if let match = processes.first(where: {
        $0.tool == session.tool && $0.cwd == session.projectPath
      }) {
        pid = match.pid
        tty = match.tty
      }
    }

    // The terminal is matched on the Project instead: a tab's directory is
    // where its shell started the agent, and the shell does not follow the
    // agent around (ADR-0009).
    let result = await TerminalFocus.focus(pid: pid, ttyHint: tty, cwd: session.projectPath)
    if !result.isOK { focusError = result.message }
    return result
  }
}
