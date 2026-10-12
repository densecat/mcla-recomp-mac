#!/bin/bash
# Check that every Mach-O file under the given folders (or the given files) is
# arm64 only, code-signed, and depends only on the system or on files inside
# the checked folders, found the way the loader finds them.
# Executables are checked first: their dependencies are followed through
# @executable_path, @loader_path and the LC_RPATH entries each image brings
# plus those it inherits from the images that loaded it. A file no executable
# reaches (a dylib that is dlopened, or checked alone) is checked standalone,
# as if the first executable dlopened it. Prints a table and exits 1
# on any failure.
#   ./scripts/check_arm64.sh <dir|file>...
set -u

if [ "$#" -eq 0 ]; then
    echo "usage: $0 <dir|file>..." >&2
    exit 2
fi

TAB="$(printf '\t')"
bad=0
count=0
standalone=0
roots=""     # canonical checked folders and files, one per line
info=""      # per Mach-O file: path, archs, signed (tab separated)
fails=""     # per canonical image: path, first dependency problem (tab separated)
reached=""   # canonical images some executable reaches
visited=""   # canonical images walked from the current executable

# Absolute path with every symlink followed, for a file or a folder. Empty if
# it does not exist. No readlink -f or realpath: macOS lacks them before 12.3.
canon() {
    local p="$1" t
    while [ -L "$p" ]; do
        t="$(readlink "$p")"
        case "$t" in /*) p="$t" ;; *) p="$(dirname "$p")/$t" ;; esac
    done
    if [ -d "$p" ]; then
        (cd "$p" 2> /dev/null && pwd -P)
    else
        (cd "$(dirname "$p")" 2> /dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$p")")
    fi
}

# True when the canonical path $1 is a checked file or inside a checked folder.
in_roots() {
    local r
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        case "$1" in "$r" | "$r"/*) return 0 ;; esac
    done <<EOF
$roots
EOF
    return 1
}

is_executable() { otool -hv "$1" 2> /dev/null | grep -q ' EXECUTE '; }

# The LC_RPATH entries of $1, with @loader_path replaced by $2 and
# @executable_path by $3, one per line. An absolute entry is marked with a
# leading "!": it ties the app to one location, so a hit through it fails.
image_rpaths() {
    local rp
    otool -l "$1" 2> /dev/null |
        awk '/^ *cmd LC_RPATH/ { r = 1; next } r && /^ *path / { sub(/^ *path /, ""); sub(/ \(offset [0-9]+\)$/, ""); print; r = 0 }' |
        while IFS= read -r rp; do
            case "$rp" in @*) ;; *) rp="!$rp" ;; esac
            rp="${rp//@loader_path/$2}"
            rp="${rp//@executable_path/$3}"
            printf '%s\n' "$rp"
        done
}

# The dependencies of $1 other than system libraries, one per line. Line 1 of
# otool -L is the file name; a dylib's first dependency line is its own install
# name.
image_deps() {
    local skip=1 n=0 dep
    case "$(file -b "$1")" in *"dynamically linked shared library"*) skip=2 ;; esac
    otool -L "$1" 2> /dev/null | while IFS= read -r dep; do
        n=$((n + 1))
        [ "$n" -gt "$skip" ] || continue
        dep="${dep#"${dep%%[![:space:]]*}"}"
        dep="${dep%% (*}"
        case "$dep" in
            /usr/lib/* | /System/*) ;;
            *) printf '%s\n' "$dep" ;;
        esac
    done
}

# Prints the canonical path of the file $1 if it exists inside the checked roots.
inside() {
    local c
    [ -e "$1" ] || return 1
    c="$(canon "$1")"
    [ -n "$c" ] && in_roots "$c" || return 1
    printf '%s\n' "$c"
}

# Prints where the dependency $1 resolves to inside the checked roots, or fails.
# $2 is the folder of the loading image, $3 the folder of the executable (empty
# if unknown), $4 the rpath list (one per line, already substituted). Like dyld,
# the first rpath with an existing candidate decides: it must lie inside the
# roots and come from a relative (@-prefixed) rpath.
resolve_dep() {
    local rp res
    case "$1" in
        @loader_path/*) inside "$2/${1#@loader_path/}" ;;
        @executable_path/*) [ -n "$3" ] && inside "$3/${1#@executable_path/}" ;;
        @rpath/*)
            while IFS= read -r rp; do
                [ -n "$rp" ] || continue
                case "$rp" in
                    !*) [ -e "${rp#!}/${1#@rpath/}" ] && return 1 ;;
                    *)
                        if [ -e "$rp/${1#@rpath/}" ]; then
                            inside "$rp/${1#@rpath/}"
                            return
                        fi ;;
                esac
            done <<EOF
$4
EOF
            return 1 ;;
        *) return 1 ;;
    esac
}

add_fail() { fails="$fails$1$TAB$2
"; bad=1; }

# Follow the dependencies of the canonical image $1 for the executable in folder
# $2; $3 is the rpath list the images above it contribute.
walk() {
    local img="$1" exe_dir="$2" loader stack dep res
    loader="$(dirname "$img")"
    stack="$(image_rpaths "$img" "$loader" "$exe_dir")
$3"
    visited="$visited$img
"
    reached="$reached$img
"
    while IFS= read -r dep; do
        [ -n "$dep" ] || continue
        case "$dep" in
            @rpath/* | @loader_path/* | @executable_path/*)
                if res="$(resolve_dep "$dep" "$loader" "$exe_dir" "$stack")"; then
                    if ! printf '%s' "$visited" | grep -qxF -- "$res" && file -b "$res" | grep -q '^Mach-O'; then
                        walk "$res" "$exe_dir" "$stack"
                    fi
                else
                    add_fail "$img" "unresolved $dep"
                fi ;;
            *) add_fail "$img" "$dep" ;;
        esac
    done <<EOF
$(image_deps "$img")
EOF
}

# A file no executable links to. With an executable among the checked files it
# is taken to be dlopened by the first one: @executable_path is that folder and
# the executable's rpaths follow its own. Without one, its own folder stands in.
check_standalone() {
    local img="$1" loader exe_dir stack dep
    loader="$(dirname "$img")"
    if [ -n "$first_exe" ]; then
        exe_dir="$(dirname "$first_exe")"
        stack="$(image_rpaths "$img" "$loader" "$exe_dir")
$(image_rpaths "$first_exe" "$exe_dir" "$exe_dir")"
    else
        exe_dir="$loader"
        stack="$(image_rpaths "$img" "$loader" "$exe_dir")"
    fi
    while IFS= read -r dep; do
        [ -n "$dep" ] || continue
        case "$dep" in
            @rpath/* | @loader_path/* | @executable_path/*)
                resolve_dep "$dep" "$loader" "$exe_dir" "$stack" > /dev/null || add_fail "$img" "unresolved $dep" ;;
            *) add_fail "$img" "$dep" ;;
        esac
    done <<EOF
$(image_deps "$img")
EOF
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
    roots="$roots$(canon "$arg")
"
done

# Architecture and signature of every Mach-O file.
files=""
while IFS= read -r f; do
    case "$(file -b "$f")" in
        Mach-O*) ;;
        *) continue ;;
    esac
    archs="$(lipo -archs "$f" 2> /dev/null)"
    [ "$archs" = "arm64" ] || bad=1
    if codesign -v "$f" > /dev/null 2>&1; then signed=yes; else signed=NO; bad=1; fi
    count=$((count + 1))
    files="$files$f
"
    info="$info$f$TAB${archs:-?}$TAB$signed
"
done < <(list_files "$@")

# Dependencies: from each executable, then the rest on their own.
have_exe=0
first_exe=""
while IFS= read -r f; do
    [ -n "$f" ] || continue
    if is_executable "$f"; then
        have_exe=1
        [ -n "$first_exe" ] || first_exe="$(canon "$f")"
    fi
done <<EOF
$files
EOF
if [ "$have_exe" -eq 1 ]; then
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if is_executable "$f"; then
            c="$(canon "$f")"
            visited=""
            walk "$c" "$(dirname "$c")" ""
        fi
    done <<EOF
$files
EOF
fi
alone=""
while IFS= read -r f; do
    [ -n "$f" ] || continue
    c="$(canon "$f")"
    if ! printf '%s' "$reached" | grep -qxF -- "$c"; then
        standalone=$((standalone + 1))
        alone="$alone$c
"
        check_standalone "$c"
    fi
done <<EOF
$files
EOF

echo "file | archs | signed | deps ok"
while IFS="$TAB" read -r f archs signed; do
    [ -n "$f" ] || continue
    c="$(canon "$f")"
    deps_ok="$(printf '%s' "$fails" | awk -F"$TAB" -v p="$c" '$1 == p { print "NO (" $2 ")"; exit }')"
    if [ -z "$deps_ok" ]; then
        deps_ok=yes
        if printf '%s' "$alone" | grep -qxF -- "$c"; then deps_ok="yes (standalone)"; fi
    fi
    echo "$f | $archs | $signed | $deps_ok"
done <<EOF
$info
EOF
echo "$count Mach-O file(s) checked"
if [ "$standalone" -gt 0 ] && [ "$have_exe" -eq 1 ]; then
    echo "$standalone file(s) no executable links to were checked standalone (as if dlopened by $first_exe)"
fi
if [ "$count" -eq 0 ]; then
    echo "FAILED: no Mach-O files found" >&2
    exit 1
fi
if [ "$bad" -ne 0 ]; then
    echo "FAILED: not arm64 only, unsigned, or depending on files outside the app" >&2
    exit 1
fi
echo "all arm64, signed, self-contained"
