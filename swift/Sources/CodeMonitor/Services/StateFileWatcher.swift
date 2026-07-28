/// Watches the directory hooks write their state files into (ADR-0008).
///
/// This is the half of ADR-0008 that survived ADR-0011. Watching transcripts
/// was abandoned because the transition that matters — a tool call going
/// *unanswered* — is the absence of an event, and no file system tells you
/// about those. A hook is the opposite: when one reports `PermissionRequest`
/// that *is* an event, it arrives in a small directory holding one small file
/// per session, and waiting for the next poll to notice it is pure latency.
///
/// It replaces no polling. The timer still has to run for everything the
/// filesystem cannot say (ADR-0011); this only removes the delay on the things
/// it can.

import Foundation

final class StateFileWatcher: @unchecked Sendable {
  /// Events arrive in bursts — the hook writes to a temp file and renames it,
  /// and several sessions can report within milliseconds of each other. A scan
  /// per event would be wasted work, so they are coalesced.
  private static let coalesce: TimeInterval = 0.08

  private let directory: URL
  private let queue = DispatchQueue(label: "codemonitor.statewatch")
  private var source: DispatchSourceFileSystemObject?
  private var descriptor: CInt = -1
  private var pending: DispatchWorkItem?

  /// Whether the watch is actually established. The poll cadence consults this:
  /// without a watch, a hook's report is only seen on the next scan, so the app
  /// cannot afford to idle as long.
  private(set) var isWatching = false

  init(directory: URL = HookStateStore.directory) {
    self.directory = directory
  }

  /// Starts watching, creating the directory if a hook has not run yet — an
  /// absent directory cannot be watched, and waiting for one to appear would
  /// mean polling for it.
  func start(onChange: @escaping @Sendable () -> Void) {
    stop()
    try? FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)

    descriptor = open(directory.path, O_EVTONLY)
    guard descriptor >= 0 else { return }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      // `.write` covers the rename a hook finishes with, which is what makes a
      // new report visible. `.delete`/`.rename` mean the directory itself went
      // away and the watch has to be rebuilt on a fresh descriptor.
      eventMask: [.write, .delete, .rename],
      queue: queue)

    source.setEventHandler { [weak self] in
      guard let self else { return }
      let events = source.data
      if events.contains(.delete) || events.contains(.rename) {
        // Rebuilt rather than resumed: the descriptor now refers to a
        // directory that is no longer at this path.
        self.start(onChange: onChange)
        onChange()
        return
      }
      self.pending?.cancel()
      let work = DispatchWorkItem { onChange() }
      self.pending = work
      self.queue.asyncAfter(deadline: .now() + Self.coalesce, execute: work)
    }

    source.setCancelHandler { [descriptor] in
      if descriptor >= 0 { close(descriptor) }
    }

    self.source = source
    isWatching = true
    source.resume()
  }

  func stop() {
    pending?.cancel()
    pending = nil
    source?.cancel()
    source = nil
    descriptor = -1
    isWatching = false
  }

  deinit { stop() }
}
