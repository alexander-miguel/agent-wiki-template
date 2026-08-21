# Infrastructure

Everything that keeps the agent running on a Linux host, as version-controlled
templates. No secrets live here. Host-specific values go in
`~/.config/agent-wiki/runtime.env`, which the installer creates at mode 600
and preserves existing values.

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
| `claude-watchdog.timer` | 1 min | Process-tree and Telegram delivery checks; guarded restart |
| `claude-telegram-refresh.timer` | 15 min | Restarts an old context, but only when idle |
| `agent-wiki-git-sync.timer` | 15 min | Pulls, lints, commits and pushes |
| `agent-wiki-lint.timer` | daily | Structural check of the vault |

## The session

`claude-telegram-session.sh` removes Telegram Bun processes leaked by an
older session, starts Claude inside tmux, and then blocks until that session
disappears. That lets systemd track a process it did not spawn directly. Attach
with `tmux attach -t claude-agent-wiki` to watch it work; detach with `Ctrl-b d`.

Every service start creates a fresh Claude Code context. There is no
`--continue`. Short-term continuity comes from `agent-wiki-session.py` and the
hooks in `.claude/settings.json`:

- `Stop` and `StopFailure` mechanically rebuild a bounded journal from the
  Claude transcript, with no model call.
- `SessionEnd` freezes the journal as a handover. With
  `AGENT_WIKI_SESSION_SUMMARY=1` (the installer default), a detached low-effort
  Sonnet pass distils it into open threads and decisions.
- `SessionStart` injects the newest prior handover or journal as additional
  context. A hard kill therefore recovers through the last completed turn even
  though no `SessionEnd` hook ran.

Only this service exports `AGENT_WIKI_SESSION_CONTINUITY=1`. Terminal Claude
sessions, subagents, and scheduled jobs do not write or inherit the brief. The
brief is bounded short-term context, not durable memory: anything that must
survive belongs in the wiki.

## The watchdog

Every minute `claude-watchdog.sh` checks, in order:

1. the systemd service is active,
2. the tmux session exists,
3. the Claude process is alive and not a zombie,
4. Telegram Bun processes exist anywhere in Claude's descendant tree,
5. `getMe` against the Telegram Bot API returns `ok`,
6. `getWebhookInfo` reports zero pending updates.

The descendant walk matters because current Claude Code can place the plugin
below daemon and PTY-host processes rather than as a direct child. Exact Bun
argv/cwd checks also identify and reap old launcher and `server.ts` processes
outside the live Claude tree; two pollers on one token otherwise race for
updates.

A single failure is recorded, not acted on, because a transient API blip is
not an outage. Two consecutive failures trigger a restart, and an inactive
service triggers one immediately. Repeat restarts inside an hour back off for
5, 10, 20, then 30 minutes. A healthy hour resets the backoff. Except when the
service is inactive, a fresh busy marker defers restart for up to ten minutes,
so the watchdog does not kill an active reply. If `TELEGRAM_ALERT_CHAT_ID` is
set, recovery alerts are sent without consuming Claude allowance.

## Context refresh

A long-lived context accumulates and eventually degrades. The refresh timer
restarts the session, but only when all of these hold:

- the context is at least six hours old (`CLAUDE_MIN_SESSION_AGE_SECONDS`),
- no Claude turn is currently running,
- the agent has been idle at least 15 minutes (`CLAUDE_MIN_IDLE_SECONDS`).

Busy markers older than ten minutes are stale. A 24-hour maximum
(`CLAUDE_MAX_SESSION_AGE_SECONDS`) is checked before the operation lock, so a
wedged repository task cannot defer refresh forever.

## Turn locking

This is the part that makes the whole thing safe, and the part people skip.

Claude Code hooks in `.claude/settings.json` call
`agent-wiki-turn-state.sh` on session start, prompt submit, stop, stop failure,
and session end. It maintains a `busy` marker and an advisory `flock` under
`$XDG_RUNTIME_DIR/agent-wiki/`. Hook lock acquisition times out after ten
seconds and logs the timeout rather than hanging Claude indefinitely.

Git sync and context refresh take the same lock. So a commit never runs against
a half-written vault, and an ordinary refresh or watchdog recovery never kills
the session in the middle of a reply. All readers discard a busy marker older
than ten minutes. Without these bounds, one hung hook can block maintenance
forever.

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
tail ~/.local/state/agent-wiki/sessions/sessions.log
tail ~/.local/state/agent-wiki/turn-state.log
python3 infra/wiki_lint.py
```
