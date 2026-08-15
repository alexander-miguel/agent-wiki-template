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
failures_before_restart="${WATCHDOG_FAILURES_BEFORE_RESTART:-2}"
restart_cooldown="${WATCHDOG_RESTART_COOLDOWN_SECONDS:-1800}"
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

telegram_api_is_healthy() {
    local token
    token=$(bot_token)
    [ -n "$token" ] || return 1
    curl --fail --silent --show-error --max-time 10 \
        "https://api.telegram.org/bot${token}/getMe" \
        | grep -q '"ok":[[:space:]]*true'
}

restart_service() {
    local reason="$1" now last_restart
    now=$(date +%s)
    last_restart=$(read_number_file "$cooldown_file")
    if (( now - last_restart < restart_cooldown )); then
        log "restart suppressed by cooldown: $reason"
        return 0
    fi
    printf '%s\n' "$now" >"$cooldown_file"
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
    elif ! pgrep -P "$claude_pid" -f 'bun run --cwd .*/telegram/.* start' >/dev/null; then
        failure_reason="Telegram plugin process is missing"
    elif ! telegram_api_is_healthy; then
        failure_reason="Telegram getMe health check failed"
    fi
fi

if [ -z "$failure_reason" ]; then
    printf '0\n' >"$failure_file"
    exit 0
fi

failure_count=$(( $(read_number_file "$failure_file") + 1 ))
printf '%s\n' "$failure_count" >"$failure_file"
log "health check failed ($failure_count/$restart_threshold): $failure_reason"
if (( failure_count >= restart_threshold )); then
    restart_service "$failure_reason"
fi
