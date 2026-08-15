#!/usr/bin/env bash
# Run the structural check against the configured vault.
set -euo pipefail
repo="${AGENT_WIKI_REPO:-$HOME/agent-wiki}"
exec python3 "$repo/infra/wiki_lint.py" "$repo" "$@"
