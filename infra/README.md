# Infrastructure

Everything that keeps the agent running on a Linux host, as version-controlled
templates. No secrets live here. Host-specific values go in
`~/.config/agent-wiki/runtime.env`, which the installer creates at mode 600
and never overwrites.

## Install or update

From the repository root:

```bash
./infra/install.sh
```

The installer copies scripts to `~/.local/lib/agent-wiki/`, installs systemd
user units under `~/.config/systemd/user/`, creates `runtime.env` if it is
missing, and enables the service and timers. It is idempotent, so re-run it
after every `git pull`.

One thing it does that is easy to miss: it rewrites the `PATH` line in
`claude-telegram.service` using the `PATH` of the shell you install from.
systemd user services do not read your shell profile, so a `claude` or `bun`
installed by nvm, mise or similar is invisible to the unit otherwise. This is
the single most common reason a fresh install starts and immediately dies.

Enable lingering, or everything stops when you log out:

```bash
sudo loginctl enable-linger "$USER"
```

## What runs

| Unit | Cadence | Job |
|---|---|---|
| `claude-telegram.service` | always on | Runs the Claude session inside tmux |
| `claude-watchdog.timer` | 5 min | Four liveness checks, restarts on repeated failure |
| `claude-telegram-refresh.timer` | 15 min | Restarts an old context, but only when idle |
| `agent-wiki-git-sync.timer` | 15 min | Pulls, lints, commits and pushes |
| `agent-wiki-lint.timer` | daily | Structural check of the vault |

## The session

`claude-telegram-session.sh` starts Claude inside a tmux session and then
blocks until that session disappears, which is what lets systemd track a
process it did not spawn directly. Attach with `tmux attach -t
claude-agent-wiki` to watch it work; detach with `Ctrl-b d`.

Every service start creates a fresh context. There is no `--continue`.

## The watchdog

Every five minutes `claude-watchdog.sh` checks, in order:

1. the systemd service is active,
2. the tmux session exists,
3. the Claude process is alive and not a zombie,
4. the Telegram plugin process is a child of it,
5. `getMe` against the Telegram Bot API returns `ok`.

A single failure is recorded, not acted on, because a transient API blip is
not an outage. Two consecutive failures trigger a restart, and an inactive
service triggers one immediately. A 30-minute cooldown stops a restart loop.
If `TELEGRAM_ALERT_CHAT_ID` is set, a failed restart sends you a message.

## Context refresh

A long-lived context accumulates and eventually degrades. The refresh timer
restarts the session, but only when all of these hold:

- the context is at least six hours old (`CLAUDE_MIN_SESSION_AGE_SECONDS`),
- no Claude turn is currently running,
- the agent has been idle at least 15 minutes (`CLAUDE_MIN_IDLE_SECONDS`).

A 24-hour maximum (`CLAUDE_MAX_SESSION_AGE_SECONDS`) bounds the case where a
busy marker gets stuck or the agent genuinely never goes idle.

## Turn locking

This is the part that makes the whole thing safe, and the part people skip.

Claude Code hooks in `.claude/settings.json` call
`agent-wiki-turn-state.sh` on session start, prompt submit, stop, stop
failure, and session end. It maintains a `busy` marker and an advisory
`flock` under `$XDG_RUNTIME_DIR/agent-wiki/`.

Git sync and context refresh take the same lock. So a commit never runs
against a half-written vault, and a refresh never kills the session in the
middle of a reply. Without this you get corrupted files and lost turns, and
both failures look random.

## Git sync

Every 15 minutes `agent-wiki-git-sync.sh`:

1. takes the lock, and exits quietly if a turn is active,
2. `git pull --ff-only`, leaving the tree untouched if that fails,
3. retries any commit sitting ahead of `origin/main` from a failed push,
4. runs `wiki_lint.py` and refuses to commit if it fails,
5. commits and pushes.

This is safe only while one machine writes to the repository. If you also
edit the vault in Obsidian on a laptop, sort out the concurrency story before
turning this on.

## Lint

`wiki_lint.py` checks the vault's structure, not its prose: frontmatter
schema, the `type` enum, ISO dates, `related` targets that exist, reverse
links present on both ends, and index coverage. Orphan pages are warnings by
default because a standalone source page is legitimate. Use `--strict-orphans`
to make them errors.

```bash
python3 infra/wiki_lint.py
python3 infra/wiki_lint.py --strict-orphans
```

## Scheduled jobs

Recurring Claude work (a nightly audit, a weekly digest) does not belong in
this directory. It goes in `claude-jobs/`, which is a small scheduler where a
job is a spec file plus a prompt file. See its README.

## Verification

```bash
systemctl --user status claude-telegram.service
systemctl --user list-timers --all
journalctl --user -u claude-watchdog.service -n 50 --no-pager
tail ~/.local/state/agent-wiki/git-sync.log
tail ~/.local/state/agent-wiki/context-refresh.log
python3 infra/wiki_lint.py
```
