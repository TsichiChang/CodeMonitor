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
  @AppStorage("ambientBand") private var ambientBand = true
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

      Toggle("Glow at the screen edge while waiting", isOn: $ambientBand)
        .help(
          "A breathing amber glow along the bottom of every screen whenever a "
            + "session is blocked on you, so it is noticed without the dashboard "
            + "being looked at.")

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
    // The band lives outside the SwiftUI graph, so toggling the stored value is
    // not enough — it has to be told, or it stays lit until the next scan.
    .onChange(of: ambientBand) { _, value in monitor.ambientBandEnabled = value }
  }
}
