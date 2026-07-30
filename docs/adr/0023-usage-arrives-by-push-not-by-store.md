# Usage arrives by push, not by store

Two questions came in: how much of the five-hour window is spent, and when does
the weekly one reset. Both are answerable, and the first draft of this ADR
concluded neither was. The investigation is recorded because the way it went
wrong is more useful than the answer.

Claude Code hands every status-line invocation a JSON payload on stdin, and it
contains exactly what was asked for:

```json
"rate_limits": {
  "five_hour": { "used_percentage": 23.5, "resets_at": 1738425600 },
  "seven_day": { "used_percentage": 41.2, "resets_at": 1738857600 }
}
```

Officially documented, both windows, a percentage and a Unix timestamp. Alongside
it: `context_window.current_usage`, `session.start_time`, and extra-usage credits.

## The error worth recording

The first draft searched transcripts, `~/.claude/`, `~/.claude.json`, the `claude`
CLI's subcommands, and the API's rate-limit response headers. It concluded the
allowance was unobservable and wrote a whole ADR around that.

Every one of those is a **store**. The status line is a **push**: Claude Code
invokes a command and hands it the data, and unless that command writes something
down, nothing remains. A search over stores cannot find it — not because it was
hidden well, but because looking for state is the wrong instrument for something
delivered as an event.

ADR-0008 and ADR-0010 are entirely about this distinction. ADR-0010 exists
*because* hooks push rather than store, which is why the hook writes a file. The
pattern was already in this repository, applied to the same vendor, and it was
not applied to the investigation.

The generalisable form: **"I could not find it" is a claim about the search, not
about the data.** Before concluding a thing does not exist, name the channels it
could arrive by — store, push, and ask-on-demand — and say which ones were
actually looked at.

## The token experiment was sound; the inference from it was not

Kept because the measurement stands and its reading has to be corrected.

Tokens per message are in the transcripts with timestamps, so a rolling five-hour
total is arithmetic. If the limit were a token budget, five model-limit events
should have fired at similar totals:

```
all models                     filtered to claude-fable-5
1,805,261                      1,709,365
  150,843                        150,843
1,659,935                              0   ← limit hit, no local usage of it
7,614,611                              0   ← same
  868,526                        868,526
50× spread                     two zeroes
```

That correctly refutes **"local token counting can predict the limit"** — two
limits were hit with none of that model's usage on this machine, so the numerator
is incomplete and no weighting fixes it.

What it does not support is the conclusion drawn from it, that nothing can know.
The limit was never a token count: it is a percentage the server computes over
data we cannot see, **and then reports**. Refuting a proxy is not refuting the
quantity.

## The channel is single-valued and already occupied

`statusLine` in `settings.json` is one object, not an array:

```json
{ "statusLine": { "type": "command", "command": "~/.claude/statusline.sh" } }
```

So installing ours would **evict** whatever is there. On this machine that is a
335-line script which already parses `rate_limits.five_hour.resets_at`,
`used_percentage`, the seven-day pair, and extra-usage credits — a working status
line the user built.

This is ADR-0001's Codex finding, unchanged except for the vendor:

> `notify` turned out to be one command per installation — `config.toml` holds a
> single entry — so registering there evicts whatever already uses it instead of
> joining it.

There ADR-0001 had an escape: the hook arrays coexist, so it used those instead.
Here there is no appendable alternative, because no hook event carries
`rate_limits`.

**The decision: this app does not install a status line.** It reads a state file,
and getting one written is a line the user adds to the script they already own —
opt-in, in a file we do not touch, and unbreakable by this app being moved or
removed, which is the property ADR-0010 was written to protect:

```sh
# one line, at the top of your own statusline script
tee "$HOME/.local/state/codemonitor/usage.json" >/dev/null <<< "$INPUT"
```

`--hooks` reports whether it is present, the same way it reports hook
registration. Absent, the app shows no usage at all rather than a stale or
guessed one.

## A reading that stops being true, and says so itself

The status line only runs while a Claude Code session is open and redrawing. With
nothing running, `used_percentage` freezes at whatever it last was, and a frozen
percentage is worse than none — it is a number that looks live.

`resets_at` is what makes it self-invalidating, and no separate staleness rule is
needed: **once `resets_at` has passed, the window has rolled over and the
percentage beside it describes a window that no longer exists.** Same shape as
the rest of the model — store what was observed and when, derive whether it still
holds (ADR-0012).

Two consequences follow. A percentage is shown only while its own `resets_at` is
in the future. And after a rollover the honest display is not `0%` — nothing was
observed about the new window — but no reading at all.

## What reaches the screen

Not a session card. Usage is a property of the account, not of any session, and
ADR-0014 settled what that means: a dimension nobody acts on per-session must not
become a sort key. It goes where the machine-wide facts already are — the menu bar
and the dashboard header — never inside the grid.

The ambient band is not involved. ADR-0015 established that the band carries no
content and lights only for something needing the user *now*; a window at 41% is
not that. When the window is actually exhausted, a session stalls, and that is
ADR-0024's business, reported through the session that hit it.

## Consequences

The app gains a second reporting channel, and `--hooks` becomes a report about
two integrations rather than one. Both are opt-in and neither is installed
silently.

Nothing is inferred. Percentages and reset times are the tool's own numbers, so
they carry ADR-0012's `reported` weight — but only for as long as `resets_at`
says they describe the current window.

A machine with no status-line cooperation shows no usage. That is the same floor
ADR-0001 chose when it kept passive detection: the feature degrades to absent
rather than to approximate.

## How this gets falsified

The claim to check is not "is the number there" — it is documented and this
machine's own script reads it. It is whether a *pushed* reading stays true long
enough to be worth showing. The instrument is the state file's own history: log
each payload with its `resets_at`, and count how often a reading is consulted
after its window has rolled. If that fraction is large, the display is mostly
showing expired windows and the honest answer is to show nothing but the reset
time.

Honestly marked: **the payload has not been captured on this machine.** The field
names come from the official schema and from the local script that reads them, not
from an observed write — capturing one means adding the line above to a file this
app must not modify on its own. Until it is captured, the field names are
documentation, not observation.
