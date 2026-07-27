#!/bin/sh
# Code Monitor — coding-agent state hook.
#
# Records what a session is doing, and where it is running, as a small JSON file
# the dashboard reads (ADR-0010). One file per session, replaced in place.
#
# This runs inside the user's own agent session on every hook event, so it is
# written to be fast and to fail silently: a broken hook would break the very
# session it reports on. It writes a file and nothing else — no client library,
# no path back to the app, nothing that breaks if the app is moved or removed.
#
# Usage (registered in a Claude Code settings.json hooks array):
#     codemonitor-hook.sh <event-state> <agent-pid>
#
#   <event-state>  running | waiting | idle | ended
#   <agent-pid>    the agent process's pid ($PPID at hook time)

set -u

STATE_DIR="${CODEMONITOR_STATE_DIR:-$HOME/.local/state/codemonitor/sessions}"

state="${1:-running}"
agent_pid="${2:-$PPID}"

# Claude passes the hook payload as JSON on stdin.
input=$(cat 2>/dev/null) || input=""

json_field() {
    printf '%s' "$input" \
        | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
        | head -n 1
}

session_id="${CLAUDE_SESSION_ID:-$(json_field session_id)}"
[ -n "$session_id" ] || exit 0

cwd=$(json_field cwd)
[ -n "$cwd" ] || cwd="$PWD"
event=$(json_field hook_event_name)

# A Task subagent runs in the background: while it works the main agent often
# yields and Claude fires Stop, even though the turn is not over. The still
# running subagent is listed in the Stop payload, so treat that as activity
# rather than reporting an idle state the user would see as "done".
if [ "$state" = idle ]; then
    compact=$(printf '%s' "$input" | tr -d ' \t\n')
    case "$compact" in
        *'"type":"subagent","status":"running"'*|*'"status":"running","type":"subagent"'*)
            state=running ;;
    esac
fi

# A session that has ended leaves nothing behind to age out.
if [ "$state" = ended ]; then
    rm -f "$STATE_DIR/$session_id.json" 2>/dev/null
    exit 0
fi

tty_path=$(ps -o tty= -p "$agent_pid" 2>/dev/null | tr -d ' ')
case "$tty_path" in
    ""|"??") tty_path="" ;;
    /dev/*) ;;
    *) tty_path="/dev/$tty_path" ;;
esac

# Terminal tab, captured only when the session's tab is certainly focused —
# the user has just typed into it (ADR-0009). Otty resolves nothing about its
# caller, so the focused tab is the only thing that can be asked for.
tab_id=""
if [ "${3:-}" = "locate" ] && [ "${TERM_PROGRAM:-}" = otty ]; then
    otty_cli="${OTTY_CLI:-/Applications/Otty.app/Contents/MacOS/otty-cli}"
    if [ -x "$otty_cli" ]; then
        # Otty serialises object keys alphabetically, so "active" precedes "id"
        # and no single pattern can span them in order. Split the array into one
        # object per line first, then filter and extract.
        split_objects='s/},{/}\
{/g'
        window=$(
            "$otty_cli" window list --json 2>/dev/null \
                | tr -d ' \n' | sed "$split_objects" \
                | grep '"focused":true' \
                | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -n 1
        )
        active_tabs=$(
            "$otty_cli" tab list --json 2>/dev/null \
                | tr -d ' \n' | sed "$split_objects" \
                | grep '"active":true'
        )
        # Narrow to the focused window when there is one. There may not be:
        # Otty reports no focused window whenever it is not the frontmost app,
        # and rather than give up we take the active tab anyway. One window is
        # the common case, and a wrong guess is rejected later by the directory
        # check that guards this value (ADR-0009).
        if [ -n "$window" ]; then
            narrowed=$(printf '%s\n' "$active_tabs" | grep -F "\"window_id\":\"$window\"")
            [ -n "$narrowed" ] && active_tabs="$narrowed"
        fi
        tab_id=$(
            printf '%s\n' "$active_tabs" \
                | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -n 1
        )
    fi
fi

existing="$STATE_DIR/$session_id.json"

# Carry the tab forward. Only two events look it up, but every event rewrites
# this file — without this, the tab found at the start of a turn is erased by
# the first tool call that follows it.
if [ -z "$tab_id" ] && [ -f "$existing" ]; then
    tab_id=$(
        sed -n 's/.*"tabId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$existing" \
            | head -n 1
    )
fi

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
tmp="$STATE_DIR/.$session_id.$$"

cat > "$tmp" <<EOF
{
  "tool": "claude",
  "sessionId": "$session_id",
  "state": "$state",
  "event": "$event",
  "pid": $agent_pid,
  "tty": "$tty_path",
  "cwd": "$cwd",
  "termProgram": "${TERM_PROGRAM:-}",
  "tabId": "$tab_id",
  "updatedAt": $(date +%s)
}
EOF

# Replaced by rename so a reader never sees a half-written file.
mv -f "$tmp" "$STATE_DIR/$session_id.json" 2>/dev/null || rm -f "$tmp" 2>/dev/null
exit 0
