# An ambient signal before a second screen

ADR-0006 assumed the deployment is a dedicated panel on the desk. The cost that
assumption was meant to pay for is now measured rather than assumed: across two
weeks of transcripts, an agent sat waiting **more than five minutes while the
user was at the keyboard working in another session 7.4 times a day** — three
times a day beyond ten minutes, once for 52 minutes. The median wait is 1.3
minutes, which is just an ordinary context switch. The tail is not.

So the problem ADR-0007 named — "costs the user time for as long as it goes
unnoticed" — is real and has a price. But the panel is one answer to it, not the
answer, and it is the one that cannot be tried first: it has to be bought, and
this machine has no iPad to stand in for it either.

During every one of those waits the menu-bar icon was already amber. It went
unseen because it is small, still, and outside where the eye is pointed. What is
missing is therefore not display area — it is **being noticed without being
looked at**. That is a different requirement, and a cheaper one.

The decision: build an ambient signal on the main screen first — a transparent,
click-through overlay along the screen edge that breathes amber while any
session waits, with the breathing rate following the *longest* current wait, so
peripheral vision reports urgency and not merely presence. No hardware, no
permissions.

## The band, as measured

Settled by running it and looking, not by choosing on paper
(`tools/band-probe.swift` reproduces it):

| | | why |
|---|---|---|
| edge | bottom only | the Dock is set to auto-hide, so that edge is free; the top would blur into the menu bar |
| height | 12 ↔ 40pt, breathing | capped where it stopped covering the bottom of an editor — reach comes from the swing, not the area |
| alpha | 0.10 ↔ 0.72 | |
| period | 1.2s | the same as a waiting card, so one urgency reads across both surfaces |
| shape | gradient rising from the edge | a hard line reads as a UI element left open; a glow reads as light |
| screens | all of them | tracking the focused screen needs window-list polling, and the band only exists while something waits anyway |

Two things had to be pushed much further than they first looked worth. The
swing was doubled — Theme.swift already records the reason, that a contrast
which is obvious side by side is nearly invisible spread across a 1.2s fade —
and the *height* breathes rather than only the tint, because peripheral vision
answers to a moving boundary long before a changing brightness. At the first
attempt, with a narrow swing and a still edge, it went unnoticed entirely.

Verified on this machine: visible above full-screen apps, on both displays at
once, click-through, without stealing focus, and asking for no permission.
Two traps found on the way:

- Windows must be created in `applicationDidFinishLaunching`. Built and ordered
  in before `NSApplication.run()`, they never reach the screen.
- `CGWindowListCopyWindowInfo` cannot be used to check any of this: without
  Screen Recording permission it filters the information out and reports zero
  windows for plainly visible ones. `NSWindow.isVisible` needs no permission.

## The signal does not say which session, and does not need to

Paired with it is a single global shortcut that jumps straight to the session
that most deserves attention — longest-waiting first, then running, skipping
whatever is already frontmost. It is queue consumption, not random access: press
and arrive, press again for the next one.

This is why "which one?" never has to be answered. A selection model would need
an aiming step, which would need to be shown on screen, which would need a
visual channel — and colour, brightness, motion and shape are all already spent
on state (ADR-0007). Arriving answers the question for free, and at three to
five concurrent sessions there is rarely more than one waiting anyway.

Two constraints worth recording because neither is visible in the code:

- **macOS has no touch-screen support at all.** The obvious escape — a touch
  panel you reach over and tap — does not exist on this platform, third-party
  drivers aside. It should not influence which panel gets bought.
- The shortcut must use Carbon's `RegisterEventHotKey`, which needs no
  entitlement. `NSEvent.addGlobalMonitorForEvents` would require Accessibility
  access, and this app has never asked for a permission it could avoid.

## How this gets falsified

The measurement is `tools/dead-wait.py`, committed for this purpose — the
baseline above is its output over the fourteen days to 2026-07-27: **7.6 waits
per day over five minutes, 3.1 over ten**, against 2.5 hours a day at the
keyboard.

Run the overlay for a week and run it again. If 7.6 drops to one or
two, the panel is unnecessary — the problem was noticing, and it is solved. If
it barely moves, then ambient signalling is the wrong approach altogether and a
second screen would not have fixed it either; the next thing to try is real
notifications, which ADR-0006 rejected on the grounds that the display is
already in view. The overlay is what makes that premise true without buying
anything.

## Nothing sorts above attention

The dashboard grouped sessions by tool, which quietly repealed all of this: a
Codex session blocked on a permission prompt sat below every Claude Code session
that had already been read, because the group header outranked the ordering
inside it. Grouping is a property of the *brand of agent*, and that is not a
dimension anyone acts on — nobody deals with their Claude work before their
Codex work.

So grouping is off by default and each card carries its tool's symbol instead,
which identifies without reordering. It remains available as a setting, for the
case where a machine really is being watched one tool at a time.

The general form is worth stating, because it will come up again for git branch,
model, or project: **a grouping is a sort key that outranks every other, so it
has to earn that rank.** Attention has earned it — it is the thing this display
exists to allocate. Identity belongs on the card.

## Consequences

ADR-0006's claim stands: designed for peripheral vision, no notifications,
motion is expensive. Two of its corollaries do not. The menu bar is not "a secondary
affordance" — with no reachable display it is the only always-available surface,
and it needs a per-session dismiss, which today exists solely as a hover target
on a card. And the dedicated panel is deferred, not assumed.

Nothing about a session may depend on hover to be reachable. Hover is a pointer
affordance, and the whole premise of an ambient display is that the eye goes
there while the hand does not.
