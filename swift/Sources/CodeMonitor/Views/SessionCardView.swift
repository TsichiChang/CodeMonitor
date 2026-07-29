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

  /// Padding that keeps the header centred in a folded tile, so `idleRowHeight`
  /// still describes what a collapsed tile measures.
  private var verticalPadding: Double {
    isIdle
      ? max(metrics.cardSpacing * 0.5, (metrics.idleRowHeight - metrics.body * 1.35) / 2)
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
    .modifier(BreathingBackground(session: session, scheme: scheme))
    .overlay(
      RoundedRectangle(cornerRadius: metrics.cornerRadius)
        .strokeBorder(
          isHovering ? Color.secondary.opacity(0.5) : Color.secondary.opacity(0.2),
          lineWidth: metrics.hairline)
    )
    .clipShape(RoundedRectangle(cornerRadius: metrics.cornerRadius))
    .overlay(alignment: .topTrailing) { dismissButton }
    .onHover { isHovering = $0 }
    .help("Jump to terminal")
  }

  /// Shown on hover only. A tile that is always wearing a close button invites
  /// being tidied away; this one has to be reached for.
  @ViewBuilder
  private var dismissButton: some View {
    if let onDismiss, isHovering {
      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.system(size: metrics.caption * 0.8, weight: .bold))
          .foregroundStyle(.secondary)
          .padding(metrics.caption * 0.4)
          .background(Circle().fill(.background.opacity(0.75)))
      }
      .buttonStyle(.plain)
      .padding(.top, isIdle ? metrics.caption * 0.5 : metrics.cardPadding * 0.79)
      .padding(.trailing, metrics.cardPadding * 0.5)
      .help("Hide until this session does something new")
      .transition(.opacity)
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

  /// How often the age re-reads the clock. Five seconds is finer than any
  /// number it displays — the smallest unit shown is a second, and below a
  /// minute a five-second step is not something a glance resolves — while
  /// staying far cheaper than a per-second redraw on a display where motion is
  /// the expensive thing (ADR-0006).
  private static let tick: TimeInterval = 5

  /// Present in both shapes, so nothing about it moves when the tile folds.
  private var header: some View {
    HStack(alignment: .center, spacing: metrics.cardSpacing * 0.7) {
      Circle()
        .fill(session.isUnread ? Palette.statusUnread : Palette.statusColor(session.state))
        .frame(width: metrics.caption * 0.55, height: metrics.caption * 0.55)

      // Which tool this is, on the card rather than in a group header. Grouping
      // by tool sorted brand above urgency — a waiting Codex session sat below
      // every read Claude one — so the tool has to be legible without it.
      Image(systemName: session.tool.symbolName)
        .font(.system(size: metrics.caption * 0.95))
        .foregroundStyle(.tertiary)
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
        // The close button is an overlay in this corner; its width is reserved
        // whether or not it shows, so the time never jumps sideways on hover.
        .padding(.trailing, onDismiss == nil ? 0 : metrics.body * 0.9)
    }
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
      StatusPill(state: session.state)
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

  static func relativeTime(_ date: Date, now: Date = Date()) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date).rounded()))
    if seconds < 60 { return "\(seconds)s" }
    let minutes = Int((Double(seconds) / 60).rounded())
    if minutes < 60 { return "\(minutes)m" }
    let hours = Int((Double(minutes) / 60).rounded())
    if hours < 24 { return "\(hours)h" }
    return "\(Int((Double(hours) / 24).rounded()))d"
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
    // A guessed block does not get to pulse. Reported `waiting` means Claude
    // Code fired `PermissionRequest`; inferred means a tool call has been quiet
    // for 45 seconds, and that guess has been wrong (ADR-0012).
    let animates = breath != nil && session.deservesAttention && !reduceMotion

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
        // Breathes but may not — an inferred block — rests at the lit end, so
        // it still reads as amber without demanding attention (ADR-0012).
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
