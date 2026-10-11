#!/bin/bash
# Bound a no-data launch and distinguish loader failures from missing UI/data.
# Usage: ci_launch_smoke.sh bare|bundle EXECUTABLE LOG_DIR
set -euo pipefail
if [ "$#" -ne 3 ]; then
    echo "usage: ci_launch_smoke.sh bare|bundle EXECUTABLE LOG_DIR" >&2
    exit 1
fi
python3 - "$@" <<'PY'
import os
import pathlib
import re
import signal
import subprocess
import sys

kind, executable, log_dir = sys.argv[1:]
if kind not in ("bare", "bundle"):
    sys.exit("CI launch: expected bare or bundle")
executable = pathlib.Path(executable).resolve()
log_dir = pathlib.Path(log_dir).resolve()
log_dir.mkdir(parents=True, exist_ok=True)
output = log_dir / (kind + "-stdout.log")
if kind == "bundle":
    if not os.environ.get("HOME"):
        sys.exit("CI launch: HOME must be set for the bundle log check")
    app_log = pathlib.Path(os.environ["HOME"]) / "Library/Logs/MCLA/mcla.log"
else:
    app_log = log_dir / "bare-app.log"
if app_log.exists():
    sys.exit("CI launch: refusing a stale app log: " + str(app_log))
missing_game = log_dir / "no-game-data"
if missing_game.exists():
    sys.exit("CI launch: no-game-data path must not exist")
command = [str(executable), "--log_level=debug", "--log_flush_interval=1",
           "--game_data_root=" + str(missing_game)]
if kind == "bare":
    command.append("--log_file=" + str(app_log))

timed_out = False
cleanup_signal = None
with output.open("wb") as capture:
    try:
        process = subprocess.Popen(command, cwd=log_dir, stdout=capture,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            timed_out = True
            # A missing-data message box can remain open indefinitely. Kill
            # only our process group, and record our signals separately.
            cleanup_signal = signal.SIGTERM
            try:
                os.killpg(process.pid, cleanup_signal)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                cleanup_signal = signal.SIGKILL
                try:
                    os.killpg(process.pid, cleanup_signal)
                except ProcessLookupError:
                    pass
                process.wait()
    except OSError as error:
        capture.write(("Launch failed: " + str(error) + "\n").encode())
        process = None

console = output.read_text(errors="replace")
print(f"--- {kind} stdout/stderr ---\n{console}", flush=True)
app_text = app_log.read_text(errors="replace") if app_log.is_file() else ""
print(f"--- {kind} app log: {app_log} ---\n{app_text}", flush=True)
if kind == "bundle" and app_log.is_file():
    (log_dir / "bundle-app.log").write_text(app_text)
combined = console + "\n" + app_text


def fail(reason):
    sys.exit(f"FAIL {kind}: {reason}")


if process is None:
    fail("could not execute mcla")
if re.search(r"Library not loaded|image not found|Symbol not found|symbol not found|"
             r"dyld\[[0-9]+\]:|dyld:|CI guest stub called", combined, re.IGNORECASE):
    fail("dynamic loader error or synthetic guest execution")
status = process.returncode
if status < 0 and not (timed_out and status == -cleanup_signal):
    fail(f"unexpected signal {signal.Signals(-status).name}")
if status >= 0 and status not in (0, 1):
    fail(f"unexpected exit status {status}")
startup = "mcla starting" in combined
no_data = bool(re.search(r"--game_data_root (?:was not provided|does not exist)", combined))
if startup or no_data:
    if not app_log.is_file():
        fail("logging was reached but the expected app log is missing")
    reached = "missing-data check reached" if no_data else "startup logging reached"
elif "SDL_InitSubSystem(SDL_INIT_VIDEO) failed:" in combined:
    # A runner without a display can fail before SetupEnvironment/log-file
    # setup. In this explicit case the criterion is only absence of dyld errors.
    reached = "SDL video unavailable; app logging not reached"
else:
    fail("neither startup, missing-data error nor explicit SDL video failure was observed")
if "Failed to load GPU plugin" in combined:
    fail("GPU plugin could not be loaded")
ending = f"timeout after 20s; cleanup={cleanup_signal.name}" if timed_out else f"exit={status}"
print(f"PASS {kind}: {reached}; no dyld errors; {ending}")
if kind == "bundle" and (startup or no_data):
    print(f"PASS bundle log outside app: {app_log}")
PY
