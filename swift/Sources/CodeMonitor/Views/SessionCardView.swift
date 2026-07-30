/// A single session tile.
///
/// One view for both shapes, not two. An idle session is this same tile with
/// its detail collapsed and its height reduced — because the alternative, a
/// separate row view swapped in by state, can only ever cross-fade: two
/// different views in two different containers, tied together by a geometry
/// match, read as a hand-off rather than as one thing folding shut. Height is
/// therefore explicit and driven by state, which is the one property SwiftUI
/// can interpolate cleanly.
///
/// Flat and airy: a hairline border, with the background tint following live
/// state (green while running, amber while waiting) and pulsing ("breathing")
/// between two tint steps so the state reads at a glance. Waiting breathes
/// faster than running for urgency. Clicking jumps to the session's terminal.

import SwiftUI

struct SessionCardView: View {
  let session: SessionInfo
  let onFocus: () -> Void
  /// Present only for sessions the user is allowed to close — idle ones.
  var onDismiss: (() -> Void)?

  @Environment(\.colorScheme) private var scheme
  @Environment(\.metrics) private var metrics
  @State private var isHovering = false

  /// Folded only once it has been seen. An idle session that finished while
  /// nobody was looking keeps its card — the shape itself says the ball is in
  /// the user's court, which is the opposite of what folding says (ADR-0018).
  private var isIdle: Bool { session.state == .idle && !session.isUnread }

  /// Height of the detail block when open, stated rather than measured so that
  /// closing it is an interpolation between two numbers. A natural height
  /// cannot be animated to zero — and hiding it with opacity alone left the
  /// space behind, which pushed the header out of a tile clipped to one row.
  private var detailHeight: Double {
    metrics.caption * 1.4 + metrics.cardSpacing + metrics.caption * 1.6
  }

  /// Height of the header row, fixed rather than left to its contents.
  ///
  /// The close button is taller than the title's line — a circle of
  /// `caption × 1.6` against roughly `body × 1.05` of text — so appearing on
  /// hover made it the tallest thing in the row and pushed the whole tile a
  /// couple of points taller. On a folded row that reads as a twitch.
  ///
  /// It is also what `verticalPadding` had been assuming all along, with
  /// nothing enforcing it. Stating it once makes the assumption true.
  private var headerHeight: Double { metrics.body * 1.35 }

  /// Padding that keeps the header centred in a folded tile, so `idleRowHeight`
  /// still describes what a collapsed tile measures.
  private var verticalPadding: Double {
    isIdle
      ? max(metrics.cardSpacing * 0.5, (metrics.idleRowHeight - headerHeight) / 2)
      : metrics.cardPadding
  }

  var body: some View {
    Button(action: onFocus) {
      VStack(alignment: .leading, spacing: isIdle ? 0 : metrics.cardSpacing) {
        header
        detail
          // Both the height and the opacity close. The height is what makes it
          // fold; the opacity keeps text from looking crushed on the way down.
          .frame(height: isIdle ? 0 : detailHeight, alignment: .top)
          .opacity(isIdle ? 0 : 1)
          .clipped()
      }
      .padding(.horizontal, metrics.cardPadding)
      .padding(.vertical, verticalPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .animation(.smooth(duration: 0.18), value: isHovering)
    .modifier(BreathingBackground(session: session, scheme: scheme))
    .overlay(
      RoundedRectangle(cornerRadius: metrics.cornerRadius)
        .strokeBorder(
          isHovering ? Color.secondary.opacity(0.5) : Color.secondary.opacity(0.2),
          lineWidth: metrics.hairline)
    )
    .clipShape(RoundedRectangle(cornerRadius: metrics.cornerRadius))
    .onHover { isHovering = $0 }
    .help("Jump to terminal")
  }

  /// True while the close button is standing in for the elapsed time.
  private var isDismissHovering: Bool { isHovering && onDismiss != nil }

  /// Shown on hover only. A tile that is always wearing a close button invites
  /// being tidied away; this one has to be reached for.
  @ViewBuilder
  private var dismissButton: some View {
    if let onDismiss, isHovering {
      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.system(size: metrics.caption * 0.8, weight: .bold))
          .foregroundStyle(.secondary)
          .frame(width: dismissWidth, height: dismissWidth)
          .background(Circle().fill(.background.opacity(0.75)))
      }
      .buttonStyle(.plain)
      .help("Hide until this session does something new")
      .transition(.opacity.combined(with: .scale(scale: 0.7)))
    }
  }

  /// How long the current state has been going — running, waiting or idle.
  ///
  /// One meaning across all three, because the old one was only accidentally
  /// right: "time since the last write" happens to equal "time in this state"
  /// for waiting and idle, since neither writes anything once it begins. A
  /// running session writes on every tool call, so the same number read as
  /// `2s` for a job ten minutes in — and it was read, correctly, as the state
  /// duration it looked like.
  private func elapsed(at now: Date) -> String {
    Self.relativeTime(session.stateSince ?? session.lastActivity, now: now)
  }

  /// Width the close button occupies, and therefore the width the elapsed time
  /// keeps clear of it. Derived rather than guessed twice: the button is its
  /// glyph plus padding on both sides, and the previous reservation was smaller
  /// than that, so the button sat on top of the time it was meant to avoid.
  private var dismissWidth: Double { metrics.caption * 1.6 }

  /// How often the age re-reads the clock. Five seconds is finer than any
  /// number it displays — the smallest unit shown is a second, and below a
  /// minute a five-second step is not something a glance resolves — while
  /// staying far cheaper than a per-second redraw on a display where motion is
  /// the expensive thing (ADR-0006).
  private static let tick: TimeInterval = 5

  @ViewBuilder
  private var toolMark: some View {
    if let icon = ToolIcon.image(for: session.tool) {
      // Colour follows the tile's weight rather than being fixed. An
      // application icon is drawn to win a Dock, so on a folded, finished
      // session it would be the loudest thing on it — and which tool a session
      // belongs to is the one fact about it that never changes (ADR-0007). A
      // live tile earns the colour back: everything on it is meant to be read.
      Image(nsImage: icon)
        .resizable()
        .interpolation(.high)
        .aspectRatio(contentMode: .fit)
        .saturation(isIdle ? 0 : 1)
        .opacity(isIdle ? 0.5 : 1)
    } else {
      // No application installed — the CLIs run without one.
      Image(systemName: session.tool.symbolName)
        .font(.system(size: metrics.caption * 0.95))
        .foregroundStyle(isIdle ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
    }
  }

  /// Present in both shapes, so nothing about it moves when the tile folds.
  private var header: some View {
    HStack(alignment: .center, spacing: metrics.cardSpacing * 0.7) {
      Circle()
        .fill(session.isUnread ? Palette.statusUnread : Palette.statusColor(session.state))
        .frame(width: metrics.caption * 0.55, height: metrics.caption * 0.55)

      // Which tool this is, on the card rather than in a group header. Grouping
      // by tool sorted brand above urgency — a waiting Codex session sat below
      // every read Claude one — so the tool has to be legible without it
      // (ADR-0014). The application's own icon rather than a symbol: it is
      // already what the user clicks on, so it needs no learning.
      toolMark
        .frame(width: metrics.body * 0.85, height: metrics.body * 0.85)
        .help(session.tool.label)

      Text(session.project)
        .font(.system(size: isIdle ? metrics.body * 0.88 : metrics.body,
                      weight: isIdle ? .regular : .semibold))
        .foregroundStyle(isIdle ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        .lineLimit(1)
        .truncationMode(.middle)

      if isIdle, session.subagentCount > 0 {
        Label("\(session.subagentCount)", systemImage: "circle.hexagongrid")
          .font(.system(size: metrics.caption * 0.9))
          .foregroundStyle(.tertiary)
      }

      Spacer(minLength: metrics.cardSpacing * 0.5)

      // Driven by a clock, not by the scan. An idle session's `SessionInfo` is
      // identical between scans, so SwiftUI rightly skips re-evaluating this
      // card — and `Date()` lives inside that evaluation, which left the age
      // frozen at whatever it read when the session went quiet. Only the label
      // is inside the timeline, so nothing else redraws on the tick.
      TimelineView(.periodic(from: .now, by: Self.tick)) { context in
        Text(elapsed(at: context.date))
          .font(.system(size: metrics.caption))
          .monospacedDigit()
          .foregroundStyle(.tertiary)
      }

      // In the row rather than floating over it. As an overlay the button could
      // neither push the time aside nor sit level with the title — its vertical
      // position was a padding guess, correct at one row height and wrong at
      // every other, which is every other screen (ADR-0013). Laid out here, the
      // stack's own alignment centres it against the title, and the time simply
      // makes room.
      dismissButton
    }
    .frame(height: headerHeight)
  }

  /// Everything an idle session does not get. Dropped because of state, not
  /// because of size — these stay on an active tile even on a small screen,
  /// and come back the moment the session acts again (ADR-0013).
  private var detail: some View {
    VStack(alignment: .leading, spacing: metrics.cardSpacing) {
      metaRow
      statusRow
    }
  }

  private var metaRow: some View {
    HStack(spacing: metrics.cardSpacing * 0.6) {
      if session.gitBranch != nil {
        Image(systemName: "arrow.trianglehead.branch")
          .font(.system(size: metrics.caption * 0.9))
          .foregroundStyle(.tertiary)
      }
      if !metaText.isEmpty {
        Text(metaText)
          .font(.system(size: metrics.caption))
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
    }
    // Reserved even when empty so tiles keep a uniform height.
    .frame(height: metrics.caption * 1.4, alignment: .leading)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var statusRow: some View {
    HStack(spacing: metrics.cardSpacing) {
      StatusPill(label: session.statusLabel)
      if session.subagentCount > 0 {
        Label("\(session.subagentCount)", systemImage: "circle.hexagongrid")
          .font(.system(size: metrics.caption))
          .foregroundStyle(.secondary)
          .help("\(session.subagentCount) sub-agent\(session.subagentCount == 1 ? "" : "s") running under this session")
      }
      if let message = session.lastMessage {
        Text(message)
          .font(.system(size: metrics.caption))
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var metaText: String {
    [session.gitBranch, session.model.map(Self.shortModel)]
      .compactMap { $0 }
      .joined(separator: " · ")
  }

  private static func shortModel(_ model: String) -> String {
    var short = model
    for prefix in ["claude-", "anthropic/"] where short.hasPrefix(prefix) {
      short.removeFirst(prefix.count)
    }
    return short
  }

  /// Kept as the name every call site already uses; the arithmetic moved to
  /// `RelativeSpan` so the quota countdown formats identically (ADR-0023).
  static func relativeTime(_ date: Date, now: Date = Date()) -> String {
    RelativeSpan.since(date, now: now)
  }
}

/// Pulses the tile background between two tints of the same hue.
/// Falls back to a static tint when the system asks for reduced motion.
private struct BreathingBackground: ViewModifier {
  let session: SessionInfo
  let scheme: ColorScheme

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Redraw rate of the tint. The breath itself is seconds long, so this only
  /// has to be fine enough that the fade reads as continuous.
  private static let fps = 30.0

  func body(content: Content) -> some View {
    let breath = Palette.breath(for: session.state, scheme: scheme)
    // Only the state and the accessibility setting decide this now. A third
    // condition used to withhold the pulse from a *guessed* block; guessed
    // blocks no longer exist, since `waiting` can only be something a tool
    // reported (ADR-0020).
    let animates = breath != nil && !reduceMotion

    content.background {
      if let breath, animates {
        // Phase is read off the wall clock rather than held in state, which is
        // what puts every card of the same state in step: two running sessions
        // brighten and dim together instead of each starting its own cycle
        // whenever it happened to appear. Several cards breathing as one is a
        // single signal; the same cards out of phase are several, on a display
        // whose scarcest resource is motion (ADR-0006).
        //
        // It also removes a whole class of defect. The previous version drove
        // this from a `lit` flag toggled on appearance, and a session that went
        // idle and came back found the flag already true — no change for the
        // repeating animation to react to, so that card silently stopped
        // breathing. A phase computed from time cannot get stuck.
        TimelineView(.periodic(from: .now, by: 1 / Self.fps)) { context in
          Rectangle().fill(tint(breath, at: context.date))
        }
      } else {
        // Idle, which has no breath at all — or reduced motion, where a card
        // that would breathe rests at the lit end instead, so the state still
        // reads as its colour without anything moving.
        Rectangle().fill(breath?.to ?? Palette.resting(scheme))
      }
    }
  }

  private func tint(_ breath: (from: Color, to: Color, period: Double), at now: Date)
    -> Color
  {
    // Absolute time, so the cycle is anchored to the same origin for everyone.
    let turns = now.timeIntervalSinceReferenceDate / breath.period
    let wave = (1 - cos(2 * .pi * turns)) / 2  // 0…1, smooth at both ends
    let from = NSColor(breath.from), to = NSColor(breath.to)
    return Color(from.blended(withFraction: wave, of: to) ?? to)
  }
}
