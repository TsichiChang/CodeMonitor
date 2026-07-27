---
status: superseded by ADR-0011 for transcripts; still applies to hook state files
---

# Watch the files, don't poll them

> **Partly superseded.** Watching transcripts does not deliver the transition
> that matters: a session becomes `waiting` by a tool call going *unanswered*,
> so the signal is the absence of an event and a timer is required regardless.
> ADR-0011 replaced transcript watching with a cadence that follows state.
>
> The argument survives for the state files in ADR-0010. Once a hook reports
> `waiting`, that *is* an event, and the directory it lands in is small and
> high-signal — the opposite of the transcript tree this ADR proposed watching.

A two-second poll cost about 6.5% of a core continuously — roughly 90 minutes of
CPU time a day for a status display. Measured per cycle: ~30ms for `ps` to walk
706 processes, under 10ms per `lsof`, and ~92ms inside the app itself. The app's
own share dominated, and most of it was avoidable: `String.range(of:options:
.regularExpression)` recompiles its pattern on every call, and the process scan
ran up to seven patterns against each of 706 command lines every cycle.

Rendering, which was the suspected culprit, turned out to be free: holding the
poll off dropped the app to 0.07% with the window open and cards animating.
Core Animation drives the breathing on the compositor, not the CPU.

All three data sources are files, so all three can be watched. Sessions are now
refreshed on file-system events, with a slow timer left in place for the parts
that are not event-driven — ageing sessions out, and the liveness check from
ADR-0005.

## Consequences

This is both cheaper and faster than polling: idle cost approaches zero, and a
change is seen in under a second instead of up to two.

Writes are bursty — median 1.41s apart, but 9.3% land within 100ms of the
previous one — so events must be coalesced. The file-system event stream's own
latency parameter does this in the kernel; a debounce in application code is not
needed.

Incremental parsing was considered and rejected. Once the process scan and the
regex recompilation are gone, a full rescan is a few milliseconds, and at the
coalesced event rate that is not worth the complexity of tracking which session
changed.

The context that makes this worth doing is that the machine runs several coding
agents at once. The cost of polling was never battery — it was CPU taken from
the very agents the app exists to watch.
