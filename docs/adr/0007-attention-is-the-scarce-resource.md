# Idle sessions are deliberately dim

Every session card used to be equally prominent — same size, same tint
treatment, same animation budget. On a screen that is always in view, that
spends the same amount of the viewer's attention on a session finished hours ago
as on one blocking right now.

State intensity is therefore asymmetric on purpose: `waiting` is saturated and
pulses quickly, `running` is moderate and pulses slowly, `idle` is dim and does
not animate at all. When space runs out, idle sessions are the ones that
collapse into a summary line; waiting and running are never displaced.

## Consequences

Idle cards will look under-designed next to the others. That is the intent, and
"fixing" it by giving idle equal weight would undo the whole scheme.

The visible information is deliberately thin — project, state, elapsed time.
Branch, model and the last-message snippet were removed rather than shrunk: at
this physical size they are unreadable across a desk, so keeping them would cost
layout space to produce noise. Detail belongs in the terminal the card jumps to.

Colour is not the only channel carrying state. Motion separates active from
idle, and pulse rate separates waiting from running — which matters because the
resting tint of a running card is by design the same neutral as an idle card,
and because red-green colour vision deficiency compresses the running/idle
distinction (ΔE 12.3 → 7.4 simulated) more than it does running/waiting
(ΔE 25.1 → 20.8).
