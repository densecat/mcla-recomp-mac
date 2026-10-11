#!/bin/bash
# Copy build inputs outside the checkout and prepare a no-game link canary.
# Usage: ci_link_stub.sh OUT_DIR SDK_SRC
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: ci_link_stub.sh OUT_DIR SDK_SRC" >&2
    exit 1
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" "$1" <<'PY'
import pathlib
import shutil
import sys

root, out = (pathlib.Path(arg).resolve() for arg in sys.argv[1:])
if out == root or root in out.parents:
    sys.exit("ci_link_stub: OUT_DIR must be outside the repository checkout")
if out.exists() and any(out.iterdir()):
    sys.exit("ci_link_stub: OUT_DIR must be empty")
out.mkdir(parents=True, exist_ok=True)
# Only build inputs: never copy game/, existing generated output or SDK builds.
for name in ("CMakeLists.txt", "CMakePresets.json", "mcla_manifest.toml",
             "generated/rexglue.cmake", "src", "scripts"):
    source, target = root / name, out / name
    if source.is_symlink() or (source.is_dir() and any(p.is_symlink() for p in source.rglob("*"))):
        sys.exit("ci_link_stub: refusing symlink in " + str(source))
    target.parent.mkdir(parents=True, exist_ok=True)
    if source.is_dir():
        shutil.copytree(source, target)
    else:
        shutil.copy2(source, target)
PY
"$ROOT/scripts/ci_host_stub.sh" "$1" "$2"

# A fresh Ninja build has no command history and schedules mcla_codegen even
# with a stamp. Override only its tool, in this copy, using a CMake include hook.
cat > "$1/ci-codegen.cmake" <<'CMAKE'
function(ci_use_synthetic_codegen)
    if(NOT TARGET rex::rexglue)
        message(FATAL_ERROR "CI requires the installed SDK's rex::rexglue target")
    endif()
    set(stub "${CMAKE_SOURCE_DIR}/ci-codegen.sh")
    set_property(TARGET rex::rexglue PROPERTY IMPORTED_LOCATION "${stub}")
    get_target_property(configs rex::rexglue IMPORTED_CONFIGURATIONS)
    foreach(config IN LISTS configs)
        string(TOUPPER "${config}" config)
        set_property(TARGET rex::rexglue PROPERTY "IMPORTED_LOCATION_${config}" "${stub}")
    endforeach()
endfunction()
cmake_language(DEFER CALL ci_use_synthetic_codegen)
CMAKE
cat > "$1/ci-codegen.sh" <<'SH'
#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
if [ "$#" -ne 2 ] || [ "$1" != codegen ] || [ "$2" != "$root/mcla_manifest.toml" ]; then
    echo "CI codegen: unexpected invocation" >&2
    exit 1
fi
for file in mcla_init.cpp mcla_register.cpp mcla_ci_stubs.cpp; do
    grep -q '^// Synthetic, no game data, CI only\.$' "$root/generated/default/$file"
done
touch "$root/generated/default/codegen.build.stamp"
echo "CI codegen: synthetic sources already rendered; real codegen skipped"
SH
chmod +x "$1/ci-codegen.sh"
echo "Synthetic project copy: $1"
