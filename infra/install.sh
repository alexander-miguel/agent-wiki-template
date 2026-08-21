#!/usr/bin/env bash
# Install or update the agent-wiki user services on this host.
#
# Idempotent: safe to re-run after every git pull. It preserves existing
# runtime.env values and only appends newly required defaults.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
lib_dir="$HOME/.local/lib/agent-wiki"
unit_dir="$HOME/.config/systemd/user"
config_dir="$HOME/.config/agent-wiki"
runtime_env="$config_dir/runtime.env"

for command in claude curl flock git jq python3 systemctl tmux; do
    command -v "$command" >/dev/null || {
        printf 'Missing required command: %s\n' "$command" >&2
        exit 1
    }
done
python3 -c 'import yaml' >/dev/null 2>&1 || {
    printf 'Missing Python dependency: PyYAML (pip install --user pyyaml)\n' >&2
    exit 1
}

install -d -m 755 "$lib_dir" "$unit_dir" "$config_dir" \
    "$HOME/.local/state/agent-wiki" \
    "$HOME/.local/state/agent-wiki/sessions/journal" \
    "$HOME/.local/state/agent-wiki/sessions/handover"
for script in "$repo"/infra/bin/*.sh "$repo"/infra/bin/*.py; do
    [ -e "$script" ] || continue
    install -m 755 "$script" "$lib_dir/$(basename "$script")"
done
for unit in "$repo"/infra/systemd/user/*; do
    install -m 644 "$unit" "$unit_dir/$(basename "$unit")"
done

# systemd user services do not source your shell profile. If claude, bun or
# node live somewhere a version manager put them, the unit's baked-in PATH
# will not find them. Rewrite it from the PATH of the shell running this.
session_unit="$unit_dir/claude-telegram.service"
if [ -n "${PATH:-}" ]; then
    python3 - "$session_unit" "$PATH" <<'PY'
import pathlib, re, sys
unit, path = pathlib.Path(sys.argv[1]), sys.argv[2]
text = unit.read_text()
home = str(pathlib.Path.home())
# %h is systemd's escape for the user's home directory.
path = ":".join(p.replace(home, "%h", 1) if p.startswith(home) else p
                for p in path.split(":") if p)
unit.write_text(re.sub(r"^Environment=PATH=.*$", f"Environment=PATH={path}",
                       text, count=1, flags=re.M))
PY
    printf 'Set the service PATH from the installing shell.\n'
fi

if [ ! -f "$runtime_env" ]; then
    {
        printf '# Host-specific values for the agent-wiki services.\n'
        printf '# Never commit this file. Mode 600.\n\n'
        printf 'AGENT_WIKI_REPO=%q\n' "$repo"
        printf 'TELEGRAM_ENV_FILE=%q\n' "$HOME/.claude/channels/telegram/.env"
        printf '\n# Chat id the watchdog alerts when it cannot restore the session.\n'
        printf '# Leave unset to disable alerting.\n'
        printf '# TELEGRAM_ALERT_CHAT_ID=123456789\n\n'
        printf 'CLAUDE_TMUX_SESSION=claude-agent-wiki\n'
        printf 'CLAUDE_MODEL=claude-opus-5\n'
        printf 'CLAUDE_EFFORT=medium\n'
        printf '\n# Refresh the context only when it is this old (6h), the agent has been\n'
        printf '# idle this long (15m), and no turn is running. The maximum bounds a\n'
        printf '# permanently busy session at 24h.\n'
        printf 'CLAUDE_MIN_SESSION_AGE_SECONDS=21600\n'
        printf 'CLAUDE_MIN_IDLE_SECONDS=900\n'
        printf 'CLAUDE_MAX_SESSION_AGE_SECONDS=86400\n'
        printf '\n# Write a deterministic turn journal and summarise clean handovers.\n'
        printf 'AGENT_WIKI_SESSION_SUMMARY=1\n'
    } >"$runtime_env"
    chmod 600 "$runtime_env"
    printf 'Created %s. Review it before relying on the services.\n' "$runtime_env"
else
    if ! grep -q '^AGENT_WIKI_SESSION_SUMMARY=' "$runtime_env"; then
        printf 'AGENT_WIKI_SESSION_SUMMARY=1\n' >>"$runtime_env"
    fi
fi

systemctl --user daemon-reload
systemctl --user enable --now \
    claude-telegram.service \
    claude-watchdog.timer \
    agent-wiki-git-sync.timer \
    claude-telegram-refresh.timer \
    agent-wiki-lint.timer

cat <<'EOF'

Installed. Verify with:
  systemctl --user status claude-telegram.service
  systemctl --user list-timers --all
  python3 infra/wiki_lint.py

Enable lingering so the services survive logout:
  sudo loginctl enable-linger "$USER"
EOF
