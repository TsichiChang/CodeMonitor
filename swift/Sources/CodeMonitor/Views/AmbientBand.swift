/// A glow along the bottom edge of every screen while a session waits.
///
/// The one surface that works when the dashboard is not being looked at
/// (ADR-0014). It says that something is waiting and how long it has been —
/// never which session, because identity costs a glance and avoiding that
/// glance is the whole point. Getting to the session is the shortcut's job.
///
/// Deliberately not SwiftUI: this has to sit above full-screen apps on every
/// display at once, pass clicks through, and never take focus. Those are
/// `NSWindow` properties with no SwiftUI equivalent.
///
/// Numbers here were found by looking, not chosen — `tools/band-probe.swift`
/// is the same band standing alone, for tuning them without a rebuild.

import AppKit
import SwiftUI

@MainActor
final class AmbientBand {
  /// Waits at or beyond this read as maximally urgent. Sits above the measured
  /// median wait of 1.3 minutes, so an ordinary context switch never drives the
  /// band to the top of its range.
  private static let urgencyCeiling: TimeInterval = 180

  private var windows: [NSWindow] = []
  private var views: [BandView] = []
  private var ticker: Timer?

  init() {
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.rebuild() }
    }
  }

  /// Shows, hides, and paces the band from the latest scan.
  func update(with snapshot: SessionSnapshot, enabled: Bool) {
    let now = Date()
    // Every `waiting` drives it, because every `waiting` was reported: exactly
    // one source can produce `blockedOnUser` (ADR-0020). This used to carry a
    // second condition excluding guessed blocks, from when silence for 45
    // seconds could invent one.
    let longest = snapshot.sessions
      .filter { $0.state == .waiting }
      .map { now.timeIntervalSince($0.lastActivity) }
      .max()

    guard enabled, let longest else { return teardown() }

    if windows.isEmpty { build() }
    let urgency = min(1, max(0, longest / Self.urgencyCeiling))
    for view in views { view.urgency = urgency }
  }

  // MARK: - Windows

  private func build() {
    for screen in NSScreen.screens {
      let window = NSWindow(
        contentRect: screen.frame, styleMask: .borderless,
        backing: .buffered, defer: false)
      window.setFrame(screen.frame, display: true)
      // Above full-screen apps: `.screenSaver` clears them, and
      // `.fullScreenAuxiliary` + `.canJoinAllSpaces` keeps it there when the
      // Space flips.
      window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
      window.collectionBehavior = [
        .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
      ]
      window.isOpaque = false
      window.backgroundColor = .clear
      window.ignoresMouseEvents = true
      window.hasShadow = false

      let view = BandView(frame: CGRect(origin: .zero, size: screen.frame.size))
      window.contentView = view
      // Ordered in without activating: this app never comes to the front for it.
      window.orderFrontRegardless()

      windows.append(window)
      views.append(view)
    }

    guard !views.isEmpty else { return }
    let tick = 1.0 / BandView.fps
    ticker = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        for view in self.views { view.advance(by: tick) }
      }
    }
  }

  private func teardown() {
    ticker?.invalidate()
    ticker = nil
    for window in windows { window.orderOut(nil) }
    windows.removeAll()
    views.removeAll()
  }

  /// Screens came or went. Rebuild rather than reconcile — the band holds no
  /// state worth preserving across a display change.
  private func rebuild() {
    guard !windows.isEmpty else { return }
    let urgency = views.first?.urgency ?? 0
    teardown()
    build()
    for view in views { view.urgency = urgency }
  }
}

// MARK: - Drawing

/// The glow itself. Both its opacity and its height breathe.
private final class BandView: NSView {
  static let fps = 30.0

  var urgency: CGFloat = 0
  private var phase: CGFloat = 0

  func advance(by seconds: Double) {
    // Faster as the wait drags on, bracketing the 1.2s a waiting card uses so
    // one urgency reads the same on both surfaces.
    let period = 1.8 - 0.8 * urgency
    phase += (2 * .pi) * CGFloat(seconds) / CGFloat(period)
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }

    // A still band was invisible in testing, so motion is not optional here —
    // but neither is honouring the setting that asks for none. Reduced motion
    // gets the peak, held.
    let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let breath: CGFloat = still ? 1 : 0.5 + 0.5 * sin(phase)

    // Both ranges are wider than they look like they need to be. A contrast
    // that is unmistakable side by side is nearly invisible spread over a
    // 1.2s fade — the same lesson Theme.swift records for card tints — and
    // peripheral vision answers to a moving boundary long before a changing
    // brightness (ADR-0006). The first two attempts, narrow and with a fixed
    // edge, went unnoticed entirely.
    let alpha = (0.09 + 0.10 * urgency) + (0.45 + 0.19 * urgency) * breath
    let height = (10 + 4 * urgency) + (24 + 8 * urgency) * breath

    let amber = NSColor(Palette.statusWaiting).withAlphaComponent(alpha).cgColor
    guard let clear = amber.copy(alpha: 0),
      let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [amber, clear] as CFArray, locations: [0, 1])
    else { return }

    ctx.saveGState()
    ctx.clip(to: CGRect(x: 0, y: 0, width: bounds.width, height: height))
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])
    ctx.restoreGState()
  }
}
