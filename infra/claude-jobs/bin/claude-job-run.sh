#!/usr/bin/env bash
# Run one scheduled Claude job from its spec.
#
# Usage: claude-job-run.sh <name> [--dry-run]
#
# Everything specific to a job lives in its spec file, its prompt file, and
# its optional validator. This script holds the parts every job needs:
# locking, preflight checks, the Claude call, validation, delivery, logging
# and retention. Adding a job should never mean copying this file.
set -euo pipefail

umask 077

JOBS_CONFIG_DIR="${CLAUDE_JOBS_CONFIG_DIR:-$HOME/.config/claude-jobs}"
JOBS_STATE_DIR="${CLAUDE_JOBS_STATE_DIR:-$HOME/.local/state/claude-jobs}"
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
CURL_BIN="${CURL_BIN:-/usr/bin/curl}"
JQ_BIN="${JQ_BIN:-/usr/bin/jq}"
FLOCK_BIN="${FLOCK_BIN:-/usr/bin/flock}"

usage() {
    echo "Usage: $0 <job-name> [--dry-run]" >&2
    exit 2
}

[[ $# -ge 1 ]] || usage
JOB="$1"
shift
MODE="deliver"
if [[ $# -gt 0 ]]; then
    case "$1" in
        --dry-run) MODE="dry-run" ;;
        *) usage ;;
    esac
fi

# A job name becomes a filename, a lock name and a systemd instance name, so
# keep it boring. This also stops a caller reaching outside the config dir.
if [[ ! "$JOB" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "Invalid job name: $JOB (use lowercase letters, digits and hyphens)" >&2
    exit 2
fi

SPEC_FILE="$JOBS_CONFIG_DIR/$JOB.job"
if [[ ! -r "$SPEC_FILE" ]]; then
    echo "No spec for job '$JOB' at $SPEC_FILE" >&2
    exit 2
fi

JOB_STATE_DIR="$JOBS_STATE_DIR/$JOB"
OUTPUT_DIR="$JOB_STATE_DIR/outputs"
LOG_FILE="$JOB_STATE_DIR/job.log"
mkdir -p "$OUTPUT_DIR"

log() {
    printf '%s [%s] %s\n' "$(date --iso-8601=seconds)" "$JOB" "$*" >>"$LOG_FILE"
}

fail() {
    log "FAILED: $*"
    echo "$*" >&2
    notify_failure "$*"
    exit 1
}

# ---------------------------------------------------------------- spec ----

# Defaults. A spec overrides what it cares about and ignores the rest.
DESCRIPTION="$JOB"
SCHEDULE=""
WORKING_DIR="$HOME"
MODEL="opus"
EFFORT="medium"
TOOLS=""
DISALLOWED_TOOLS=""
ADD_DIR=""
SYSTEM_PROMPT=""
SYSTEM_PROMPT_FILE=""
PROMPT=""
PROMPT_FILE=""
PRE_COMMAND=""
POST_COMMAND=""
GUARD_PATHS=""
TIMEOUT="25min"
DELIVERY="file"
DELIVERY_TARGET=""
DELIVERY_TOKEN_FILE=""
VALIDATOR=""
REQUIRED_ENV=""
MAX_CHARS=""
HARD_MAX_CHARS=""
OVERLONG_POLICY="fail"
KEEP_OUTPUTS="60"
NOTIFY_ON_FAILURE="1"
FAILURE_CHAT_ID=""
FAILURE_TOKEN_FILE=""
ENABLED="1"

# Host-specific values (chat ids and the like) load first, so a spec can
# refer to them. systemd also passes these in through the unit's second
# EnvironmentFile; sourcing here is what makes a manual run behave the same
# as a scheduled one.
RUNTIME_ENV="$JOBS_CONFIG_DIR/runtime.env"
if [[ -r "$RUNTIME_ENV" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$RUNTIME_ENV"
    set +a
fi

# shellcheck disable=SC1090
source "$SPEC_FILE"

if [[ "$ENABLED" != "1" ]]; then
    log "skipped: ENABLED is not 1"
    echo "Job '$JOB' is disabled (ENABLED=$ENABLED)."
    exit 0
fi

# --------------------------------------------------------- notification ----

# Defined early so fail() can use it. A failed notification never masks the
# original error: the job has already failed and that is what matters.
notify_failure() {
    local message="$1"
    [[ "$NOTIFY_ON_FAILURE" == "1" ]] || return 0
    [[ "$MODE" == "deliver" ]] || return 0
    local chat="${FAILURE_CHAT_ID:-$DELIVERY_TARGET}"
    local token_file="${FAILURE_TOKEN_FILE:-$DELIVERY_TOKEN_FILE}"
    [[ -n "$chat" && -r "$token_file" ]] || return 0
    local token
    IFS= read -r token <"$token_file" || return 0
    [[ -n "$token" ]] || return 0
    "$CURL_BIN" --silent --show-error --max-time 30 \
        --request POST "https://api.telegram.org/bot${token}/sendMessage" \
        --data-urlencode "chat_id=$chat" \
        --data-urlencode "text=Scheduled job '$JOB' failed: $message" \
        >/dev/null 2>&1 || true
}

# ------------------------------------------------------------ preflight ----

for executable in "$CLAUDE_BIN" "$FLOCK_BIN"; do
    [[ -x "$executable" ]] || fail "required executable is missing: $executable"
done

if [[ "$DELIVERY" == "telegram" ]]; then
    for executable in "$CURL_BIN" "$JQ_BIN"; do
        [[ -x "$executable" ]] || fail "required executable is missing: $executable"
    done
fi

[[ -d "$WORKING_DIR" ]] || fail "working directory not found: $WORKING_DIR"

for name in $REQUIRED_ENV; do
    [[ -n "${!name:-}" ]] || fail "required environment variable is unset: $name"
done

resolve_prompt() {
    local literal="$1" file="$2" label="$3"
    if [[ -n "$file" ]]; then
        local path="$file"
        [[ "$path" == /* ]] || path="$JOBS_CONFIG_DIR/prompts/$path"
        [[ -r "$path" ]] || fail "$label file not readable: $path"
        cat "$path"
        return
    fi
    printf '%s' "$literal"
}

prompt_text="$(resolve_prompt "$PROMPT" "$PROMPT_FILE" "prompt")"
[[ -n "${prompt_text//[[:space:]]/}" ]] || fail "prompt is empty"

# A job that needs local data in its prompt runs its own extractor here and
# the runner substitutes the output for {input}. This keeps data gathering
# out of Claude's hands: it reads what the job already fetched rather than
# being given a tool to fetch it.
if [[ -n "$PRE_COMMAND" ]]; then
    if ! pre_output="$( cd "$WORKING_DIR" && eval "$PRE_COMMAND" )"; then
        fail "PRE_COMMAND failed: $PRE_COMMAND"
    fi
    [[ -n "${pre_output//[[:space:]]/}" ]] || fail "PRE_COMMAND produced no output"
    if [[ "$prompt_text" != *"{input}"* ]]; then
        fail "PRE_COMMAND is set but the prompt has no {input} placeholder"
    fi
    prompt_text="${prompt_text//\{input\}/$pre_output}"
fi
system_prompt_text="$(resolve_prompt "$SYSTEM_PROMPT" "$SYSTEM_PROMPT_FILE" "system prompt")"

validator_path=""
if [[ -n "$VALIDATOR" ]]; then
    validator_path="$VALIDATOR"
    [[ "$validator_path" == /* ]] || validator_path="$JOBS_CONFIG_DIR/validators/$validator_path"
    [[ -x "$validator_path" ]] || fail "validator is not executable: $validator_path"
fi

# Delivery preflight only matters when this run will actually deliver. A dry
# run on a machine with no chat id or token still has to be possible, which
# is the whole point of a dry run.
if [[ "$MODE" == "deliver" ]]; then
    if [[ "$DELIVERY" == "telegram" ]]; then
        [[ -n "$DELIVERY_TARGET" ]] || fail "DELIVERY=telegram needs DELIVERY_TARGET (a chat id)"
        [[ -r "$DELIVERY_TOKEN_FILE" ]] || fail "token file is missing or unreadable: $DELIVERY_TOKEN_FILE"
        [[ "$(stat -c %a "$DELIVERY_TOKEN_FILE")" == "600" ]] \
            || fail "token file must have mode 600: $DELIVERY_TOKEN_FILE"
    fi

    if [[ "$DELIVERY" == "file" || "$DELIVERY" == "wiki" ]]; then
        [[ -n "$DELIVERY_TARGET" ]] || fail "DELIVERY=$DELIVERY needs DELIVERY_TARGET (a path)"
    fi
fi

# ----------------------------------------------------------------- lock ----

LOCK_FILE="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/claude-job-$JOB.lock"
exec 9>"$LOCK_FILE"
if ! "$FLOCK_BIN" --nonblock 9; then
    log "skipped: already running"
    echo "Job '$JOB' is already running." >&2
    exit 0
fi

# ----------------------------------------------------------------- run ----

run_claude() {
    local prompt="$1"
    local -a args=(
        --print
        --model "$MODEL"
        --effort "$EFFORT"
        --permission-mode dontAsk
        --safe-mode
        --no-session-persistence
    )
    # Only pass the tool flags when there is a value. `--tools ""` makes the
    # CLI swallow the next argument, which silently eats the prompt and the
    # run dies with "Input must be provided". A job with no tools simply
    # says nothing about tools.
    if [[ -n "$TOOLS" ]]; then
        args+=(--tools "$TOOLS" --allowedTools "$TOOLS")
    fi
    # A read-only job names what it must never reach for, so a prompt change
    # cannot quietly hand it write or network access.
    if [[ -n "$DISALLOWED_TOOLS" ]]; then
        args+=(--disallowedTools "$DISALLOWED_TOOLS")
    fi
    local dir
    for dir in $ADD_DIR; do
        args+=(--add-dir "$dir")
    done
    if [[ -n "${system_prompt_text//[[:space:]]/}" ]]; then
        args+=(--system-prompt "$system_prompt_text")
    fi
    # stdin closed: an unattended job has nothing to type, and leaving it
    # open costs a three-second wait on every call.
    ( cd "$WORKING_DIR" && "$CLAUDE_BIN" "${args[@]}" "$prompt" </dev/null )
}

# A read-only job can name paths it must not change. They are fingerprinted
# before the call and checked after, so a prompt that talks the session into
# editing something is caught rather than trusted.
fingerprint_guarded() {
    local path
    for path in $GUARD_PATHS; do
        if [[ -e "$path" ]]; then
            find "$path" -type f -exec sha256sum {} + 2>/dev/null | sort
        else
            echo "absent $path"
        fi
    done | sha256sum
}

started_at="$(date +%s)"
log "starting model=$MODEL effort=$EFFORT mode=$MODE tools=${TOOLS:-none}"

guard_before=""
if [[ -n "$GUARD_PATHS" ]]; then
    guard_before="$(fingerprint_guarded)"
fi

output="$(run_claude "$prompt_text")" || fail "claude exited non-zero"

if [[ -n "$GUARD_PATHS" ]]; then
    if [[ "$guard_before" != "$(fingerprint_guarded)" ]]; then
        fail "guarded paths changed during the run: $GUARD_PATHS"
    fi
    log "guarded paths unchanged"
fi

[[ -n "${output//[[:space:]]/}" ]] || fail "claude returned empty output"

# Length policy. `compress` asks Claude to edit its own answer down without
# changing any fact; `fail` refuses to deliver something over budget.
if [[ -n "$MAX_CHARS" && "${#output}" -gt "$MAX_CHARS" ]]; then
    case "$OVERLONG_POLICY" in
        compress)
            log "output is ${#output} chars, over $MAX_CHARS: compressing"
            compression_prompt="$(printf '%s\n\nORIGINAL:\n%s' \
                "Edit the text below to at most $MAX_CHARS characters. Return only the edited text. Preserve every heading, label, link, number, date, factual claim and any exact required closing line. Do not add or change facts. Remove redundancy and compress prose." \
                "$output")"
            TOOLS_SAVED="$TOOLS"
            TOOLS=""
            compressed="$(run_claude "$compression_prompt")" || fail "compression pass exited non-zero"
            TOOLS="$TOOLS_SAVED"
            [[ -n "${compressed//[[:space:]]/}" ]] || fail "compression pass returned empty output"
            output="$compressed"
            ;;
        fail)
            fail "output is ${#output} chars, over the $MAX_CHARS limit"
            ;;
        allow) : ;;
        *) fail "unknown OVERLONG_POLICY: $OVERLONG_POLICY" ;;
    esac
fi

if [[ -n "$HARD_MAX_CHARS" && "${#output}" -gt "$HARD_MAX_CHARS" ]]; then
    fail "output is ${#output} chars after the length policy, over the hard cap of $HARD_MAX_CHARS"
fi

# ------------------------------------------------------------ validate ----

if [[ -n "$validator_path" ]]; then
    if ! printf '%s' "$output" | "$validator_path"; then
        fail "validator rejected the output: $validator_path"
    fi
    log "validator passed"
fi

# ---------------------------------------------------------------- post ----

# A job whose answer is not simply one blob to deliver puts that logic in a
# handler: it reads the validated output on stdin, does the job-specific
# writing, and prints what should actually be delivered. CLAUDE_JOB_DRY_RUN
# tells it to compute without writing.
if [[ -n "$POST_COMMAND" ]]; then
    post_path="$POST_COMMAND"
    [[ "$post_path" == /* ]] || post_path="$JOBS_CONFIG_DIR/handlers/$post_path"
    [[ -x "$post_path" ]] || fail "post command is not executable: $post_path"
    dry_flag=0
    [[ "$MODE" == "dry-run" ]] && dry_flag=1
    if ! post_output="$(printf '%s' "$output" \
        | CLAUDE_JOB_DRY_RUN="$dry_flag" CLAUDE_JOB_NAME="$JOB" "$post_path")"; then
        fail "post command failed: $post_path"
    fi
    [[ -n "${post_output//[[:space:]]/}" ]] || fail "post command produced no output to deliver"
    output="$post_output"
    log "post command done: $post_path"
fi

# ------------------------------------------------------------- persist ----

stamp="$(date +%Y%m%dT%H%M%S)"
output_file="$OUTPUT_DIR/$stamp.txt"
printf '%s\n' "$output" >"$output_file"

if [[ "$KEEP_OUTPUTS" =~ ^[0-9]+$ && "$KEEP_OUTPUTS" -gt 0 ]]; then
    mapfile -t stale < <(ls -1 "$OUTPUT_DIR" | sort -r | tail -n +$((KEEP_OUTPUTS + 1)))
    for old in "${stale[@]}"; do
        [[ -n "$old" ]] && rm -f -- "$OUTPUT_DIR/$old"
    done
fi

# ------------------------------------------------------------- deliver ----

deliver_telegram() {
    local token response message_id
    IFS= read -r token <"$DELIVERY_TOKEN_FILE"
    [[ -n "$token" ]] || fail "token file is empty: $DELIVERY_TOKEN_FILE"
    response="$("$CURL_BIN" --silent --show-error --fail-with-body --max-time 60 \
        --request POST "https://api.telegram.org/bot${token}/sendMessage" \
        --data-urlencode "chat_id=$DELIVERY_TARGET" \
        --data-urlencode "text=$output")" || fail "telegram delivery failed"
    message_id="$(printf '%s' "$response" | "$JQ_BIN" -er '.result.message_id')" \
        || fail "telegram returned no message id"
    echo "Delivered to Telegram chat $DELIVERY_TARGET: message_id=$message_id"
}

deliver_file() {
    local target="$DELIVERY_TARGET"
    # A target containing a date placeholder becomes a dated file.
    target="${target//\{date\}/$(date +%F)}"
    target="${target//\{stamp\}/$stamp}"
    mkdir -p "$(dirname "$target")"
    printf '%s\n' "$output" >"$target"
    echo "Wrote $target"
}

case "$MODE" in
    dry-run)
        printf '%s\n' "$output"
        log "dry run complete, ${#output} chars, nothing delivered"
        exit 0
        ;;
    deliver)
        case "$DELIVERY" in
            telegram) deliver_telegram ;;
            file|wiki) deliver_file ;;
            none) echo "No delivery configured; output kept at $output_file" ;;
            *) fail "unknown DELIVERY: $DELIVERY" ;;
        esac
        ;;
esac

elapsed=$(( $(date +%s) - started_at ))
log "delivered chars=${#output} seconds=$elapsed via=$DELIVERY"
echo "Job '$JOB' finished in ${elapsed}s (${#output} chars)."
