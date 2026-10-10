#!/bin/bash
# Check that every Mach-O file under the given folders (or the given files) is
# arm64 only, code-signed, and depends only on the system or on files that ship
# next to it. Prints a table and exits 1 on any failure.
#   ./scripts/check_arm64.sh <dir|file>...
set -u

if [ "$#" -eq 0 ]; then
    echo "usage: $0 <dir|file>..." >&2
    exit 2
fi

bad=0
count=0
rows=""

check_one() {
    local f="$1" archs signed deps_ok kind skip dep first
    archs="$(lipo -archs "$f" 2> /dev/null)"
    [ "$archs" = "arm64" ] || bad=1
    if codesign -v "$f" > /dev/null 2>&1; then signed=yes; else signed=NO; bad=1; fi
    deps_ok=yes
    kind="$(file -b "$f")"
    # Line 1 of otool -L is the file name; a dylib's first dependency line is
    # its own install name.
    skip=1
    case "$kind" in *"dynamically linked shared library"*) skip=2 ;; esac
    first=1
    while IFS= read -r dep; do
        if [ "$first" -le "$skip" ]; then
            first=$((first + 1))
            continue
        fi
        dep="${dep#"${dep%%[![:space:]]*}"}"
        dep="${dep%% (*}"
        case "$dep" in
            /usr/lib/* | /System/* | @rpath/* | @loader_path/* | @executable_path/*) ;;
            *) deps_ok="NO ($dep)"; bad=1 ;;
        esac
    done < <(otool -L "$f" 2> /dev/null)
    count=$((count + 1))
    rows="$rows$f | ${archs:-?} | $signed | $deps_ok
"
}

list_files() {
    local arg
    for arg in "$@"; do
        if [ -d "$arg" ]; then
            find "$arg" -type f -not -name '*.o' -not -path '*/CMakeFiles/*'
        elif [ -f "$arg" ]; then
            echo "$arg"
        fi
    done
}

# list_files runs in a subshell, so unknown arguments are rejected here.
for arg in "$@"; do
    [ -e "$arg" ] || { echo "no such file or folder: $arg" >&2; exit 1; }
done

while IFS= read -r f; do
    case "$(file -b "$f")" in
        Mach-O*) check_one "$f" ;;
    esac
done < <(list_files "$@")

echo "file | archs | signed | deps ok"
printf '%s' "$rows"
echo "$count Mach-O file(s) checked"
if [ "$count" -eq 0 ]; then
    echo "FAILED: no Mach-O files found" >&2
    exit 1
fi
if [ "$bad" -ne 0 ]; then
    echo "FAILED: not arm64 only, unsigned, or depending on files outside the app" >&2
    exit 1
fi
echo "all arm64, signed, self-contained"
