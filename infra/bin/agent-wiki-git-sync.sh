#!/usr/bin/env bash
# Sync only completed wiki operations, and retry previously unpushed commits.
set -euo pipefail

repo="${AGENT_WIKI_REPO:-$HOME/agent-wiki}"
log_file="${AGENT_WIKI_GIT_LOG:-$HOME/.local/state/agent-wiki/git-sync.log}"
state_dir="${AGENT_WIKI_STATE_DIR:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/agent-wiki}"
lock_file="$state_dir/operation.lock"
busy_file="$state_dir/busy"

mkdir -p "$(dirname "$log_file")" "$state_dir"
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$log_file"; }

exec 9>"$lock_file"
if ! flock -n 9; then
    log "sync skipped: another repository operation holds the lock"
    exit 0
fi
if [ -f "$busy_file" ]; then
    log "sync deferred: Claude turn is active"
    exit 0
fi

cd "$repo"

if ! git pull --ff-only origin main >>"$log_file" 2>&1; then
    log "pull --ff-only failed; working tree left untouched"
    exit 1
fi

# A prior push may have failed after its commit succeeded. Retry even when the
# working tree is clean.
if [ "$(git rev-list --count origin/main..HEAD)" -gt 0 ]; then
    if git push origin main >>"$log_file" 2>&1; then
        log "pushed previously unpushed commits"
    else
        log "push retry failed"
        exit 1
    fi
fi

if [ -z "$(git status --porcelain)" ]; then
    exit 0
fi

if ! python3 "$repo/infra/wiki_lint.py" "$repo" >>"$log_file" 2>&1; then
    log "wiki invariant check failed; changes not committed"
    exit 1
fi

git add -A
if git diff --cached --quiet; then
    exit 0
fi
git commit -m "vault backup: $(date -u +%Y-%m-%d\ %H:%M:%S)" >>"$log_file" 2>&1
if git push origin main >>"$log_file" 2>&1; then
    log "committed and pushed completed changes"
else
    log "push failed; the next run will retry this commit"
    exit 1
fi
