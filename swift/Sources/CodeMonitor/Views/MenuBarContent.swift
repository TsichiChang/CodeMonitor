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
      Button("Jump to Next  \(monitor.hotKeyDescription ?? "(shortcut unavailable)")") {
        Task { await monitor.focusNext() }
      }
      // Named even when the key could not be claimed — another process holding
      // it fails silently, and a menu item that quietly loses its shortcut is
      // how that went unnoticed.
      Divider()
      // In the order the shortcut visits them, so the list and the key agree.
      // Bounded so a busy machine can't produce an unusable menu.
      ForEach(monitor.snapshot.byAttention.prefix(20)) { session in
        Button("\(session.state.glyph)  \(session.project) — \(session.state.shortLabel)") {
          Task { await monitor.focus(session) }
        }
      }
    }

    Divider()

    // Quota windows, one row per tool per window (ADR-0023). Unlike the
    // dashboard's line this has room for the reset time, and the menu is where
    // the number is *consulted* — you open it to decide whether to start
    // something big, which is the one moment the figure changes a decision.
    //
    // Not clickable: there is nothing to do to a quota. Disabled buttons are how
    // a SwiftUI menu says "this is a reading, not a control".
    if monitor.snapshot.usage.isEmpty {
      Button("Usage — no tool is reporting") {}.disabled(true)
    } else {
      let now = Date()
      ForEach(monitor.snapshot.usage.sorted { $0.tool.rawValue < $1.tool.rawValue }, id: \.tool) {
        usage in
        ForEach(usage.displayedMinutes, id: \.self) { minutes in
          let reading = usage.reading(forMinutes: minutes, now: now)
          let window = usageWindowLabel(minutes: minutes)
          let tail = reading.resetsInText.map { " · resets in \($0)" } ?? ""
          Button("\(usage.tool.label)  \(window)  \(reading.text)\(tail)") {}
            .disabled(true)
        }
      }
    }

    Divider()

    // Hiding lives here as well as on the card, because the card may be on a
    // display nobody can reach — an ambient surface is looked at, not pointed
    // at (ADR-0014). Low-frequency action, so a submenu is the right cost.
    let hideable = monitor.snapshot.sessions.filter { $0.state == .idle }
    if !hideable.isEmpty {
      Menu("Hide an Idle Session") {
        ForEach(hideable) { session in
          Button(session.project) { monitor.dismiss(session) }
        }
      }
    }

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
