/// The dashboard window: every detected session, grouped by tool.

import SwiftUI

struct DashboardView: View {
  @Environment(SessionMonitor.self) private var monitor
  /// Which screen this window is on decides every length below (ADR-0013).
  @State private var metrics = Metrics()
  /// Ties a session's row and its card together so one turns into the other
  /// rather than one vanishing while the other appears.
  @Namespace private var sessionShape

  /// Width available to the cards, measured rather than assumed.
  @State private var contentWidth: CGFloat = 0

  /// Backs up the geometry match when it cannot apply — the two shapes live in
  /// different containers, and a lazy grid does not always keep a departing
  /// child around long enough to interpolate it. Without this the fallback is a
  /// hard cut, which is exactly what the animation exists to avoid.
  private static let shapeChange: AnyTransition = .scale(scale: 0.94)
    .combined(with: .opacity)

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
    // Spacing is padding rather than stack spacing, and both containers are
    // always present even when empty. Wrapping either in `if` removed the
    // container itself the moment its last session changed state, and a
    // matchedGeometryEffect has nowhere to land when one side is a view that
    // no longer exists — so the last card going idle jumped instead of moving.
    VStack(alignment: .leading, spacing: 0) {
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
      .padding(.bottom, metrics.cardSpacing * 1.5)

      // Active sessions get cards; idle ones get a line each, below them. The
      // split is by state alone, never by how much room is left (ADR-0013).
      let active = items.filter { $0.state != .idle }
      let idle = items.filter { $0.state == .idle }

      LazyVGrid(columns: columns, spacing: metrics.gridSpacing) {
        ForEach(active) { session in
          // Cards carry no close button: only idle sessions may be hidden,
          // and an idle session is a row (ADR-0007, ADR-0013).
          SessionCardView(
            session: session,
            onFocus: { Task { await monitor.focus(session) } }
          )
          .matchedGeometryEffect(id: session.id, in: sessionShape)
          .transition(Self.shapeChange)
        }
      }
      .padding(.bottom, active.isEmpty || idle.isEmpty ? 0 : metrics.gridSpacing)

      VStack(spacing: metrics.gridSpacing * 0.4) {
        ForEach(idle) { session in
          IdleRowView(
            session: session,
            onFocus: { Task { await monitor.focus(session) } },
            onDismiss: { monitor.dismiss(session) }
          )
          .matchedGeometryEffect(id: session.id, in: sessionShape)
          .transition(Self.shapeChange)
        }
      }
    }
    // A session waking up grows from its row into a card. This motion is worth
    // its cost because it *carries* information — that session changed — unlike
    // the relayout ADR-0013 refuses to animate, which only reports that some
    // other session appeared. Bound to the state signature so an ordinary scan,
    // which changes elapsed times every couple of seconds, moves nothing.
    .animation(.smooth(duration: 0.42), value: monitor.snapshot.stateSignature)
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
