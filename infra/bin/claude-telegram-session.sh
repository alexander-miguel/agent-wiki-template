#!/usr/bin/env bash
# Run the Telegram channel in a tmux session while systemd tracks its lifetime.
set -euo pipefail

session="${CLAUDE_TMUX_SESSION:-claude-agent-wiki}"
repo="${AGENT_WIKI_REPO:-$HOME/agent-wiki}"
model="${CLAUDE_MODEL:-claude-opus-5}"
effort="${CLAUDE_EFFORT:-medium}"
channel="${CLAUDE_CHANNEL:-plugin:telegram@claude-plugins-official}"

# Marks this as the session whose turns are journalled and whose ending writes
# a handover note for its successor. See agent-wiki-session.py.
export AGENT_WIKI_SESSION_CONTINUITY=1

tmux kill-session -t "$session" 2>/dev/null || true

telegram_process_is_candidate() {
    local pid="$1" cwd arg
    local -a argv=()
    [ -r "/proc/$pid/cmdline" ] || return 1
    mapfile -d '' -t argv <"/proc/$pid/cmdline"
    [ "${argv[0]##*/}" = "bun" ] || return 1
    if [ "${argv[1]:-}" = "run" ]; then
        for ((arg = 2; arg + 1 < ${#argv[@]}; arg++)); do
            if [ "${argv[$arg]}" = "--cwd" ] &&
                [[ "${argv[$((arg + 1))]}" == */telegram/* ]] &&
                [ "${argv[-1]}" = "start" ]; then
                return 0
            fi
        done
    elif [ "${argv[1]:-}" = "server.ts" ]; then
        cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)
        [[ "$cwd" == */telegram/* ]] && return 0
    fi
    return 1
}

terminate_telegram_process() {
    local pid="$1" attempt
    kill "$pid" 2>/dev/null || return 1
    for ((attempt = 0; attempt < 10; attempt++)); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.1
    done
    kill -KILL "$pid" 2>/dev/null || return 1
}

# A killed tmux/Claude tree can leave both Bun's Telegram launcher and its
# server.ts child adopted by init. Remove every old process immediately before
# starting the sole intended session so two pollers never share one bot token.
while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    telegram_process_is_candidate "$pid" || continue
    if kill -0 "$pid" 2>/dev/null && terminate_telegram_process "$pid"; then
        printf '%s reaped orphaned Telegram process pid=%s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pid" >&2
    fi
done < <(pgrep -x bun || true)

printf -v command 'claude --model %q --effort %q --permission-mode auto --channels %q' \
    "$model" "$effort" "$channel"
tmux new-session -d -s "$session" -c "$repo" "$command"

while tmux has-session -t "$session" 2>/dev/null; do
    sleep 5
done
