#!/usr/bin/env bash
# Reusable startup progress renderer for local-agents.
#
# Source this file from a launcher, then call:
#
#   la_progress_init
#   la_progress_stage "Starting server"
#   la_progress_tick "Starting server"
#   la_progress_success "Server ready"
#
# TTY output updates in place with an animated spinner. Redirected output and
# tests receive timestamped lines without terminal control sequences.

_LA_PROGRESS_START=0
_LA_PROGRESS_LAST_LINE=-1
_LA_PROGRESS_REASSURED=0
_LA_PROGRESS_LABEL=""

la_progress_mode() {
    case "${LA_PROGRESS_MODE:-auto}" in
        tty)
            printf '%s' tty
            ;;
        line)
            printf '%s' line
            ;;
        auto)
            if [ -t 2 ]; then
                printf '%s' tty
            else
                printf '%s' line
            fi
            ;;
        *)
            printf '%s\n' \
                "ERROR: LA_PROGRESS_MODE must be auto, tty, or line" >&2
            return 2
            ;;
    esac
}

la_progress_init() {
    _LA_PROGRESS_START=$SECONDS
    _LA_PROGRESS_LAST_LINE=-1
    _LA_PROGRESS_REASSURED=0
    _LA_PROGRESS_LABEL=""
}

la_progress_elapsed_seconds() {
    printf '%s' "$((SECONDS - _LA_PROGRESS_START))"
}

la_progress_elapsed() {
    local elapsed minutes seconds

    elapsed="$(la_progress_elapsed_seconds)"
    minutes=$((elapsed / 60))
    seconds=$((elapsed % 60))

    printf '%02d:%02d' "$minutes" "$seconds"
}

la_progress_frame() {
    local elapsed index

    elapsed="$(la_progress_elapsed_seconds)"
    index=$((elapsed % 10))

    case "$index" in
        0) printf '%s' "⠋" ;;
        1) printf '%s' "⠙" ;;
        2) printf '%s' "⠹" ;;
        3) printf '%s' "⠸" ;;
        4) printf '%s' "⠼" ;;
        5) printf '%s' "⠴" ;;
        6) printf '%s' "⠦" ;;
        7) printf '%s' "⠧" ;;
        8) printf '%s' "⠇" ;;
        *) printf '%s' "⠏" ;;
    esac
}

la_progress_stage() {
    local label="$1"
    local mode

    mode="$(la_progress_mode)" || return

    _LA_PROGRESS_LABEL="$label"
    _LA_PROGRESS_REASSURED=0

    if [ "$mode" = tty ]; then
        printf '\r\033[K%s [%s] %s' \
            "$(la_progress_frame)" \
            "$(la_progress_elapsed)" \
            "$label" >&2
    else
        printf '[%s] %s\n' \
            "$(la_progress_elapsed)" \
            "$label" >&2
        _LA_PROGRESS_LAST_LINE=$SECONDS
    fi
}

la_progress_reassure_if_needed() {
    local mode elapsed

    mode="$(la_progress_mode)" || return
    elapsed="$(la_progress_elapsed_seconds)"

    if [ "$elapsed" -lt 60 ] ||
       [ "$_LA_PROGRESS_REASSURED" = 1 ]
    then
        return 0
    fi

    if [ "$mode" = tty ]; then
        printf '\r\033[K\n' >&2
    fi

    printf '%s\n' \
        "Still working — a first genuine classifier prefill can take several minutes." \
        "Future launches can reuse its verified private fixture and persistent cache." >&2

    _LA_PROGRESS_REASSURED=1

    if [ "$mode" = tty ] && [ -n "$_LA_PROGRESS_LABEL" ]; then
        printf '%s [%s] %s' \
            "$(la_progress_frame)" \
            "$(la_progress_elapsed)" \
            "$_LA_PROGRESS_LABEL" >&2
    fi
}

la_progress_tick() {
    local label="${1:-$_LA_PROGRESS_LABEL}"
    local mode interval

    mode="$(la_progress_mode)" || return
    interval="${LA_OMLX_PREWARM_PROGRESS_INTERVAL_S:-15}"

    case "$interval" in
        ''|*[!0-9]*)
            printf '%s\n' \
                "ERROR: LA_OMLX_PREWARM_PROGRESS_INTERVAL_S must be an integer" >&2
            return 2
            ;;
    esac

    if [ "$mode" = tty ]; then
        printf '\r\033[K%s [%s] %s' \
            "$(la_progress_frame)" \
            "$(la_progress_elapsed)" \
            "$label" >&2
    elif [ "$_LA_PROGRESS_LAST_LINE" -lt 0 ] ||
         [ $((SECONDS - _LA_PROGRESS_LAST_LINE)) -ge "$interval" ]
    then
        printf '[%s] Still working: %s\n' \
            "$(la_progress_elapsed)" \
            "$label" >&2
        _LA_PROGRESS_LAST_LINE=$SECONDS
    fi

    la_progress_reassure_if_needed
}

la_progress_finish_line() {
    local symbol="$1"
    local label="$2"
    local mode

    mode="$(la_progress_mode)" || return

    if [ "$mode" = tty ]; then
        printf '\r\033[K' >&2
    fi

    printf '%s [%s] %s\n' \
        "$symbol" \
        "$(la_progress_elapsed)" \
        "$label" >&2
}

la_progress_success() {
    la_progress_finish_line "✓" "$1"
}

la_progress_failure() {
    la_progress_finish_line "✗" "$1"
}

la_progress_wait_pid() {
    local pid="$1"
    local label="$2"
    local state

    while kill -0 "$pid" 2>/dev/null; do
        state="$(ps -o state= -p "$pid" 2>/dev/null || true)"

        case "$state" in
            *Z*)
                break
                ;;
        esac

        la_progress_tick "$label"
        sleep 1
    done
}

la_progress_run() {
    local label="$1"
    local stdout_file="$2"
    local stderr_file="$3"
    local pid status
    shift 3

    la_progress_stage "$label"

    "$@" >"$stdout_file" 2>"$stderr_file" &
    pid=$!

    la_progress_wait_pid "$pid" "$label"

    if wait "$pid"; then
        la_progress_success "$label"
        return 0
    else
        status=$?
        la_progress_failure "$label"
        return "$status"
    fi
}

la_progress_self_test() {
    local mode="$1"
    local test_root

    LA_PROGRESS_MODE="$mode"
    LA_OMLX_PREWARM_PROGRESS_INTERVAL_S=1

    la_progress_init
    la_progress_stage "Starting isolated oMLX server"

    _LA_PROGRESS_LAST_LINE=$((SECONDS - 2))
    la_progress_tick "Discovering session and classifier models"

    la_progress_success "Progress renderer ready"

    test_root="$(
        mktemp -d "${TMPDIR:-/tmp}/la-progress-self-test.XXXXXX"
    )"
    test_root="$(cd -P "$test_root" && /bin/pwd -P)"

    la_progress_run \
        "Testing bounded process progress" \
        "$test_root/stdout" \
        "$test_root/stderr" \
        /usr/bin/true

    rm -rf "$test_root"
}

la_progress_reassurance_self_test() {
    LA_PROGRESS_MODE=line
    LA_OMLX_PREWARM_PROGRESS_INTERVAL_S=1

    la_progress_init
    _LA_PROGRESS_START=$((SECONDS - 65))
    _LA_PROGRESS_LAST_LINE=$((SECONDS - 2))
    la_progress_stage "Completing detached classifier prefill"

    # la_progress_stage resets the most recent line timestamp but deliberately
    # does not reset the global elapsed timer.
    _LA_PROGRESS_LAST_LINE=$((SECONDS - 2))
    la_progress_tick "Completing detached classifier prefill"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        --self-test-line)
            la_progress_self_test line
            ;;
        --self-test-tty)
            la_progress_self_test tty
            ;;
        --self-test-reassurance)
            la_progress_reassurance_self_test
            ;;
        *)
            printf '%s\n' \
                "Usage: $0 --self-test-line|--self-test-tty|--self-test-reassurance" >&2
            exit 2
            ;;
    esac
fi
