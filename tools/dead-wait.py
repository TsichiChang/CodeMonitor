#!/usr/bin/env python3
"""Measure dead wait: time an agent spent waiting while the user was at the
keyboard, working in a different session.

This is the number ADR-0014 rests on, and the one that decides whether the
ambient overlay worked. Run it before, run it again a week after.

    python3 tools/dead-wait.py [days]

Two traps this deliberately avoids, both of which produced a wrong answer the
first time round:

1. **A long gap is not evidence of a missed signal.** The p99 gap between an
   agent stopping and the user replying is four hours — that is going home, not
   failing to notice. Only the part of a gap that overlaps a period when the
   user was demonstrably present counts.

2. **Presence must be reconstructed, not assumed.** It is inferred from the
   user's own typing across *all* sessions: inputs less than PRESENCE_GAP apart
   are one continuous stretch at the keyboard. This under-reports presence —
   reading without typing looks like absence — which is the safe direction, as
   it can only understate the problem.

The result is in session-minutes, not wall-clock: three sessions waiting on you
for five minutes is fifteen. Read the counts, not the total.
"""

import bisect
import glob
import json
import os
import sys
import time
from datetime import datetime

TRANSCRIPTS = os.path.expanduser("~/.claude/projects")
PRESENCE_GAP = 600  # inputs this close together are one stretch at the keyboard
PRESENCE_PAD = 60   # each input also vouches for a minute either side
MAX_GAP = 6 * 3600  # beyond this it is not a wait, it is an abandoned session


def parse(days):
    """Returns (waits, inputs): waits are (start, end, project), inputs are epochs."""
    cutoff = time.time() - days * 86400
    waits, inputs = [], []

    for path in glob.glob(os.path.join(TRANSCRIPTS, "*", "*.jsonl")):
        if os.path.getmtime(path) < cutoff:
            continue
        project = os.path.basename(os.path.dirname(path)).split("-")[-1]
        stopped = None

        with open(path, errors="ignore") as handle:
            for line in handle:
                if '"timestamp"' not in line:
                    continue
                try:
                    record = json.loads(line)
                    when = datetime.fromisoformat(
                        record["timestamp"].replace("Z", "+00:00")
                    ).timestamp()
                except (ValueError, KeyError, TypeError):
                    continue
                if when < cutoff:
                    continue

                kind = record.get("type")
                if kind == "assistant":
                    stopped = when
                elif kind == "user":
                    content = (record.get("message") or {}).get("content")
                    text = content if isinstance(content, str) else " ".join(
                        block.get("text", "")
                        for block in (content or [])
                        if isinstance(block, dict)
                    )
                    # A tool result is not a person. Nor is Esc — Claude Code
                    # writes that as a user record too, and reading it as input
                    # is the same misreading that once showed an interrupted
                    # session as waiting for approval.
                    if not text or text.startswith("[Request interrupted"):
                        continue
                    inputs.append(when)
                    if stopped and 0 < when - stopped < MAX_GAP:
                        waits.append((stopped, when, project))
                    stopped = None

    inputs.sort()
    return waits, inputs


def presence(inputs):
    """Stretches during which the user was demonstrably at the keyboard."""
    spans = []
    for when in inputs:
        start, end = when - PRESENCE_PAD, when + PRESENCE_PAD
        if spans and start - spans[-1][1] <= PRESENCE_GAP:
            spans[-1][1] = end
        else:
            spans.append([start, end])
    return spans


def main():
    days = int(sys.argv[1]) if len(sys.argv) > 1 else 14
    waits, inputs = parse(days)
    if not waits:
        print("no waits found")
        return

    spans = presence(inputs)
    starts = [span[0] for span in spans]

    dead = []
    for start, end, project in waits:
        first = max(0, bisect.bisect_right(starts, start) - 1)
        overlap = sum(
            max(0, min(end, span_end) - max(start, span_start))
            for span_start, span_end in spans[first:first + 40]
        )
        if overlap > 0:
            dead.append((overlap, project))
    dead.sort(reverse=True)

    at_keyboard = sum(end - start for start, end in spans)
    total = sum(seconds for seconds, _ in dead)
    median = sorted(seconds for seconds, _ in dead)[len(dead) // 2]

    print(f"over {days} days")
    print(f"  at the keyboard   {at_keyboard / 3600:.1f} h  ({at_keyboard / 3600 / days:.1f} h/day)")
    print(f"  dead wait         {total / 3600:.1f} session-h,  median {median / 60:.1f} min\n")
    for threshold in (60, 180, 300, 600):
        count = sum(1 for seconds, _ in dead if seconds > threshold)
        print(f"  waits over {threshold // 60:2d} min: {count:4d}   ({count / days:.1f}/day)")
    print("\nlongest")
    for seconds, project in dead[:6]:
        print(f"  {seconds / 60:6.1f} min   {project}")


if __name__ == "__main__":
    main()
