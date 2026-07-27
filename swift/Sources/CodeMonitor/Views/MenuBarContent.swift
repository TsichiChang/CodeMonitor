/// Menu-bar dropdown: a compact glance at session state, with each entry
/// jumping straight to its terminal tab.

import SwiftUI

struct MenuBarContent: View {
  @Environment(SessionMonitor.self) private var monitor
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    Text("Code Sessions")

    Divider()

    if monitor.snapshot.sessions.isEmpty {
      Text("No active sessions")
    } else {
      // Bounded so a busy machine can't produce an unusable menu.
      ForEach(monitor.snapshot.sessions.prefix(20)) { session in
        Button("\(session.state.glyph)  \(session.project) — \(session.state.shortLabel)") {
          Task { await monitor.focus(session) }
        }
      }
    }

    Divider()

    // Only offered when something is actually hidden, so dismissing never
    // becomes a one-way door the user cannot find their way back through.
    if monitor.dismissedCount > 0 {
      Button("Show \(monitor.dismissedCount) hidden session\(monitor.dismissedCount == 1 ? "" : "s")") {
        monitor.restoreAllDismissed()
      }
      Divider()
    }

    Button("Open Dashboard") {
      NSApp.activate(ignoringOtherApps: true)
      openWindow(id: WindowID.dashboard)
    }
    Button("Settings…") {
      NSApp.activate(ignoringOtherApps: true)
      openSettings()
    }

    Divider()

    Button("Quit Code Monitor") {
      NSApp.terminate(nil)
    }
    .keyboardShortcut("q")
  }
}

/// Menu-bar icon: tinted by the most urgent state present, with the active
/// session count alongside.
struct MenuBarLabel: View {
  let snapshot: SessionSnapshot

  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: "terminal")
      if snapshot.counts.total > 0 {
        Text("\(snapshot.counts.total)").monospacedDigit()
      }
    }
    .foregroundStyle(tint)
  }

  private var tint: Color {
    if snapshot.counts.waiting > 0 { return Palette.statusWaiting }
    if snapshot.counts.running > 0 { return Palette.statusRunning }
    return .primary
  }
}
