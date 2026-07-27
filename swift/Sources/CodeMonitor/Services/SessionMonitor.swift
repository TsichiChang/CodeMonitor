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
    HookStateStore.pruneAbandoned()
    start()
  }

  /// How long to wait when nothing is running.
  private static let quietInterval: TimeInterval = 15

  /// How long a dismissal is remembered. Long enough that closing a card is not
  /// quietly undone, short enough that the list cannot grow without bound.
  private static let dismissalLifetime: TimeInterval = 7 * 24 * 60 * 60

  /// The gap before the next scan, chosen from what the last one found.
  ///
  /// Only a `running` session changes on its own, so only a running session
  /// earns the fast cadence. `idle` and `waiting` are both static until the
  /// user does something, and polling them at full rate reflects nothing.
  ///
  /// This also keeps the one clock-driven transition sharp: a session becomes
  /// `waiting` by *not* being touched for long enough, and it is `running`
  /// right up until that moment — so the fast cadence is still in force when
  /// the threshold passes. Watching the filesystem could not do this; the
  /// signal is the absence of an event.
  private var nextDelay: TimeInterval {
    snapshot.counts.running > 0 ? interval : max(interval, Self.quietInterval)
  }

  func start() {
    pollTask?.cancel()
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.refresh()
        try? await Task.sleep(for: .seconds(self.nextDelay))
      }
    }
  }

  func stop() {
    pollTask?.cancel()
    pollTask = nil
  }

  func refresh() async {
    snapshot = applyDismissals(to: await scanner.scan())
  }

  // MARK: - Dismissal

  /// Sessions the user has closed, and how recently each had acted when they
  /// did. Persisted, so closing one survives a relaunch.
  @ObservationIgnored
  private var dismissed: [String: Date] = HookStateStore.loadDismissals()

  /// Hides a session until it does something new.
  ///
  /// Not a delete: the session still exists and its agent may still be sitting
  /// in a terminal. Recording *when* it was dismissed is what lets it come back
  /// on its own — a session that speaks again has stopped being the finished
  /// thing that was closed.
  func dismiss(_ session: SessionInfo) {
    dismissed[session.id] = session.lastActivity
    HookStateStore.saveDismissals(dismissed)
    snapshot = applyDismissals(to: snapshot)
  }

  func restoreAllDismissed() {
    dismissed.removeAll()
    HookStateStore.saveDismissals(dismissed)
    snapshot = applyDismissals(to: snapshot)
  }

  var dismissedCount: Int { dismissed.count }

  private func applyDismissals(to snapshot: SessionSnapshot) -> SessionSnapshot {
    guard !dismissed.isEmpty else { return snapshot }

    var revived = false
    var kept: [SessionInfo] = []
    for session in snapshot.sessions {
      guard let mark = dismissed[session.id] else { kept.append(session); continue }
      if session.lastActivity > mark {
        dismissed.removeValue(forKey: session.id)
        revived = true
        kept.append(session)
      }
    }
    // Entries expire by age, not by absence from the current scan. A session
    // can drop out of one scan and come back in the next — most easily the
    // process-derived cards, whose id changes with the pid — and pruning on
    // absence deleted the dismissal moments after it was made, so closing such
    // a card did nothing at all.
    let cutoff = Date().addingTimeInterval(-Self.dismissalLifetime)
    let expired = dismissed.filter { $0.value < cutoff }.map(\.key)
    for key in expired { dismissed.removeValue(forKey: key) }
    if revived || !expired.isEmpty { HookStateStore.saveDismissals(dismissed) }

    var counts = StateCounts()
    for session in kept { counts[session.state] += 1 }
    var result = snapshot
    result.sessions = kept
    result.counts = counts
    return result
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
      let (processes, _) = ProcessScanner.scan()
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
    let result = await TerminalFocus.focus(
      pid: pid, ttyHint: tty, cwd: session.projectPath,
      tabID: session.tabID, paneID: session.paneID)
    if !result.isOK { focusError = result.message }
    return result
  }
}
