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
/// Not SwiftUI does not mean not Core Animation, and for a while it was taken
/// to. The breathing was a 30fps timer setting `needsDisplay` on a
/// screen-sized view, which redrew a gradient on the CPU every frame, on every
/// display. Measured with `tools/band-probe.swift`: **11.5% of a core while
/// lit** — nearly twice what the two-second poll cost before ADR-0008 replaced
/// it, and 165 times what ADR-0008 measured for the dashboard's own breathing
/// cards, which are driven on the compositor. That measurement predated the
/// band, so this cost had never been in one.
///
/// It is now a `CAGradientLayer` built once at its tallest, with opacity and a
/// vertical scale animated by Core Animation. Nothing is drawn per frame and
/// there is no timer at all.
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
    // Every `waiting` drives it, because every `waiting` was reported. This used
    // to carry a second condition excluding guessed blocks, from when silence
    // for 45 seconds could invent one (ADR-0020).
    //
    // The reason first written here was "exactly one source can produce
    // `blockedOnUser`", which ADR-0024 made false: a usage limit reports one
    // too, from the transcript. The condition that matters survived the change —
    // no source *guesses* a block — so the band still lights for all of them,
    // including the limit stalls it could not see before.
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
  }

  private func teardown() {
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
///
/// The layer is built once at the tallest and brightest the band ever gets, and
/// the breath is expressed as a fraction of that: `opacity` for the tint, a
/// vertical `transform.scale` anchored at the screen edge for the height. Both
/// are properties Core Animation interpolates in the render server, so the
/// breathing costs no per-frame work in this process — which is the whole point
/// of the change, and the same mechanism the dashboard's cards already ran on
/// when ADR-0008 measured them at 0.07%.
private final class BandView: NSView {
  /// The band at full urgency, at the top of a breath. Everything else is this
  /// scaled down, so the geometry is computed once instead of per frame.
  private static let maxHeight: CGFloat = 46
  private static let maxAlpha: CGFloat = 0.83

  private let glow = CAGradientLayer()

  var urgency: CGFloat = 0 {
    didSet { breathe() }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    // Nothing is ever drawn into this view, so AppKit should not keep a backing
    // store for it — the sublayer is the entire contents.
    layerContentsRedrawPolicy = .never

    let amber = NSColor(Palette.statusWaiting)
    glow.colors = [amber.withAlphaComponent(1).cgColor, amber.withAlphaComponent(0).cgColor]
    // Unit coordinates in an unflipped layer: (0.5, 0) is the bottom edge, which
    // is where the light comes from. A hard line reads as a UI element left
    // open; a glow reads as light (ADR-0014).
    glow.startPoint = CGPoint(x: 0.5, y: 0)
    glow.endPoint = CGPoint(x: 0.5, y: 1)
    // Grows upward from the screen edge rather than about its own centre.
    glow.anchorPoint = CGPoint(x: 0.5, y: 0)
    layer?.addSublayer(glow)
    layoutGlow()
    breathe()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    layoutGlow()
  }

  private func layoutGlow() {
    // Implicit animations off: a window being placed is not a breath.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    glow.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: Self.maxHeight)
    glow.position = CGPoint(x: bounds.midX, y: 0)
    CATransaction.commit()
  }

  /// Restarts the breath at the current urgency.
  ///
  /// Both ranges are wider than they look like they need to be. A contrast that
  /// is unmistakable side by side is nearly invisible spread over a 1.2s fade —
  /// the same lesson Theme.swift records for card tints — and peripheral vision
  /// answers to a moving boundary long before a changing brightness (ADR-0006).
  /// The first two attempts, narrow and with a fixed edge, went unnoticed
  /// entirely.
  private func breathe() {
    let lowAlpha = 0.09 + 0.10 * urgency
    let highAlpha = lowAlpha + (0.45 + 0.19 * urgency)
    let lowHeight = 10 + 4 * urgency
    let highHeight = lowHeight + (24 + 8 * urgency)

    glow.removeAllAnimations()

    // A still band was invisible in testing, so motion is not optional here —
    // but neither is honouring the setting that asks for none. Reduced motion
    // gets the peak, held.
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      glow.opacity = Float(highAlpha / Self.maxAlpha)
      glow.transform = CATransform3DMakeScale(1, highHeight / Self.maxHeight, 1)
      CATransaction.commit()
      return
    }

    // Faster as the wait drags on, bracketing the 1.2s a waiting card uses so
    // one urgency reads the same on both surfaces. Halved because autoreversing
    // makes a full cycle out of two passes.
    let period = 1.8 - 0.8 * urgency
    let ease = CAMediaTimingFunction(name: .easeInEaseOut)

    func pulse(_ keyPath: String, _ from: CGFloat, _ to: CGFloat) -> CABasicAnimation {
      let animation = CABasicAnimation(keyPath: keyPath)
      animation.fromValue = from
      animation.toValue = to
      animation.duration = period / 2
      animation.autoreverses = true
      animation.repeatCount = .infinity
      animation.timingFunction = ease
      return animation
    }

    // Resting at the low end, so a band that somehow loses its animation reads
    // as dim rather than as a lit bar sitting there.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    glow.opacity = Float(lowAlpha / Self.maxAlpha)
    glow.transform = CATransform3DMakeScale(1, lowHeight / Self.maxHeight, 1)
    CATransaction.commit()

    glow.add(
      pulse("opacity", lowAlpha / Self.maxAlpha, highAlpha / Self.maxAlpha), forKey: "alpha")
    glow.add(
      pulse("transform.scale.y", lowHeight / Self.maxHeight, highHeight / Self.maxHeight),
      forKey: "height")
  }
}
