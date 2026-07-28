# Finished work stays until it is seen

An idle session used to fold the moment its turn ended. Folding means "nothing
to do here" (ADR-0013), and the event it was firing on means the opposite: a
turn just finished and the ball is back with the user. The interface was
playing the most important thing that happens as a disappearance.

It is also the common case, not an edge one. Of the dead wait measured over two
weeks, **91% was a turn that had ended and was waiting on a reply** — 251
spells, 23.4 hours — against 9% blocked on tool approval (ADR-0015).

So folding is deferred until the session has been looked at. A session that
finished while nobody was watching keeps its card; the shape itself says whose
turn it is. Once visited it collapses to a line. The original reason for folding
— idle should not compete for attention — is untouched; it had simply been
carrying two opposite meanings on its own.

## Unread is derived, not stored

There is no read flag. A session is unread when `lastActivity > lastVisited`,
from two observations that are recorded anyway: when it last acted, and when it
was last jumped to. A stored flag would need something to clear it, and every
"something" is a place that can forget — leaving a session marked read after it
has spoken again. Deriving it means a session that acts once more becomes unread
by itself, with nothing to reset (ADR-0012).

Jumping is the only thing that counts as reading, and there is no separate
"mark as read". Another button would be another piece of state to maintain, and
the meaning it would carry — "I am not going back to this" — is what dismissing
already says.

## A fourth colour, which is why it is allowed

ADR-0007 gives colour to state, and green, amber and grey account for running,
waiting and idle. Blue is added for unread on the grounds that **it does not
name a state**: it says whose turn it is. It appears only on idle sessions,
replacing exactly the grey it would otherwise conflict with, so no card ever has
two colours speaking at once. Blue for unread is also what every mail client has
already taught, so it costs nothing to learn.

## Consequences

Sorting gains a band: waiting, running, unread, then seen. Within each, order
stays stable — waiting by how long, running by name, both idle bands by last
activity — so a card changing band is caused by that session and moves nothing
else, which is the rule ADR-0013 set when it refused to fold on a threshold.

Unread has to be part of what the display animates on. The signature was
`id:state`, and reading a session changes neither: it is idle before and after.
Folding and moving both cut instantly until the signature included it — the same
shape as every other defect in this codebase where something that should move on
its own was riding on a change in data.
