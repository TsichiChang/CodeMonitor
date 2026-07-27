/// Code Session Monitor — a menu-bar app that surfaces local coding-agent
/// sessions (Claude Code, Codex, OpenCode) and jumps to their terminal tabs.

import SwiftUI

enum WindowID {
  static let dashboard = "dashboard"
}

struct CodeMonitorApp: App {
  @State private var monitor = SessionMonitor()
  @AppStorage("appearance") private var appearance = Appearance.system

  var body: some Scene {
    Window("Code Sessions", id: WindowID.dashboard) {
      DashboardView()
        .environment(monitor)
        .preferredColorScheme(appearance.colorScheme)
    }
    .defaultSize(width: 1024, height: 620)
    .commands {
      CommandGroup(after: .toolbar) {
        Button("Refresh Now") {
          Task { await monitor.refresh() }
        }
        .keyboardShortcut("r")
      }
    }

    MenuBarExtra {
      MenuBarContent()
        .environment(monitor)
    } label: {
      MenuBarLabel(snapshot: monitor.snapshot)
    }

    Settings {
      SettingsView()
        .environment(monitor)
        .preferredColorScheme(appearance.colorScheme)
    }
  }
}
