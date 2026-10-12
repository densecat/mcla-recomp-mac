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
#   --strict-fp      enable strict floating point for game code (default off)
#   --sdk-only       stop after the SDK is built and installed (step 3)
#   --with-tests     also build the SDK's tests; needs --ppc-bins. Reconfigures
#                    and rebuilds the SDK even when it is already installed
#   --ppc-bins DIR   folder with the assembled PowerPC test binaries (*.bin and
#                    *.map, such as the ppc-test-bins artifact of the CI
#                    workflow). The SDK's own assembler only runs on Linux and
#                    Windows, so the tests cannot assemble them here
#   --jobs N         number of parallel build jobs
set -u
# shellcheck source=mac_common.sh
. "$(dirname "$0")/mac_common.sh"

ISO=""
PLAY=0
PRESET="mac-arm64-release"
STRICT_FP=OFF
SDK_ONLY=0
WITH_TESTS=0
PPC_BINS=""
JOBS=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --iso) [ "$#" -ge 2 ] || fail "--iso needs a path"; ISO="$2"; shift 2 ;;
        --play) PLAY=1; shift ;;
        --install-tools) INSTALL_TOOLS=1; shift ;;
        --preset) [ "$#" -ge 2 ] || fail "--preset needs a name"; PRESET="$2"; shift 2 ;;
        --strict-fp) STRICT_FP=ON; shift ;;
        --sdk-only) SDK_ONLY=1; shift ;;
        --with-tests) WITH_TESTS=1; shift ;;
        --ppc-bins) [ "$#" -ge 2 ] || fail "--ppc-bins needs a folder"; PPC_BINS="$2"; shift 2 ;;
        --jobs) [ "$#" -ge 2 ] || fail "--jobs needs a number"; JOBS="$2"; shift 2 ;;
        *) fail "unknown option: $1 (see the top of scripts/make_mac.sh)" ;;
    esac
done

if [ "$WITH_TESTS" -eq 1 ]; then
    [ -n "$PPC_BINS" ] || fail "--with-tests needs --ppc-bins DIR: the SDK's PowerPC assembler does not run on macOS (see the top of scripts/make_mac.sh)"
    [ -d "$PPC_BINS" ] || fail "no such folder: $PPC_BINS"
    PPC_BINS="$(cd "$PPC_BINS" && pwd)"
    ls "$PPC_BINS"/*.bin > /dev/null 2>&1 || fail "no *.bin files in $PPC_BINS"
    ls "$PPC_BINS"/*.map > /dev/null 2>&1 || fail "no *.map files in $PPC_BINS"
elif [ -n "$PPC_BINS" ]; then
    fail "--ppc-bins is only used together with --with-tests"
fi

cd "$ROOT" || fail "cannot enter $ROOT"

# -----------------------------------------------------------------------
step "1/6 tools"
case "$PRESET" in
    *arm64*) ;;
    *) fail "preset '$PRESET' is not an arm64 preset (the mac-base preset defaults to x86_64); use mac-arm64-release" ;;
esac
ALLOW_BREW_INSTALL=1
preflight_tools

# -----------------------------------------------------------------------
step "2/6 ReXGlue SDK $SDK_TAG with this project's patches"
# The marker holds a hash of the patches, so after a `git pull` that changes
# them the checkout is restored to the release and patched again, and the newer
# marker makes step 3 rebuild. Build trees under out/ are kept.
patches_hash="$(cat "$ROOT/patches/rexglue-v0.10.0-mcla.patch" "$ROOT/patches/rexglue-v0.10.0-metal.patch" "$ROOT/patches/rexglue-ffmpeg-ps5-config.patch" | shasum -a 256 | cut -c1-64)"
if [ -e "$MARKER" ] && [ "$(cat "$MARKER")" != "$patches_hash" ]; then
    echo "the patches changed: restoring $SDK to $SDK_TAG and patching it again"
    logged sdk-unpatch git -C "$SDK" checkout -- .
    logged sdk-unpatch-clean git -C "$SDK" clean -fd -e out/ -e .mcla-patched
    logged sdk-unpatch-ffmpeg git -C "$SDK/thirdparty/FFmpeg" checkout -- .
    logged sdk-unpatch-ffmpeg-clean git -C "$SDK/thirdparty/FFmpeg" clean -fd
    rm -f "$MARKER"
fi
if [ ! -e "$MARKER" ]; then
    if [ ! -e "$SDK/.git" ]; then
        mkdir -p "$ROOT/third_party"
        logged sdk-clone git clone --recursive --branch "$SDK_TAG" https://github.com/rexglue/rexglue-sdk.git "$SDK"
    fi
    [ "$(git -C "$SDK" rev-parse HEAD)" = "$SDK_COMMIT" ] || fail "the SDK checkout is not $SDK_TAG ($SDK_COMMIT)"
    patch_in sdk-patch "$SDK" "$ROOT/patches/rexglue-v0.10.0-mcla.patch"
    patch_in sdk-patch-metal "$SDK" "$ROOT/patches/rexglue-v0.10.0-metal.patch"
    patch_in sdk-patch-ffmpeg "$SDK/thirdparty/FFmpeg" "$ROOT/patches/rexglue-ffmpeg-ps5-config.patch"
    echo "$patches_hash" > "$MARKER"
else
    echo "already patched: $SDK"
fi

# -----------------------------------------------------------------------
step "3/6 build and install the SDK (the long step, once)"
if [ ! -x "$INSTALL/bin/rexglue" ] || [ "$MARKER" -nt "$INSTALL/bin/rexglue" ] || [ "$WITH_TESTS" -eq 1 ]; then
    cd "$SDK" || fail "cannot enter $SDK"
    # Apple's install_name_tool, not whichever is first on PATH: Anaconda's
    # cctools port writes a placeholder signature that does not verify.
    install_name_tool_bin="$(xcrun -f install_name_tool)" || fail "xcrun cannot find install_name_tool"
    configure_args="-DREXGLUE_ENABLE_TRACY=OFF -DCMAKE_OSX_DEPLOYMENT_TARGET=13.3 -DCMAKE_C_COMPILER=$CC_BIN -DCMAKE_CXX_COMPILER=$CXX_BIN -DCMAKE_INSTALL_NAME_TOOL=$install_name_tool_bin"
    if [ "$WITH_TESTS" -eq 1 ]; then configure_args="$configure_args -DREXGLUE_BUILD_TESTS=ON"; fi
    # shellcheck disable=SC2086 # configure_args is a list of -D options without spaces in values
    logged sdk-configure cmake --preset mac-arm64 $configure_args ${PPC_BINS:+"-DREXGLUE_PPC_PREBUILT_DIR=$PPC_BINS"}
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
# Installing rewrites rpaths in place. A file whose signature no longer
# verifies (an older install, or another install_name_tool) would not load
# on arm64, so re-sign any such file.
for f in "$INSTALL"/bin/* "$INSTALL"/lib/*.dylib; do
    if [ ! -f "$f" ] || [ -L "$f" ]; then continue; fi
    if ! file -b "$f" | grep -q '^Mach-O'; then continue; fi
    if codesign -v "$f" > /dev/null 2>&1; then continue; fi
    codesign --force -s - "$f" || fail "could not re-sign $f"
    echo "re-signed after install: $f"
done
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
if [ "$STRICT_FP" = ON ]; then build_args="$build_args --strict-fp"; fi
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
