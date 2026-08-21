# SETUP.md — instructions for the LLM doing the install

You are setting up a personal, LLM-maintained knowledge vault with a Telegram
front end on a Linux host. Work through the phases in order. Do not skip
verification steps: each one catches a failure that is invisible until much
later.

Read `README.md` for what the system is. This file is how to build it.

## Rules for you, the installing agent

1. **Stop at every 🧑 marker.** Those steps need a human: a browser login, a
   token from another app, a `sudo` password. Ask for exactly what you need,
   wait, then continue. Never invent a token or guess a chat id.
2. **Never commit a secret.** Bot tokens, chat ids and API keys go in the
   files named below, all of which `.gitignore` already excludes. If you are
   about to write a credential into a tracked file, stop.
3. **Verify before moving on.** Each phase ends with a check. If it fails,
   fix it there. A broken phase 3 shows up as an inexplicable phase 7.
4. **Report at the end**, not throughout: what is running, what is not, and
   what the human still has to do.

## Phase 0 — Gather

Ask the user for these before touching anything. All but the first are
optional and can be added later.

| Need | Used for | Optional |
|---|---|---|
| Their name and a two-line description of themselves | Personalising `CLAUDE.md` | no |
| A Telegram bot token | The chat channel | no |
| Their Telegram numeric user id | Allowlisting and watchdog alerts | no |
| A GitHub repo URL (private) | Backup and sync | yes |
| Google account | Calendar/Gmail connectors | yes |

## Phase 1 — Host prerequisites

Target: a Linux host with systemd user services. A 1 GB VPS is enough.

```bash
sudo apt update
sudo apt install -y git curl jq tmux python3 python3-pip python3-yaml
```

If `python3-yaml` is unavailable, use `pip3 install --user pyyaml`.

Install Node (22 or newer) and the Claude CLI. Any install method works, but
remember where it lands, because systemd will need that path:

```bash
curl -fsSL https://claude.ai/install.sh | bash
claude --version
```

Enable lingering, or every service stops the moment the user logs out. This is
the single most common cause of "it worked until I closed my laptop":

```bash
sudo loginctl enable-linger "$USER"        # 🧑 needs sudo
```

**Verify:** `systemctl --user list-units` returns without error, and
`command -v claude` prints a path.

## Phase 2 — The vault

```bash
git clone <this-repo-url> ~/agent-wiki
cd ~/agent-wiki
```

If the user gave you a private GitHub repo of their own, repoint the remote
now, because git sync pushes to `origin/main`:

```bash
git remote set-url origin git@github.com:<user>/<repo>.git
git push -u origin main
```

🧑 If that push asks for credentials, hand it to the user, or have them run
`gh auth login`.

**Verify:** `python3 infra/wiki_lint.py` prints `errors=0`.

## Phase 3 — Personalise CLAUDE.md

`CLAUDE.md` is the agent's constitution and it is read on every session. Edit
these, and only these, in place:

1. The `## About the owner` block: name, context, interests.
2. The `## Out of scope` list: the boundaries that stop the vault sprawling.
3. Delete the two `<!-- PERSONALISE -->` comments once done.

Leave the frontmatter schema, workflows, log and index formats alone until
the vault has been used for a few weeks. They are load-bearing, and the
linter enforces several of them.

Then replace the three example pages in `wiki/`. Keep `about-me.md` and
rewrite it from what the user told you in phase 0. Delete
`example-concept.md` and `2026-01-15-example-source.md`, and remove their
lines from `wiki/index.md`.

**Verify:** `python3 infra/wiki_lint.py` still prints `errors=0`. If it
complains about a missing reverse link, you deleted one side of a `related`
pair; fix the other side.

## Phase 4 — Telegram

🧑 The user creates the bot themselves. Tell them:

> Message @BotFather on Telegram, send `/newbot`, follow the prompts, and
> paste me the token. Then message @userinfobot and paste me the numeric id
> it replies with.

With the token in hand, install the channel plugin and configure it:

```bash
claude
```

Inside the session:

```
/plugin marketplace add claude-plugins-official
/plugin install telegram@claude-plugins-official
/telegram:configure
```

Paste the token when asked. It is stored at
`~/.claude/channels/telegram/.env`, which is outside the repository. Never
copy it in.

Then set access policy so strangers cannot reach the bot:

```
/telegram:access
```

Allowlist the user's numeric id. Set the DM policy to `pairing` so a new
person has to be approved rather than admitted.

Also write the token where scheduled jobs can find it, at mode 600. The
runner refuses to start if the permissions are looser:

```bash
install -m 600 /dev/null ~/.claude/channels/telegram/bot.token
printf '%s' '<TOKEN>' > ~/.claude/channels/telegram/bot.token
```

**Verify:** run `claude --channels plugin:telegram@claude-plugins-official`
in a terminal, message the bot from Telegram, and confirm a reply arrives on
the phone. Stop the session with Ctrl-C once it works. Do not proceed until
a real message round-trips.

## Phase 5 — Services

```bash
cd ~/agent-wiki
./infra/install.sh
```

This copies scripts to `~/.local/lib/agent-wiki/`, installs systemd units,
creates `~/.config/agent-wiki/runtime.env` at mode 600, and enables
everything.

It also rewrites the `PATH` line in `claude-telegram.service` from the shell
you run it in. That matters: systemd user services do not read shell
profiles, so a `claude` installed by nvm or mise is otherwise invisible and
the service dies on start with a confusing error. If you installed Node in a
way that only your interactive shell knows about, run the installer from that
same shell.

The installer also deploys Claude Code session-continuity hooks. Each service
start still uses a fresh context, but the newest bounded handover or completed-
turn journal is injected at `SessionStart`. This survives hard kills without
using `--continue`. `AGENT_WIKI_SESSION_SUMMARY=1` enables the default detached
Sonnet handover summary; set it to `0` in `runtime.env` to keep mechanical
journals only.

Now fill in `~/.config/agent-wiki/runtime.env`:

```bash
TELEGRAM_ALERT_CHAT_ID=<the user's numeric id>
```

That is what lets the watchdog tell them when it cannot heal itself. Restart
to pick it up:

```bash
systemctl --user restart claude-telegram.service
```

**Verify, all four:**

```bash
systemctl --user is-active claude-telegram.service     # active
tmux ls                                                 # claude-agent-wiki exists
systemctl --user list-timers --all                      # four timers scheduled
```

Then message the bot from Telegram and confirm it answers. Restart the
service once, send a follow-up, and confirm the new session can use the prior
turn's brief. These are the real tests; process status alone proves neither
Telegram delivery nor conversation continuity.

## Phase 6 — Git sync

Sync is already enabled by phase 5. Confirm it works rather than assuming:

```bash
systemctl --user start agent-wiki-git-sync.service
tail ~/.local/state/agent-wiki/git-sync.log
```

A first run on a clean tree logs nothing and exits 0. Touch a file in `wiki/`
and run it again to see a commit.

⚠️ Tell the user plainly: this design assumes **one writer**. It pulls
`--ff-only` and pushes on a timer. If they also edit the vault in Obsidian on
a laptop, the two will conflict and the sync will start failing. Sort that out
before enabling it in two places.

## Phase 7 — Scheduled jobs (optional)

```bash
cd ~/agent-wiki/infra/claude-jobs
./install.sh
claude-jobs list
```

Installing schedules nothing, deliberately. Two examples ship:
`wiki-contradiction-sweep` (nightly, writes a file) and `weekly-digest`
(Sundays, sends Telegram).

For the digest, put the chat id in `~/.config/claude-jobs/runtime.env`:

```bash
echo 'DIGEST_CHAT_ID=<numeric id>' >> ~/.config/claude-jobs/runtime.env
```

Always dry-run before scheduling:

```bash
claude-jobs run wiki-contradiction-sweep --dry-run
claude-jobs install wiki-contradiction-sweep
```

**Verify:** `systemctl --user list-timers 'claude-job@*'` shows the timer with
a next-run time.

## Phase 8 — Google connectors (optional)

🧑 This one is entirely the user's, because it is an OAuth flow in a browser
and the tokens are theirs.

Tell them: open Claude in a browser, go to Settings → Connectors, and connect
Google Calendar, Gmail and Drive. Those connectors then appear as tools in
the agent's sessions.

**Verify:** ask the agent over Telegram "what's on my calendar tomorrow". If
the tools are missing it will say so.

## Phase 9 — Obsidian (optional, desktop only)

The vault is plain Markdown and needs no app. If the user wants the graph
view, on their laptop:

1. Open `~/agent-wiki` as a vault.
2. Community plugins: Dataview (query frontmatter) and Linter (formatting).
3. Attachments already point at `assets/` via `.obsidian/app.json`.
4. 🧑 Bind a hotkey to "Download attachments for current file"
   (Settings → Hotkeys, search "Download"). This cannot be scripted, and it
   is what makes clipping a web article a one-keystroke habit.

Do **not** install the obsidian-git plugin if `agent-wiki-git-sync.timer` is
running on the VPS. Two writers, one branch, guaranteed conflicts.

## Phase 10 — Final report

Tell the user:

- Which services and timers are running.
- Which optional phases were skipped, and how to come back to them.
- The three files holding secrets, none of them in git:
  `~/.claude/channels/telegram/.env`, `~/.config/agent-wiki/runtime.env`,
  `~/.config/claude-jobs/runtime.env`.
- That the first thing to do is drop a file in `raw/` and say "ingest this".

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Service starts then dies in seconds | systemd `PATH` misses `claude` or `node` | Re-run `./infra/install.sh` from a shell where `claude --version` works |
| Everything stops when the user logs out | Lingering not enabled | `sudo loginctl enable-linger "$USER"` |
| Bot silent, service active | Plugin process died inside tmux | `tmux attach -t claude-agent-wiki` and read the pane |
| Watchdog restart loop | Repeated health failure despite escalating backoff | `tail ~/.local/state/agent-wiki/watchdog/watchdog.log` |
| Git sync always defers | Hook or repository operation is stuck | Wait ten minutes for stale-marker cleanup; inspect `turn-state.log` and the lock holder |
| Sync log says lint failed | Vault broke its own schema | `python3 infra/wiki_lint.py` and fix what it names |
| Job fails instantly | Token file not mode 600, or a required var unset | `chmod 600` the token; check `REQUIRED_ENV` in the spec |
| Context never refreshes | Session never idle for 15 minutes | Expected; the 24-hour maximum will force it |

## What good looks like

```bash
systemctl --user list-timers --all
# agent-wiki-git-sync.timer        every 15 min
# agent-wiki-lint.timer            daily
# claude-telegram-refresh.timer    every 15 min
# claude-watchdog.timer            every 1 min

systemctl --user is-active claude-telegram.service   # active
python3 ~/agent-wiki/infra/wiki_lint.py              # errors=0
```

Plus a bot that answers on Telegram within a second or two.
