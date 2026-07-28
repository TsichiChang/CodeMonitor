# Type follows the screen, layout follows the window

Every font size in the app is a fixed `pt` constant — `.body`, `.caption`,
`.caption2`. A `pt` is a logical unit, so the same constant is a different
physical size on every screen: 4.0mm on the 27" external (82 points per inch),
3.0mm on the 16" built-in (110), and 2.0mm on the 7"/1024×600 panel ADR-0006 was
written for (168). ADR-0006 predicted exactly this failure — "carried the
dimensions across while silently adopting desktop-window typography" — and it
happened again in the Swift rewrite: `.defaultSize(1024×620)` came across, the
typography did not.

Three signals therefore drive three things, and none of them drives another:

```
point density  (screen, from EDID)  →  type size      physical readability
layout budget  (window, in points)  →  column count   how much fits
state          (waiting/running/idle) → card or line  what deserves the room
```

Point density is read, not guessed: `CGDisplayScreenSize` returns the panel's
millimetres from its EDID, and dividing the mode's logical width by it gives
points per inch directly. It is not PPI — PPI names physical pixel density,
which is 254 on the same built-in screen that has 110 points per inch, and
confusing the two produces type off by a factor of two.

## The baseline is 16 arcminutes at 60cm — a seated distance, not a glanced one

What the eye resolves is angular size, so the constant is stated as an angle:
**cap height 16 arcminutes at an assumed 60cm**, the bottom of the 16–22 range
ISO 9241 gives for comfortable reading, which UI labels may sit at. That works
out to 2.8mm of cap height, so 4.0mm of font size against SF Pro's ~0.70 cap
ratio — 12.9pt at 82 points per inch, 17.3pt at 110, 26.4pt at 168.

The first of those is why the constant is trusted: it independently reproduces
the 13pt the app already uses, on the one screen where the current typography
looks right. It also predicts that the same text is a third too small on the
built-in screen, which is checkable by dragging the window across.

Deliberately this is a *seated reading* baseline, not the "larger type" ADR-0006
asked for. That instruction existed so the project name could be read across a
desk — and ADR-0014 removed the need to read it at all, by jumping to the
session that deserves attention instead of naming it. Everything peripheral
vision still has to carry (something waits, how urgently, running versus idle)
travels by colour, motion and pulse rate, which ADR-0007 had already established
and which do not get larger. So type is sized for the moment it is actually
read: seated at the main screen, or walked up to.

## One number scales; everything else is a multiple of it

Point density feeds exactly one value — the body size — and every other length
is expressed as a multiple of it: padding 1.08, inner spacing 0.62, corner
radius 0.77, minimum card width 18.5, hairline 0.077. Scaling type alone would
strand 17pt text inside 14pt padding, and giving each constant its own factor
would invent dozens of parameters to tune.

The ratios are not designed, they are divided out of the existing 27" layout,
which is trustworthy precisely because that screen is where 13pt already equals
the baseline. So the change is a no-op at 82 points per inch — the main screen
does not move by a pixel — and only takes effect on a different display. A
mistake can only be wrong somewhere other than where the design was verified.

Minimum card width scaling with the rest is what produces ADR-0006's "fewer and
larger cards" without a small-screen branch anywhere: the same 1024-point window
holds four columns at 82 points per inch and two at 168, because each card costs
twice the points to keep the same millimetres.

The one length with nothing to divide from is the collapsed idle row — a new
shape, with no counterpart in the current layout. It has to be *visibly* shorter
to work at a distance, and how much is enough is an eye judgement, not an
arithmetic one. It starts at 0.4 of a card and gets looked at.

## Viewing distance is not measurable, so it is asked once

Physical size alone does not settle type size; what the eye resolves is physical
size over viewing distance. A 7" panel across the desk is further away than a
16" laptop screen, so it is not simply "small screen, small type" — that panel
needs the largest type of the three. Distance cannot be measured, so point
density supplies a default and each screen keeps a manual offset, remembered
against the display's stable EDID identity. Automatic where it can be, asked
once where it cannot.

## Consequences

Idle sessions collapse to a single line, and cards are no longer uniform height.
The current code deliberately reserves an empty meta row so that a grid lines up;
that trades away the fastest channel a glance has. Across a desk, peripheral
vision reads *shape* long before text, and a visibly shorter row is "nothing to
do here" at a distance where no label is legible. Alignment loses to attention.

Collapsing is unconditional — not triggered by running out of room. A threshold
would mean a session changes shape because a *different* session appeared, and
that relayout is motion carrying no information about anything the viewer is
looking at. On a display that lives in peripheral vision, motion is the most
expensive thing on screen (ADR-0006), so it may only ever mean something.

Idle cards therefore never show branch, model, or the last message — not even on
a 27" screen with room to spare. ADR-0007 removed those three fields outright;
that was a judgement about millimetres generalised into one about worth, and it
was too broad. They are legible at 82 points per inch and they earn their space
on an active session. They are dropped for idle sessions because of state, not
because of size.

The 168-point-per-inch tier is extrapolation. Only 82 and 110 exist on this
machine; the panel has not been bought. The formula is written to cover it, and
is claimed to be verified only where it has been seen.
