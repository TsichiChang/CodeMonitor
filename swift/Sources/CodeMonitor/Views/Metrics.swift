/// Every length in the dashboard, derived from the screen it is being shown on
/// (ADR-0013).
///
/// A `pt` is a logical unit, so a fixed constant is a different physical size on
/// every display — 13pt is 4.0mm on a 27" external and 3.0mm on a built-in
/// laptop screen, a third smaller for the same words at the same desk. Only one
/// number here scales; everything else is a multiple of it, and the multiples
/// are the existing 27" layout divided through, so this is a no-op on the
/// screen where the design was actually verified.

import AppKit
import SwiftUI

struct Metrics: Equatable, Sendable {
  /// Points per inch of the screen in question — how large a `pt` physically
  /// is. Not PPI: that names physical pixel density, which is 254 on the same
  /// built-in screen that has 110 points per inch.
  var pointsPerInch: Double = Metrics.fallbackPointsPerInch

  /// Body text, sized so its cap height subtends 16 arcminutes at 60cm — the
  /// bottom of the range ISO 9241 gives for comfortable reading, which short UI
  /// labels may sit at. See ADR-0013 for why this is a seated distance rather
  /// than the "across a desk" one ADR-0006 asked for.
  static let bodyMillimetres = 4.0

  var body: Double { Self.bodyMillimetres * pointsPerInch / 25.4 }

  // Ratios, not designs: each is the current 27" value over its 13pt body.
  var caption: Double { body * 0.77 }
  var cardPadding: Double { body * 1.08 }
  var cardSpacing: Double { body * 0.62 }
  var cornerRadius: Double { body * 0.77 }
  var gridSpacing: Double { body * 0.77 }
  var groupSpacing: Double { body * 2.15 }
  var edgePadding: Double { body * 1.54 }
  /// What decides the column count once divided into the window's width. It
  /// scales with everything else, which is what produces ADR-0006's "fewer and
  /// larger cards" on a dense screen without a small-screen branch anywhere.
  var minCardWidth: Double { body * 18.5 }
  var hairline: Double { body * 0.077 }

  /// The collapsed idle row. The one length with nothing to divide from — a new
  /// shape, judged by eye rather than derived (ADR-0013).
  var idleRowHeight: Double { body * 2.6 }

  // MARK: - Reading the screen

  /// 82 points per inch: the external display this design was verified on, so
  /// an unknown screen falls back to unchanged behaviour rather than to a guess.
  static let fallbackPointsPerInch = 82.0

  static func pointsPerInch(of screen: NSScreen?) -> Double {
    guard let screen,
      let number = screen.deviceDescription[
        NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    else { return fallbackPointsPerInch }

    // Physical millimetres come from the display's EDID. External displays that
    // report nothing give zeroes, hence the guard.
    let millimetres = CGDisplayScreenSize(CGDirectDisplayID(number.uint32Value))
    guard millimetres.width > 1 else { return fallbackPointsPerInch }

    let inches = millimetres.width / 25.4
    let points = screen.frame.width
    let density = points / inches
    // A pathological EDID should not produce unreadable or absurd type.
    return min(max(density, 50), 250)
  }
}

// MARK: - Checks

extension Metrics {
  /// What each length was, hard-coded, on the 27" screen this layout was
  /// designed against. Deriving them must reproduce those numbers there — that
  /// is the whole claim of ADR-0013: a no-op where the design was verified, and
  /// different only where it was never checked.
  static var checks: [(name: String, path: KeyPath<Metrics, Double>, was: Double)] { [
    ("body was 13pt", \.body, 13),
    ("caption was 10pt", \.caption, 10),
    ("card padding was 14pt", \.cardPadding, 14),
    ("card spacing was 8pt", \.cardSpacing, 8),
    ("corner radius was 10pt", \.cornerRadius, 10),
    ("grid spacing was 10pt", \.gridSpacing, 10),
    ("group spacing was 28pt", \.groupSpacing, 28),
    ("edge padding was 20pt", \.edgePadding, 20),
    ("minimum card width was 240pt", \.minCardWidth, 240),
    ("hairline was 1pt", \.hairline, 1),
  ] }

  /// Runs the table at 82 points per inch. Returns the number of failures.
  static func runChecks() -> Int {
    let reference = Metrics(pointsPerInch: fallbackPointsPerInch)
    var failures = 0
    for check in checks {
      let value = reference[keyPath: check.path]
      // Within a point: these are ratios of an irrational body size, so exact
      // equality was never on offer, and a point is invisible.
      let tolerance = max(1.0, check.was * 0.01)
      if abs(value - check.was) <= tolerance {
        print("  ✓ \(check.name), derives \(String(format: "%.1f", value))")
      } else {
        failures += 1
        print("  ✗ \(check.name), derives \(String(format: "%.1f", value))")
      }
    }
    return failures
  }
}

extension EnvironmentValues {
  @Entry var metrics = Metrics()
}

/// Reports which screen the view is on, and follows it when the window moves.
///
/// SwiftUI has no way to ask: `displayScale` is the backing scale factor, a
/// different quantity entirely. The screen is reachable only through the
/// hosting `NSWindow`.
struct ScreenMetricsReader: NSViewRepresentable {
  @Binding var metrics: Metrics

  func makeNSView(context: Context) -> NSView { Probe(onChange: report) }

  func updateNSView(_ view: NSView, context: Context) {
    (view as? Probe)?.onChange = report
  }

  private func report(_ screen: NSScreen?) {
    let density = Metrics.pointsPerInch(of: screen)
    if metrics.pointsPerInch != density { metrics.pointsPerInch = density }
  }

  private final class Probe: NSView {
    var onChange: (NSScreen?) -> Void

    init(onChange: @escaping (NSScreen?) -> Void) {
      self.onChange = onChange
      super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      NotificationCenter.default.removeObserver(self)
      guard let window else { return }
      // Both matter: dragging a window to another display, and a display being
      // reconfigured underneath a window that never moved.
      for name in [
        NSWindow.didChangeScreenNotification,
        NSWindow.didChangeScreenProfileNotification,
      ] {
        NotificationCenter.default.addObserver(
          self, selector: #selector(screenChanged), name: name, object: window)
      }
      NotificationCenter.default.addObserver(
        self, selector: #selector(screenChanged),
        name: NSApplication.didChangeScreenParametersNotification, object: nil)
      onChange(window.screen)
    }

    @objc private func screenChanged() { onChange(window?.screen) }

    deinit { NotificationCenter.default.removeObserver(self) }
  }
}
