#!/usr/bin/env bash
# Host-local liveness checks for the Claude process and Telegram channel.
set -euo pipefail

session="${CLAUDE_TMUX_SESSION:-claude-agent-wiki}"
telegram_env="${TELEGRAM_ENV_FILE:-$HOME/.claude/channels/telegram/.env}"
alert_chat_id="${TELEGRAM_ALERT_CHAT_ID:-}"
state_dir="${CLAUDE_WATCHDOG_STATE_DIR:-$HOME/.local/state/agent-wiki/watchdog}"
log_file="$state_dir/watchdog.log"
failure_file="$state_dir/consecutive-failures"
cooldown_file="$state_dir/last-restart"
backoff_file="$state_dir/restart-backoff"
failures_before_restart="${WATCHDOG_FAILURES_BEFORE_RESTART:-2}"
initial_backoff="${WATCHDOG_INITIAL_BACKOFF_SECONDS:-300}"
maximum_backoff="${WATCHDOG_MAX_BACKOFF_SECONDS:-1800}"
backoff_reset_age="${WATCHDOG_BACKOFF_RESET_SECONDS:-3600}"
turn_state_dir="${AGENT_WIKI_STATE_DIR:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/agent-wiki}"
busy_file="$turn_state_dir/busy"
busy_max_age="${AGENT_WIKI_BUSY_MAX_AGE_SECONDS:-600}"
mkdir -p "$state_dir"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$log_file"; }

bot_token() {
    sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$telegram_env" | head -n 1
}

send_telegram() {
    local message="$1" token
    [ -n "$alert_chat_id" ] || return 0
    token=$(bot_token)
    if [ -z "$token" ]; then
        log "no bot token found; cannot alert"
        return 0
    fi
    curl --fail --silent --show-error --max-time 10 \
        -X POST "https://api.telegram.org/bot${token}/sendMessage" \
        -d "chat_id=${alert_chat_id}" --data-urlencode "text=${message}" \
        >/dev/null || log "Telegram alert send failed"
}

read_number_file() {
    local value=0
    [ -f "$1" ] && value=$(<"$1")
    [[ "$value" =~ ^[0-9]+$ ]] && printf '%s' "$value" || printf '0'
}

process_is_healthy() {
    local state
    [ -n "$1" ] && kill -0 "$1" 2>/dev/null || return 1
    state=$(ps -o stat= -p "$1" 2>/dev/null || true)
    [ -n "$state" ] && [[ "$state" != *Z* ]]
}

parent_pid() {
    local stat rest
    [ -r "/proc/$1/stat" ] || return 1
    IFS= read -r stat <"/proc/$1/stat" || return 1
    rest=${stat##*) }
    set -- $rest
    [[ "${2:-}" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$2"
}

is_descendant_of() {
    local current="$1" ancestor="$2" parent hops
    for ((hops = 0; hops < 12; hops++)); do
        [ "$current" = "$ancestor" ] && return 0
        parent=$(parent_pid "$current") || return 1
        [ "$parent" -gt 1 ] 2>/dev/null || return 1
        [ "$parent" != "$current" ] || return 1
        current="$parent"
    done
    return 1
}

telegram_process_is_candidate() {
    local pid="$1" cwd arg
    local -a argv=()
    [ -r "/proc/$pid/cmdline" ] || return 1
    mapfile -d '' -t argv <"/proc/$pid/cmdline"
    [ "${argv[0]##*/}" = "bun" ] || return 1

    # The launcher wrapper has an explicit Telegram working directory.
    if [ "${argv[1]:-}" = "run" ]; then
        for ((arg = 2; arg + 1 < ${#argv[@]}; arg++)); do
            if [ "${argv[$arg]}" = "--cwd" ] &&
                [[ "${argv[$((arg + 1))]}" == */telegram/* ]] &&
                [ "${argv[-1]}" = "start" ]; then
                return 0
            fi
        done
    fi

    # If the wrapper is killed first, Bun's server.ts child survives under PID
    # 1 with no Telegram path in argv. Its process cwd still identifies it.
    if [ "${argv[1]:-}" = "server.ts" ]; then
        cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)
        [[ "$cwd" == */telegram/* ]] && return 0
    fi
    return 1
}

terminate_telegram_process() {
    local pid="$1" attempt
    kill "$pid" 2>/dev/null || return 1
    for ((attempt = 0; attempt < 10; attempt++)); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.1
    done
    kill -KILL "$pid" 2>/dev/null || return 1
}

# Print the number of live Telegram processes under Claude, and terminate any
# matching process left behind by an older session.
telegram_poller_count() {
    local claude_pid="$1" pid count=0
    while IFS= read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        telegram_process_is_candidate "$pid" || continue
        if is_descendant_of "$pid" "$claude_pid"; then
            count=$((count + 1))
        elif kill -0 "$pid" 2>/dev/null; then
            if terminate_telegram_process "$pid"; then
                log "reaped orphaned Telegram process pid=$pid"
            fi
        fi
    done < <(pgrep -x bun || true)
    printf '%s\n' "$count"
}

telegram_api_is_healthy() {
    local token
    token=$(bot_token)
    [ -n "$token" ] || return 1
    curl --fail --silent --show-error --max-time 10 \
        "https://api.telegram.org/bot${token}/getMe" \
        | grep -q '"ok":[[:space:]]*true'
}

telegram_pending_updates() {
    local token response
    token=$(bot_token)
    [ -n "$token" ] || return 1
    response=$(curl --fail --silent --show-error --max-time 10 \
        "https://api.telegram.org/bot${token}/getWebhookInfo") || return 1
    jq -er \
        'if .ok == true and (.result.pending_update_count | type == "number") then .result.pending_update_count else error("invalid response") end' \
        <<<"$response"
}

busy_marker_is_fresh() {
    local now modified age
    [ -f "$busy_file" ] || return 1
    now=$(date +%s)
    modified=$(stat -c %Y "$busy_file" 2>/dev/null || printf '0')
    [[ "$modified" =~ ^[0-9]+$ ]] || modified=0
    age=$((now - modified))
    if (( age >= 0 && age < busy_max_age )); then
        return 0
    fi
    rm -f "$busy_file"
    return 1
}

reset_backoff_if_stable() {
    local now last_restart
    now=$(date +%s)
    last_restart=$(read_number_file "$cooldown_file")
    if (( last_restart > 0 && now - last_restart >= backoff_reset_age )); then
        rm -f "$cooldown_file"
        printf '%s\n' "$initial_backoff" >"$backoff_file"
    fi
}

restart_service() {
    local reason="$1" now last_restart backoff next_backoff remaining
    if [ "$reason" != "service is not active" ] && busy_marker_is_fresh; then
        log "restart deferred: Claude turn is active ($reason)"
        return 0
    fi

    now=$(date +%s)
    last_restart=$(read_number_file "$cooldown_file")
    backoff=$(read_number_file "$backoff_file")
    (( backoff >= initial_backoff && backoff <= maximum_backoff )) || backoff="$initial_backoff"
    if (( last_restart > 0 && now - last_restart < backoff )); then
        remaining=$((backoff - (now - last_restart)))
        log "restart suppressed by ${backoff}s backoff (${remaining}s remaining): $reason"
        return 0
    fi

    if (( last_restart == 0 || now - last_restart >= backoff_reset_age )); then
        next_backoff="$initial_backoff"
    else
        next_backoff=$((backoff * 2))
        (( next_backoff <= maximum_backoff )) || next_backoff="$maximum_backoff"
    fi
    printf '%s\n' "$now" >"$cooldown_file"
    printf '%s\n' "$next_backoff" >"$backoff_file"
    log "$reason; attempting restart"
    if systemctl --user restart claude-telegram.service; then
        sleep 5
        if systemctl --user is-active --quiet claude-telegram.service; then
            printf '0\n' >"$failure_file"
            log "restart succeeded"
            send_telegram "Agent watchdog restarted the Telegram session after failed health checks."
            return 0
        fi
    fi
    log "restart did not restore the service"
    send_telegram "Agent watchdog could not restore the Telegram session; manual attention is required."
    return 1
}

failure_reason=""
restart_threshold="$failures_before_restart"
if ! systemctl --user is-active --quiet claude-telegram.service; then
    failure_reason="service is not active"
    restart_threshold=1
elif ! tmux has-session -t "$session" 2>/dev/null; then
    failure_reason="tmux session is missing"
else
    claude_pid=$(tmux display-message -p -t "$session" '#{pane_pid}' 2>/dev/null || true)
    if ! process_is_healthy "$claude_pid"; then
        failure_reason="Claude process is missing or unhealthy"
    else
        poller_count=$(telegram_poller_count "$claude_pid")
        if (( poller_count == 0 )); then
            failure_reason="Telegram plugin process is missing"
        elif ! telegram_api_is_healthy; then
            failure_reason="Telegram getMe health check failed"
        elif ! pending_updates=$(telegram_pending_updates); then
            failure_reason="Telegram getWebhookInfo health check failed"
        elif (( pending_updates > 0 )); then
            failure_reason="Telegram has ${pending_updates} pending update(s)"
        fi
    fi
fi

if [ -z "$failure_reason" ]; then
    printf '0\n' >"$failure_file"
    reset_backoff_if_stable
    exit 0
fi

failure_count=$(( $(read_number_file "$failure_file") + 1 ))
printf '%s\n' "$failure_count" >"$failure_file"
log "health check failed ($failure_count/$restart_threshold): $failure_reason"
if (( failure_count >= restart_threshold )); then
    restart_service "$failure_reason"
fi
