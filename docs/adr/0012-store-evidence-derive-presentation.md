# Store evidence, derive presentation

Seven defects landed in one small region of this codebase — the state
classification, its lifecycle windows, and the hook's event mapping. Roughly 150
lines produced: a finished session pinned as "waiting approval" forever, an
untouched session shown as running for 86 minutes, a session whose process had
died staying on screen permanently, a process-only card locking the app at full
poll rate, a dismissal that undid itself on the next scan, a live pid attached
to a dead session, and — found by inspection rather than by being hit — a
process scan failure emptying the entire list.

They are one defect. `SessionState` was doing four jobs: naming what the agent
is doing, deciding how long the card stays on screen, choosing its colour and
animation, and setting the app's poll rate. An error in the first became an
error in all four at once, which is why a single wrong `running` both
mislabelled a card and pinned the machine at full rate forever.

A session therefore stores *evidence* and derives everything else from it:

```
Evidence                          Derived
  lastEvent   what happened         state       ← event, age, source
  at          when                  lifetime    ← age, liveness
  source      inferred | reported   appearance  ← state, source
  liveness    alive|absent|unknown  cadence     ← state
```

Nothing derived feeds another derivation. Lifetime in particular no longer
consults state, which is what made a mistaken `waiting` immortal.

## Evidence is what a source can honestly say

Sources differ enormously in what they know, and the vocabulary is the common
denominator rather than the richest member: `turnInFlight`, `blockedOnUser`,
`turnComplete`, `opened`, `unknown`. A Claude hook reports a precise event; a
Claude transcript supports a guess; a Codex rollout gives `task_complete` or
silence; OpenCode's store gives a timestamp and nothing else, which is exactly
what `unknown` is for.

Hooks report the event name and nothing more. Previously the interpretation
lived in the hook's registration — `codemonitor-hook.sh running "$PPID"` — which
made a shell argument in the user's `settings.json` the authoritative definition
of what a state means. Both mapping defects could only be fixed by editing that
file: back it up, append carefully, re-verify. Interpretation belongs in one
Swift function that can be changed in a line and tested without touching
anything the user owns.

## Liveness has three values, not two

`live: Bool` conflated "confirmed absent" with "could not tell", and each of
those confusions produced a defect at opposite extremes: a dead session treated
as alive never expired, and a failed process scan would have marked every
session dead and emptied the list five minutes later. `unknown` is a real
observation and the type now says so, which forces each use to decide what it
means rather than defaulting to "absent".

## Inferred and reported are not shown alike

`CONTEXT.md` already called inferred state the weaker claim; the display treated
them identically. A reported `waiting` means Claude Code fired
`PermissionRequest`. An inferred one means a tool call has been quiet for 45
seconds, which is a guess that has been wrong. Both appear, but only the
reported one animates — the cost of a wrong guess should not be an
attention-grabbing card that never goes away.

## Consequences

More indirection: reading a card's colour now means reading the derivation
rather than a stored field. In exchange there is one place where each output is
decided, and each can be tested against evidence directly instead of by
arranging a session on disk.

The hook's registration in `settings.json` has to change one final time, to stop
passing a state. After that, mapping changes never touch the user's
configuration again.
