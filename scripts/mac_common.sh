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

# True when $1 >= $2, both dotted versions.
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -n 1)" = "$2" ]; }
# The file a command name really is, following symlinks (macOS has no readlink -f
# before 12.3 and none in some setups, so walk the links).
resolve() {
    local p
    p="$(command -v "$1")" || return 1
    while [ -L "$p" ]; do
        local t
        t="$(readlink "$p")"
        case "$t" in /*) p="$t" ;; *) p="$(dirname "$p")/$t" ;; esac
    done
    echo "$p"
}
has_arm64() { lipo -archs "$(resolve "$1")" 2> /dev/null | tr ' ' '\n' | grep -qx arm64; }

# Native Apple Silicon toolchain checks, shared by make_mac.sh and build_mac.sh
# so that neither can run a build under Rosetta or with an Intel tool. A missing
# CMake or Ninja is installed with Homebrew only when ALLOW_BREW_INSTALL=1
# (make_mac.sh); INSTALL_TOOLS=1 skips its question.
ALLOW_BREW_INSTALL=0
INSTALL_TOOLS=0
preflight_tools() {
    local translated cxx_version apple_major missing tool answer cmake_version python_version
    [ "$(uname -m)" = "arm64" ] || fail "this needs an Apple Silicon Mac, or a Terminal that runs natively; uname -m says '$(uname -m)'. A Terminal or shell started under Rosetta makes every tool build x86_64"
    translated="$(sysctl -n sysctl.proc_translated 2> /dev/null || echo 0)"
    [ "$translated" = "0" ] || fail "this shell runs under Rosetta (sysctl.proc_translated=$translated). Open a Terminal that is not set to 'Open using Rosetta' (Get Info on the app) and run this again"

    [ -x "$CXX_BIN" ] || fail "$CXX_BIN is missing: install Xcode 16 or newer, or run 'xcode-select --install'"
    cxx_version="$("$CXX_BIN" --version 2> /dev/null | head -n 1)"
    case "$cxx_version" in
        *"Apple clang"*) ;;
        *) fail "$CXX_BIN is not Apple clang ($cxx_version): install Xcode 16 or newer, or run 'xcode-select --install'" ;;
    esac
    apple_major="$(echo "$cxx_version" | sed -n 's/.*version \([0-9][0-9]*\).*/\1/p')"
    if [ -z "$apple_major" ] || [ "$apple_major" -lt 16 ]; then
        fail "Apple clang 16 or newer is needed ($cxx_version): install Xcode 16 or newer, or run 'xcode-select --install'"
    fi

    missing=""
    command -v git > /dev/null 2>&1 || missing="$missing git"
    command -v cmake > /dev/null 2>&1 || missing="$missing cmake"
    command -v ninja > /dev/null 2>&1 || missing="$missing ninja"
    command -v python3 > /dev/null 2>&1 || missing="$missing python3"
    if [ -n "$missing" ]; then
        echo "missing:$missing"
        for tool in $missing; do
            case "$tool" in
                git | python3) fail "$tool is missing: run 'xcode-select --install' (it provides Git and Python 3) and run this again" ;;
            esac
        done
        # Only cmake and/or ninja are missing: Homebrew can provide them.
        if [ "$ALLOW_BREW_INSTALL" -ne 1 ]; then
            fail "install them (brew install$missing; see docs/pc-build-guide.md) and run this again"
        fi
        if [ "$INSTALL_TOOLS" -ne 1 ]; then
            printf 'Install them now with Homebrew (brew install cmake ninja)? [y/N] '
            answer=""
            read -r answer || answer=""
            case "$answer" in
                y | Y | yes | YES) ;;
                *) fail "install them (see docs/pc-build-guide.md for what is needed) and run this again, or run with --install-tools" ;;
            esac
        fi
        if [ -x /opt/homebrew/bin/brew ]; then
            BREW=/opt/homebrew/bin/brew
        elif [ -x /usr/local/bin/brew ]; then
            fail "the Homebrew in /usr/local is the Intel (Rosetta) one and installs x86_64 tools. Install Homebrew for Apple Silicon (it lives in /opt/homebrew, see https://brew.sh) and run this again"
        else
            fail "Homebrew is not installed. Install it for Apple Silicon (https://brew.sh, it lives in /opt/homebrew), or install cmake and ninja by hand, and run this again"
        fi
        PATH="/opt/homebrew/bin:$PATH"
        export PATH
        echo "installing:$missing"
        # shellcheck disable=SC2086 # $missing is a list of tool names
        logged install-tools "$BREW" install $missing
        command -v cmake > /dev/null 2>&1 || fail "cmake is still missing after installing; open a new Terminal window and run this again"
        command -v ninja > /dev/null 2>&1 || fail "ninja is still missing after installing; open a new Terminal window and run this again"
    fi

    cmake_version="$(cmake --version | head -n 1 | sed -n 's/.*version \([0-9][0-9.]*\).*/\1/p')"
    version_ge "$cmake_version" 3.25 || fail "CMake 3.25 or newer is needed (found $cmake_version): brew install cmake"
    python_version="$(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])')"
    version_ge "$python_version" 3.9 || fail "Python 3.9 or newer is needed (found $python_version)"
    has_arm64 cmake || fail "cmake ($(resolve cmake)) has no arm64 slice, it is an Intel build: install the Apple Silicon one (/opt/homebrew)"
    has_arm64 ninja || fail "ninja ($(resolve ninja)) has no arm64 slice, it is an Intel build: install the Apple Silicon one (/opt/homebrew)"
    echo "clang: $cxx_version"
    echo "cmake: $cmake_version, ninja: $(ninja --version), python: $python_version"
}

# Value of a cache entry (KEY:TYPE=value) in a CMakeCache.txt.
cache_value() { sed -n "s/^$2:[A-Z]*=//p" "$1" | head -n 1; }

# Refuse a build folder configured with anything but the pinned toolchain.
# CMake throws the cache away when the compiler changes, which hides what was
# wrong and leaves stale objects of another architecture, so deleting the
# folder is left to the user.
check_build_cache() {
    local dir="$1" cache="$1/CMakeCache.txt" pin key want got
    [ -f "$cache" ] || return 0
    for pin in CMAKE_C_COMPILER=$CC_BIN CMAKE_CXX_COMPILER=$CXX_BIN CMAKE_OSX_ARCHITECTURES=arm64 CMAKE_OSX_DEPLOYMENT_TARGET=13.3; do
        key="${pin%%=*}"
        want="${pin#*=}"
        got="$(cache_value "$cache" "$key")"
        [ "$got" = "$want" ] || fail "$dir was configured with $key='$got', not '$want'. Delete the folder (rm -rf '$dir') and run this again"
    done
}
