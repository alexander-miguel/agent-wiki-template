#!/usr/bin/env bash
# Claude Code hook: prevent Git sync and context refresh during an active turn.
set -euo pipefail

payload=$(cat)
event=$(jq -r '.hook_event_name // empty' <<<"$payload")
session_id=$(jq -r '.session_id // empty' <<<"$payload")

state_dir="${AGENT_WIKI_STATE_DIR:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/agent-wiki}"
lock_file="$state_dir/operation.lock"
busy_file="$state_dir/busy"
last_activity_file="$state_dir/last-activity"
mkdir -p "$state_dir"

exec 9>"$lock_file"
flock 9

case "$event" in
    SessionStart)
        rm -f "$busy_file"
        touch "$last_activity_file"
        ;;
    UserPromptSubmit)
        printf '%s %s\n' "$session_id" "$(date +%s)" >"$busy_file.tmp"
        mv "$busy_file.tmp" "$busy_file"
        touch "$last_activity_file"
        ;;
    Stop|StopFailure|SessionEnd)
        if [ ! -f "$busy_file" ] || [ "$(cut -d' ' -f1 "$busy_file")" = "$session_id" ]; then
            rm -f "$busy_file"
        fi
        touch "$last_activity_file"
        ;;
esac
