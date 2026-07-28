/// The dashboard window: every detected session, grouped by tool.

import SwiftUI

struct DashboardView: View {
  @Environment(SessionMonitor.self) private var monitor
  /// Which screen this window is on decides every length below (ADR-0013).
  @State private var metrics = Metrics()

  /// Width available to the cards, measured rather than assumed.
  @State private var contentWidth: CGFloat = 0

  private var columns: [GridItem] {
    [GridItem(.adaptive(minimum: metrics.minCardWidth), spacing: metrics.gridSpacing,
              alignment: .top)]
  }

  /// How many columns `.adaptive` will lay out, by its own rule: as many as fit
  /// at the minimum width. Recomputed here because the grid does not report it,
  /// and the counts above need to know whether there is a right edge to sit
  /// against or just one column down the middle.
  private var columnCount: Int {
    let available = contentWidth - metrics.edgePadding * 2
    guard available > 0 else { return 1 }
    return max(1, Int((available + metrics.gridSpacing)
      / (metrics.minCardWidth + metrics.gridSpacing)))
  }

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
    .environment(\.metrics, metrics)
    .background(ScreenMetricsReader(metrics: $metrics))
    .background(
      GeometryReader { proxy in
        Color.clear
          .onAppear { contentWidth = proxy.size.width }
          .onChange(of: proxy.size.width) { _, width in contentWidth = width }
      }
    )
    .navigationTitle("Code Sessions")
    .safeAreaInset(edge: .top) {
      // Kept out of the toolbar: macOS wraps toolbar content in its own
      // material, which put a grey slab behind the counts that no amount of
      // styling on them could remove.
      //
      // Centred once the cards are a single column, right-aligned otherwise:
      // with one column there is no right edge for it to belong to, and hanging
      // off in the corner reads as a stray rather than as a heading.
      counts
        .frame(maxWidth: .infinity, alignment: columnCount == 1 ? .center : .trailing)
        .padding(.horizontal, metrics.edgePadding)
        .padding(.top, metrics.edgePadding * 0.5)
        // Animated on the column count, not the width: it should glide across
        // once when the layout actually changes, not track the cursor through
        // every intermediate width of a drag.
        .animation(.smooth(duration: 0.35), value: columnCount)
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
      VStack(alignment: .leading, spacing: metrics.groupSpacing) {
        ForEach(monitor.snapshot.groupedByTool, id: \.tool) { group in
          toolGroup(group.tool, items: group.items)
        }
      }
      .padding(.horizontal, metrics.edgePadding)
      .padding(.vertical, metrics.edgePadding * 0.8)
    }
  }

  private func toolGroup(_ tool: ToolKind, items: [SessionInfo]) -> some View {
    VStack(alignment: .leading, spacing: metrics.cardSpacing * 1.5) {
      HStack(spacing: metrics.cardSpacing) {
        Image(systemName: tool.symbolName)
          .font(.system(size: metrics.caption))
          .foregroundStyle(.tertiary)
        Text(tool.label.uppercased())
          .font(.system(size: metrics.caption, weight: .semibold))
          .kerning(0.5)
          .foregroundStyle(.tertiary)
        Text("\(items.count)")
          .font(.system(size: metrics.caption))
          .monospacedDigit()
          .foregroundStyle(.tertiary)
        Divider()
      }

      // One grid, one tile per session, whatever its state. An idle session is
      // the same tile folded shut — moving it to a second container is what
      // made the change read as a swap rather than as one thing collapsing.
      // Sessions arrive sorted by attention, so tiles that are still open sit
      // above the folded ones without anything here having to arrange that.
      LazyVGrid(columns: columns, spacing: metrics.gridSpacing) {
        ForEach(items) { session in
          SessionCardView(
            session: session,
            onFocus: { Task { await monitor.focus(session) } },
            // Only idle sessions may be hidden. Closing something that is
            // running, or waiting on you, would hide the two things this
            // display exists to show (ADR-0007).
            onDismiss: session.state == .idle ? { monitor.dismiss(session) } : nil
          )
        }
      }
    }
    // A session waking up unfolds its own tile; going idle folds it shut. This
    // motion earns its cost because it *carries* information — that session
    // changed — unlike the relayout ADR-0013 refuses to animate, which reports
    // only that some other session appeared. Bound to the state signature so an
    // ordinary scan, which changes elapsed times every couple of seconds, moves
    // nothing at all.
    .animation(.smooth(duration: 0.42), value: monitor.snapshot.stateSignature)
  }

  private var counts: some View {
    HStack(spacing: metrics.caption * 0.6) {
      countBadge(monitor.snapshot.counts.running, "running", Palette.statusRunning)
      countBadge(monitor.snapshot.counts.waiting, "waiting", Palette.statusWaiting)
      countBadge(monitor.snapshot.counts.idle, "idle", nil)
    }
  }

  /// Tinted for the states worth looking at; idle carries no fill at all, so
  /// the row reads as "two things are happening" rather than three equal
  /// chips (ADR-0007).
  private func countBadge(_ value: Int, _ label: String, _ color: Color?) -> some View {
    HStack(spacing: metrics.caption * 0.4) {
      Circle().fill(color ?? .secondary)
        .frame(width: metrics.caption * 0.6, height: metrics.caption * 0.6)
      Text("\(value) \(label)")
        .font(.system(size: metrics.caption))
        .monospacedDigit()
        .foregroundStyle(color == nil ? .secondary : .primary)
    }
    .padding(.horizontal, metrics.caption * 0.8)
    .padding(.vertical, metrics.caption * 0.3)
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
