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
