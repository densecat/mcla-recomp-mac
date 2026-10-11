#!/bin/bash
# Check that every Mach-O file under the given folders (or the given files) is
# arm64 only, code-signed, and depends only on the system or on files that
# really resolve through its own @loader_path, @executable_path or LC_RPATH
# entries. Prints a table and exits 1 on any failure.
#   ./scripts/check_arm64.sh <dir|file>...
set -u

if [ "$#" -eq 0 ]; then
    echo "usage: $0 <dir|file>..." >&2
    exit 2
fi

bad=0
count=0
rows=""

# True when the @rpath/@loader_path/@executable_path dependency $1 names a file
# that exists. $dir, $exe_dir and $rpaths are set by check_one. The executable
# is not known for a dylib checked on its own, so its folder stands in.
dep_resolves() {
    local dep="$1" rp
    case "$dep" in
        @loader_path/*) [ -e "$dir/${dep#@loader_path/}" ] ;;
        @executable_path/*) [ -e "$exe_dir/${dep#@executable_path/}" ] ;;
        @rpath/*)
            while IFS= read -r rp; do
                [ -n "$rp" ] || continue
                rp="${rp//@loader_path/$dir}"
                rp="${rp//@executable_path/$exe_dir}"
                [ -e "$rp/${dep#@rpath/}" ] && return 0
            done <<EOF
$rpaths
EOF
            return 1 ;;
        *) return 1 ;;
    esac
}

check_one() {
    local f="$1" archs signed deps_ok kind skip dep first dir exe_dir rpaths
    dir="$(dirname "$f")"
    exe_dir="$dir"
    rpaths="$(otool -l "$f" 2> /dev/null | awk '/^ *cmd LC_RPATH/ { r = 1; next } r && /^ *path / { sub(/^ *path /, ""); sub(/ \(offset [0-9]+\)$/, ""); print; r = 0 }')"
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
            /usr/lib/* | /System/*) ;;
            @rpath/* | @loader_path/* | @executable_path/*)
                # Has to ship with it: the file must exist where the loader looks.
                dep_resolves "$dep" || { deps_ok="NO (unresolved $dep)"; bad=1; } ;;
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
