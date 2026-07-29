---
status: the per-state timeout is superseded by ADR-0012; the amendment below stands
---

# How long a session stays listed depends on its state

> **The title is no longer true, and that is the point of ADR-0012.** How long a
> session stays listed depends on its *liveness*, not on its state. Tying the
> two together is precisely what made a mistaken `waiting` immortal, which is
> the defect ADR-0012 was written to remove. What survives here is the
> amendment at the end — every state ages out on the same short window once no
> process can be matched — and the asymmetry it rests on. The per-state window
> below is history; `Aging.window(for:)` is the dead code it left behind.

Sessions aged out of the list on a single 30-minute silence timer. A session
blocked on an approval prompt is silent by definition, so the state most worth
seeing was the one most likely to disappear — and it only survived at all
because a matched live process suppressed the timeout, which no longer happens
(ADR-0003).

The timeout is now per state: `waiting` does not expire, `running` gets a
generous window, `idle` a short one. Where a tool reports session lifecycle
authoritatively, its end event removes the session outright.

> **The second sentence overstates what was built — and the reason it existed
> has since been removed.** It was a patch. With `waiting` never expiring, a
> session blocked on a prompt whose terminal had been closed would sit in the
> list forever in the loudest colour on screen — the first consequence below
> says exactly that — and an authoritative end event was the only thing that
> could take it away. The amendment at the end of this ADR closed that hole
> generally: every state ages out once no process can be matched. The end event
> stopped being the only exit and became merely a faster one.
>
> What exists is the first half. The hook deletes its own state file on
> `SessionEnd`, and that works. It does not remove the session, because deleting
> a file expresses the *absence of evidence*, and the scanner cannot tell that
> from a session which never had a hook — the same conflation three-valued
> liveness was introduced to end (ADR-0012). So a cleanly closed Claude session
> leaves the display within the five-minute no-process window rather than at
> once, and for Codex not even this half applies: it fires no end event to
> register.
>
> The residue is narrower than "a card lingers". That card is idle, dim and
> folded — but if it was unread it also stays in the jump shortcut's queue, with
> its recorded pane deleted alongside its state file. So for those few minutes
> ⌃⌥⌘J can land on a session that is gone and report that it cannot find the
> terminal.
>
> Building it properly means a tombstone rather than a deletion, and a tombstone
> is a fourth kind of input to the scanner: neither evidence nor liveness, and
> needing a lifetime of its own longer than the day a source goes on reading the
> transcript. ADR-0019 refused a fourth `Activity` on a weaker version of this
> argument.
>
> What settles it is where the cost falls. The end event exists only for Claude,
> whose sessions already take the *shortest* window — five minutes. The ones that
> linger longest are Codex desktop sessions at thirty, because nothing can be
> observed about their liveness at all (ADR-0017), and those have no end event to
> use. It would buy least where it is available and nothing where it is needed.
> Left undone deliberately. If the five minutes ever bites, what to fix is the
> shortcut routing to an unreachable session — a different change, and a much
> cheaper one.

## Consequences

A `waiting` session whose terminal was closed would otherwise sit in the list
forever, in the most attention-grabbing colour. Sessions waiting longer than a
threshold therefore get a targeted liveness check — a narrow, deliberate
exception to ADR-0003.

That check leans on an asymmetry: a matching process does **not** prove a given
session is alive (identity can't be established from a process, ADR-0002), but
the total absence of any process for that tool in that directory is strong
evidence it is dead. The check only asks the reliable question.

## Amendment: the exemption requires a live process

`waiting` never ageing out was too broad. A session whose agent has been killed
keeps whatever state it was last inferred to be in, and if that was `waiting` it
stayed on the display permanently — two such cards were sitting there after
their processes had gone.

The exemption exists for a session that is genuinely sitting there blocked, and
that is a claim about a *running* agent. With no process, a session cannot be
waiting on anyone: nothing would act on the answer. Every state therefore ages
out on the same short window once no process can be matched to it.

This uses the asymmetry established in ADR-0002 — a process is never proof of
*which* session it belongs to, but the absence of any matching process is decent
evidence that a session is over, and it is the only evidence there is. The cost
is that a session whose process exists but went unmatched, which happens when
two sessions share a directory and only one can be given the pid, ages out
early. Hooks report their own pid and are not subject to that.
