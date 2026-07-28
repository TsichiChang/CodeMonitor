# A grant is invisible; the work after it is not

Claude Code fires `PermissionRequest` when a prompt appears and **nothing at all
when permission is given** — confirmed against the hook reference, which lists
no event between approval and execution:

```
PreToolUse → PermissionRequest → [approved, no event] → tool runs → PostToolUse
```

So from the moment the user answers until the tool finishes, the last word from
any hook is still "blocked on the user". A build that takes a minute reads as a
minute of waiting for approval that was given at the start of it — and `waiting`
is the one state this app exists to report correctly (ADR-0007).

Watching the state directory made it worse rather than causing it (ADR-0008).
At a two-second poll the window was usually missed; delivered as an event, every
one of them lands.

Three ways out are closed. There is no grant event. The transcript is not
written during execution, so the source that rescued the other misreadings
(ADR-0012) has nothing to say here. And under `defaultMode: auto` the decision
is made by a classifier model, so it cannot be predicted from configuration —
copying the `permissions.allow` matching rules would be guessing at an internal
implementation that is free to change.

**The decision: a child process started after the prompt dates the answer.** It
cannot have been started by a user who had not answered yet, and it is a later
observation than the prompt it supersedes — the same rule that settled the
transcript-versus-hook conflict.

Long-lived children are why the newest start time is read rather than a count:
an agent keeps MCP servers running for its whole session, and their existence
proves nothing. One that started *after* the prompt does.

This is not a new `Activity`. "Approved and now working" is what `turnInFlight`
already means, and a fourth value would have to be given a meaning everywhere
activities are read, to describe a condition nothing else distinguishes.

## Consequences

A tool that is approved and then runs without spawning anything — something
purely internal — still reads as waiting until `PostToolUse` arrives. That is
under-reporting rather than over-reporting, and the asymmetry is deliberate: a
card that fails to say "this is running" costs a glance, while one that says
"this needs you" when it does not spends attention on nothing, which is the only
currency this display has.

The check runs on sessions already showing as blocked, which is rarely more than
one, so it costs a single `proc_listchildpids` per scan in the common case.
