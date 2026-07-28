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
let FPS = 30.0

final class BandView: NSView {
  var phase: CGFloat = 0

  override func draw(_ dirty: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    let breath = 0.5 + 0.5 * sin(phase)

    // Both the tint and the edge itself move. A swing that is unmistakable side
    // by side is nearly invisible spread across a 1.2s fade (Theme.swift says
    // the same about card tints), and peripheral vision answers to a moving
    // boundary long before a changing brightness (ADR-0006).
    let alpha = ALPHA.low + (ALPHA.high - ALPHA.low) * breath
    let h = HEIGHT.low + (HEIGHT.high - HEIGHT.low) * breath

    let amber = NSColor(srgbRed: AMBER.r, green: AMBER.g, blue: AMBER.b, alpha: alpha).cgColor
    guard let grad = CGGradient(
      colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
      colors: [amber, amber.copy(alpha: 0)!] as CFArray,
      locations: [0, 1]) else { return }

    ctx.saveGState()
    ctx.clip(to: CGRect(x: 0, y: 0, width: bounds.width, height: h))
    ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: h), options: [])
    ctx.restoreGState()
  }
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

    Timer.scheduledTimer(withTimeInterval: 1 / FPS, repeats: true) { _ in
      self.elapsed += 1 / FPS
      if self.elapsed >= self.total { NSApp.terminate(nil) }
      for v in self.views {
        v.phase += (2 * .pi) / (PERIOD * FPS)
        v.needsDisplay = true
      }
    }
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Delegate()
app.delegate = delegate
app.run()
