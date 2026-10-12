#!/bin/bash
# Play with automatic recovery of unregistered indirect-call targets.
#   ./scripts/play_loop_mac.sh [--preset mac-arm64-release] [--max-restarts 40]
#                             [--big-texture-cache] [-- extra mcla args]
set -u
# shellcheck source=mac_common.sh
. "$(dirname "$0")/mac_common.sh"

PRESET="mac-arm64-release"
MAX_RESTARTS=40
BIG_CACHE=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --preset) [ "$#" -ge 2 ] || fail "--preset needs a name"; PRESET="$2"; shift 2 ;;
        --max-restarts) [ "$#" -ge 2 ] || fail "--max-restarts needs a number"; MAX_RESTARTS="$2"; shift 2 ;;
        --big-texture-cache) BIG_CACHE=1; shift ;;
        --) shift; break ;;
        *) fail "unknown option: $1 (see usage in scripts/play_loop_mac.sh)" ;;
    esac
done
case "$MAX_RESTARTS" in '' | *[!0-9]*) fail "--max-restarts must be a nonnegative integer" ;; esac
MAX_RESTARTS=$((10#$MAX_RESTARTS))
BUILD="$ROOT/out/build/$PRESET"
[ -x "$BUILD/mcla" ] || fail "$BUILD/mcla is missing; run scripts/make_mac.sh first"
if [ "$BIG_CACHE" -eq 1 ]; then
    set -- --texture_cache_memory_limit_soft=1536 --texture_cache_memory_limit_hard=2048 \
        --texture_cache_memory_limit_render_to_texture=64 "$@"
fi

mkdir -p "$ROOT/out/runs" || fail "cannot create out/runs"
RUN="$(mktemp -d "$ROOT/out/runs/play-$(date +%Y%m%d-%H%M%S)-XXXXXX")" || fail "cannot create run directory"
HINTS="$ROOT/config/runtime_discovered.toml"
pid=""
stop_game() {
    [ -n "$pid" ] || return 0
    kill -TERM "$pid" 2> /dev/null || true
    for _ in 1 2 3 4 5; do
        kill -0 "$pid" 2> /dev/null || break
        sleep 1
    done
    kill -KILL "$pid" 2> /dev/null || true
    wait "$pid" 2> /dev/null || true
    pid=""
}
trap stop_game EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cd "$BUILD" || fail "cannot enter $BUILD"
i=0
while [ "$i" -le "$MAX_RESTARTS" ]; do
    LOG="$RUN/play-$i.log"
    start=$SECONDS
    REX_PERF_LOG_CSV="$RUN/play-$i.csv" ./mcla --log_file="$LOG" --log_level=info --fullscreen=false "$@" \
        > "$RUN/play-$i.stdout.txt" 2>&1 &
    pid=$!
    code=0
    wait "$pid" || code=$?
    pid=""
    elapsed=$((SECONDS - start))
    [ -f "$LOG" ] || fail "no game log after ${elapsed}s (exit $code); see $RUN/play-$i.stdout.txt"
    addr="$(grep -i 'unregistered function at guest address' "$LOG" | \
        sed -nE 's/.*0[xX]([0-9A-Fa-f]{8}).*/\1/p' | head -n 1 | tr '[:lower:]' '[:upper:]')"
    if [ -z "$addr" ]; then
        echo "session ended after ${elapsed}s, exit code $code, log $LOG"
        grep -iE 'null-page|Unhandled guest|\[critical\]' "$LOG" | head -n 3
        echo "counters: $RUN/play-$i.csv (python3 scripts/analyze_perf.py <csv>)"
        exit "$code"
    fi
    if grep -qi "0x$addr" "$ROOT"/config/*.toml; then
        fail "0x$addr already hinted but still unregistered; stopping ($LOG)"
    fi
    [ "$i" -lt "$MAX_RESTARTS" ] || fail "restart limit reached at 0x$addr ($LOG)"
    echo "after ${elapsed}s: missing function 0x$addr, rebuilding and relaunching"
    BUILD_ARGS=(--preset "$PRESET")
    if [ -f "$BUILD/CMakeCache.txt" ]; then
        strict_fp="$(cache_value "$BUILD/CMakeCache.txt" MCLA_STRICT_FP | tr '[:lower:]' '[:upper:]')"
        case "$strict_fp" in
            ON | YES | TRUE | Y | 1) BUILD_ARGS+=(--strict-fp) ;;
        esac
    fi
    printf '\n[functions."0x%s"]\nname = "sub_%s"\n' "$addr" "$addr" >> "$HINTS" || fail "cannot write $HINTS"
    "$MAC_SCRIPTS/build_mac.sh" "${BUILD_ARGS[@]}" || fail "rebuild failed; see out/logs and out/build.log"
    i=$((i + 1))
done
