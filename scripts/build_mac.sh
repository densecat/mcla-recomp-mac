#!/bin/bash
# Regenerate code from the user's XEX and build.
#   ./scripts/build_mac.sh [--preset mac-arm64-release] [--jobs N] [--strict-fp]
# --strict-fp enables strict floating point for game code (default off).
set -u
# shellcheck source=mac_common.sh
. "$(dirname "$0")/mac_common.sh"

PRESET="mac-arm64-release"
JOBS=""
STRICT_FP=OFF
while [ "$#" -gt 0 ]; do
    case "$1" in
        --preset) [ "$#" -ge 2 ] || fail "--preset needs a name"; PRESET="$2"; shift 2 ;;
        --jobs) [ "$#" -ge 2 ] || fail "--jobs needs a number"; JOBS="$2"; shift 2 ;;
        --strict-fp) STRICT_FP=ON; shift ;;
        *) fail "unknown option: $1 (usage: build_mac.sh [--preset NAME] [--jobs N] [--strict-fp])" ;;
    esac
done
case "$PRESET" in *arm64*) ;; *) fail "preset '$PRESET' is not an arm64 preset" ;; esac

cd "$ROOT" || fail "cannot enter $ROOT"
mkdir -p "$ROOT/out"
preflight_tools
[ -x "$INSTALL/bin/rexglue" ] || fail "the SDK is not installed ($INSTALL/bin/rexglue); run scripts/make_mac.sh --sdk-only"

# The codegen stamp does not cover the rexglue binary, so a rebuilt or
# re-patched SDK needs --ignore-stamp.
STAMP="$ROOT/out/.codegen-sdk-stamp"
CODEGEN_ARGS=""
if [ ! -e "$STAMP" ] || [ "$MARKER" -nt "$STAMP" ] || [ "$INSTALL/bin/rexglue" -nt "$STAMP" ]; then
    CODEGEN_ARGS="--ignore-stamp"
fi
# shellcheck disable=SC2086 # CODEGEN_ARGS is empty or one flag
if ! "$INSTALL/bin/rexglue" codegen $CODEGEN_ARGS mcla_manifest.toml > "$ROOT/out/codegen.log" 2>&1; then
    tail -n 20 "$ROOT/out/codegen.log"
    fail "codegen failed (log: $ROOT/out/codegen.log)"
fi
touch "$STAMP"
grep "Codegen summary" "$ROOT/out/codegen.log"
unimpl=0
for f in "$ROOT"/generated/default/*.cpp; do
    [ -f "$f" ] || continue
    n="$(grep -c UNIMPLEMENTED "$f")"
    unimpl=$((unimpl + n))
done
echo "UNIMPLEMENTED in generated code: $unimpl"

# An existing build folder must carry the pins; strict FP can change in place.
check_build_cache "$ROOT/out/build/$PRESET"
if [ ! -f "$ROOT/out/build/$PRESET/build.ninja" ]; then
    if ! cmake --preset "$PRESET" "-DCMAKE_PREFIX_PATH=$INSTALL" \
        "-DCMAKE_C_COMPILER=$CC_BIN" "-DCMAKE_CXX_COMPILER=$CXX_BIN" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=13.3 \
        "-DMCLA_STRICT_FP=$STRICT_FP" > "$ROOT/out/configure.log" 2>&1; then
        tail -n 20 "$ROOT/out/configure.log"
        fail "configure failed (log: $ROOT/out/configure.log)"
    fi
elif [ "$(cache_value "$ROOT/out/build/$PRESET/CMakeCache.txt" MCLA_STRICT_FP)" != "$STRICT_FP" ]; then
    if ! cmake -S . -B "$ROOT/out/build/$PRESET" "-DMCLA_STRICT_FP=$STRICT_FP" > "$ROOT/out/configure.log" 2>&1; then
        tail -n 20 "$ROOT/out/configure.log"
        fail "configure failed (log: $ROOT/out/configure.log)"
    fi
fi
BUILD_ARGS=""
if [ -n "$JOBS" ]; then BUILD_ARGS="--parallel $JOBS"; fi
# shellcheck disable=SC2086 # BUILD_ARGS is empty or "--parallel N"
if ! cmake --build --preset "$PRESET" $BUILD_ARGS > "$ROOT/out/build.log" 2>&1; then
    grep -E 'error:|FAILED:' "$ROOT/out/build.log" | head -n 30
    fail "build failed (log: $ROOT/out/build.log)"
fi
tail -n 1 "$ROOT/out/build.log"

BUILD="$ROOT/out/build/$PRESET"
[ -x "$BUILD/mcla" ] || fail "mcla was not built (log: $ROOT/out/build.log)"

# The graphics plugin is loaded next to the executable.
PLUGIN="$(find "$INSTALL/lib" -name 'librexgpu-xenos.dylib' 2> /dev/null | head -n 1)"
[ -n "$PLUGIN" ] || fail "librexgpu-xenos.dylib not found under $INSTALL/lib"
cp -f "$PLUGIN" "$BUILD/" || fail "could not copy $PLUGIN"

# The SDK stages these next to the executable after the link. That step does
# not rerun without a relink, so a file that went missing is copied again from
# the SDK install, where the same files are installed (lib/ and share/).
for rel in librexruntime.dylib vulkan/lib/libvulkan.1.dylib vulkan/lib/libMoltenVK.dylib vulkan/share/vulkan/icd.d/MoltenVK_icd.json; do
    [ -e "$BUILD/$rel" ] && continue
    case "$rel" in
        librexruntime.dylib) src="$INSTALL/lib/librexruntime.dylib" ;;
        vulkan/lib/*) src="$INSTALL/lib/${rel##*/}" ;;
        *) src="$INSTALL/share/vulkan/icd.d/${rel##*/}" ;;
    esac
    [ -e "$src" ] || fail "$rel is missing next to mcla and $src is not there either: run scripts/make_mac.sh --sdk-only again, or delete $BUILD and run this again"
    mkdir -p "$BUILD/$(dirname "$rel")"
    cp -f "$src" "$BUILD/$rel" || fail "could not copy $src to $BUILD/$rel"
    echo "staged again from the SDK install: $rel"
done

"$MAC_SCRIPTS/check_arm64.sh" "$BUILD" || fail "the build folder failed the arm64 check"
