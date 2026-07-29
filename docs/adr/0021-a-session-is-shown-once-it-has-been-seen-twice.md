# A session is shown once it has been seen twice

Switching to a conversation that has not been opened for a while makes the
desktop app load several sessions for a moment. Each of them fires a hook or
touches a transcript, becomes a card, and is gone one or two seconds later. What
the app's own log caught:

```
globalpay_cashier     1ed3adae     17:27:58–17:27:59    1 second
CodeMonitor           bfdd2218     17:28:06             1 second
cyber-ops-team        b24391af     17:28:15             one scan
globalpay-workspace   pid-42409    17:28:29             one scan
```

They are all real sessions — each carries its own UUID, so this is not one
session counted four times. The problem is that nothing about any of them can be
acted on in the time it exists. A card that appears and vanishes is motion and
nothing else, and motion is the most expensive thing on a display that lives in
peripheral vision (ADR-0006).

**The decision: a session is displayed only once it has been present in two
consecutive scans.** The cost is that a genuinely new session appears one cycle
late — about two seconds while anything is running. What it buys is that
everything on screen was there long enough to be worth reading, which is the
premise the whole display rests on (ADR-0007).

## Nothing is stored about why

There is no pending flag, no timer and no per-session bookkeeping. A session is
withheld because it is not yet in the previous scan's set, and the next scan
fixes that by itself — the same shape as unread being derived from two
observations rather than stored as state (ADR-0012, ADR-0018). Nothing has to
remember to clear anything.

One ordering carries the whole mechanism: the seen set is recorded **before**
withholding, not after. Recorded after, a withheld session would never enter the
set the next scan compares against, so it would be withheld forever. That
deadlock is reachable only along the path this rule exists to handle, which is
why it is stated here rather than left to the code to imply.

The first scan of a launch has no previous set at all, and shows everything.
Withholding the entire list for a cycle would leave the window empty at the one
moment it is most likely to be opened and looked at.

## The method error was the more expensive one

This went unexplained for a while because it was chased with `--diagnose`, and
`--diagnose` cannot answer it: it is a **separate process that scans again**. The
card on screen belongs to one of the app's scans, and by the time a second
process looks, two seconds later, it is gone. Four sources reporting "nothing
here" only established that they were empty at the moment of that scan; it said
nothing about the moment the card appeared.

What settled it was `snapshotLog` — off by default, diagnostic only — which
appends what each scan actually produced, from inside the app. It caught the
sequence on the first attempt. The general form is worth keeping: a question
about *the running app* cannot be answered by a second process that reproduces
its inputs.

## Consequences

A session that drops off the display and comes back is now absent for at least
one scan **by construction**, not by accident. Anything that prunes per-session
state on absence from a single scan therefore prunes it for every session that
returns. The dismissal map already refuses to do this — it expires entries by
age, having once deleted a dismissal moments after it was made — and that rule
is no longer a lesson about dismissals specifically. It applies to every map
keyed on a session id.

A session that exists for less than one poll interval is now invisible rather
than briefly visible. That is the intent, and it is not free: an agent that
starts, does something and exits inside two seconds leaves no trace on the
display. Nothing that short can be attended to, so the trade stands, but it is a
deliberate blind spot rather than an oversight.
