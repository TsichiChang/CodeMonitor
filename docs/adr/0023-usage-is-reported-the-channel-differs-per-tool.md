# Usage is reported; the channel differs per tool

Two questions arrived together — how much of the five-hour window is spent, and
when does the weekly one reset. Both are answerable for both tools that have
limits, and the first draft of this ADR concluded neither was answerable at all.

Neither tool has to be asked. Both hand the numbers over, and they do it through
completely different doors:

| | Claude Code | Codex |
|---|---|---|
| where | the status-line payload — a **push** | inside the rollout — a **store** |
| needs cooperation | yes, one line in a script we must not own | no |
| attribution | last writer wins; only account-level fields usable | per session, all fields attributable |
| window keys | semantic: `five_hour`, `seven_day` | **positional**: `primary`, `secondary` |
| extras | `extra_usage` (disabled at org level here) | `plan_type`, `credits` |

This is ADR-0004's claim landing where it was not expected. That ADR said each
tool's fidelity is "bounded by its own data rather than by the weakest tool's",
and here the tool with no cooperation requirement and the richer payload is the
one whose *stores* ADR-0004 called a trap.

## Claude Code: pushed, and the channel is already occupied

Every status-line invocation gets a JSON payload on stdin:

```json
"rate_limits": {
  "five_hour": { "used_percentage": 28.000000000000004, "resets_at": 1785410400 },
  "seven_day": { "used_percentage": 59,                 "resets_at": 1785798000 }
}
```

Captured on this machine, matching the published schema. `resets_at` is seconds,
the five-hour value is the earlier of the two, and `used_percentage` is an
unrounded double — a float to format, never a string to show.

`statusLine` in `settings.json` is **one object, not an array**, so installing
ours would evict whatever is there — here a 335-line script that already parses
these fields. That is ADR-0001's Codex `notify` finding with the vendor swapped:

> `notify` turned out to be one command per installation … so registering there
> evicts whatever already uses it instead of joining it.

There, ADR-0001 had an escape: the hook arrays coexist. Here there is none, since
no hook event carries `rate_limits`.

**So this app does not install a status line.** It reads a state file, and getting
one written is a line added to the script the user already owns — opt-in, in a
file we do not touch, unbreakable by this app moving or being removed, which is
ADR-0010's property:

```sh
_cm_usage="${CODEMONITOR_USAGE_FILE:-$HOME/.local/state/codemonitor/usage.json}"
if mkdir -p "$(dirname "$_cm_usage")" 2>/dev/null; then
    printf '%s' "$input" > "$_cm_usage.$$" 2>/dev/null
    mv -f "$_cm_usage.$$" "$_cm_usage" 2>/dev/null || rm -f "$_cm_usage.$$" 2>/dev/null
fi
```

### Only `rate_limits` may be read from that file

The captured payload describes **the session that redrew most recently**, which
need not be the session anyone is looking at — the first capture came from a
different project while this conversation ran elsewhere. So the fields split, and
only one half survives:

```
rate_limits.five_hour / .seven_day     account-level, identical everywhere  ✓
extra_usage                            account-level ✓ (absent here)

session_id, cwd, workspace, prompt_id  whichever session wrote last  ✗
context_window.*                       ✗
cost.total_cost_usd                    ✗
model, effort, version, thinking       ✗
```

`context_window.used_percentage` is the tempting one, and exactly what this file
cannot deliver: shown against a named session it would attribute one session's
numbers to another — ADR-0002's error in a new place, a value standing in for an
identity it does not have.

## Codex: in the store, richer, and positionally keyed

Every `token_count` event in a rollout carries it — 4,258 of them across 126
rollouts here:

```json
"rate_limits": {
  "limit_id": "codex",
  "primary":   { "used_percent": 4.0, "window_minutes": 10080, "resets_at": 1785914691 },
  "secondary": null,
  "credits":   { "has_credits": false, "unlimited": false, "balance": "0" },
  "plan_type": "plus"
}
```

No cooperation needed, per-session attribution, and three things Claude does not
give: the window's **length in minutes**, the plan, and a credit balance.

**The slots are positional, and that is the trap.** `primary` is the seven-day
window 3,799 times and the five-hour window 307 times; when both appear,
`secondary` holds the seven-day one. Keying on `primary` would silently read a
different window depending on when you looked. **`window_minutes` is the only
thing that says which window a slot describes** — 300 or 10080 — and it is what
must be matched on.

## A window can be absent because it does not exist, and that is visible

Codex omits the five-hour slot most of the time: 307 events have it, 3,799 do not.
The first reading of that split was wrong in a way worth keeping, because the
mistake is a common one.

It went: `plan_type: "plus"` appears both with the five-hour window (257 events)
and without it (3,594), so the same plan cannot have the limit in one case and
lack it in the other; therefore omission means "not reported". **That aggregated
across five months and a vendor-side change.** Sorted by date the split is not
mixed at all:

```
2026-03-06 → 05-05     only seven-day      228 readings
2026-06-09 → 07-09     only five-hour      307 readings   ← every 5h reading, ever
2026-07-13 → 07-30     only seven-day    3,720 readings
```

Codex introduced a five-hour window and then withdrew it. Every five-hour reading
on this machine falls inside that one month; none before, none after. Same plan,
different eras — and the lesson is that **a population spanning a vendor change is
not one population**, which is the same shape as reading a card's elapsed time
without asking what the clock was measuring.

So omission genuinely can mean the limit does not exist. But "Codex has no
five-hour limit" must not be written into the app either: it was true for a month
and may become false again, and hard-coding vendor state is how ADR-0004's
`state_5.sqlite` trap works — believing a snapshot of someone else's system.

### The rule is derived, not configured

Absence has two meanings and they are distinguishable without knowing anything
about the vendor:

| what happened | what it means | shown |
|---|---|---|
| a payload arrived and this window was **not among its slots** | the tool enumerated its limits and this is not one | **∞** |
| **no payload has arrived at all** | nothing observed | **—** |

A tool that reports its limits and does not mention a window is saying that
window does not constrain it, and `∞` is the honest reading of that. A tool that
has said nothing is not saying anything, and `—` is the honest reading of *that*.
Neither is `0%`, which would claim a fresh window was measured at zero when it was
not measured at all.

This is `Liveness.unknown` a third time — the reason ADR-0012 introduced it was
that `Bool` conflated "confirmed absent" with "could not tell", and each confusion
produced a defect at an opposite extreme. Here the two confusions are `∞` for
unobserved and `—` for genuinely unlimited, and the distinction that separates
them is whether *any* reading arrived.

It also self-corrects: the day Codex reinstates a five-hour window, the slot
reappears in the payload and the display goes back to a percentage with nothing
changed here.

The rolled-over case below is the same rule once more: **nothing observed renders
as nothing claimed.**

## A reading that stops being true, and says so itself

Both channels are snapshots. Claude's stops updating when no session is
redrawing; Codex's stops when no session is writing. A frozen percentage is worse
than none, because it looks live.

`resets_at` makes it self-invalidating, so no separate staleness rule is needed:
**once `resets_at` has passed, the window has rolled over and the percentage
beside it describes a window that no longer exists.** Store what was observed and
when; derive whether it still holds (ADR-0012).

## The error worth recording

The first draft searched transcripts, `~/.claude/`, `~/.claude.json`, the `claude`
CLI's subcommands, and the API's rate-limit response headers, and concluded the
allowance was unobservable.

Every one of those is a **store**. Claude's channel is a push: the data is handed
to a command, and unless that command writes it down, nothing remains. A search
over stores could not find it — not because it was hidden, but because looking for
state is the wrong instrument for something delivered as an event.

ADR-0008 and ADR-0010 are entirely about that distinction, and ADR-0010 exists
*because* hooks push rather than store. The pattern was in this repository,
applied to the same vendor, and was not applied to the investigation.

The generalisable form: **"I could not find it" is a claim about the search, not
about the data.** Before concluding something does not exist, name the channels it
could arrive by — store, push, ask-on-demand — and say which were looked at. The
irony is that the *other* tool stores it, so a store-only search would have
succeeded on Codex and did not run there either.

## The token experiment was sound; the inference from it was not

Kept because the measurement stands and its reading needs correcting. Totals in
the five hours before five Claude model-limit events:

```
all models                     filtered to claude-fable-5
1,805,261                      1,709,365
  150,843                        150,843
1,659,935                              0   ← limit hit, none of that model's usage
7,614,611                              0   ← same
  868,526                        868,526
50× spread                     two zeroes
```

That refutes **"local token counting can predict the limit"**: two limits were hit
with none of that model's usage on this machine, so the numerator is incomplete
and no weighting fixes it.

It does not support the conclusion drawn from it, that nothing can know. The limit
was never a token count — it is a percentage the server computes over data we
cannot see, **and then reports**. Refuting a proxy is not refuting the quantity.

## What reaches the screen

Not a session card. Usage is a property of the account, and ADR-0014 settled what
that means: a dimension nobody acts on per-session must not become a sort key. It
goes where machine-wide facts already are — the menu bar and the dashboard header
— never inside the grid.

Per-tool, because the limits are per-tool and unrelated. A Codex account at 100%
says nothing about Claude Code, so one merged figure would be meaningless.

The ambient band is not involved. ADR-0015 established that the band carries no
content and lights only for something needing the user *now*; a window at 41% is
not that. An exhausted window stalls a session, and that is ADR-0024's business.

## Consequences

Two reporting channels with different shapes, so the adapters stay asymmetric —
which is what ADR-0004 chose. Claude's needs opt-in cooperation and yields only
account-level fields; Codex's needs nothing and yields more. Neither is installed
silently.

`--hooks` becomes a report about integrations generally rather than hooks
specifically, since one of the two things it reports is now a status-line line.

Nothing is inferred. These are the tools' own numbers, carrying ADR-0012's
`reported` weight — but only while `resets_at` says they describe the current
window.

OpenCode has no limits to report and appears nowhere in this.

## How this gets falsified

The claim to check is not whether the numbers exist — they are documented and
captured. It is whether a snapshot stays true long enough to be worth showing.
The instrument is the state file's own history: log each reading with its
`resets_at`, and count how often one is consulted after its window has rolled. A
large fraction means the display is mostly showing expired windows, and the honest
answer shrinks to the reset time alone.

Unobserved so far: **no capture spans a `resets_at` passing.** The
self-invalidation rule above is reasoning, not something seen. It is the first
thing the log will show and it is cheap to wait for.

The `∞` half has a sharper test, and it is the one that already caught an error
here: **sort by time before concluding anything about a distribution.** If a
future split between present and absent slots turns out to be interleaved by day
rather than separated into eras, then absence is not a vendor state and `∞` is
over-claiming. The day-by-day table above is the query; it takes seconds and it
inverted the first conclusion.
