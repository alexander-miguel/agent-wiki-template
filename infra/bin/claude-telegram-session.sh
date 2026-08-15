#!/usr/bin/env bash
# Run the Telegram channel in a tmux session while systemd tracks its lifetime.
set -euo pipefail

session="${CLAUDE_TMUX_SESSION:-claude-agent-wiki}"
repo="${AGENT_WIKI_REPO:-$HOME/agent-wiki}"
model="${CLAUDE_MODEL:-claude-opus-5}"
effort="${CLAUDE_EFFORT:-medium}"
channel="${CLAUDE_CHANNEL:-plugin:telegram@claude-plugins-official}"

tmux kill-session -t "$session" 2>/dev/null || true
printf -v command 'claude --model %q --effort %q --permission-mode auto --channels %q' \
    "$model" "$effort" "$channel"
tmux new-session -d -s "$session" -c "$repo" "$command"

while tmux has-session -t "$session" 2>/dev/null; do
    sleep 5
done
