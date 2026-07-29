# The poll cadence follows session state, not the filesystem

Scanning every two seconds around the clock cost about 34 minutes of CPU a day
on a display that is meant to sit in the corner of a desk indefinitely. The
cadence now depends on what the last scan found: full rate while any session is
`running`, and every fifteen seconds otherwise, which costs about 9 minutes a
day.

Only a `running` session changes on its own. `idle` and `waiting` are both
static until the user does something, so polling them at full rate re-reads
files to learn nothing.

## Considered options

Watching the filesystem was the obvious idea and does not work here. The
transition that matters most — a session becoming `waiting` — is defined by a
tool call going *unanswered* for long enough. The signal is the absence of an
event, so no file-watching API can deliver it and a timer is required anyway.
Once the timer exists, watching adds responsiveness for new activity but saves
nothing.

State-driven cadence gets that transition sharp for free: a session is `running`
right up until the threshold passes, so the fast cadence is still in force at
the moment it flips.

## Consequences

Activity that begins while everything is quiet can take up to fifteen seconds to
appear. That is the cost of the arrangement, and it applies only when nothing is
running — once anything is, the display is back to two seconds.

It also puts weight on state being right. A process the scan cannot match to any
session is reported `idle` rather than `running` for this reason: claiming
activity we cannot observe would pin the app at full rate for as long as that
process lived, and one agent quiet for five days did exactly that.

## Amendment: `waiting` costs the fast cadence, and a watch buys most of it back

"Full rate while running, fifteen seconds otherwise" was two cadences, and there
turned out to be a third. By the rule above, `waiting` belongs in the slow tier —
it changes nothing on its own. What that missed is the ambient band: it is lit
for as long as the wait lasts, and the band **going out** is how the user learns
that their answer registered (ADR-0014). Fifteen seconds of amber after the
answer reads as a broken signal, not as thrifty polling. So `waiting` took the
fast cadence, and a wait can run for hours — the state that changes least often
became the one holding the machine at full rate the longest.

Watching the state directory is what buys most of it back. This ADR rejected
file watching because the transition it cares about most — a session *becoming*
`waiting` — is the absence of an event, and that conclusion still stands. A hook
reporting is the opposite: it lands as one small file in a directory of one file
per session, which is the half of ADR-0008 that was never superseded. With a
watch established, `waiting` idles at the slow cadence and a reported event
still reaches the display in well under a second.

Where no watch could be established, `isWatching` is false and the previous
behaviour stands unchanged — a machine with no hook installed keeps paying for
its band in poll rate.

Verified by setting the interval to thirty seconds: writing a state file lit the
band at once and deleting it darkened it at once, which at that interval only
the watch can have done.

### What the watch does not buy back

The one transition it cannot deliver is the one ADR-0019 was written about, and
that ADR came later than this arrangement. **Claude Code fires nothing when
permission is granted.** So the moment the user answers produces no file, and
the block is retracted instead by the child-process check — which runs on a
*scan*, not on an event.

That splits the case the fast cadence was bought for:

- the approved tool finishes quickly, `PostToolUse` fires, the watch delivers it,
  and the band goes out immediately;
- the approved tool takes a while — ADR-0019's minute-long build — and nothing
  is written until it ends, so the band stays lit until the next timer tick: up
  to fifteen seconds of amber after an answer that was already given.

Codex is the worse half of that, having no per-tool events at all (ADR-0001):
nothing is reported between its `PermissionRequest` and its `Stop`.

This is a residue, not a defect to fix by raising the cadence again — that would
put every waiting session back at full rate for hours to shorten one gap to two
seconds. It is recorded so that "the band is slow to go out" is recognised as
this, and measured against the grant path rather than against the watch.

The timer does not go away in any case, for the reason this ADR was written: no
filesystem reports that nothing happened.
