# How long a session stays listed depends on its state

Sessions aged out of the list on a single 30-minute silence timer. A session
blocked on an approval prompt is silent by definition, so the state most worth
seeing was the one most likely to disappear — and it only survived at all
because a matched live process suppressed the timeout, which no longer happens
(ADR-0003).

The timeout is now per state: `waiting` does not expire, `running` gets a
generous window, `idle` a short one. Where a tool reports session lifecycle
authoritatively, its end event removes the session outright.

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
