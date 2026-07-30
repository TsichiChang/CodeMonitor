/// The dashboard window: every detected session, in attention order.

import SwiftUI

struct DashboardView: View {
  @Environment(SessionMonitor.self) private var monitor
  /// Which screen this window is on decides every length below (ADR-0013).
  @State private var metrics = Metrics()

  /// Width available to the cards, measured rather than assumed.
  @State private var contentWidth: CGFloat = 0
  /// Off by default: grouping sorts by which tool, above how urgent, so a
  /// waiting Codex session sat below every read Claude one. The tool is on the
  /// card instead, where it identifies without reordering (ADR-0014).
  @AppStorage("groupByTool") private var groupByTool = false

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
      // Folding only as far as it has to, each rung the next-narrowest
      // arrangement, so dragging the window never skips a step or jumps back.
      //
      // Three rungs, widest first, and the whole thing only works because every
      // rung refuses to compress.
      //
      // `ViewThatFits` asks each candidate for its ideal width and takes the
      // first that fits. A candidate containing text that can wrap or truncate
      // has no honest ideal width — it will always claim to fit and then arrive
      // mangled, which is how `running` came to be set one letter per line and
      // how the `5h` labels truncated to nothing. So the leaves carry
      // `.lineLimit(1).fixedSize()` and the ladder does the adapting instead.
      ViewThatFits(in: .horizontal) {
        // 1. Everything on one line.
        HStack(alignment: .center, spacing: metrics.groupSpacing) {
          counts
          quotaBlock(.allOnOneLine, folding: false)
        }
        // 2. Opposite ends of the same row: quotas take the leading edge, counts
        //    keep the trailing one, and the width between them gets used rather
        //    than left empty while both crowd one corner.
        HStack(alignment: .top, spacing: metrics.groupSpacing) {
          quotaBlock(.oneLinePerTool, folding: false)
          Spacer(minLength: 0)
          counts
        }
        // 3. Stacked. The last rung, and the only adaptive one — its quota rows
        //    fold their own windows onto separate lines, which is the fold below
        //    this one. Replacing this rung with the arrangement above, rather than
        //    adding to it, is what left nothing to fall through to.
        // Centred on each other, not left-aligned to each other. The two blocks
        // are different widths and neither is the other's margin, so a shared
        // left edge just made the narrower one look indented; a shared centre
        // line reads as one heading in two rows.
        VStack(alignment: .center, spacing: metrics.cardSpacing * 1.2) {
          counts
          quotaBlock(.oneLinePerTool, folding: true)
        }
      }
        .frame(maxWidth: .infinity, alignment: columnCount == 1 ? .center : .trailing)
        .padding(.horizontal, metrics.edgePadding)
        .padding(.vertical, metrics.edgePadding * 0.5)
        // Opaque, so cards scroll *under* the heading instead of through it.
        // Without a background the inset is transparent, the two draw into the
        // same band, and a card's title lands on top of the quota rows — the
        // heading is the fixed thing here and must occlude what moves.
        //
        // Not a material — a material is what kept this out of the toolbar in
        // the first place, since it renders a grey slab no styling can remove.
        //
        // And not `NSColor.windowBackgroundColor` either, which was the first
        // attempt: it names *a* window background rather than *this* window's,
        // and in dark mode the two are different greys, so the heading sat as a
        // visibly lighter band above the scroll area. `.background` is the
        // semantic style for whatever the enclosing surface is painted with, so
        // it cannot disagree with it.
        .background(.background)
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
        if groupByTool {
          ForEach(monitor.snapshot.groupedByTool, id: \.tool) { group in
            toolGroup(group.tool, items: group.items)
          }
        } else {
          grid(monitor.snapshot.sessions)
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

      grid(items)
    }
  }

  /// One grid, one tile per session, whatever its state. An idle session is the
  /// same tile folded shut — moving it to a second container is what made the
  /// change read as a swap rather than as one thing collapsing. Sessions arrive
  /// sorted by attention, so tiles that are still open sit above the folded ones
  /// without anything here having to arrange that.
  private func grid(_ items: [SessionInfo]) -> some View {
    LazyVGrid(columns: columns, spacing: metrics.gridSpacing) {
      ForEach(items) { session in
        SessionCardView(
          session: session,
          onFocus: { Task { await monitor.focus(session) } },
          // Only idle sessions may be hidden. Closing something that is running,
          // or waiting on you, would hide the two things this display exists to
          // show (ADR-0007).
          onDismiss: session.state == .idle ? { monitor.dismiss(session) } : nil
        )
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

  /// Quota windows, one line per tool (ADR-0023).
  ///
  /// Grouped by tool because the numbers are not comparable: Claude's five-hour
  /// window and Codex's seven-day one are different accounts on different plans,
  /// and setting them side by side under a shared heading would invite reading a
  /// difference that does not exist.
  ///
  /// The dimmest thing in the header, deliberately. It moves slowly, it is
  /// consulted rather than watched, and on a display whose scarcest resource is
  /// attention it has to sit below the counts in every sense (ADR-0007). The
  /// moment a quota actually bites, the session that hit it goes `waiting` and
  /// the band lights — so the loud channel already exists and this one does not
  /// need to compete for it (ADR-0024).
  /// How the tools are arranged relative to each other.
  private enum QuotaArrangement { case allOnOneLine, oneLinePerTool }

  /// The quota block, in one arrangement.
  ///
  /// One function rather than three near-identical properties: the rungs differ by
  /// two parameters, and three copies of the same body would be the shape this
  /// repository keeps paying for.
  ///
  /// `folding` is what makes a rung adaptive, and only the last rung may be. A
  /// candidate that can rearrange itself always reports that it fits, so any rung
  /// above the last must be rigid or the ones below it are unreachable.
  @ViewBuilder
  private func quotaBlock(_ arrangement: QuotaArrangement, folding: Bool) -> some View {
    quotaTicker { now in
      let rows = ForEach(quotaRows, id: \.tool) { usage in
        if folding {
          quotaRow(usage, now: now)
        } else {
          quotaRowInline(usage, now: now)
        }
      }
      switch arrangement {
      case .allOnOneLine:
        HStack(spacing: metrics.groupSpacing * 0.6) { rows }
      case .oneLinePerTool:
        VStack(alignment: .leading, spacing: metrics.caption * 0.5) { rows }
      }
    }
  }

  /// Shared wrapper: nothing at all when no tool reports, and a clock for the
  /// countdowns.
  ///
  /// Nothing rather than an empty row, because an empty `HStack` still claims the
  /// stack's spacing and the ticker still wakes every five seconds to draw it — a
  /// cost with nothing on the other side. The clock is here for the same reason a
  /// card's elapsed time has one: the countdown must keep falling between scans,
  /// and at the slow cadence a scan can be fifteen seconds away.
  @ViewBuilder
  private func quotaTicker<Content: View>(
    @ViewBuilder _ content: @escaping (Date) -> Content
  ) -> some View {
    if !monitor.snapshot.usage.isEmpty {
      TimelineView(.periodic(from: .now, by: 5)) { context in
        content(context.date)
          .font(.system(size: quotaText))
          .lineLimit(1)
      }
    }
  }

  /// One line per tool, with each window labelled inside its own cell.
  ///
  /// **Not a grid with shared column headings**, which is what the first attempt
  /// built and what ADR-0023 forbids in as many words: setting Claude's five-hour
  /// window beside Codex's under one heading invites reading a difference between
  /// two numbers that share no denominator. `5h` is comparable — both are five
  /// hours — but 79% of one plan's quota against 26% of another's is not, and a
  /// column is an instruction to compare. Repeating `5h` on each row costs four
  /// characters and removes the invitation.
  private func quotaRow(_ usage: ToolUsage, now: Date) -> some View {
    // One line while the windows fit beside each other, one line each when they
    // do not. `ViewThatFits` picks the first that fits, and the stacked variant
    // is narrower by construction, so it is chosen only when it has to be.
    ViewThatFits(in: .horizontal) {
      quotaRowInline(usage, now: now)
      quotaRowStacked(usage, now: now)
    }
  }

  private func quotaRowInline(_ usage: ToolUsage, now: Date) -> some View {
    HStack(spacing: metrics.caption * 0.75) {
      // The icon rather than the name. It is what the cards already use
      // (ADR-0014), and it costs a fixed size instead of eleven characters that
      // were wrapping onto a second line.
      //
      // In colour, not greyed. On a card the icon is redundant — the project
      // name says which session it is — so ADR-0014 mutes it there. Here it is
      // the row's only label, and greyscale made two vendors indistinguishable.
      // Same element, different job.
      ToolMark(tool: usage.tool, size: quotaIconSize)
      ForEach(quotaColumns, id: \.self) { minutes in
        quotaCell(usage, minutes: minutes, now: now)
      }
    }
    // Rigid, so this arrangement can genuinely fail to fit and let the next rung
    // take over. Truncating the `5h` label to nothing would have counted as
    // fitting.
    .fixedSize()
  }

  /// Every tool worth a row: whatever reported, plus whatever has sessions on
  /// screen but has said nothing.
  ///
  /// The second half is why `—` exists. A tool running sessions and reporting no
  /// quota is not a tool without limits — it is an integration that is not wired
  /// up, and Claude needs a line in the user's own status-line script where Codex
  /// needs nothing (ADR-0023). Showing the row makes the difference visible
  /// instead of leaving a silent gap.
  private var quotaRows: [ToolUsage] {
    let reported = monitor.snapshot.usage
    let silent = Set(monitor.snapshot.sessions.map(\.tool)).subtracting(reported.map(\.tool))
      .map { ToolUsage(tool: $0, windows: [], observedAt: .distantPast) }
    return (reported + silent).sorted { $0.tool.rawValue < $1.tool.rawValue }
  }

  private var quotaColumns: [Int] { ToolUsage.columns(across: monitor.snapshot.usage) }

  /// Big enough to tell two vendors apart, small enough not to compete with the
  /// state dots beside it.
  private var quotaIconSize: Double { quotaText * 1.3 }

  /// Type size for the whole quota block, and the unit every length in it is
  /// stated in.
  ///
  /// A step above `caption`, which is what the count badges beside it use. Those
  /// carry a tinted capsule and `.primary` text, so they read at a glance at the
  /// same size; these are bare `.secondary` marks and did not. Making the block
  /// *quieter* than the counts was always the intent (ADR-0007) and greys are
  /// what deliver it — a size nobody can read is not restraint, it is the same
  /// mistake as the first attempt's `.tertiary`.
  ///
  /// Everything below is a multiple of this rather than of `caption`, so the
  /// reserved slots grow with the text. They were stated in `caption` while the
  /// text was `caption`, and the two agreeing by coincidence is exactly the shape
  /// that drifts: `↻4h` would have overflowed a slot sized for smaller digits.
  private var quotaText: Double { metrics.caption * 1.15 }

  /// The windows of one tool, stacked, when they will not sit side by side.
  ///
  /// The icon aligns to the first line rather than centring across both: it
  /// labels the group, and a mark floating between two rows belongs to neither.
  private func quotaRowStacked(_ usage: ToolUsage, now: Date) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: metrics.caption * 0.75) {
      ToolMark(tool: usage.tool, size: quotaIconSize)
      VStack(alignment: .leading, spacing: metrics.caption * 0.35) {
        ForEach(quotaColumns, id: \.self) { minutes in
          quotaCell(usage, minutes: minutes, now: now)
        }
      }
    }
  }

  /// One window: its length, a bar, and how long until it clears.
  ///
  /// **No percentage.** The bar and a number beside it were the same fact twice —
  /// the visual form of the duplication this repository keeps paying for — and the
  /// bar was the half doing less, at 26pt wide where 4% rounded to a single pixel
  /// and could not be told from empty. Widening the bar and dropping the digits
  /// leaves one expression per quantity. The exact figure lives in the tooltip and
  /// in the menu, which is where an exact figure is actually wanted.
  ///
  /// No tint: colour belongs to session state and nothing else (ADR-0007), so a
  /// quota at 90% is a longer bar, never a red one.
  private func quotaCell(_ usage: ToolUsage, minutes: Int, now: Date) -> some View {
    let reading = usage.reading(forMinutes: minutes, now: now)
    return HStack(spacing: metrics.caption * 0.45) {
      // `.secondary` like everything else here. The floor for this block is
      // `.secondary`, not `.tertiary`: `caption` is already 0.77 of the size
      // ADR-0013 derived for readability, and stacking an opacity reduction on
      // top of a size reduction puts text under the legible line twice over.
      //
      // Hierarchy comes from the bar being `.primary`, not from grading the text
      // below what can be read. That was the mistake three attempts in a row —
      // "quiet" implemented as "everything dimmer" rather than as "only the one
      // mark that carries information is loud".
      Text(usageWindowLabel(minutes: minutes))
        .foregroundStyle(.secondary)
      quotaBar(reading)
      // `↻` because a window's length and the time until it clears are the same
      // kind of token — `5h` beside `5h` for a five-hour window clearing in five
      // hours, `7d` beside `4d`. Two bare durations in one style are not two
      // facts, they are one unreadable pair.
      //
      // The slot keeps its width when there is no countdown to put in it. An
      // unlimited window has none, and letting that cell collapse dragged
      // everything after it leftwards — so `7d` sat at a different x on each row
      // and two rows that should read as a column did not.
      // `.secondary`, a step above the window label beside it. Everything in this
      // block sat within one grey step of everything else and read as a single
      // smear; a hierarchy needs the steps actually spent. The countdown is data,
      // the `5h` label is scaffolding, so they do not belong at the same weight.
      Text(reading.resetsInText.map { "↻\($0)" } ?? "")
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(width: quotaClearsWidth, alignment: .leading)
    }
    .help(quotaHelp(usage.tool, minutes, reading))
  }

  /// The bar, or the mark that stands in for one where there is no proportion to
  /// show: an unlimited window has no length to fill, an unheard one none to
  /// claim. Drawing either as an empty track would read as "nothing spent yet",
  /// which is a third, different thing (ADR-0023).
  ///
  /// Wide enough that a few percent is a few pixels rather than one — the whole
  /// point of preferring a length over a number is that small values stay
  /// distinguishable from zero.
  private var quotaBarWidth: Double { quotaText * 6 }

  /// Room for `↻` plus the longest countdown a window produces — `↻23h`, `↻7d`.
  /// Reserved rather than measured so every cell is the same width whether or not
  /// it has a countdown at all.
  private var quotaClearsWidth: Double { quotaText * 2.6 }

  @ViewBuilder
  private func quotaBar(_ reading: UsageReading) -> some View {
    // Thicker than a hairline, and stated in the block's own type size so it
    // grows with it. At 2pt the fill and the track were two greys of a line too
    // thin to compare, which is the whole job the bar took over from the number.
    let height = max(3, quotaText * 0.3)
    switch reading {
    case let .spent(percent, _):
      // `.tertiary`, not `.quaternary`. A track nobody can see is not a track:
      // the fill's length only means something against the full extent it could
      // have reached, and on a dark background `.quaternary` vanished into it —
      // leaving a line of varying length with nothing to read it against.
      Capsule().fill(.tertiary)
        .frame(width: quotaBarWidth, height: height)
        .overlay(alignment: .leading) {
          // `.primary`, the loudest thing in the block, because since ADR-0023
          // chose a length over a number this fill *is* the reading — there is no
          // digit beside it to fall back on. A 3pt line at full contrast is still
          // quieter than a word at `.secondary`, so this does not cost the block
          // the restraint ADR-0007 asks of it; it spends what it has on the one
          // mark that carries information.
          Capsule().fill(.primary)
            .frame(width: quotaBarWidth * min(1, max(0, percent / 100)), height: height)
        }
    case .unlimited, .unheard:
      // The mark keeps the bar's width so a tool with no limits does not drag the
      // rest of its row leftwards, and sits centred in it: a single glyph pinned
      // to the leading edge of a wide empty slot reads as something that fell out
      // of place, where a centred one reads as this slot's content.
      Text(reading.text)
        .foregroundStyle(.secondary)
        .frame(width: quotaBarWidth, alignment: .center)
    }
  }

  /// Says in words what the row says in marks. The countdown appears in both,
  /// not only here: ADR-0014 rejects anything reachable by hover alone, and an
  /// earlier draft put the reset time in this tooltip and nowhere else.
  private func quotaHelp(_ tool: ToolKind, _ minutes: Int, _ reading: UsageReading) -> String {
    let window = usageWindowLabel(minutes: minutes)
    switch reading {
    case let .spent(percent, _):
      let clears = reading.resetsInText ?? "?"
      let spent = percent == 0
        ? "just reset, nothing spent yet"
        : "\(Int(percent.rounded()))% spent"
      return "\(tool.label) · \(window) window — \(spent), clears in \(clears)"
    case .unlimited:
      return "\(tool.label) reported its limits and the \(window) window was not one of them"
    case .unheard:
      return "\(tool.label) is not reporting quotas — see Settings for how to enable it"
    }
  }

  private var counts: some View {
    HStack(spacing: metrics.caption * 0.6) {
      countBadge(monitor.snapshot.counts.running, "running", Palette.statusRunning)
      countBadge(monitor.snapshot.counts.waiting, "waiting", Palette.statusWaiting)
      countBadge(monitor.snapshot.counts.idle, "idle", nil)
    }
    // A hard minimum width. Without this the badges narrow by wrapping their own
    // labels, and `running` arrives set one letter per line — while still
    // reporting to `ViewThatFits` that it fitted.
    .lineLimit(1)
    .fixedSize()
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
