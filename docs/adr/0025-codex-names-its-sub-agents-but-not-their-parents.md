# Codex names its sub-agents but not their parents

Every Codex card on the dashboard right now is a sub-agent. Not most — all five:

```
• globalpay_machpro    [codex]  running (inferred)
• globalpay_machpro    [codex]  idle · unread (inferred)
• globalpay_machpro    [codex]  idle · unread (inferred)
• globalpay-workspace  [codex]  idle · unread (inferred)
• globalpay-workspace  [codex]  idle · unread (inferred)
```

Of 109 Codex rollouts on this machine, **87 are sub-agents** — `thread_source:
"subagent"` — against 22 a person started (16 `cli`, 6 `vscode`). Inside the
twenty-four-hour read horizon it is 6 against 4, and the four a person started are
not the ones on screen.

ADR-0004 and the sub-agent section of the README describe this defect and its fix,
for Claude: `isDelegated` comes from `entrypoint`, and delegated agents fold into a
count on the session that spawned them, because "listing them individually buries
the sessions a person is actually sitting in front of, which is the one thing this
display must not do". `CodexSource` has no such field. It was never implemented
there, and nothing said so.

Three of the five are `idle · unread`, which is the part that costs something. Blue
puts them in `attentionGroup` 2 — above every session already read — and in the
`⌃⌥⌘J` queue. **The shortcut built to walk what deserves attention routes to
programs.**

## The signal is stronger than Claude's

Three fields in `session_meta` agree, where Claude offers one:

```
thread_source     "subagent"                              87 / 87
source            {"subagent": {"other": "guardian"}}     87 / 87
parent_thread_id  non-null                                87 / 87
```

Claude's `entrypoint?.hasPrefix("sdk")` is a string-prefix heuristic over a field
that names an entry point rather than a relationship. Codex states the
relationship outright.

**Key on `thread_source`.** It is the one field whose only job is to say what kind
of thread this is. `parent_thread_id` implies the same thing indirectly, and
`source` carries a trap worth recording: it is a *string* for human sessions
(`"cli"`, `"vscode"`) and an *object* for delegated ones
(`{"subagent": {…}}`). A parser that expects one shape gets the other exactly when
the answer matters, and a textual scan for `"subagent"` inside it would match the
whole record rather than that field.

## Considered: attribute to the actual parent

`parent_thread_id` is the thing Claude cannot offer — the README notes that
"nothing in a transcript names the session that spawned it", which is why Claude
attributes by project directory. Codex names it, so folding could hang each
sub-agent off its real parent instead of guessing.

It is not worth building, and the measurement is why:

```
parent ids that resolve to a rollout here    5 / 87
of those, parent and child share a directory 5 / 5
delegation depth                             82 at unresolvable, 5 at one level
```

**Eighty-two of eighty-seven parents are not on this machine** — the orchestrator
sits somewhere that writes no rollout, and `guardian` in the `source` object hints
at a system outside Codex entirely. So a parent-id mechanism would run on 6% of
cases, and on every one of those it would agree with the directory it replaced.

A mechanism exercised rarely and never disagreeing with the cheap one is a
mechanism that cannot be verified. Attribution stays by project directory — the
same method as Claude, reached for opposite reasons: Claude because nothing names
the parent, Codex because what names it cannot be resolved.

## Consequences

Measured after the change, on a machine whose sessions had moved on:

```
sessions the Codex source produced   10   (6 subagent, 4 user)
cards on the dashboard                2   both thread_source=user
```

Not one delegated session produces a card of its own. That is the whole claim, and
it holds.

**The `⬡ N` count turns out to be rarer than expected**, which the first draft of
this ADR got wrong. It predicted one card carrying `⬡ 1`; there was none.
`foldDelegated` counts only delegated agents whose activity is `turnInFlight`, so a
sub-agent has to be mid-turn at the moment of a scan to be counted — and
sub-agents finish quickly. The three under `globalpay_machpro` had last written 22,
44 and 96 minutes earlier, so all three read `turnComplete` and the count was zero.

Idle sub-agents are therefore dropped outright rather than summarised. That is
correct rather than lossy — one that has finished its piece of somebody else's task
leaves the user nothing to do — but it means the badge reports *concurrent* work,
never work that happened. Claude has behaved this way since ADR-0004 and nobody
noticed, because the same condition hid it there too.

"Show delegated sessions" in Settings still lists them, unchanged, for the case
where the sub-agents *are* the work being watched.

The two tools' delegation vocabularies stay separate in the adapters and converge
only at `isDelegated`, which is what ADR-0004 asks for: each source says what its
own data supports, and the scanner reads one boolean.

## How this gets falsified

The count is the test, and it was available before and after — 87 of 109 rollouts
carry `thread_source: "subagent"`, every one of them produced a card while inside
the read horizon, and none does now.

Stating it as "five cards become one" was the wrong form, and the reason is worth
keeping: **a prediction about a live machine has to be about the rule, not about
the current contents.** The sessions had turned over by the time it was checked, so
a prediction naming specific cards could only be confirmed by luck. The rule —
*no session whose `thread_source` is `subagent` appears on its own* — is checkable
against whatever happens to be running.

What would overturn the decision above is finding delegated Codex sessions whose
`parent_thread_id` resolves to a *different* directory than their own. The
directory method would be wrong there, and five out of five is far too small a
sample to be sure it cannot happen. The query is the one in this ADR; it costs
seconds and should be re-run rather than assumed.

Honestly marked: **`thread_source` has only ever been observed with two values
here** — `"subagent"` and absent. `"user"` appears alongside `vscode`, so at least
three exist, and nothing establishes that a delegated session must say
`"subagent"` rather than some future third thing. Treating any non-absent value
other than `"subagent"` as human is the conservative reading — it under-reports
delegation, which shows a card too many rather than hiding one.
