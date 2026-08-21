# agent-wiki

A personal knowledge base that an LLM maintains for you, running on a small
Linux box, reachable from your phone over Telegram.

You send it an article, a voice note, a half-formed thought. It files that
into a Markdown vault with consistent frontmatter and links, updates the
index, and appends to a log. Later you ask it a question and it answers from
your own notes, with citations to the pages it used. It runs unattended:
watchdog, auto-restart, context refresh, git sync, nightly checks.

The vault is plain Markdown in a git repo. No database, no lock-in. Obsidian
opens it, `grep` searches it, and you can walk away with it.

## What you get

- **A filing agent.** Drop sources in `raw/`, say "ingest these", get back a
  consolidated report of what it created and any contradictions it noticed.
- **A structure that holds.** Five page types, bidirectional links, a linter
  that fails the commit if the schema breaks.
- **A phone interface.** Telegram, with a reply discipline that acknowledges
  in one line and follows up when the work is done, so long tasks do not feel
  like a hang.
- **Restart-safe conversation continuity.** Every Claude Code session is
  fresh, but hooks inject a bounded brief from the last completed turns. The
  Markdown wiki remains the canonical long-term memory.
- **Unattended operation.** Health checks every minute, restart on repeated
  failure, context refresh when idle, commit and push every fifteen minutes.
- **A job scheduler.** Recurring Claude work as a spec file plus a prompt
  file, with locking, validation and delivery supplied for you.

## Requirements

- A Linux host with systemd user services. 1 GB of RAM is enough. A cheap VPS
  is the intended home.
- Node 22+, `git`, `curl`, `jq`, `tmux`, `python3` with PyYAML.
- The Claude CLI and a Claude subscription or API key.
- A Telegram bot token, free from @BotFather.

## Setup

Hand `SETUP.md` to a coding agent and let it do the install:

```bash
git clone <this-repo> ~/agent-wiki
cd ~/agent-wiki
claude
```

Then: *"Read SETUP.md and set this up on this host."*

It is written to be followed end to end, stopping to ask you only for the
things a machine cannot get by itself: a bot token, a sudo password, a browser
login. If you would rather do it by hand, the same file works as a checklist.

Fastest path once installed: put a file in `raw/`, message the bot "ingest
this", and read what comes back.

## How it fits together

```
Telegram  ──►  claude-telegram.service  ──►  tmux  ──►  claude
                        ▲                                  │
                        │                                  ▼
              claude-watchdog.timer                    wiki/*.md
              (1 min liveness checks)                      │
                        │                                  ▼
              claude-telegram-refresh.timer         git-sync.timer
              (restart old idle contexts)           (lint, commit, push)
```

The piece worth understanding is the **turn lock**. Claude Code hooks mark a
turn as active in `$XDG_RUNTIME_DIR`; git sync and context refresh take the
same lock. So a commit never catches a half-written vault, and a refresh
never kills the session mid-reply. Both failures, without it, look random and
are miserable to debug.

The same hooks maintain a mechanical per-turn journal. Clean exits freeze a
handover; hard kills leave the journal behind. The next fresh session receives
the newest one as bounded `SessionStart` context, without using `--continue`.
This bridges short conversational gaps while keeping durable memory explicit
and reviewable in `wiki/`.

Full detail in `infra/README.md`.

## The vault

```
raw/      source material, read-only, never edited
assets/   images and generated charts
wiki/     the layer the agent owns: flat, no subfolders
  index.md   catalog, one line per page
  log.md     append-only record of every operation
```

Every page carries frontmatter:

```yaml
---
type: concept          # source | concept | goal | list | overview
tags: [habit, focus]
created: 2026-01-15
updated: 2026-01-15
related:
  - "[[deep-work]]"    # must be mirrored on the other page
---
```

`related` is bidirectional and the linter enforces it. That constraint is
what turns a pile of notes into something you can traverse.

```bash
python3 infra/wiki_lint.py                  # schema, dates, links, index
python3 infra/wiki_lint.py --strict-orphans # also fail on unlinked pages
```

## Daily use

| You want | You say |
|---|---|
| File something | Put it in `raw/`, then "ingest this" |
| Ask your notes | "What have I written about X?" |
| Keep an answer | "File that" — it becomes a page, linked and indexed |
| Health check | "Lint the wiki" — reports, never auto-fixes |
| Remember a preference | "Remember that I..." — written to a page, not to chat |

The agent reports findings and asks before acting on them. It does not
silently rewrite your pages.

## Scheduled jobs

Recurring work lives in `infra/claude-jobs/` as a spec plus a prompt. The
runner handles locking, preflight, validation, delivery, logging and
retention, so a job is configuration rather than another 150-line script.

```bash
claude-jobs list
claude-jobs run weekly-digest --dry-run
claude-jobs install weekly-digest
```

Two examples ship: a nightly contradiction sweep that writes a report, and a
weekly digest that messages you. Installing schedules nothing until you say
so. See `infra/claude-jobs/README.md`.

## Making it yours

`CLAUDE.md` is the agent's constitution, read at the start of every session.
Personalise the owner block and the out-of-scope list; leave the schema and
workflows alone until you have lived with them for a few weeks.

The strong opinions in there, and why they are worth keeping:

- **Reply fast, then follow up.** Acknowledge in one sentence, do the work in
  the background, send the result as a new message. Anything else feels
  broken on a phone.
- **One writer.** Git sync assumes this host is the only thing committing. Add
  a second and you will get conflicts.
- **Never write to `raw/`.** Provenance is the point.
- **Links go both ways.** Enforced, not encouraged.
- **Report, don't auto-fix.** The lint and sweep tell you what they found and
  leave the decision with you.

## Security

Three files hold secrets. None is tracked by git, and `.gitignore` already
excludes them:

- `~/.claude/channels/telegram/.env` — bot token
- `~/.config/agent-wiki/runtime.env` — chat ids, host paths
- `~/.config/claude-jobs/runtime.env` — per-job chat ids

Set the Telegram DM policy to `pairing` so unknown people have to be approved
rather than admitted. Job token files must be mode 600; the runner refuses to
start otherwise. Read-only jobs use an explicit tool denylist rather than
trusting the prompt, and `GUARD_PATHS` fails a run that modified a file it
was only supposed to read.

The vault will accumulate personal detail quickly. Keep the GitHub repo
private. This template is public; the vault you build with it should not be.

One thing to decide consciously before you start it: the session runs with
`--permission-mode auto`, which is what makes an unattended agent useful and
also means it acts without asking. It is reachable from Telegram, so anyone
who can message the bot can direct it. Set the DM policy to `pairing`,
allowlist yourself, and do not run it as a user with more access than the job
needs. If that trade is not one you want, change the mode in
`infra/bin/claude-telegram-session.sh` before the first start.

## Layout

```
CLAUDE.md              agent conventions, read every session
SETUP.md               install guide, written for an LLM to execute
README.md              this file
wiki/ raw/ assets/     the vault
infra/
  install.sh           idempotent installer
  wiki_lint.py         structural checks
  bin/                 launcher, continuity, watchdog, refresh, sync, hooks
  systemd/user/        one service and four timers
  claude-jobs/         scheduler for recurring Claude work
.claude/settings.json  turn-state hooks
.obsidian/             plugin and attachment config
```

## Licence

MIT. Take it apart.
