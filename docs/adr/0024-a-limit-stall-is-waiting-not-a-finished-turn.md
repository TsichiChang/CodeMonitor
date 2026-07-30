# A limit stall is waiting, not a finished turn

A session cut off by a usage limit currently reads as `idle`. The record Claude
Code writes when it stops looks like this:

```
type: assistant   model: <synthetic>   stop_reason: stop_sequence
isApiErrorMessage: true
text: "You've hit your session limit · resets 8:20pm (Asia/Shanghai)"
```

And `ClaudeSource.activity` maps `stop_reason == "stop_sequence"` to
`turnComplete`, so the card folds to a dim line and sorts below everything —
saying "nothing to do here" about work that stopped mid-task and needs a decision.

This is ADR-0018's defect arriving through a door nobody had checked. That ADR
was written because folding on a finished turn "was playing the most important
thing that happens as a disappearance"; the same fold now hides a stall.

It is not rare. Across 857 transcripts:

```
"hit your session limit · resets"    975   the five-hour window
"reached your Fable 5 limit"          50   model-specific
"reached your usage limit"             3
```

**The decision: a session stopped by a usage limit is `waiting`.** It matches what
`CONTEXT.md` already defines — the agent has stopped and cannot continue without
the user — and there is a real action: wait, switch models, or buy credits.

## `isApiErrorMessage` is not the discriminator

The flag looks like a clean hook and is not. It covers 124 records on this
machine, and most are something else: 401 and 403 authentication failures, "Not
logged in", connection closed mid-response, `ECONNRESET`. Those are not one state
— a dropped connection retries by itself, a login failure blocks the user with a
different remedy.

So detection is the flag **and** the text, and the fragility has to be stated:
when the wording changes, the record falls through `stop_reason == "stop_sequence"`
to `turnComplete` and the stall silently reads as `idle` again.

That is the expensive direction, not the safe one. ADR-0019's asymmetry — a
missing "this is running" costs a glance, a false "this needs you" spends
attention on nothing — does not apply here, because the failure is a *missing*
"this needs you", and what it costs is the whole stall going unnoticed, which is
the thing ADR-0014 measured. Two phrasings have held across a month of data. That
is the entire evidence, and a phrasing change is a silent regression.

## This falsifies ADR-0020's "exactly one source"

`blockedOnUser` gains a second producer, so that property stops holding. **The
correction is written in ADR-0020**, as a blockquote on the paragraph that claims
it, not argued around here — an earlier draft did the latter and it was the wrong
place, because a reader of ADR-0020 would have found an unmarked claim that was no
longer true.

What survives is the half that was doing the work: ADR-0020's argument was
**reported versus guessed**, never hook versus transcript. A flagged statement
that the model refused is not a guess, whatever channel carries it. `waiting`
still cannot be invented from silence.

Two comments were written on the stronger reading and are wrong for the reason
they give, though their conclusions hold:

```
AmbientBand.swift:53   dropped its second filter condition, "because every
                       `waiting` was reported: exactly one source can produce it"
Session.swift:196      deleted `deservesAttention`, `true` since ADR-0020 because
                       "`blockedOnUser` is emitted by the hook store alone"
```

## `EvidenceSource` has to mean strength, not channel

```swift
/// Read off timestamps and file contents. A guess, and guesses have been wrong.
case inferred
/// The tool said so itself.
case reported
```

By that wording a limit event is `inferred` — it is literally read off file
contents. Then `waiting` becomes producible by inference, ADR-0012's "inferred and
reported are not shown alike" collapses, and the two deletions above rest on a
false premise.

So the field is **reported**, and the comment changes with it: `inferred` means
*we guessed what the file implies*; `reported` means *the tool stated it* —
usually through a hook, and through a flagged transcript record where no hook
event exists.

This is the conflation this codebase keeps finding: how a fact arrived and how
much it is worth were riding in one value. ADR-0012 needed the second meaning all
along — "inferred state is the weaker claim" is about strength — and the channel
reading held only while hooks were the sole strong channel.

## The grant retraction must not reach this

ADR-0019 retracts a block when a child process starts after it, because approval
fires no event of its own. That check runs on **every** `blockedOnUser` with a pid
(`SessionScanner.swift:32`), and here it is simply wrong: nothing a local process
does clears a usage limit. One MCP server restarting would flip the card back to
`running`, and because `resolvingGrant` also rewrites `at`, it would reset the
elapsed time along with it.

So `blockedOnUser` has to carry one bit: **whether a local answer could clear it.**
Permission prompts, yes — that is ADR-0019's whole mechanism. Limit stalls, no.

ADR-0019 refused a fourth `Activity` value, and the reason it gave was "to
describe a condition nothing else distinguishes". That reason no longer holds:
two things now distinguish it, the retraction and the card's label. The mechanical
cost is also smaller than that ADR implies, because ADR-0012 has since collapsed
the branching into one switch — outside `state()` and the tests, only two sites
read a specific activity, and both are this retraction. A distinct value makes the
misfire impossible rather than guarded, since the guard already reads
`== .blockedOnUser`.

**What that bit is called and where it lives is left open**, because it also
settles the card's label, and one thing it no longer has to settle is the reset
time — see below.

## The countdown is not this ADR's

An earlier draft assumed the reset time had to ride on the block, since it appears
in the stall message. It does not. `rate_limits.five_hour.resets_at` is
account-level state available at any time through the channel ADR-0023 describes,
whether or not anything is stalled.

So the label here says what is being waited on; it does not have to say until when.
"Waiting approval" is wrong for these and has to stop naming a cause it can no
longer guarantee, but the clock belongs to the account, not to the session that
happened to hit it.

## Consequences

`waiting` stops being synonymous with a permission prompt, in the vocabulary as
well as on screen. `CONTEXT.md` already says "most importantly, blocked on a
permission prompt" — "most importantly" now has a second member rather than being
a description of the only one.

The ambient band lights amber for a limit stall. That is correct and was
previously impossible: ADR-0015 split dead wait into approval waits and finished
turns because those were the two classes it could see. This is a third, and it was
invisible on every surface.

## How this gets falsified

The regression test is the history rather than a constructed case: **1,028 records
already on disk** are read as `turnComplete` today, and after the change every one
must read `waiting`. That is stronger than anything in `--selftest`, where each
assertion stands for one defect seen once — and it costs nothing to re-run, since
the corpus only grows.

The mislabelling itself is certain — it follows from the mapping in
`ClaudeSource.activity`, which is code rather than observation. What twenty-four
days of data cannot settle is whether showing it correctly saves any time. The
base rate is high enough that a week of running will say something, which is the
opposite of what an earlier draft concluded from a five-event sample it had
mistaken for the whole.
