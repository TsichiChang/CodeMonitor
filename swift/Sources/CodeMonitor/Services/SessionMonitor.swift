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
  /// Driven from here rather than by observing this object: the band is AppKit
  /// and lives outside the SwiftUI graph, and this type already exists to feed
  /// the surfaces that show a snapshot.
  @ObservationIgnored private let band = AmbientBand()
  /// Turns a hook's report into an event instead of something to poll for
  /// (ADR-0008). It shortens no code — the timer still runs — it only removes
  /// the wait between a hook writing and the display noticing.
  @ObservationIgnored private let watcher = StateFileWatcher()
  /// Guards against a watch event and a timer tick scanning at once.
  @ObservationIgnored private var scanning = false

  var ambientBandEnabled: Bool {
    get { UserDefaults.standard.object(forKey: "ambientBand") as? Bool ?? true }
    set {
      UserDefaults.standard.set(newValue, forKey: "ambientBand")
      band.update(with: snapshot, enabled: newValue)
    }
  }

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

  /// - Parameter registersHotKey: only the running app may claim the shortcut.
  ///   A hot key is owned by one process at a time, so a CLI command that took
  ///   it — every diagnostic builds one of these — would leave the app unable
  ///   to register at launch, silently, for as long as that process lived.
  init(registersHotKey: Bool = false) {
    let stored = UserDefaults.standard.double(forKey: "refreshInterval")
    if stored >= 0.5, stored <= 60 { interval = stored }
    HookStateStore.pruneAbandoned()
    start()
    guard registersHotKey else { return }
    hotKey = GlobalHotKey { [weak self] in
      Task { await self?.focusNext() }
    }
  }

  // MARK: - Jump to the next session that needs you

  @ObservationIgnored private var hotKey: GlobalHotKey?
  @ObservationIgnored private var lastJumped: (id: String, at: Date)?

  /// How long a jump keeps its place in the queue.
  ///
  /// Press again inside this and it advances — "not that one, next". Come back
  /// later and it starts from the most urgent again, which by then is usually a
  /// different session, and is what a jump after any real pause should mean.
  private static let queueWindow: TimeInterval = 8

  /// Jumps to whatever most deserves attention, then to the next one, and so on.
  ///
  /// No selection is involved and none is displayed: arriving is what answers
  /// "which session?", so nothing on screen has to (ADR-0014).
  func focusNext() async {
    var previous = lastJumped.flatMap {
      Date().timeIntervalSince($0.at) < Self.queueWindow ? $0.id : nil
    }
    // Outside that window the queue restarts — but not onto the session already
    // in front of the user. Jumping to where they are looks identical to the
    // key doing nothing, and costs a second press to get anywhere.
    if previous == nil, let last = lastJumped?.id,
      let session = snapshot.sessions.first(where: { $0.id == last }),
      await TerminalFocus.isHostFrontmost(pid: session.pid)
    {
      previous = last
    }

    guard let target = snapshot.nextToHandle(after: previous) else { return }
    lastJumped = (target.id, Date())
    await focus(target)
  }

  var hotKeyDescription: String? {
    hotKey == nil ? nil : GlobalHotKey.displayName
  }

  /// How long to wait when nothing is running.
  private static let quietInterval: TimeInterval = 15

  /// How long a dismissal is remembered — and, for the same reasons, a visit.
  /// Long enough that closing or reading a card is not quietly undone, short
  /// enough that neither list can grow without bound. One constant rather than
  /// two, because the two maps age for identical reasons and a second number
  /// would only be a second thing to keep in step.
  nonisolated private static let dismissalLifetime: TimeInterval = 7 * 24 * 60 * 60

  /// The gap before the next scan, chosen from what the last one found.
  ///
  /// A `running` session changes on its own, so it earns the fast cadence: its
  /// transcript is being written and nothing announces that.
  ///
  /// A `waiting` one changes nothing on its own — but the ambient band is lit
  /// for as long as it waits, and the band going out is how the user sees that
  /// their answer registered; a late confirmation reads as a broken signal
  /// rather than as thrifty polling (ADR-0014). That bought waiting the fast
  /// cadence too, and it is what watching the state directory buys back: with a
  /// watch the hook's next report arrives as an event instead of being waited
  /// for (ADR-0008), so waiting can idle at the slow cadence again. Without one
  /// it cannot, and an unwatched machine keeps the old behaviour.
  ///
  /// The timer does not go away either way. A session becomes `waiting` by
  /// *not* being touched for long enough, and no filesystem reports the absence
  /// of an event — the conclusion of ADR-0011, and why the fast cadence has to
  /// stay in force while a running session approaches that threshold.
  private var nextDelay: TimeInterval {
    if snapshot.counts.running > 0 { return interval }
    if snapshot.counts.waiting > 0, !watcher.isWatching { return interval }
    return max(interval, Self.quietInterval)
  }

  func start() {
    pollTask?.cancel()
    watcher.start { [weak self] in
      Task { @MainActor in await self?.refresh() }
    }
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
    watcher.stop()
  }

  func refresh() async {
    // A burst of hook writes and the poll timer can both land here; the extra
    // scan would only reproduce the one already in flight.
    guard !scanning else { return }
    scanning = true
    defer { scanning = false }

    var fresh = applyDismissals(to: await scanner.scan())
    // Recorded before withholding, not after: a session held back on its first
    // sighting has to be in the set the next scan checks against, or it would
    // be withheld forever.
    let sighted = Set(fresh.sessions.map(\.id))
    fresh.sessions = Self.withholdingFirstSightings(
      fresh.sessions, seenBefore: previouslySeen)
    previouslySeen = sighted
    markTurnStarts(in: &fresh)
    markUnread(in: &fresh)
    // Sorted again: the scanner ordered these before anything knew what had
    // been read, and unread is a band of its own.
    fresh.sessions.sort(by: SessionInfo.inAttentionOrder)
    snapshot = fresh
    band.update(with: snapshot, enabled: ambientBandEnabled)
    Self.logSnapshot(snapshot)
  }

  /// Ids the previous scan saw, or nil before the first scan.
  @ObservationIgnored private var previouslySeen: Set<String>?
  /// Drops sessions being seen for the first time.
  ///
  /// Switching to an old conversation makes a desktop app load several sessions
  /// for a moment; each fires a hook or touches a transcript, becomes a card,
  /// and is gone one or two seconds later. Nothing about such a card can be
  /// acted on in the time it exists — it is motion and nothing else, on a
  /// display where motion is the expensive thing (ADR-0006).
  ///
  /// The cost is that a genuinely new session appears one scan late. That is
  /// two seconds while anything is running, and it buys the guarantee that
  /// everything on screen was there long enough to be worth reading.
  ///
  /// Nothing is remembered about *why* a session was withheld: it is simply not
  /// yet in the previous scan's set, which the next scan fixes on its own.
  nonisolated static func withholdingFirstSightings(
    _ sessions: [SessionInfo], seenBefore: Set<String>?
  ) -> [SessionInfo] {
    // The first scan of a launch has no previous set, and withholding
    // everything would leave the window empty for a cycle.
    guard let seenBefore else { return sessions }
    return sessions.filter { seenBefore.contains($0.id) }
  }

  /// Flags idle sessions that have acted since they were last visited.
  private func markUnread(in snapshot: inout SessionSnapshot) {
    for index in snapshot.sessions.indices {
      let session = snapshot.sessions[index]
      snapshot.sessions[index].isUnread =
        session.state == .idle && session.lastActivity > (visits[session.id] ?? .distantPast)
    }

    let kept = Self.retainedVisits(visits, now: Date())
    guard kept.count != visits.count else { return }
    visits = kept
    HookStateStore.saveVisits(visits)
  }

  /// Visits still worth remembering.
  ///
  /// **By age, never by absence from a scan**, and deliberately taking no
  /// session list so that it cannot do otherwise. Dropping visits to sessions
  /// missing from the current snapshot looked like tidy housekeeping and was
  /// the same defect the dismissal map had already been fixed for. It is worse
  /// here, because ADR-0021 made the absence *guaranteed*: a session that comes
  /// back is withheld for a scan first, so every returning session lost its
  /// visit, turned blue again, jumped back above the sessions already read, and
  /// re-entered the shortcut's queue — with no way to clear it but jumping a
  /// second time, since jumping is the only thing that counts as reading
  /// (ADR-0018).
  ///
  /// The window is the dismissal window for the same reason: long enough that a
  /// visit is not quietly forgotten, short enough that the map cannot grow
  /// without bound. Nothing listed can outlast it — a source stops reading a
  /// transcript at a day (`Aging.readHorizon`), so a week-old visit belongs to
  /// a session that cannot be on screen.
  nonisolated static func retainedVisits(
    _ visits: [String: Date], now: Date
  ) -> [String: Date] {
    let cutoff = now.addingTimeInterval(-dismissalLifetime)
    return visits.filter { $0.value >= cutoff }
  }

  /// Appends what this scan saw, when `snapshotLog` is set in defaults.
  ///
  /// Off by default and diagnostic only. It exists because `--diagnose` cannot
  /// answer questions about the running app: it is a separate process that
  /// scans again, so a card that appeared for one cycle is already gone by the
  /// time it looks. This records the snapshot the display was actually built
  /// from.
  private static func logSnapshot(_ snapshot: SessionSnapshot) {
    guard UserDefaults.standard.bool(forKey: "snapshotLog") else { return }
    let url = HookStateStore.directory
      .deletingLastPathComponent().appending(path: "snapshots.log")
    let stamp = snapshot.generatedAt.formatted(date: .omitted, time: .standard)
    let rows = snapshot.sessions.map {
      "\($0.project)|\($0.id)|\($0.evidence.source.rawValue)|\($0.evidence.activity.rawValue)"
    }
    let line = "\(stamp) \(rows.joined(separator: "  "))\n"
    guard let data = line.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
    } else {
      try? data.write(to: url)
    }
  }

  // MARK: - Turn starts

  /// When each in-flight turn began, for the sessions currently running one.
  ///
  /// Kept here rather than derived from evidence because it cannot be: a
  /// running session's transcript says when it last wrote, and reaching back
  /// to the start of the turn means reading a third of a megabyte per session
  /// per scan — measured at p50 296 KB against a 64 KB tail window.
  ///
  /// This does not reintroduce what ADR-0012 removed. State is still derived
  /// from evidence on every scan and never from its own previous value; this
  /// map is read only by the label on a card, so a wrong entry shows one
  /// wrong number and cannot spread into a state, a lifetime or a poll rate.
  @ObservationIgnored private var turnStarts: [String: Date] = [:]

  /// A turn starts when a session begins running and ends when it goes idle.
  ///
  /// Waiting deliberately keeps the existing start: approving a permission
  /// prompt resumes the same turn, and the time spent waiting on you is part
  /// of how long the task has taken. Only `idle → running` opens a new one.
  private func markTurnStarts(in snapshot: inout SessionSnapshot) {
    let now = Date()
    var live: Set<String> = []

    for index in snapshot.sessions.indices {
      let session = snapshot.sessions[index]
      live.insert(session.id)

      switch session.state {
      case .running:
        // Absent means the previous state was idle, or this is the first sight
        // of the session — a relaunch mid-task therefore starts counting from
        // now, understating rather than inventing a duration.
        let start = turnStarts[session.id] ?? now
        turnStarts[session.id] = start
        snapshot.sessions[index].stateSince = start
      case .waiting:
        snapshot.sessions[index].stateSince = session.lastActivity
      case .idle:
        turnStarts.removeValue(forKey: session.id)
        snapshot.sessions[index].stateSince = session.lastActivity
      }
    }

    turnStarts = turnStarts.filter { live.contains($0.key) }
  }

  // MARK: - Dismissal

  /// Sessions the user has closed, and how recently each had acted when they
  /// did. Persisted, so closing one survives a relaunch.
  @ObservationIgnored
  private var dismissed: [String: Date] = HookStateStore.loadDismissals()

  /// When each session was last jumped to, for deciding what is still unread.
  @ObservationIgnored
  private var visits: [String: Date] = HookStateStore.loadVisits()

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

    var result = snapshot
    result.sessions = kept
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

    // Going there is what counts as reading it. Recorded before the jump is
    // attempted: the intent to look is what the mark is about, and a jump that
    // lands in the wrong tab still means the user went looking.
    visits[session.id] = Date()
    HookStateStore.saveVisits(visits)
    if let index = snapshot.sessions.firstIndex(where: { $0.id == session.id }) {
      snapshot.sessions[index].isUnread = false
    }

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
      tabID: session.tabID, paneID: session.paneID,
      hostBundleID: session.hostBundleID)
    if !result.isOK { focusError = result.message }
    return result
  }
}
