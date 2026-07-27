# Built for an always-on secondary display, not a menu-bar glance

The intended deployment is a small dedicated screen (roughly 7–10", ~1024×600)
sitting on the desk, permanently showing the dashboard. This is a constraint
that is invisible in the code and easy to lose — an earlier implementation
encoded it only as a window-size comment, and a later rewrite carried the
dimensions across while silently adopting desktop-window typography.

Two things follow. Notifications are not built: the display is already in view,
so an alert would interrupt to report something the user can see. And layout is
designed for reading at a glance across a desk rather than for information
density — larger type, state carried by colour and motion rather than by small
text, fewer and larger cards, and secondary detail dropped rather than shrunk.

## Consequences

The menu bar becomes a secondary affordance, not the primary surface.

Anything that wastes vertical space is a real cost, not a cosmetic one — for
instance sessions whose working directory resolves to `/`, which are artefacts
of a process's directory being unreadable rather than things a user recognises.

The breathing animation carries more weight than it would in a focused window,
because peripheral vision detects motion long before it reads text.
