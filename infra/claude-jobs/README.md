# claude-jobs

A small scheduler for repeatable tasks that run a Claude session and do
something with the answer. One runner, one spec file per job, one systemd
template unit.

It is self-contained: copy this directory onto any Linux box with systemd
user services and the Claude CLI, run `./install.sh`, and it works. Nothing
in it is specific to this vault beyond the two job specs shipped with it,
which are examples to copy rather than jobs you have to keep.

## Why

Every scheduled Claude task does the same seven things: lock, preflight, call
Claude, validate, deliver, log, prune. Written as standalone shell scripts
they drift apart, and the validation step is the one that quietly gets
skipped. Here a job is a spec file and a prompt file, and the runner supplies
the other seven.

## Install

```bash
./install.sh
```

This puts the runner in `~/.local/lib/claude-jobs/`, the `claude-jobs` CLI on
your path, the template unit in `~/.config/systemd/user/`, and the shipped
specs, prompts and validators in `~/.config/claude-jobs/`.

Installing schedules nothing. A fresh clone must never start firing timers on
its own, so you turn each job on by hand:

```bash
claude-jobs list
claude-jobs run market-review --dry-run
claude-jobs install market-review
```

`claude-jobs install` reads `SCHEDULE` from the spec and generates
`claude-job@<name>.timer` from it. systemd cannot read `OnCalendar` from an
environment file, so the timer is generated rather than templated. The spec
stays the single source of truth: edit `SCHEDULE`, re-run install.

## Adding a job

1. Write the prompt in `prompts/<name>.md`.
2. Write `jobs/<name>.job`. Copy the closest existing one.
3. Optionally write `validators/<name>.sh`, executable, which reads the
   output on stdin and exits non-zero to block delivery.
4. `./install.sh`, then `claude-jobs run <name> --dry-run`.
5. Happy with it: `claude-jobs install <name>`.

## Spec keys

| Key | Meaning |
|---|---|
| `DESCRIPTION` | Human label, used in the unit description. |
| `SCHEDULE` | systemd `OnCalendar` value. Read by `claude-jobs install`. |
| `WORKING_DIR` | Directory the Claude session runs in. |
| `MODEL` / `EFFORT` | Passed to the CLI. |
| `TOOLS` | Comma-separated allowlist. Empty means no tools. |
| `DISALLOWED_TOOLS` | Explicit denylist, for read-only jobs. |
| `ADD_DIR` | Extra directories the session may read, space separated. |
| `PROMPT_FILE` / `PROMPT` | The prompt, from `prompts/` or inline. |
| `SYSTEM_PROMPT_FILE` / `SYSTEM_PROMPT` | Same, for the system prompt. |
| `PRE_COMMAND` | Runs first; its stdout replaces `{input}` in the prompt. |
| `POST_COMMAND` | Handler in `handlers/`. Reads the validated output, does job-specific writing, prints what to deliver. |
| `GUARD_PATHS` | Paths fingerprinted before and after the call. Any change fails the run. |
| `VALIDATOR` | Script in `validators/`. Non-zero exit blocks delivery. |
| `REQUIRED_ENV` | Space-separated env vars that must be set. |
| `MAX_CHARS` | Length budget. |
| `OVERLONG_POLICY` | `compress`, `fail`, or `allow`. |
| `HARD_MAX_CHARS` | Refuse to deliver above this, even after compression. |
| `DELIVERY` | `telegram`, `file`, `wiki`, or `none`. |
| `DELIVERY_TARGET` | Chat id, or a path. Paths accept `{date}` and `{stamp}`. |
| `DELIVERY_TOKEN_FILE` | Bot token file, must be mode 600. |
| `NOTIFY_ON_FAILURE` | Send a Telegram line when the job fails. Default on. |
| `KEEP_OUTPUTS` | How many past outputs to keep. |
| `ENABLED` | `0` makes the runner exit cleanly without doing anything. |

One bot token can serve every job. A job chooses its audience with
`DELIVERY_TARGET` (a chat id, a group id, or a channel id), never by using a
different bot. `DELIVERY_TOKEN_FILE` must be mode 600 or the run fails before
Claude is called.

Secrets do not belong in a spec, because specs are committed. Put host
specific values such as chat ids in `~/.config/claude-jobs/runtime.env`,
which the template unit loads and which `.gitignore` keeps out of the
repository.

## What the runner guarantees

- One instance per job. A second start while the first is running exits 0,
  not an error, so an overrun never stacks up.
- Missing binaries, an unreadable prompt, a token file that is not mode 600
  and an unset required variable all fail before Claude is called.
- Empty output is a failure.
- The validator runs before delivery, never after.
- Every job supports `--dry-run`, which does everything except deliver.
- Every run appends one line to `~/.local/state/claude-jobs/<name>/job.log`
  and keeps the last `KEEP_OUTPUTS` outputs.
- A failure notifies Telegram when the job has somewhere to notify, because
  a weekly job that quietly stopped working could go unnoticed for a month.

## Jobs shipped here

Two examples ship here. Copy the one whose shape matches what you want.

| Job | Schedule | Delivery | Shows |
|---|---|---|---|
| `wiki-contradiction-sweep` | Nightly 03:32 | Dated file | A read-only audit with a tool denylist |
| `weekly-digest` | Sundays 18:00 | Telegram | A length budget, compression, and a chat id from `runtime.env` |

Neither is scheduled by installing. Turn one on with `claude-jobs install
<name>` once its dry run looks right.

### The pattern for work Claude should not do alone

Some jobs need Claude for judgement but must not give it the keys. Three spec
keys exist for that, and they are worth knowing before you need them:

- `PRE_COMMAND` runs a script of yours first and substitutes its stdout for
  `{input}` in the prompt. Use it to hand Claude a prepared data extract
  rather than a database handle or a shell.
- `POST_COMMAND` takes the validated answer and does the writing itself, so
  the model produces text and your code decides what lands on disk.
- `GUARD_PATHS` fingerprints paths before and after the call. A session
  allowed to read the vault for context, but which changed a byte of it,
  fails instead of being trusted.

Together they let a job read sensitive local data, reason over it, and write
a result, without the model ever holding write access.

## Migrating an existing job

Do one at a time, and prove it before switching:

1. Write the spec and prompt from the old script.
2. `claude-jobs run <name> --dry-run` and compare against the old script's
   `--dry-run` output.
3. `claude-jobs install <name>`.
4. Disable the old timer: `systemctl --user disable --now <old>.timer`.
5. Delete the old script only after a full cycle has run green.

Never leave both scheduled at once. They will both deliver.
