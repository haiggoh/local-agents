#!/bin/bash
# la-evict.sh — eviction fallback for local model servers.
#
# WHY THIS EXISTS
# When too many model servers are resident, the Mac runs out of RAM, and the failure
# mode is not a clean error: Terminal.app and even the Force Quit window stop
# responding, so there is no way left to type a kill command. The only remaining exit
# is a hardware reboot — and with FileVault on, a reboot ends any remote session for
# good, because the pre-boot unlock screen cannot be reached remotely.
#
# So this script has one job: free the most memory it can while touching the fewest
# things, from a single non-interactive invocation that needs no terminal.
#
# IT EVICTS ONE SERVER, NOT ALL OF THEM.
# Killing everything is the blunt version and throws away work that was fine. Instead
# the servers are ranked and only the top candidate is evicted, giving the others room
# to recover. If that was not enough, invoke it again: each invocation inside the
# escalation window advances one place down the ranking, and past the end of the list
# it evicts everything remaining.
#
# DELIBERATELY STANDALONE
# It does not source config-lib.sh and does not consult the model registry. A fallback
# that runs when the stack is already sick must not depend on the stack. Ports and
# thresholds come from the environment with defaults, and servers are discovered from
# the live process table — which is also why it survives a backend change (Rapid-MLX,
# vllm-mlx, mlx_lm.server and llama.cpp are all recognised, and an unfamiliar listener
# is reported rather than silently ignored).
#
# Usage: la-evict.sh [--status] [--dry-run] [--tier N] [--all] [--reset] [--allow-unknown]

set -u

PORT_START="${LA_PORT_START:-8000}"
PORT_MAX="${LA_PORT_MAX:-8010}"
EXTRA_PORTS="${LA_EVICT_EXTRA_PORTS:-8080}"
STATE_FILE="${LA_EVICT_STATE:-$HOME/.claude/logs/la-evict.state}"
LOG_DIR="${LA_EVICT_LOG_DIR:-$HOME/.claude/logs}"
WINDOW_S="${LA_EVICT_WINDOW:-600}"      # repeat inside this window escalates
YOUNG_S="${LA_EVICT_YOUNG:-120}"        # "just launched" — prime suspect
TERM_WAIT="${LA_EVICT_TERM_WAIT:-8}"    # seconds to wait for SIGTERM before SIGKILL

DRY_RUN=0; STATUS_ONLY=0; FORCE_TIER=""; KILL_ALL=0; ALLOW_UNKNOWN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --status)        STATUS_ONLY=1 ;;
        --dry-run|-n)    DRY_RUN=1 ;;
        --tier)          shift; FORCE_TIER="${1:-}" ;;
        --all)           KILL_ALL=1 ;;
        --allow-unknown) ALLOW_UNKNOWN=1 ;;
        --reset)         rm -f "$STATE_FILE"; echo "escalation state cleared"; exit 0 ;;
        -h|--help)       sed -n '2,28p' "$0"; exit 0 ;;
        *)               echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true

# --- which ports are backing a live Claude Code session -----------------------
# A server with a session attached is the expensive one to evict, so it ranks last.
# ANTHROPIC_BASE_URL in the session's own environment is the authoritative signal
# (ps -Eww exposes it for same-user processes); the port named in the injected system
# prompt is a second, weaker signal kept as a fallback.
attached_ports() {
    for cpid in $(pgrep -x claude 2>/dev/null); do
        ps -Eww -p "$cpid" 2>/dev/null | tr ' ' '\n' \
            | sed -n \
                -e 's|^ANTHROPIC_BASE_URL=http://localhost:\([0-9]*\).*|\1|p' \
                -e 's|^ANTHROPIC_BASE_URL=http://127\.0\.0\.1:\([0-9]*\).*|\1|p'
        ps -o command= -p "$cpid" 2>/dev/null \
            | sed -n 's/.*served by a local server process on port \([0-9]*\).*/\1/p'
    done | sort -u
}

ATTACHED="$(attached_ports | tr '\n' ' ')"
is_attached() { case " $ATTACHED " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# --- elapsed "[[DD-]HH:]MM:SS" -> seconds -------------------------------------
etime_to_s() {
    awk -v e="$1" 'BEGIN{
        d=0; n=split(e,a,"-"); if(n==2){d=a[1]; e=a[2]}
        m=split(e,b,":")
        if(m==3){print d*86400+b[1]*3600+b[2]*60+b[3]}
        else if(m==2){print d*86400+b[1]*60+b[2]}
        else{print 0}
    }'
}

# --- restart-loop heuristic ---------------------------------------------------
# Best-effort and never decisive on its own: a server that is both very young and has
# several startup banners in its recent log is almost certainly cycling rather than
# serving. Log naming has changed before, so every candidate log for the port is read
# and a missing log simply scores zero.
loop_score() {
    port="$1"; age="$2"
    [ "$age" -gt "$YOUNG_S" ] && { echo 0; return; }
    starts=0
    for lf in "$LOG_DIR"/*_"$port".log "$LOG_DIR"/*"$port"*.log; do
        [ -f "$lf" ] || continue
        n=$(tail -n 400 "$lf" 2>/dev/null | grep -c -i -E "uvicorn running|application startup|loading model|started server|Traceback|out of memory" 2>/dev/null)
        [ "$n" -gt "$starts" ] && starts="$n"
    done
    [ "$starts" -ge 3 ] && echo 2 && return
    [ "$starts" -ge 1 ] && echo 1 && return
    echo 0
}

# --- discover the servers -----------------------------------------------------
ROWS="$(mktemp -t laevict)"; trap 'rm -f "$ROWS"' EXIT

for port in $(seq "$PORT_START" "$PORT_MAX") $EXTRA_PORTS; do
    pid=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -1)
    [ -n "${pid:-}" ] || continue
    [ "$pid" -gt 1 ] 2>/dev/null || continue

    cmd=$(ps -o command= -p "$pid" 2>/dev/null)
    [ -n "$cmd" ] || continue
    rss_kb=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "${rss_kb:-}" ] || rss_kb=0
    age=$(etime_to_s "$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')")

    case "$cmd" in
        *rapid-mlx*)      backend=rapid-mlx ;;
        *vllm-mlx*)       backend=vllm-mlx ;;
        *mlx_lm.server*)  backend=mlx-lm ;;
        *llama-server*)   backend=llama.cpp ;;
        *)                backend=unknown ;;
    esac

    # Never a candidate: a Claude Code process is a client, not a server.
    case "$cmd" in *"claude --model"*|claude) continue ;; esac

    if is_attached "$port"; then att=yes; else att=no; fi
    loop=$(loop_score "$port" "$age")

    # Rank key, lowest first. Unattached before attached; within that, cycling before
    # young before merely large. Age and size are negated so "newest" and "biggest"
    # sort first.
    if [ "$att" = no ]; then band=0; else band=5; fi
    if [ "$loop" -ge 2 ]; then band=$((band+0)); elif [ "$age" -le "$YOUNG_S" ]; then band=$((band+1)); else band=$((band+2)); fi

    printf '%d|%012d|%012d|%s|%s|%s|%s|%s\n' \
        "$band" "$age" "$((99999999 - rss_kb/1024))" "$port" "$pid" "$backend" "$att" "$loop" >> "$ROWS"
done

if [ ! -s "$ROWS" ]; then
    echo "No local model servers are listening on ${PORT_START}-${PORT_MAX} ${EXTRA_PORTS}."
    echo "RESULT: nothing to evict — no model server is running."
    exit 0
fi

RANKED="$(sort -t'|' -k1,1n -k2,2n -k3,3n "$ROWS")"
COUNT=$(printf '%s\n' "$RANKED" | wc -l | tr -d ' ')

human_gb() { awk -v k="$1" 'BEGIN{printf "%.1fGB", k/1048576}'; }

show_table() {
    printf '%-6s %-7s %-11s %-9s %-9s %-8s %s\n' PORT PID BACKEND RSS AGE ATTACHED SUSPECT
    printf '%s\n' "$RANKED" | while IFS='|' read -r _ age _ port pid backend att loop; do
        age=$((10#$age))   # stored zero-padded for sorting; display unpadded
        rss_kb=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' '); [ -n "${rss_kb:-}" ] || rss_kb=0
        case "$loop" in 2) s="cycling" ;; 1) s="log-noise" ;; *) s="-" ;; esac
        [ "$age" -le "$YOUNG_S" ] && [ "$s" = "-" ] && s="just-launched"
        printf '%-6s %-7s %-11s %-9s %-9s %-8s %s\n' \
            ":$port" "$pid" "$backend" "$(human_gb "$rss_kb")" "${age}s" "$att" "$s"
    done
}

echo "=== local model servers (eviction order, top first) ==="
show_table
echo
free_mb=$(vm_stat 2>/dev/null | awk '/Pages free/{gsub(/\./,"",$3); printf "%d", $3*16384/1048576}')
echo "Free RAM now: ${free_mb:-?}MB"

if [ "$STATUS_ONLY" = 1 ]; then
    echo "RESULT: status only — ${COUNT} server(s) up, nothing evicted."
    exit 0
fi

# --- escalation tier ----------------------------------------------------------
now=$(date +%s)
tier=1
if [ -n "$FORCE_TIER" ]; then
    tier="$FORCE_TIER"
elif [ -f "$STATE_FILE" ]; then
    last_epoch=$(awk 'END{print $1}' "$STATE_FILE" 2>/dev/null)
    last_tier=$(awk 'END{print $2}' "$STATE_FILE" 2>/dev/null)
    case "${last_epoch:-}" in ''|*[!0-9]*) last_epoch=0 ;; esac
    case "${last_tier:-}" in ''|*[!0-9]*) last_tier=0 ;; esac
    if [ $((now - last_epoch)) -le "$WINDOW_S" ]; then
        tier=$((last_tier + 1))
        echo "Repeat invocation inside ${WINDOW_S}s — escalating to tier ${tier}."
    fi
fi

if [ "$KILL_ALL" = 1 ] || [ "$tier" -gt "$COUNT" ]; then
    targets="$RANKED"
    [ "$KILL_ALL" = 1 ] || echo "Tier ${tier} is past the end of the list — evicting everything left."
else
    targets="$(printf '%s\n' "$RANKED" | sed -n "${tier}p")"
fi

# A first invocation must never take the backend out from under a live session. When
# the only candidate left is attached, stop and make the caller ask again: pressing the
# button a second time escalates past this guard, so the escalating-tier state is still
# recorded here even though nothing was stopped.
TOP_ATT="$(printf '%s\n' "$targets" | head -1 | cut -d'|' -f7)"
TOP_PORT="$(printf '%s\n' "$targets" | head -1 | cut -d'|' -f4)"
if [ "$tier" = 1 ] && [ "$TOP_ATT" = yes ] && [ "$KILL_ALL" != 1 ] && [ -z "$FORCE_TIER" ]; then
    [ "$DRY_RUN" = 1 ] || printf '%s %s %s\n' "$now" "$tier" "guard" >> "$STATE_FILE"
    echo "=== held back ==="
    echo "  The best candidate (:$TOP_PORT) has a live Claude Code session attached, and no"
    echo "  unattached server is available to take instead. Stopping it would cut that"
    echo "  session's backend out from under it, so nothing was stopped."
    echo
    echo "RESULT: held back — the only candidate :$TOP_PORT is in use by a live session. Run again to override."
    exit 3
fi

# --- evict ---------------------------------------------------------------------
evict_one() {
    port="$1"; pid="$2"; backend="$3"; att="$4"
    if [ "$backend" = unknown ] && [ "$ALLOW_UNKNOWN" != 1 ]; then
        echo "  ⏭  :$port pid $pid — unrecognised listener, refusing without --allow-unknown"
        return 1
    fi
    if ! ps -o user= -p "$pid" 2>/dev/null | grep -qx "$(id -un)"; then
        echo "  ⏭  :$port pid $pid — not owned by $(id -un), refusing"
        return 1
    fi
    rss_kb=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' '); [ -n "${rss_kb:-}" ] || rss_kb=0
    note=""; [ "$att" = yes ] && note=" (a live session is attached — it will lose its backend)"
    if [ "$DRY_RUN" = 1 ]; then
        echo "  [dry-run] would evict $backend on :$port (pid $pid, $(human_gb "$rss_kb"))$note"
        return 0
    fi
    echo "  → evicting $backend on :$port (pid $pid, $(human_gb "$rss_kb"))$note"
    kill -TERM "$pid" 2>/dev/null
    waited=0
    while [ "$waited" -lt "$TERM_WAIT" ]; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1; waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        echo "    SIGTERM ignored after ${TERM_WAIT}s — sending SIGKILL"
        kill -9 "$pid" 2>/dev/null
        sleep 1
    fi
    if kill -0 "$pid" 2>/dev/null; then
        echo "    ⚠️  pid $pid still alive"
        return 1
    fi
    echo "    ✅ gone, ~$(human_gb "$rss_kb") released"
    EVICT_MB=$((EVICT_MB + rss_kb / 1024))
    EVICT_N=$((EVICT_N + 1))
    return 0
}

EVICT_MB=0; EVICT_N=0
echo "=== evicting (tier ${tier}) ==="
printf '%s\n' "$targets" | while IFS='|' read -r _ _ _ port pid backend att _; do
    evict_one "$port" "$pid" "$backend" "$att"
done

# The while-loop above runs in a subshell, so recount from the live system rather
# than trusting counters that cannot survive the pipe.
sleep 1
still_up=0
for port in $(seq "$PORT_START" "$PORT_MAX") $EXTRA_PORTS; do
    lsof -nP -iTCP:"$port" -sTCP:LISTEN -t >/dev/null 2>&1 && still_up=$((still_up + 1))
done
free_after=$(vm_stat 2>/dev/null | awk '/Pages free/{gsub(/\./,"",$3); printf "%d", $3*16384/1048576}')

if [ "$DRY_RUN" != 1 ]; then
    printf '%s %s %s\n' "$now" "$tier" "$(printf '%s' "$targets" | head -1 | cut -d'|' -f5)" >> "$STATE_FILE"
fi

echo
if [ "$DRY_RUN" = 1 ]; then
    echo "RESULT: dry run at tier ${tier} — nothing was stopped, ${still_up} server(s) still up."
    exit 0
fi
echo "Free RAM after: ${free_after:-?}MB (was ${free_mb:-?}MB)   servers still up: ${still_up}"
if [ "$still_up" -gt 0 ]; then
    echo "RESULT: tier ${tier} done; ${still_up} server(s) still up, free RAM ${free_after:-?}MB. Run again for the next one."
else
    echo "RESULT: tier ${tier} done; no model servers left, free RAM ${free_after:-?}MB."
fi
