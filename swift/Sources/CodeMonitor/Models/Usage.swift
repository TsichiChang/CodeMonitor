/// How much of a quota window is spent, and when it clears (ADR-0023).
///
/// Account-level, not per-session: there is no such thing as "this machine's
/// usage" to aggregate. Claude's five-hour window and Codex's seven-day one are
/// different accounts on different plans, so there is no sum and no maximum —
/// only several independent readings, which is why the display groups by tool
/// and never puts a number where a session's own facts go.

import Foundation

/// One quota window's reading.
///
/// Identified by **length**, never by the slot it arrived in. Claude names its
/// windows (`five_hour`, `seven_day`); Codex fills positional slots whose
/// meaning is only recoverable from `window_minutes` — on this machine `primary`
/// was the seven-day window 3,799 times and the five-hour window 307, so keying
/// on the slot would read a different quantity depending on when you looked.
struct UsageWindow: Sendable, Hashable {
  /// The window's length in minutes, and its identity.
  let minutes: Int
  let usedPercent: Double
  let resetsAt: Date
}

/// What one tool last said about its own quotas.
///
/// Its *existence* is the evidence that the tool reported at all, which is what
/// separates "no limit here" from "nothing heard" below.
struct ToolUsage: Sendable, Hashable {
  let tool: ToolKind
  /// Only the windows the tool actually named.
  let windows: [UsageWindow]
  /// When the reading was taken.
  let observedAt: Date
}

/// What to show for one window.
enum UsageReading: Sendable, Hashable {
  /// A live reading: how much is spent, and how long until it clears.
  case spent(percent: Double, resetsIn: TimeInterval)
  /// The tool listed its limits and this window was not among them, so nothing
  /// constrains it. Rendered `∞`.
  case unlimited
  /// Nothing was heard, or what was heard describes a window that has since
  /// rolled over. Rendered `—`.
  case unheard
}

extension ToolUsage {
  /// Window lengths the display asks about whether or not they were reported:
  /// the two both vendors have a name for.
  ///
  /// Asking about a window nobody mentioned is the point — that is how `∞` gets
  /// said. Codex withdrew its five-hour window in July 2026, and "no five-hour
  /// limit" is a fact worth showing rather than a blank.
  static let canonicalMinutes = [300, 10_080]

  /// Every window worth a column, shortest first, **across all tools**.
  ///
  /// Shared rather than per-tool so the table is rectangular: a tool with one
  /// extra window would otherwise push its own row's cells out of line with the
  /// others, and a column of numbers that does not line up is harder to read
  /// than no column at all.
  ///
  /// A tool that never mentioned a column still gets a cell, and that cell reads
  /// `∞` — which is exactly right by this ADR's own rule: the tool listed its
  /// limits and this was not among them.
  static func columns(across readings: [ToolUsage]) -> [Int] {
    Set(canonicalMinutes + readings.flatMap { $0.windows.map(\.minutes) }).sorted()
  }

  /// The reading for one window length.
  ///
  /// A window the tool never named is `unlimited` — it enumerated its limits and
  /// this was not among them. Nothing heard from the tool at all is the absence
  /// of a `ToolUsage`, which the caller renders as `—`.
  ///
  /// **A rolled-over window reads `0%`, and that number is derived rather than
  /// reported.** An earlier rule said `—` here, on the grounds that claiming a
  /// fresh window was empty would be measuring something nobody measured. That
  /// was over-cautious in a way worth recording: the reset time and the window's
  /// length together *say* where the new window starts and how much of it has
  /// elapsed, so zero is a derivation, not an invention — the same standard the
  /// rest of the model holds (ADR-0012).
  ///
  /// The failure mode is real but narrow. A derived `0%` is optimistic: usage may
  /// have happened since the rollover and no payload has arrived to say so. That
  /// only occurs while nothing is writing — and nothing writes while nothing is
  /// running, which is exactly when a quota cannot be about to bite. The stale
  /// case and the case where it matters do not overlap.
  func reading(forMinutes minutes: Int, now: Date) -> UsageReading {
    guard let window = windows.first(where: { $0.minutes == minutes }) else {
      return .unlimited
    }
    let remaining = window.resetsAt.timeIntervalSince(now)
    if remaining > 0 { return .spent(percent: window.usedPercent, resetsIn: remaining) }

    // Rolled over, possibly more than once if nothing has written for a while.
    // Advance whole windows from the last known boundary rather than from `now`,
    // so the countdown lands on the vendor's own cadence.
    let span = TimeInterval(minutes * 60)
    let elapsedWindows = (-remaining / span).rounded(.down) + 1
    return .spent(percent: 0, resetsIn: remaining + elapsedWindows * span)
  }
}

extension UsageReading {
  /// The percentage, or the mark that stands in for one.
  var text: String {
    switch self {
    case let .spent(percent, _): "\(Int(percent.rounded()))%"
    case .unlimited: "∞"
    case .unheard: "—"
    }
  }

  /// How long until this window clears, in the same units a card's elapsed time
  /// uses — one formatter, so the two cannot drift apart.
  var resetsInText: String? {
    guard case let .spent(_, remaining) = self else { return nil }
    return RelativeSpan.text(remaining)
  }
}

/// A window length as a person says it: `5h`, `7d`, `12h`.
func usageWindowLabel(minutes: Int) -> String {
  if minutes % (60 * 24) == 0 { return "\(minutes / (60 * 24))d" }
  if minutes % 60 == 0 { return "\(minutes / 60)h" }
  return "\(minutes)m"
}
