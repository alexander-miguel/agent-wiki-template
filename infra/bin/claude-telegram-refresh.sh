#!/usr/bin/env bash
# Refresh an old context only after Claude has been idle for a safe interval.
set -euo pipefail

state_dir="${AGENT_WIKI_STATE_DIR:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/agent-wiki}"
log_file="${AGENT_WIKI_REFRESH_LOG:-$HOME/.local/state/agent-wiki/context-refresh.log}"
min_session_age="${CLAUDE_MIN_SESSION_AGE_SECONDS:-21600}"
min_idle_age="${CLAUDE_MIN_IDLE_SECONDS:-900}"
max_session_age="${CLAUDE_MAX_SESSION_AGE_SECONDS:-86400}"
lock_file="$state_dir/operation.lock"
busy_file="$state_dir/busy"
last_activity_file="$state_dir/last-activity"

mkdir -p "$state_dir" "$(dirname "$log_file")"
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$log_file"; }

systemctl --user is-active --quiet claude-telegram.service || exit 0

started_usec=$(systemctl --user show claude-telegram.service \
    --property=ActiveEnterTimestampMonotonic --value)
now_usec=$(awk '{printf "%.0f", $1 * 1000000}' /proc/uptime)
if ! [[ "$started_usec" =~ ^[0-9]+$ ]] || [ "$started_usec" -eq 0 ]; then
    log "refresh skipped: could not determine service age"
    exit 0
fi
session_age=$(( (now_usec - started_usec) / 1000000 ))
[ "$session_age" -ge "$min_session_age" ] || exit 0

exec 9>"$lock_file"
if ! flock -n 9; then
    log "refresh deferred: repository operation holds the lock"
    exit 0
fi

if [ -f "$busy_file" ] && [ "$session_age" -lt "$max_session_age" ]; then
    log "refresh deferred: Claude turn is active (session age ${session_age}s)"
    exit 0
fi

if [ -f "$last_activity_file" ]; then
    idle_age=$(( $(date +%s) - $(stat -c %Y "$last_activity_file") ))
else
    idle_age="$session_age"
fi
if [ "$idle_age" -lt "$min_idle_age" ] && [ "$session_age" -lt "$max_session_age" ]; then
    log "refresh deferred: only ${idle_age}s idle"
    exit 0
fi

if [ "$session_age" -ge "$max_session_age" ]; then
    log "refreshing context at maximum age ${session_age}s"
else
    log "refreshing idle context at age ${session_age}s after ${idle_age}s idle"
fi
systemctl --user restart claude-telegram.service
