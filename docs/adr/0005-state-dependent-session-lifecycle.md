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
