# Waiting is only ever reported

An amber card appeared on the dashboard while the ambient band stayed dark. Both
surfaces were behaving as designed, which is the problem: the band lights only
for a *reported* block (ADR-0014), while the card painted reported and inferred
blocks the same amber and merely withheld the breathing. ADR-0012 said "both
appear, but only the reported one animates" and stopped one step short — colour
asks for attention too, and at reading distance it asks harder than motion does.

The fix is not to tint the guess more weakly. It is that the guess should not
exist.

`waiting` had two entrances. One was a tool saying so: `PermissionRequest`, or a
`Notification` whose subtype is a permission prompt. The other was inference —
a dispatched tool that had gone quiet for 45 seconds *might* be blocked, so it
was shown as blocked. That is a guess about the single state this display exists
to get right.

**Its premise has since been removed.** The guess was for sessions with no hook,
where silence was the only available hint; ADR-0001 accepted that setup cost,
and hooks stayed a manual edit of two config files. They are now installed by
the app itself. So the sessions still lacking one are the sessions where
reporting has broken — and there a wrong `waiting` costs more than a missing
one, by the same asymmetry ADR-0019 records: a card that fails to say "running"
costs a glance, one that says "this needs you" when it does not spends the only
currency this display has.

Nothing it detected has become invisible. A card now shows how long its current
state has run (ADR-0018), so a genuinely stalled turn reads as `running 12m` —
which states a fact rather than making a claim about why.

## What this buys

`waiting` acquires a property none of the other states have: **exactly one
source can produce it.** `blockedOnUser` is emitted only by the hook store, and
`waiting` is derived only from `blockedOnUser`. Everything else — which session
is running, which is idle — may be inferred from a transcript, a rollout, a
bare process, and being wrong about those costs a glance.

One thing may still overturn it, in the safe direction: a child process started
after the prompt retracts the block, because approval fires no event of its own
(ADR-0019). Inference may take a `waiting` away. It may no longer invent one.

## Consequences

A session with no working hook, sitting on a permission prompt, shows as
`running` until it ages out. That is the case this ADR chooses to under-report,
and the elapsed time on its card is what remains to notice it by.

`Aging.approvalSuspect` is deleted rather than raised. A larger threshold would
be the same guess made later, and the argument here is not that 45 seconds was
too short — it is that silence never meant a permission prompt in the first
place.
