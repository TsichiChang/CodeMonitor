/// A duration as a person reads it at a glance: `4s`, `12m`, `3h`, `2d`.
///
/// One formatter for every span the app shows, in both directions — how long a
/// card's state has run, and how long until a quota window clears. Two
/// formatters would have drifted: this one rounds rather than truncates, so 119
/// seconds reads `2m` and not `1m`, and a countdown that disagreed with an
/// elapsed time about that would look like a bug in whichever was read second.

import Foundation

enum RelativeSpan {
  /// Coarsest unit that keeps the number small. Never negative — a span is a
  /// length, and a caller with a date in the wrong order should read `0s` rather
  /// than a minus sign.
  static func text(_ seconds: TimeInterval) -> String {
    let whole = max(0, Int(seconds.rounded()))
    if whole < 60 { return "\(whole)s" }
    let minutes = Int((Double(whole) / 60).rounded())
    if minutes < 60 { return "\(minutes)m" }
    let hours = Int((Double(minutes) / 60).rounded())
    if hours < 24 { return "\(hours)h" }
    return "\(Int((Double(hours) / 24).rounded()))d"
  }

  /// How long ago `date` was.
  static func since(_ date: Date, now: Date = Date()) -> String {
    text(now.timeIntervalSince(date))
  }
}
