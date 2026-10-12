#!/bin/bash
# Launch the macOS build for a fixed time, capture screenshots, then stop it.
#   ./scripts/smoke_mac.sh [--seconds 90] [--shots 3] [--preset mac-arm64-release] [-- extra mcla args]
# Screenshots are of the whole screen (screencapture), so the game should be in
# front, and the terminal running this needs Screen Recording permission
# (System Settings > Privacy & Security); without it the shots show no windows.
set -u
# shellcheck source=mac_common.sh
. "$(dirname "$0")/mac_common.sh"

SECONDS_TOTAL=90
SHOTS=3
PRESET="mac-arm64-release"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --seconds) [ "$#" -ge 2 ] || fail "--seconds needs a number"; SECONDS_TOTAL="$2"; shift 2 ;;
        --shots) [ "$#" -ge 2 ] || fail "--shots needs a number"; SHOTS="$2"; shift 2 ;;
        --preset) [ "$#" -ge 2 ] || fail "--preset needs a name"; PRESET="$2"; shift 2 ;;
        --) shift; break ;;
        *) fail "unknown option: $1 (usage: smoke_mac.sh [--seconds N] [--shots K] [--preset NAME] [-- mcla args])" ;;
    esac
done
[ "$SHOTS" -ge 1 ] || fail "--shots must be at least 1"
BUILD="$ROOT/out/build/$PRESET"
[ -x "$BUILD/mcla" ] || fail "$BUILD/mcla is missing; run scripts/make_mac.sh first"

RUN="$ROOT/out/runs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN"
LOG="$RUN/run.log"

cd "$BUILD" || fail "cannot enter $BUILD"
REX_PERF_LOG_CSV="$RUN/perf.csv" ./mcla --log_file="$LOG" --log_level=info --fullscreen=false "$@" > "$RUN/stdout.txt" 2>&1 &
pid=$!
echo "started mcla, pid $pid, for ${SECONDS_TOTAL}s"

interval=$((SECONDS_TOTAL / SHOTS))
[ "$interval" -ge 1 ] || interval=1
arch_done=0
shot=0
last_size=-1
last_change=0
elapsed=0
exited=0
while [ "$elapsed" -lt "$SECONDS_TOTAL" ]; do
    sleep 1
    elapsed=$((elapsed + 1))
    if ! kill -0 "$pid" 2> /dev/null; then
        exited=1
        break
    fi
    # Which architecture the process really runs as (arm64, not translated).
    if [ "$arch_done" -eq 0 ] && [ "$elapsed" -ge 10 ]; then
        arch_done=1
        {
            vmmap --summary "$pid" 2> /dev/null | grep -i "code type"
            echo "proc_translated: $(sysctl -n sysctl.proc_translated 2> /dev/null || echo 0)"
        } > "$RUN/arch.txt"
        cat "$RUN/arch.txt"
    fi
    if [ "$shot" -lt "$SHOTS" ] && [ $((elapsed % interval)) -eq 0 ]; then
        shot=$((shot + 1))
        if screencapture -x "$RUN/shot-$shot.png" 2> /dev/null; then
            echo "shot $shot at ${elapsed}s: $RUN/shot-$shot.png"
        else
            echo "shot ${shot}: screencapture failed"
        fi
    fi
    # A process that burns CPU while its log stands still is probably stuck in
    # a fault loop.
    size="$(wc -c < "$LOG" 2> /dev/null || echo 0)"
    size="${size##* }"
    if [ "$size" != "$last_size" ]; then
        last_size="$size"
        last_change="$elapsed"
    elif [ $((elapsed - last_change)) -ge 30 ]; then
        cpu="$(ps -o %cpu= -p "$pid" 2> /dev/null | tr -d ' ')"
        cpu_int="${cpu%%.*}"
        if [ -n "$cpu_int" ] && [ "$cpu_int" -gt 90 ]; then
            echo "possible fault loop: log unchanged for $((elapsed - last_change))s at ${cpu}% CPU (${elapsed}s)"
            last_change="$elapsed"
        fi
    fi
done

if [ "$exited" -eq 1 ]; then
    code=0
    wait "$pid" || code=$?
    echo "FAILED: process exited early after ${elapsed}s, code $code"
else
    kill -TERM "$pid" 2> /dev/null
    for _ in 1 2 3 4 5; do
        kill -0 "$pid" 2> /dev/null || break
        sleep 1
    done
    if kill -0 "$pid" 2> /dev/null; then
        kill -KILL "$pid" 2> /dev/null
    fi
    wait "$pid" 2> /dev/null
fi

echo "log: $LOG"
if [ -f "$LOG" ]; then
    grep -iE 'null-page|unhandled|critical|unregistered|MapViewsMac' "$LOG" | head -n 20
fi
# The game is meant to run for the whole duration: stopping on its own is a failure.
[ "$exited" -eq 0 ] || exit 1
exit 0
