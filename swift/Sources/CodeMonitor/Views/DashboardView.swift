/// The dashboard window: every detected session, grouped by tool.

import SwiftUI

struct DashboardView: View {
  @Environment(SessionMonitor.self) private var monitor

  private let columns = [GridItem(.adaptive(minimum: 240), spacing: 10, alignment: .top)]

  var body: some View {
    @Bindable var monitor = monitor

    Group {
      if monitor.snapshot.sessions.isEmpty {
        emptyState
      } else {
        sessionList
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .navigationTitle("Code Sessions")
    .safeAreaInset(edge: .top) {
      // Kept out of the toolbar: macOS wraps toolbar content in its own
      // material, which put a grey slab behind the counts that no amount of
      // styling on them could remove.
      HStack {
        Spacer()
        counts
      }
      .padding(.horizontal, 20)
      .padding(.top, 10)
    }
    .alert(
      "Couldn't jump to the terminal",
      isPresented: .init(
        get: { monitor.focusError != nil },
        set: { if !$0 { monitor.focusError = nil } }
      ),
      presenting: monitor.focusError
    ) { _ in
      Button("OK", role: .cancel) {}
    } message: { error in
      Text(error)
    }
  }

  private var sessionList: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        ForEach(monitor.snapshot.groupedByTool, id: \.tool) { group in
          toolGroup(group.tool, items: group.items)
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 16)
    }
  }

  private func toolGroup(_ tool: ToolKind, items: [SessionInfo]) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Image(systemName: tool.symbolName)
          .font(.caption)
          .foregroundStyle(.tertiary)
        Text(tool.label.uppercased())
          .font(.caption.weight(.semibold))
          .kerning(0.5)
          .foregroundStyle(.tertiary)
        Text("\(items.count)")
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(.tertiary)
        Divider()
      }
      LazyVGrid(columns: columns, spacing: 10) {
        ForEach(items) { session in
          SessionCardView(
            session: session,
            onFocus: { Task { await monitor.focus(session) } },
            // Only idle cards can be closed. Closing something that is running,
            // or waiting on you, would hide the two things this display exists
            // to show (ADR-0007).
            onDismiss: session.state == .idle ? { monitor.dismiss(session) } : nil
          )
        }
      }
    }
  }

  private var counts: some View {
    HStack(spacing: 6) {
      countBadge(monitor.snapshot.counts.running, "running", Palette.statusRunning)
      countBadge(monitor.snapshot.counts.waiting, "waiting", Palette.statusWaiting)
      countBadge(monitor.snapshot.counts.idle, "idle", nil)
    }
  }

  /// Tinted for the states worth looking at; idle carries no fill at all, so
  /// the row reads as "two things are happening" rather than three equal
  /// chips (ADR-0007).
  private func countBadge(_ value: Int, _ label: String, _ color: Color?) -> some View {
    HStack(spacing: 4) {
      Circle().fill(color ?? .secondary).frame(width: 6, height: 6)
      Text("\(value) \(label)")
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(color == nil ? .secondary : .primary)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(Capsule().fill(color?.opacity(0.12) ?? .clear))
  }

  private var emptyState: some View {
    ContentUnavailableView {
      Label("No active sessions", systemImage: "terminal")
    } description: {
      Text(
        "Start a Claude Code, Codex, or OpenCode session in a terminal and it will appear here."
      )
    }
  }
}
