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
  @AppStorage("groupByTool") private var groupByTool = false
  @State private var interval: Double = 2
  @State private var hookStatus: [ToolKind: HookInstaller.Status] = [:]
  @State private var hookNote: String?

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

      Toggle("Group by tool", isOn: $groupByTool)
        .help(
          "Off by default: grouping puts every Claude Code session above every "
            + "Codex one, however urgent. Each card carries its tool's symbol, so "
            + "they stay told apart without it.")

      Toggle("Glow at the screen edge while waiting", isOn: $ambientBand)
        .help(
          "A breathing amber glow along the bottom of every screen whenever a "
            + "session is blocked on you, so it is noticed without the dashboard "
            + "being looked at.")

      Section {
        ForEach(HookInstaller.targets, id: \.tool) { target in
          LabeledContent(target.tool.label) {
            HStack(spacing: 10) {
              Text(describe(hookStatus[target.tool] ?? .missing))
                .foregroundStyle(.secondary)
              Button(hookStatus[target.tool]?.isInstalled == true ? "Remove" : "Install") {
                change(target, installing: hookStatus[target.tool]?.isInstalled != true)
              }
            }
          }
        }
      } header: {
        Text("Report state from hooks")
      } footer: {
        // What it is about to do to a file it does not own, before it does it.
        Text(
          hookNote
            ?? "Lets each tool report what it is doing instead of it being inferred. "
              + "Writes to the tool's own config, which other integrations also use — "
              + "a dated backup is made first, and removing takes only these entries out. "
              + "Sessions already running keep their old setup until they restart."
        )
        .font(.caption)
        .foregroundStyle(hookNote == nil ? .secondary : .primary)
      }

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
    .frame(width: 420)
    .onAppear {
      interval = monitor.refreshInterval
      refreshHookStatus()
    }
    .onChange(of: interval) { _, value in monitor.refreshInterval = value }
    // The band lives outside the SwiftUI graph, so toggling the stored value is
    // not enough — it has to be told, or it stays lit until the next scan.
    .onChange(of: ambientBand) { _, value in monitor.ambientBandEnabled = value }
  }

  private func describe(_ status: HookInstaller.Status) -> String {
    switch status {
    case .installed: "Installed"
    case .missing: "Not installed"
    // Worth naming rather than rounding to "not installed": it usually means a
    // newer version reports an event the existing registration predates.
    case let .partial(present, expected): "\(present) of \(expected) events"
    }
  }

  private func refreshHookStatus() {
    for target in HookInstaller.targets {
      hookStatus[target.tool] = HookInstaller.status(of: target)
    }
  }

  private func change(_ target: HookInstaller.Target, installing: Bool) {
    do {
      let backup = try installing
        ? HookInstaller.install(target) : HookInstaller.uninstall(target)
      hookNote =
        backup.map { "\(target.tool.label): done. Previous config saved as \($0.lastPathComponent)." }
        ?? "\(target.tool.label): done."
    } catch {
      hookNote = "\(target.tool.label): \(error.localizedDescription)"
    }
    refreshHookStatus()
  }
}
