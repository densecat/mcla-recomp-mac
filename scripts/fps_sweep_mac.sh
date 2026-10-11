#!/bin/bash
# Measure frame times and CPU at each target, optionally comparing two builds.
#   ./scripts/fps_sweep_mac.sh [--preset mac-arm64-release] [--targets 30,60,120]
#       [--a DIR --b DIR] [--scenarios title,race,roam,map] [--runs 3]
#       [--seconds 120] [--discard 20] [--output DIR] [-- extra mcla args]
# For strict-FP A/B, build the second preset with build_mac.sh --strict-fp,
# then pass the default build directory as --a and the strict build as --b.
# Non-title scenarios prompt after launch: restore the same save/route/view,
# then press Return. Use AC power, Low Power Mode off, and identical settings.
set -u
# shellcheck source=mac_common.sh
. "$(dirname "$0")/mac_common.sh"

PRESET="mac-arm64-release"
BUILD_A=""
BUILD_B=""
TARGETS="30,60,120"
SCENARIOS="title"
RUNS=3
SECONDS_TOTAL=120
DISCARD=20
OUTPUT=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --preset | --a | --b | --targets | --scenarios | --runs | --seconds | --discard | --output)
            [ "$#" -ge 2 ] || fail "$1 needs a value"
            case "$1" in
                --preset) PRESET="$2" ;;
                --a) BUILD_A="$2" ;;
                --b) BUILD_B="$2" ;;
                --targets) TARGETS="$2" ;;
                --scenarios) SCENARIOS="$2" ;;
                --runs) RUNS="$2" ;;
                --seconds) SECONDS_TOTAL="$2" ;;
                --discard) DISCARD="$2" ;;
                --output) OUTPUT="$2" ;;
            esac
            shift 2 ;;
        --) shift; break ;;
        *) fail "unknown option: $1 (see usage in scripts/fps_sweep_mac.sh)" ;;
    esac
done
for value in "$RUNS" "$SECONDS_TOTAL" "$DISCARD"; do
    case "$value" in '' | *[!0-9]*) fail "runs, seconds and discard must be integers" ;; esac
done
RUNS=$((10#$RUNS))
SECONDS_TOTAL=$((10#$SECONDS_TOTAL))
DISCARD=$((10#$DISCARD))
[ "$RUNS" -gt 0 ] || fail "runs must be positive"
[ "$SECONDS_TOTAL" -gt "$DISCARD" ] || fail "seconds must exceed discard"
case "$TARGETS,$SCENARIOS" in ,* | *, | *,,*) fail "empty target or scenario" ;; esac
IFS=',' read -r -a targets <<< "$TARGETS"
IFS=',' read -r -a scenarios <<< "$SCENARIOS"
for fps in "${targets[@]}"; do
    case "$fps" in '' | *[!0-9]*) fail "invalid FPS target: $fps" ;; esac
    [ "$((10#$fps))" -gt 0 ] || fail "FPS targets must be positive"
done
for scenario in "${scenarios[@]}"; do
    case "$scenario" in
        title) ;;
        race | roam | map) [ -t 0 ] || fail "$scenario needs an interactive terminal for scenario setup" ;;
        *) fail "unknown scenario: $scenario (use title,race,roam,map)" ;;
    esac
done
command -v python3 > /dev/null 2>&1 || fail "python3 is needed"
command -v top > /dev/null 2>&1 || fail "top is needed"
BUILD_A="${BUILD_A:-$ROOT/out/build/$PRESET}"
BUILD_A="$(cd "$BUILD_A" && pwd)" || fail "cannot enter build A"
[ -x "$BUILD_A/mcla" ] || fail "$BUILD_A/mcla is missing; run scripts/make_mac.sh first"
if [ -n "$BUILD_B" ]; then
    BUILD_B="$(cd "$BUILD_B" && pwd)" || fail "cannot enter build B"
    [ -x "$BUILD_B/mcla" ] || fail "$BUILD_B/mcla is missing"
    [ "$BUILD_A" != "$BUILD_B" ] || fail "--a and --b must be different build directories"
fi
if [ -z "$OUTPUT" ]; then
    mkdir -p "$ROOT/out/perf" || fail "cannot create out/perf"
    OUTPUT="$(mktemp -d "$ROOT/out/perf/sweep-$(date +%Y%m%d-%H%M%S)-XXXXXX")" || fail "cannot create output directory"
else
    [ ! -e "$OUTPUT" ] || fail "output already exists: $OUTPUT"
    mkdir -p "$OUTPUT" || fail "cannot create $OUTPUT"
fi
OUTPUT="$(cd "$OUTPUT" && pwd)" || fail "cannot enter output directory"
{
    date -u
    uname -a
    sw_vers 2> /dev/null || true
    sysctl -n machdep.cpu.brand_string hw.memsize 2> /dev/null || true
    pmset -g batt 2> /dev/null || true
    printf 'a=%s\nb=%s\nscenarios=%s\ntargets=%s\nruns=%s\nseconds=%s\ndiscard=%s\n' \
        "$BUILD_A" "$BUILD_B" "$SCENARIOS" "$TARGETS" "$RUNS" "$SECONDS_TOTAL" "$DISCARD"
    printf 'extra args:'; printf ' %q' "$@"; printf '\n'
    for build in "$BUILD_A" "$BUILD_B"; do
        [ -n "$build" ] || continue
        echo "build: $build"
        shasum -a 256 "$build/mcla"
        if [ -f "$build/CMakeCache.txt" ]; then
            grep -E '^(MCLA_STRICT_FP|CMAKE_BUILD_TYPE|CMAKE_CXX_FLAGS[^:]*):' "$build/CMakeCache.txt" || true
        fi
    done
} > "$OUTPUT/environment.txt"

pid=""
top_pid=""
stop_run() {
    if [ -n "$top_pid" ]; then
        kill -TERM "$top_pid" 2> /dev/null || true
        wait "$top_pid" 2> /dev/null || true
        top_pid=""
    fi
    if [ -n "$pid" ]; then
        kill -TERM "$pid" 2> /dev/null || true
        for _ in 1 2 3 4 5; do
            kill -0 "$pid" 2> /dev/null || break
            sleep 1
        done
        kill -KILL "$pid" 2> /dev/null || true
        wait "$pid" 2> /dev/null || true
        pid=""
    fi
}
trap stop_run EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for scenario in "${scenarios[@]}"; do
    for fps in "${targets[@]}"; do
        repeat=1
        while [ "$repeat" -le "$RUNS" ]; do
            order="a"
            if [ -n "$BUILD_B" ]; then
                order="a b"
                if [ $((repeat % 2)) -eq 0 ]; then order="b a"; fi
            fi
            for variant in $order; do
                build="$BUILD_A"
                if [ "$variant" = b ]; then build="$BUILD_B"; fi
                RUN="$OUTPUT/$scenario-$fps-$variant-$repeat"
                mkdir -p "$RUN" || fail "cannot create $RUN"
                cd "$build" || fail "cannot enter $build"
                REX_PERF_LOG_CSV="$RUN/perf.csv" ./mcla --log_file="$RUN/run.log" --log_level=info \
                    --fullscreen=false "--mcla_fps=$fps" "$@" > "$RUN/stdout.txt" 2>&1 &
                pid=$!
                echo "$scenario target $fps, build $variant, run $repeat/$RUNS: pid $pid"
                if [ "$scenario" != title ]; then
                    echo "Prepare $scenario (race: same starting save; roam: downtown route; map: same zoom)."
                    read -r -p 'Press Return when ready to begin the timed run: ' answer || fail "scenario setup cancelled"
                fi
                # Anchor both clocks at a fresh flush, excluding boot/manual setup.
                # The SDK flushes every 60 frames; a stopped run can lose that tail.
                if ! skip_rows="$(python3 - "$RUN/perf.csv" "$pid" <<'PY'
import os
import pathlib
import sys
import time

path, pid = pathlib.Path(sys.argv[1]), int(sys.argv[2])
def rows():
    try:
        return max(0, path.read_bytes().count(b"\n") - 1)
    except FileNotFoundError:
        return 0

previous = rows()
deadline = time.monotonic() + 60
while time.monotonic() < deadline:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        raise SystemExit("game exited before measurement began")
    current = rows()
    if current > previous:
        print(current)
        break
    time.sleep(.1)
else:
    raise SystemExit("no fresh CSV frames within 60 seconds")
PY
)"; then
                    if ! kill -0 "$pid" 2> /dev/null; then
                        code=0
                        wait "$pid" || code=$?
                        pid=""
                        fail "process exited early, code $code ($RUN)"
                    fi
                    fail "could not start measurement ($RUN)"
                fi
                top -l 0 -pid "$pid" -s 1 -stats pid,cpu > "$RUN/top.txt" 2> "$RUN/top.stderr.txt" &
                top_pid=$!
                elapsed=0
                while [ "$elapsed" -lt "$SECONDS_TOTAL" ]; do
                    sleep 1
                    elapsed=$((elapsed + 1))
                    if ! kill -0 "$pid" 2> /dev/null; then
                        code=0
                        wait "$pid" || code=$?
                        pid=""
                        fail "process exited early after ${elapsed}s, code $code ($RUN)"
                    fi
                done
                sampled_pid="$pid"
                stop_run
                [ -s "$RUN/perf.csv" ] || fail "no frame data ($RUN)"
                if [ -f "$RUN/run.log" ] && grep -qiE 'unregistered function|\[critical\]|unhandled guest' "$RUN/run.log"; then
                    fail "game errors during measurement ($RUN/run.log)"
                fi
                if ! python3 - "$RUN" "$OUTPUT/summary.csv" "$scenario" "$fps" "$variant" "$repeat" \
                    "$DISCARD" "$SECONDS_TOTAL" "$skip_rows" "$sampled_pid" <<'PY'
import csv
import math
import pathlib
import statistics
import sys

run = pathlib.Path(sys.argv[1])
summary = pathlib.Path(sys.argv[2])
scenario, fps, variant, repeat = sys.argv[3:7]
discard, seconds, skip_rows, pid = map(int, sys.argv[7:])
with (run / "perf.csv").open(newline="") as f:
    reader = csv.DictReader(f)
    fields = reader.fieldnames
    rows = list(reader)
kept, elapsed = [], 0.0
for i, row in enumerate(rows[skip_rows:]):
    # A forced stop can leave an incomplete final CSV row.
    if None in row or None in row.values():
        if i == len(rows) - skip_rows - 1:
            break
        raise SystemExit("incomplete CSV row before end of file")
    ms = float(row["frame_time_us"]) / 1000
    if not math.isfinite(ms) or ms < 0:
        raise SystemExit("invalid frame time")
    start = elapsed
    elapsed += ms / 1000
    # No timestamp column: use cumulative frame time, excluding boundary frames.
    if ms > 0 and start + 1e-9 >= discard and elapsed <= seconds + 1e-9:
        kept.append(row)
if len(kept) < 10:
    raise SystemExit("too few frames after warm-up")
ft = sorted(float(r["frame_time_us"]) / 1000 for r in kept)
if sum(ft) / 1000 < .95 * (seconds - discard):
    raise SystemExit("insufficient frame coverage (less than 95% of the steady window)")
with (run / "steady.csv").open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=fields)
    writer.writeheader()
    writer.writerows(kept)
cpu, sample = [], -1
for line in (run / "top.txt").read_text().splitlines():
    parts = line.split()
    if parts and parts[0] == "PID":
        sample += 1
    elif len(parts) == 2 and parts[0] == str(pid) and max(1, discard) <= sample < seconds:
        value = float(parts[1].rstrip("%"))
        if math.isfinite(value) and value >= 0:
            cpu.append(value)
if not cpu:
    raise SystemExit("no CPU samples after warm-up; inspect top.txt and top.stderr.txt")
if len(cpu) < .95 * (seconds - max(1, discard)):
    raise SystemExit("insufficient CPU coverage; inspect top.txt and top.stderr.txt")
result = dict(scenario=scenario, target_fps=fps, build=variant, run=repeat, frames=len(ft),
              measured_s=f"{sum(ft) / 1000:.3f}", median_ms=f"{statistics.median(ft):.3f}",
              p95_ms=f"{ft[min(len(ft) - 1, int(len(ft) * .95))]:.3f}",
              p99_ms=f"{ft[min(len(ft) - 1, int(len(ft) * .99))]:.3f}",
              over_33_4_pct=f"{100 * sum(t > 33.4 for t in ft) / len(ft):.3f}",
              over_16_7_pct=f"{100 * sum(t > 16.7 for t in ft) / len(ft):.3f}",
              cpu_mean_pct=f"{statistics.mean(cpu):.3f}", cpu_samples=len(cpu))
new = not summary.exists()
with summary.open("a", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=result.keys())
    if new:
        writer.writeheader()
    writer.writerow(result)
print(f"  median {result['median_ms']} ms, p95 {result['p95_ms']}, p99 {result['p99_ms']}; "
      f">33.4 ms {result['over_33_4_pct']}%, >16.7 ms {result['over_16_7_pct']}%; "
      f"CPU {result['cpu_mean_pct']}% ({len(cpu)} samples), {result['measured_s']} s of frames")
PY
                then
                    fail "could not summarize $RUN"
                fi
                python3 "$MAC_SCRIPTS/analyze_perf.py" "$RUN/steady.csv" > "$RUN/analysis.txt" || fail "analyze_perf failed ($RUN)"
                python3 "$MAC_SCRIPTS/sweep_stats.py" "$SECONDS_TOTAL" "$RUN/steady.csv" > "$RUN/stats.txt" || fail "sweep_stats failed ($RUN)"
                sleep 2
            done
            repeat=$((repeat + 1))
        done
    done
done
echo "per-run results: $OUTPUT/summary.csv"
python3 - "$OUTPUT/summary.csv" <<'PY'
import collections
import csv
import statistics
import sys

groups = collections.defaultdict(list)
with open(sys.argv[1], newline="") as f:
    for row in csv.DictReader(f):
        groups[(row["scenario"], row["target_fps"], row["build"])].append(row)
print("Medians across runs (CPU is the median of per-run means):")
for (scenario, fps, build), rows in sorted(groups.items()):
    metrics = ("median_ms", "p95_ms", "p99_ms", "over_33_4_pct", "over_16_7_pct", "cpu_mean_pct")
    values = ", ".join(f"{k}={statistics.median(float(r[k]) for r in rows):.3f}" for k in metrics)
    print(f"{scenario} target {fps} build {build} ({len(rows)} runs): {values}")
PY
