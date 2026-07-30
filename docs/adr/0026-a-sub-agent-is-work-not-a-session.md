# A sub-agent is work, not a session

This decision has been running since before ADR-0004 and has never had an entry.
It is written now because of what that cost: `CodexSource` went its entire
existence without delegation detection, 87 of 109 rollouts unhandled, and **nothing
in this repository could have found it.**

`--selftest` checks code against the ADRs. The audit that swept all twenty-two
entries symbol by symbol checked the ADRs against the code. Both require an entry
to exist. A decision that lives only in a doc comment and a README section is
invisible to both, so `CodexSource` lacking `isDelegated` was an *absence* rather
than a *contradiction* — there was nothing to contradict.

Measured now rather than inherited from the comment that has carried these numbers:

```
Claude   209 transcripts   46 delegated (sdk-cli 30, sdk-ts 16)     22%
Codex    109 rollouts      87 delegated (thread_source: subagent)   80%
```

The heaviest single project holds 26 delegated Claude transcripts — the same 26
the original comment cited, still true. Codex delegates nearly four times as
readily, which is why the gap mattered more there than anyone noticed.

## The decision

**A delegated agent gets no card. It becomes a count on the session that spawned
it.**

A card is a claim that somebody should look at something. A sub-agent is a piece of
another session's turn: it was started by a program, it reports to a program, and
when it finishes there is nobody for whom that is news. Listing them individually
buries the sessions a person is actually sitting in front of, which is the one
thing this display must not do (ADR-0007).

"List sub-agents separately" in Settings turns the folding off, for the case where
the sub-agents *are* the work being watched.

## Detection is per-tool, and neither tool offers a good field

Each adapter answers for its own data (ADR-0004), and the scanner reads one
boolean:

- **Claude** — `entrypoint` prefixed `sdk`. It names an entry point, not a
  relationship, so this is a heuristic over a field that means something adjacent.
- **Codex** — `thread_source == "subagent"` (ADR-0025). A direct statement, and the
  stronger of the two.

`isSidechain` looks like exactly the right field and is never set: **0 of 209
transcripts**, re-checked. It is named for the concept and carries nothing.

## Attribution is by project directory, which is not the ADR-0002 violation it
## resembles

ADR-0016 records that keying a *session* on its directory "is exactly what ADR-0002
forbids", because a directory is not an identity. Folding uses the directory too,
and the difference is worth stating: it is a **join between sessions**, not an
identity for one. Every session here already has its UUID; the directory only
answers which pile a sub-agent belongs to.

Nothing in a Claude transcript names the parent. Codex does name it —
`parent_thread_id` — and ADR-0025 measured why that is not used: 82 of 87 parents
are not on this machine, and where they resolve they share the child's directory in
5 of 5. A mechanism running on 6% of cases and never disagreeing with the cheap one
cannot be verified.

## The count means concurrent, and is therefore nearly always absent

`workingByProject` counts only delegated agents whose activity is `turnInFlight`.
So `⬡ N` reports **how many sub-agents are working right now**, never how many ran.
Sub-agents finish quickly, so in practice the badge is rarely on screen: the
README's `⬡ 3` illustration has not been observed while writing either this entry
or ADR-0025, where three sub-agents under one project had last written 22, 44 and 96
minutes earlier and the count was zero.

That is accepted rather than widened. Counting finished sub-agents would need a
window — "finished within the last N minutes" — and a threshold makes a card change
because of elapsed time rather than because of anything a session did, which is the
motion ADR-0013 refused. A count of work already done is also not actionable: the
turn it belonged to has ended, and the parent session's own state already says so.

**What the badge is for is deciding whether a quiet parent is actually quiet.** A
session showing `idle · ⬡ 3` has handed its work out and is waiting on it; the same
session showing `idle` alone has nothing outstanding. That distinction only exists
while the sub-agents are running, which is exactly when the count exists.

## Orphan adoption survives; its stated reason does not

The code carries this justification:

> A batch with no session of its own to hang off still deserves to be visible —
> otherwise the work would vanish from the display entirely.

**The work vanishes anyway.** Adoption iterates `workingByProject`, which only has
entries for projects holding a `turnInFlight` agent, so a batch whose sub-agents
have all finished is never adopted and every one of its sessions is filtered out.
Observed while writing this: `globalpay_cashier` had one delegated session inside
the read horizon, the Codex source produced it, and no card existed for it — the
project was absent from the display entirely.

The behaviour is right and the reason was wrong. Adoption exists so that
**concurrent** work stays visible when its parent is not on screen — a batch
running under a session that has aged out, or under an orchestrator this machine
never saw. A finished batch has nothing to act on, and the display is not a log.

So the sentence is corrected rather than the code. Written down, the rule is: a
project is shown when something is running in it, whoever started that something.

## Consequences

A project whose sub-agents have all finished shows nothing at all — not a card, not
a count. That is deliberate under-reporting in the direction this display always
chooses (ADR-0019, ADR-0020): a missing row costs a glance, an unnecessary one
spends the attention the whole thing exists to protect.

`⬡ N` is a rare sight, and that is the badge working rather than failing. If it
were common it would mean sub-agents routinely outlive the scan interval, which
would be a fact about the agents and not about this display.

The folding is now checkable. Any tool added without an `isDelegated` answer
contradicts this entry, which is the whole reason for writing it — the next
Codex-shaped miss becomes visible instead of silent.

## How this gets falsified

Two counts, both cheap and both already scripted in this entry's own investigation:
the share of transcripts that are delegated per tool, and the number of cards a
project with only delegated sessions produces. The second must be zero when those
sessions are idle and one when any is running.

The claim most likely to be wrong is the one about the badge's purpose. "A quiet
parent with `⬡ 3` is waiting on its own work" is an argument, not an observation —
nobody has been watched using it. If the badge turns out to be noticed only after
the fact, the honest conclusion is that concurrent-only was the wrong choice and a
finished-work count with an explicit window is worth its threshold.

Honestly marked: the two ratios above are this machine on one day. The 22%-versus-80%
contrast is what justified treating Codex's gap as serious, and a machine that uses
Codex differently would not reproduce it.
