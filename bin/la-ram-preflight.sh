#!/usr/bin/env bash
# la-ram-preflight.sh — decide whether a model can be loaded WITHOUT stalling the machine.
#
# Why this exists: booting a session for a model while other model servers already hold RAM has
# pushed this machine past the edge — Terminal froze and even the force-quit menu stopped
# responding. Once you are in that state there is no graceful recovery, so the check has to happen
# BEFORE the load.
#
# It deliberately asks three INDEPENDENT questions, cheapest first, and stops as soon as the answer
# is settled — most launches never need questions 2 and 3:
#
#   1. Does this specific model fit in available RAM, with a floor left over?
#   2. Are other models already loaded on vllm / llama.cpp ports?      (only if 1 is tight)
#   3. Are those attached to a live session, or merely idle?            (only if 2 found any)
#
# It is NOT a gate that just says no. When it is tight it reports what would free how much, and
# never kills anything itself — eviction is always an explicit choice.
#
# Usage:  la-ram-preflight.sh <alias> [--quiet] [--json]
# Exit:   0 = safe to load (or an existing server already serves this alias)
#         1 = would not fit; advice printed
#         2 = usage/resolution error
#
# Tunables:  LA_RAM_MODEL_OVERHEAD_GB (default 6)  runtime+KV on top of weights
#            LA_RAM_FLOOR_GB          (default 16) must remain free AFTER loading
#            LA_PORT_LOW / LA_PORT_HIGH            port range to scan (default 8000-8010)
set -uo pipefail
# Pin numeric formatting: under a comma-decimal locale awk emits "24,4", which silently produces
# INVALID JSON and unparseable numbers for any caller. One export beats remembering per-call.
export LC_ALL=C

QUIET=0; JSON=0; ALIAS=""
for a in "$@"; do case "$a" in
  --quiet) QUIET=1 ;; --json) JSON=1 ;;
  -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
  -*) echo "unknown arg: $a" >&2; exit 2 ;;
  *) ALIAS="$a" ;;
esac; done
[[ -n $ALIAS ]] || { echo "Usage: $(basename "$0") <alias> [--quiet] [--json]" >&2; exit 2; }

_s="${BASH_SOURCE[0]}"; while [ -h "$_s" ]; do _d="$(cd -P "$(dirname "$_s")" && pwd)"; _s="$(readlink "$_s")"; case "$_s" in /*) ;; *) _s="$_d/$_s";; esac; done
HERE="$(cd -P "$(dirname "$_s")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../config/config-lib.sh"
la_load_config || exit 2
la_lookup "$ALIAS" >/dev/null 2>&1 || { echo "❌ unknown alias '$ALIAS'" >&2; exit 2; }
MODEL_DIR="$LA_CUR_DIR"
OVERHEAD=${LA_RAM_MODEL_OVERHEAD_GB:-6}
FLOOR=${LA_RAM_FLOOR_GB:-16}
PLOW=${LA_PORT_LOW:-8000}; PHIGH=${LA_PORT_HIGH:-8010}

# ---- question 0: is this model already being served? Then nothing new is loaded at all. --------
for p in $(seq "$PLOW" "$PHIGH"); do
  ids=$(curl -s --max-time 2 "http://localhost:$p/v1/models" 2>/dev/null | grep -o '"id":"[^"]*"' | cut -d'"' -f4)
  if [[ -n $ids ]] && grep -qxF "$ALIAS" <<<"$ids"; then
    ((QUIET)) || printf '✅ RAM preflight: %s is ALREADY served on port %s — reusing it, no new weights load.\n' "$ALIAS" "$p"
    exit 0
  fi
done

# ---- question 1: does it fit? (weights on disk + runtime overhead vs available, keeping a floor)
read -r AVAIL_GB WIRED_GB TOTAL_GB <<<"$(vm_stat | awk -v tot="$(sysctl -n hw.memsize)" '
  /page size of/{gsub(/[^0-9]/,"",$0); ps=$0}
  /Pages free/{gsub(/[^0-9]/,"",$3); f=$3} /Pages inactive/{gsub(/[^0-9]/,"",$3); i=$3}
  /Pages purgeable/{gsub(/[^0-9]/,"",$3); p=$3} /Pages speculative/{gsub(/[^0-9]/,"",$3); s=$3}
  /Pages wired down/{gsub(/[^0-9]/,"",$4); w=$4}
  END{printf "%.1f %.1f %.1f", (f+i+p+s)*ps/1073741824, w*ps/1073741824, tot/1073741824}')"
# Weights on disk are the honest floor for resident size. -L so a symlink-farm override counts.
WEIGHTS_GB=$(find -L "$MODEL_DIR" -type f -size +1024k -print0 2>/dev/null | xargs -0 stat -f%z 2>/dev/null \
             | awk '{t+=$1} END{printf "%.1f", t/1073741824}')
[[ -n $WEIGHTS_GB && $WEIGHTS_GB != 0.0 ]] || WEIGHTS_GB=${LA_SIZE[$ALIAS]:-0}
NEED_GB=$(LC_ALL=C awk -v w="$WEIGHTS_GB" -v o="$OVERHEAD" 'BEGIN{printf "%.1f", w+o}')
SWAP_USED=$(sysctl -n vm.swapusage | sed -E 's/.*used = ([0-9.,]+)M.*/\1/' | tr ',' '.')
FITS=$(LC_ALL=C awk -v a="$AVAIL_GB" -v n="$NEED_GB" -v fl="$FLOOR" 'BEGIN{print (a-n>=fl)?1:0}')

if ((JSON)); then
  printf '{"alias":"%s","weights_gb":%s,"need_gb":%s,"available_gb":%s,"floor_gb":%s,"wired_gb":%s,"swap_used_mb":%s,"fits":%s}\n' \
    "$ALIAS" "$WEIGHTS_GB" "$NEED_GB" "$AVAIL_GB" "$FLOOR" "$WIRED_GB" "${SWAP_USED:-0}" "$FITS"
fi

if ((FITS)); then
  ((QUIET||JSON)) || printf '✅ RAM preflight: %s needs ~%s GB (weights %s + %s overhead); %s GB available, %s GB floor kept. Clear.\n' \
      "$ALIAS" "$NEED_GB" "$WEIGHTS_GB" "$OVERHEAD" "$AVAIL_GB" "$FLOOR"
  exit 0
fi

# ---- questions 2 and 3: only reached when it is genuinely tight. -------------------------------
printf '\n⚠️  RAM PREFLIGHT: loading %s looks UNSAFE right now.\n' "$ALIAS"
printf '    needs ~%s GB (weights %s + %s overhead) · available %s GB · floor %s GB · wired %s of %s GB\n' \
  "$NEED_GB" "$WEIGHTS_GB" "$OVERHEAD" "$AVAIL_GB" "$FLOOR" "$WIRED_GB" "$TOTAL_GB"
LC_ALL=C awk -v s="${SWAP_USED:-0}" 'BEGIN{if (s+0>1024) printf "    swap already in use: %.1f GB — the machine is ALREADY under pressure.\n", s/1024}'

# WHICH PORTS HAVE A LIVE SESSION ATTACHED?
# An ESTABLISHED connection is NOT the signal: Claude Code opens one only while a request is in
# flight, so between turns a fully-live session shows ZERO connections. Relying on that offered to
# kill a live session in testing. The reliable signal is the CLIENT's own environment: every local
# session's `claude` process carries ANTHROPIC_BASE_URL=http://localhost:<port>.
declare -A PORT_CLIENT
while read -r cpid; do
  [[ -n $cpid ]] || continue
  curl_url=$(ps eww -p "$cpid" 2>/dev/null | tr ' ' '\n' | grep -m1 '^ANTHROPIC_BASE_URL=' | cut -d= -f2-)
  [[ $curl_url =~ localhost:([0-9]+) ]] && PORT_CLIENT[${BASH_REMATCH[1]}]="$cpid"
done < <(pgrep -x claude 2>/dev/null)

EVICTABLE_PIDS=(); EVICTABLE_GB=0; FOUND=0
printf '\n    Model servers currently holding RAM:\n'
for p in $(seq "$PLOW" "$PHIGH"); do
  pid=$(lsof -nP -iTCP:"$p" -sTCP:LISTEN 2>/dev/null | tail -n +2 | awk '{print $2}' | head -1)
  [[ -n $pid ]] || continue
  FOUND=1
  rss=$(ps -o rss= -p "$pid" 2>/dev/null | LC_ALL=C awk '{printf "%.1f", $1/1048576}')
  est=$(lsof -nP -iTCP:"$p" -sTCP:ESTABLISHED 2>/dev/null | tail -n +2 | grep -c . || true)
  ids=$(curl -s --max-time 2 "http://localhost:$p/v1/models" 2>/dev/null | grep -o '"id":"[^"]*"' | cut -d'"' -f4 | tr '\n' ' ')
  if [[ -n ${PORT_CLIENT[$p]:-} ]]; then
    printf '      :%s  %-6s GB  ATTACHED — local session pid %s is using it. LEAVE ALONE%s\n' \
      "$p" "$rss" "${PORT_CLIENT[$p]}" "$( (( est > 0 )) && echo ' (mid-request)' || echo ' (idle between turns)')"
  elif (( est > 0 )); then
    printf '      :%s  %-6s GB  BUSY — %d live connection(s) but no local session found; something is talking to it\n' "$p" "$rss" "$est"
  else
    printf '      :%s  %-6s GB  no session attached, idle — evictable, would free %s GB\n' "$p" "$rss" "$rss"
    EVICTABLE_PIDS+=("$pid:$p:$rss")
    EVICTABLE_GB=$(LC_ALL=C awk -v a="$EVICTABLE_GB" -v b="$rss" 'BEGIN{printf "%.1f", a+b}')
  fi
  printf '            serving: %s\n' "${ids:-<unknown>}"
done
(( FOUND )) || printf '      (none — the shortfall is other applications, not model servers)\n'

printf '\n    Options:\n'
if ((${#EVICTABLE_PIDS[@]})); then
  would=$(LC_ALL=C awk -v a="$AVAIL_GB" -v e="$EVICTABLE_GB" -v n="$NEED_GB" -v f="$FLOOR" 'BEGIN{printf "%s", (a+e-n>=f)?"yes":"no"}')
  printf '      A) evict %d idle server(s), freeing ~%s GB — %s\n' "${#EVICTABLE_PIDS[@]}" "$EVICTABLE_GB" \
     "$([[ $would == yes ]] && echo 'that WOULD be enough' || echo 'still would NOT be enough on its own')"
  for e in "${EVICTABLE_PIDS[@]}"; do IFS=: read -r ep eport erss <<<"$e"; printf '           kill -TERM %-7s # port %s, frees ~%s GB\n' "$ep" "$eport" "$erss"; done
fi
# Only suggest alternatives that would ACTUALLY fit right now, on disk, largest-first (best
# capability that still works). A list of everything smaller is noise, not a recommendation.
smaller=$(for a in "${LA_ALIASES[@]}"; do
    sz=${LA_SIZE[$a]:-}; [[ $sz =~ ^[0-9.]+$ ]] || continue
    la_on_disk "$a" 2>/dev/null || continue
    awk -v s="$sz" -v a="$AVAIL_GB" -v o="$OVERHEAD" -v f="$FLOOR" -v n="$a" \
        'BEGIN{if (a-(s+o) >= f) printf "%s\t%s\n", s, n}'
  done | sort -rn -k1,1 | head -4 | awk '{printf "%s(~%sGB) ", $2, $1}')
if [[ -n $smaller ]]; then
  printf '      B) launch one of these instead — on disk and fits right now: %s\n' "$smaller"
else
  printf '      B) no registered model currently on disk would fit either — free RAM first\n'
fi
printf '      C) close a live local session (that frees its server AND its client)\n'
printf '      D) proceed anyway — only if you know the numbers are wrong. Risk: an unrecoverable stall.\n'

if [[ -t 0 ]] && ((!QUIET)); then
  printf '\n    Proceed anyway (p), evict all idle servers then load (e), or abort (a)? [p/e/a] '
  read -r ans
  case ${ans:-a} in
    e|E) for e in "${EVICTABLE_PIDS[@]}"; do IFS=: read -r ep eport erss <<<"$e"
           printf '      evicting pid %s (port %s, ~%s GB)...\n' "$ep" "$eport" "$erss"; kill -TERM "$ep" 2>/dev/null
         done
         sleep 3; printf '      re-checking...\n'; exec "$0" "$ALIAS" ;;
    p|P) printf '      proceeding at your risk.\n'; exit 0 ;;
    *)   printf '      aborted; nothing loaded.\n'; exit 1 ;;
  esac
fi
exit 1
