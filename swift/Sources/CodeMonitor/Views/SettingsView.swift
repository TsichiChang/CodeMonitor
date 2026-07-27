/// Settings window (⌘,): appearance and polling cadence.

import SwiftUI

enum Appearance: String, CaseIterable, Identifiable {
  case system
  case light
  case dark

  var id: String { rawValue }

  var label: String {
    switch self {
    case .system: "Auto"
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }
}

struct SettingsView: View {
  @Environment(SessionMonitor.self) private var monitor
  @AppStorage("appearance") private var appearance = Appearance.system
  @AppStorage("showDelegatedSessions") private var showDelegated = false
  @State private var interval: Double = 2

  var body: some View {
    Form {
      Picker("Theme", selection: $appearance) {
        ForEach(Appearance.allCases) { option in
          Text(option.label).tag(option)
        }
      }
      .pickerStyle(.segmented)

      Toggle("List sub-agents separately", isOn: $showDelegated)
        .help(
          "Agents started by a program get one card each instead of being counted "
            + "on the session that spawned them.")

      LabeledContent("Refresh every") {
        HStack {
          Slider(value: $interval, in: 0.5...10, step: 0.5)
          Text(String(format: "%.1fs", interval))
            .font(.callout)
            .monospacedDigit()
            .frame(width: 44, alignment: .trailing)
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 380)
    .onAppear { interval = monitor.refreshInterval }
    .onChange(of: interval) { _, value in monitor.refreshInterval = value }
  }
}
