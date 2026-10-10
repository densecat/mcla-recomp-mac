#!/bin/bash
# One command from your own disc image to the game running on an Apple Silicon Mac.
#
#   ./scripts/make_mac.sh --iso /path/to/your.iso
#
# Needs an Apple Silicon Mac (macOS 13.3 or newer), Xcode 16 or newer (or its
# command line tools), Git, CMake, Ninja and Python 3. CMake and Ninja are
# installed with Homebrew (in /opt/homebrew) if you let it.
# Everything is built on your machine from your own copy of the game: nothing
# of the game is in this repository, and what this builds is not for sharing.
#
# Each step is skipped when its result is already there, so after a failure,
# or after `git pull`, run the same command again and it continues.
#
#   --iso PATH       your disc image (Midnight Club: Los Angeles Complete
#                    Edition, USA/Europe, Xbox 360). Not needed once game/ is
#                    extracted.
#   --play           start the game when the build is done
#   --install-tools  install missing CMake and Ninja without asking first
#   --preset NAME    CMake preset of the game build (default mac-arm64-release)
#   --sdk-only       stop after the SDK is built and installed (step 3)
#   --with-tests     also build the SDK's tests
#   --jobs N         number of parallel build jobs
set -u
# shellcheck source=mac_common.sh
. "$(dirname "$0")/mac_common.sh"

ISO=""
PLAY=0
INSTALL_TOOLS=0
PRESET="mac-arm64-release"
SDK_ONLY=0
WITH_TESTS=0
JOBS=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --iso) [ "$#" -ge 2 ] || fail "--iso needs a path"; ISO="$2"; shift 2 ;;
        --play) PLAY=1; shift ;;
        --install-tools) INSTALL_TOOLS=1; shift ;;
        --preset) [ "$#" -ge 2 ] || fail "--preset needs a name"; PRESET="$2"; shift 2 ;;
        --sdk-only) SDK_ONLY=1; shift ;;
        --with-tests) WITH_TESTS=1; shift ;;
        --jobs) [ "$#" -ge 2 ] || fail "--jobs needs a number"; JOBS="$2"; shift 2 ;;
        *) fail "unknown option: $1 (see the top of scripts/make_mac.sh)" ;;
    esac
done

cd "$ROOT" || fail "cannot enter $ROOT"

# Major version of "x.y.z" style text.
major_of() { echo "${1%%.*}"; }
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

# -----------------------------------------------------------------------
step "1/6 tools"
case "$PRESET" in
    *arm64*) ;;
    *) fail "preset '$PRESET' is not an arm64 preset (the mac-base preset defaults to x86_64); use mac-arm64-release" ;;
esac
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

# -----------------------------------------------------------------------
step "2/6 ReXGlue SDK $SDK_TAG with this project's patches"
if [ ! -e "$MARKER" ]; then
    if [ ! -e "$SDK/.git" ]; then
        mkdir -p "$ROOT/third_party"
        logged sdk-clone git clone --recursive --branch "$SDK_TAG" https://github.com/rexglue/rexglue-sdk.git "$SDK"
    fi
    [ "$(git -C "$SDK" rev-parse HEAD)" = "$SDK_COMMIT" ] || fail "the SDK checkout is not $SDK_TAG ($SDK_COMMIT)"
    patch_in sdk-patch "$SDK" "$ROOT/patches/rexglue-v0.10.0-mcla.patch"
    patch_in sdk-patch-ffmpeg "$SDK/thirdparty/FFmpeg" "$ROOT/patches/rexglue-ffmpeg-ps5-config.patch"
    touch "$MARKER"
else
    echo "already patched: $SDK"
fi

# -----------------------------------------------------------------------
step "3/6 build and install the SDK (the long step, once)"
if [ ! -x "$INSTALL/bin/rexglue" ] || [ "$MARKER" -nt "$INSTALL/bin/rexglue" ]; then
    cd "$SDK" || fail "cannot enter $SDK"
    configure_args="-DREXGLUE_ENABLE_TRACY=OFF -DCMAKE_OSX_DEPLOYMENT_TARGET=13.3 -DCMAKE_C_COMPILER=$CC_BIN -DCMAKE_CXX_COMPILER=$CXX_BIN"
    if [ "$WITH_TESTS" -eq 1 ]; then configure_args="$configure_args -DREXGLUE_BUILD_TESTS=ON"; fi
    # shellcheck disable=SC2086 # configure_args is a list of -D options without spaces in values
    logged sdk-configure cmake --preset mac-arm64 $configure_args
    # CMake does not cache the host processor; it writes it to CMakeSystem.cmake.
    system_file=""
    for f in out/build/mac-arm64/CMakeFiles/*/CMakeSystem.cmake; do
        if [ -f "$f" ]; then system_file="$f"; break; fi
    done
    [ -n "$system_file" ] || fail "the SDK configure wrote no CMakeSystem.cmake (log: $LOGS/sdk-configure.log)"
    host_cpu="$(sed -n 's/^set(CMAKE_HOST_SYSTEM_PROCESSOR "\(.*\)")$/\1/p' "$system_file" | head -n 1)"
    [ "$host_cpu" = "arm64" ] || fail "CMake saw the host as '$host_cpu', not arm64: it (or the shell) runs under Rosetta. Use a native Terminal and an Apple Silicon CMake, delete $SDK/out/build/mac-arm64 and run this again"
    jobs_args=""
    if [ -n "$JOBS" ]; then jobs_args="--parallel $JOBS"; fi
    # shellcheck disable=SC2086 # jobs_args is empty or "--parallel N"
    logged sdk-build cmake --build out/build/mac-arm64 --config Release $jobs_args
    logged sdk-install cmake --install out/build/mac-arm64 --config Release
    cd "$ROOT" || fail "cannot enter $ROOT"
else
    echo "already installed: $INSTALL"
fi
[ -x "$INSTALL/bin/rexglue" ] || fail "the SDK was not installed"
"$MAC_SCRIPTS/check_arm64.sh" "$INSTALL" || fail "the installed SDK failed the arm64 check"
if [ "$SDK_ONLY" -eq 1 ]; then
    echo ""
    echo "SDK built and installed: $INSTALL"
    exit 0
fi

# -----------------------------------------------------------------------
step "4/6 your game: extract from the disc image"
if [ ! -e "$ROOT/game/default.xex" ]; then
    [ -n "$ISO" ] || fail "game/ is empty: give your disc image with --iso"
    [ -f "$ISO" ] || fail "no such file: $ISO"
    logged extract python3 "$MAC_SCRIPTS/extract_game.py" "$ISO" "$ROOT/game"
else
    echo "already extracted: $ROOT/game"
fi
[ -e "$ROOT/game/default.xex" ] || fail "game/default.xex is missing after extraction"

# -----------------------------------------------------------------------
step "5/6 recompile the game's code and build it (several minutes the first time)"
build_args="--preset $PRESET"
if [ -n "$JOBS" ]; then build_args="$build_args --jobs $JOBS"; fi
# shellcheck disable=SC2086 # build_args is a list of options without spaces in values
"$MAC_SCRIPTS/build_mac.sh" $build_args || fail "build_mac.sh failed"
BUILD="$ROOT/out/build/$PRESET"
[ -x "$BUILD/mcla" ] || fail "mcla was not built (log: $ROOT/out/build.log)"

# -----------------------------------------------------------------------
step "6/6 done"
# A launcher in the repository folder, so that playing is a double-click.
# mcla finds the game folder and its graphics plugin by itself.
LAUNCHER="$ROOT/Midnight Club Los Angeles.command"
{
    echo '#!/bin/bash'
    printf 'cd "%s" || exit 1\n' "$BUILD"
    echo 'exec ./mcla "$@"'
} > "$LAUNCHER"
chmod +x "$LAUNCHER"
echo "game:     $BUILD/mcla"
echo "launcher: $LAUNCHER"
echo "To play, double-click the launcher (or run it in Terminal)."
if [ "$PLAY" -eq 1 ]; then
    cd "$BUILD" && exec ./mcla
fi
