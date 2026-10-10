# shellcheck shell=bash
# shellcheck disable=SC2034 # the variables are used by the scripts that source this
# Shared by the macOS scripts; source it, do not run it:
#   . "$(dirname "$0")/mac_common.sh"
# Plain bash 3.2 (macOS /bin/bash), no newer features.

MAC_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$MAC_SCRIPTS")"
SDK="$ROOT/third_party/rexglue-sdk"
SDK_TAG="v0.10.0"
SDK_COMMIT="f5337cdc947ff6d4c4196737e2c807a48f2a1fc2"
INSTALL="$SDK/out/install/mac-arm64"
MARKER="$SDK/.mcla-patched"
LOGS="$ROOT/out/logs"
CC_BIN=/usr/bin/clang
CXX_BIN=/usr/bin/clang++
mkdir -p "$LOGS"

step() { printf '\n==> %s\n' "$1"; }
fail() { printf '\nFAILED: %s\n' "$1" >&2; exit 1; }

# Run a command with its output in a log; on failure show the end of the log.
logged() {
    local name="$1"
    shift
    local log="$LOGS/$name.log"
    if ! "$@" > "$log" 2>&1; then
        tail -n 25 "$log"
        fail "$name (full log: $log)"
    fi
}

# Apply a patch unless it is already in: a run that stopped after this patch
# and before the end of step 2 leaves it applied, and it does not apply twice.
patch_in() {
    local name="$1" repo="$2" patch="$3"
    if git -C "$repo" apply --reverse --check "$patch" > /dev/null 2>&1; then
        echo "already applied: $(basename "$patch")"
        return 0
    fi
    logged "$name" git -C "$repo" apply "$patch"
}
