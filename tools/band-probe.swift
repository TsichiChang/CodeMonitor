// The ambient band (ADR-0014), standalone, so its look can be tuned without
// rebuilding and relaunching the app.
//
//     swiftc -O tools/band-probe.swift -o /tmp/band && /tmp/band [seconds]
//
// It is committed because the numbers below were not chosen, they were found —
// five rounds of running it and looking, with the first two invisible. Anyone
// changing them should be able to see the change in two seconds, and the app
// is a bad instrument for that.
//
// Two traps this encodes, both of which cost a round:
//
//   * Windows must be created in applicationDidFinishLaunching. Built and
//     ordered in before NSApplication.run(), they never reach the screen —
//     and no error says so.
//   * CGWindowListCopyWindowInfo cannot verify any of this. Without Screen
//     Recording permission it filters the information out and reports zero
//     windows for ones plainly on screen. NSWindow.isVisible needs no
//     permission and tells the truth.

import AppKit

// Tunables. Amber matches Palette.statusWaiting; the period matches a waiting
// card, so one urgency reads the same on both surfaces.
let AMBER = (r: 1.0, g: 0.60, b: 0.15)
let ALPHA = (low: 0.10, high: 0.72)
let HEIGHT = (low: 12.0, high: 40.0)   // peak capped: past ~40 it covers an editor's last line
let PERIOD = 1.2                        // seconds per full breath

// The band is a CAGradientLayer built once at its tallest and brightest; the
// breath is a fraction of that, animated by Core Animation in the render
// server. It was a 30fps timer redrawing a gradient into a screen-sized view,
// which this probe measured at 11.5% of a core — nearly twice what the poll
// ADR-0008 replaced used to cost, and 165× the dashboard's own breathing cards,
// which were on the compositor all along.
//
// Both the tint and the edge itself move. A swing that is unmistakable side by
// side is nearly invisible spread across a 1.2s fade (Theme.swift says the same
// about card tints), and peripheral vision answers to a moving boundary long
// before a changing brightness (ADR-0006).
final class BandView: NSView {
  private let glow = CAGradientLayer()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layerContentsRedrawPolicy = .never

    let amber = NSColor(srgbRed: AMBER.r, green: AMBER.g, blue: AMBER.b, alpha: 1)
    glow.colors = [amber.cgColor, amber.withAlphaComponent(0).cgColor]
    glow.startPoint = CGPoint(x: 0.5, y: 0)   // unflipped: the bottom edge
    glow.endPoint = CGPoint(x: 0.5, y: 1)
    glow.anchorPoint = CGPoint(x: 0.5, y: 0)  // grows upward from the edge
    glow.bounds = CGRect(x: 0, y: 0, width: frameRect.width, height: HEIGHT.high)
    glow.position = CGPoint(x: frameRect.midX, y: 0)
    layer?.addSublayer(glow)

    func pulse(_ keyPath: String, _ from: CGFloat, _ to: CGFloat) -> CABasicAnimation {
      let a = CABasicAnimation(keyPath: keyPath)
      a.fromValue = from
      a.toValue = to
      a.duration = PERIOD / 2          // autoreversing makes a cycle of two passes
      a.autoreverses = true
      a.repeatCount = .infinity
      a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      return a
    }
    glow.opacity = Float(ALPHA.low / ALPHA.high)
    glow.transform = CATransform3DMakeScale(1, HEIGHT.low / HEIGHT.high, 1)
    glow.add(pulse("opacity", ALPHA.low / ALPHA.high, 1), forKey: "alpha")
    glow.add(
      pulse("transform.scale.y", HEIGHT.low / HEIGHT.high, 1), forKey: "height")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }
}

final class Delegate: NSObject, NSApplicationDelegate {
  var windows: [NSWindow] = []
  var views: [BandView] = []
  var elapsed = 0.0
  let total = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1])! : 20

  func applicationDidFinishLaunching(_ note: Notification) {
    for screen in NSScreen.screens {
      let w = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                       backing: .buffered, defer: false)
      w.setFrame(screen.frame, display: true)
      // Above full-screen apps: screenSaver level clears them, and
      // fullScreenAuxiliary + canJoinAllSpaces keeps it there across Spaces.
      w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
      w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
      w.isOpaque = false
      w.backgroundColor = .clear
      w.ignoresMouseEvents = true      // never in the way of a click
      w.hasShadow = false
      let v = BandView(frame: CGRect(origin: .zero, size: screen.frame.size))
      w.contentView = v
      w.orderFrontRegardless()         // shown without activating this app
      windows.append(w)
      views.append(v)
    }

    for (i, w) in windows.enumerated() {
      print("window \(i): visible \(w.isVisible)  level \(w.level.rawValue)"
        + "  \(Int(w.frame.width))×\(Int(w.frame.height))")
    }

    // Only to end the run. The breathing needs no timer at all now — that is
    // the difference this probe exists to show.
    Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
      self.elapsed += 0.25
      if self.elapsed >= self.total { NSApp.terminate(nil) }
    }
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Delegate()
app.delegate = delegate
app.run()
