#!/bin/bash
# Package an existing macOS build. No game data is copied into the bundle.
#   ./scripts/make_app_mac.sh [--preset mac-arm64-release]
set -u
# shellcheck source=mac_common.sh
. "$(dirname "$0")/mac_common.sh"

PRESET="mac-arm64-release"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --preset) [ "$#" -ge 2 ] || fail "--preset needs a name"; PRESET="$2"; shift 2 ;;
        *) fail "unknown option: $1 (usage: make_app_mac.sh [--preset NAME])" ;;
    esac
done
case "$PRESET" in *arm64*) ;; *) fail "preset '$PRESET' is not an arm64 preset" ;; esac

[ "$(uname -s)" = "Darwin" ] || fail "packaging needs macOS (codesign and otool)"
[ "$(uname -m)" = "arm64" ] || fail "packaging needs a native Apple Silicon shell"
translated="$(sysctl -n sysctl.proc_translated 2> /dev/null || echo 0)"
[ "$translated" = "0" ] || fail "this shell runs under Rosetta; open a native Terminal and run this again"
for tool in codesign otool lipo file python3; do
    command -v "$tool" > /dev/null 2>&1 || fail "$tool is missing; install the Xcode command line tools"
done

BUILD="$ROOT/out/build/$PRESET"
APP="$ROOT/MCLA.app"
MACOS="$APP/Contents/MacOS"
RESOURCES="$APP/Contents/Resources"
[ -x "$BUILD/mcla" ] || fail "$BUILD/mcla is missing; run scripts/build_mac.sh --preset $PRESET first"
RUNTIME_FILES=(
    vulkan/lib/libMoltenVK.dylib
    vulkan/lib/libvulkan.1.dylib
    librexruntime.dylib
    librexgpu-xenos.dylib
)
ICD="vulkan/share/vulkan/icd.d/MoltenVK_icd.json"
for rel in "${RUNTIME_FILES[@]}" "$ICD"; do
    [ -f "$BUILD/$rel" ] || fail "$BUILD/$rel is missing; run scripts/build_mac.sh --preset $PRESET again"
done

step "assemble MCLA.app"
[ ! -L "$APP" ] || fail "$APP is a symlink; move it aside before packaging"
rm -rf "$APP" || fail "could not remove the previous $APP"
mkdir -p "$MACOS" "$RESOURCES" || fail "could not create the bundle folders"
cp -f "$BUILD/mcla" "$MACOS/mcla" || fail "could not copy mcla"
for rel in "${RUNTIME_FILES[@]}"; do
    mkdir -p "$MACOS/$(dirname "$rel")" || fail "could not create the folder for $rel"
    cp -f "$BUILD/$rel" "$MACOS/$rel" || fail "could not copy $rel"
done

# Dotted directories under MacOS are treated as nested bundles by codesign.
# The host selects this resource before Vulkan starts; dylib lookup is unchanged.
python3 - "$BUILD/$ICD" "$RESOURCES/MoltenVK_icd.json" <<'PY' || fail "could not relocate the Vulkan ICD"
import json
import sys

with open(sys.argv[1]) as source:
    manifest = json.load(source)
manifest["ICD"]["library_path"] = "../MacOS/vulkan/lib/libMoltenVK.dylib"
with open(sys.argv[2], "w") as target:
    json.dump(manifest, target, indent=4)
    target.write("\n")
PY

cat > "$APP/Contents/Info.plist" <<'EOF' || fail "could not write Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>mcla</string>
    <key>CFBundleIdentifier</key>
    <string>local.mcla.recomp</string>
    <key>CFBundleName</key>
    <string>MCLA</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.3</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.racing-games</string>
</dict>
</plist>
EOF

# The patched SDK links mcla with this rpath; the final check follows every
# dylib dependency with otool and rejects paths outside the bundle or system.
otool -l "$MACOS/mcla" |
    awk '/^ *cmd LC_RPATH/ { r = 1; next } r && /^ *path / { sub(/^ *path /, ""); sub(/ \(offset [0-9]+\)$/, ""); print; r = 0 }' |
    grep -qx '@executable_path' || fail "mcla has no @executable_path rpath; rebuild with the patched SDK"

step "ad-hoc sign and verify"
for rel in "${RUNTIME_FILES[@]}"; do
    case "$rel" in
        *.dylib) codesign --force -s - "$MACOS/$rel" || fail "could not sign $rel" ;;
    esac
done
codesign --force -s - "$MACOS/mcla" || fail "could not sign mcla"
codesign --force -s - "$APP" || fail "could not sign MCLA.app"
codesign --verify --strict --verbose=2 "$APP" || fail "MCLA.app failed signature verification"
"$MAC_SCRIPTS/check_arm64.sh" "$APP" || fail "MCLA.app failed the arm64 check"

echo "app: $APP"
echo "Keep MCLA.app in the repository folder so it can find game/. Double-click it to play."
