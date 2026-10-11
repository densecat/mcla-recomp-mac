#!/bin/bash
# Synthetic generated sources, no game data, CI only.
# Usage: ci_host_stub.sh OUT_DIR SDK_SRC
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: ci_host_stub.sh OUT_DIR SDK_SRC" >&2
    exit 1
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

python3 - "$ROOT" "$1" "$2" <<'PY'
import pathlib
import re
import subprocess
import sys

root, out, sdk = (pathlib.Path(arg).resolve() for arg in sys.argv[1:])
if out == root or root in out.parents:
    sys.exit("ci_host_stub: OUT_DIR must be outside the repository checkout")
generated = (out / "generated/default").resolve()
if root in generated.parents:
    sys.exit("ci_host_stub: generated headers must stay outside the repository checkout")
if generated.exists():
    sys.exit("ci_host_stub: refusing to overwrite an existing generated/default directory")
templates = sdk / "resources/templates"

# Grep identifiers from src/ only, excluding comments and string/character
# literals. Names used through the runtime's address lookup need no declaration.
sources = sorted(p for p in (root / "src").rglob("*") if p.suffix in (".cpp", ".h"))
if not sources:
    sys.exit("ci_host_stub: no host sources found")
non_code = re.compile(
    r'//[^\n]*|/\*.*?\*/|R"([^ ()\\\t\r\n]{0,16})\(.*?\)\1"'
    r'|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\\n])\'',
    re.DOTALL,
)
source = "\n".join(non_code.sub(" ", p.read_text()) for p in sources)
matches = subprocess.run(
    ["grep", "-Eow", r"(__imp__)?sub_[[:xdigit:]]{8}"],
    input=source, text=True, capture_output=True,
)
if matches.returncode not in (0, 1):
    sys.exit("ci_host_stub: guest-symbol grep failed: " + matches.stderr)
# DECLARE_REX_FUNC declares both the hook and its __imp__ entry point.
symbols = sorted({name.removeprefix("__imp__") for name in matches.stdout.split()})

# Render only the templates' empty-project branches. Keep their fixed
# text verbatim, including the indirect-call include and platform macros.
# Unknown template syntax must fail rather than silently weaken the canary.
values = dict.fromkeys(
    ("image_base", "image_size", "code_base", "code_size", "thunk_reserve_size"), "0"
)
values["project"] = "mcla"
flags = (
    "skip_lr", "ctr_as_local", "xer_as_local", "reserved_as_local", "skip_msr",
    "cr_as_local", "non_argument_as_local", "non_volatile_as_local",
)
for flag in flags:
    values["config_flags." + flag] = "false"
values['cmake_var("CMAKE_CURRENT_LIST_DIR")'] = "${CMAKE_CURRENT_LIST_DIR}"


def render(name):
    text = (templates / "codegen" / name).read_text()
    text = text.replace(
        '{% include "codegen/_indirect_call.inja" %}',
        (templates / "codegen/_indirect_call.inja").read_text(),
    )
    text = re.sub(
        r"{% if config_flags\.[a-z_]+ %}#define REX_CONFIG_[A-Z_]+\n{% endif %}", "", text
    )
    text = text.replace("{% if rexcrt_heap %}1{% else %}0{% endif %}", "0")
    text = re.sub(
        r"{% if has_dll_modules and not is_dll %}.*?{% endif %}", "", text,
        flags=re.DOTALL,
    )
    text = re.sub(
        r"{% if is_dll %}.*?{% else %}(.*?){% endif %}", r"\1", text,
        flags=re.DOTALL,
    )
    text = re.sub(r"{% if is_dll %}.*?{% endif %}", "", text, flags=re.DOTALL)
    text = re.sub(
        r"{% for fn in functions %}(.*?){% endfor %}",
        # Declarations for host references, but no guest address mappings.
        lambda m: "".join(m[1].replace("{{ fn.name }}", symbol) for symbol in symbols)
        if name == "funcs_h.inja" else "",
        text, flags=re.DOTALL,
    )
    text = re.sub(
        r"{% for file in recomp_files %}(.*?){% endfor %}",
        lambda m: m[1].replace("{{ file }}", "mcla_ci_stubs.cpp"),
        text, flags=re.DOTALL,
    )
    for key, value in values.items():
        text = text.replace("{{ " + key + " }}", value)
    if any(token in text for token in ("{%", "{{", "{#")):
        sys.exit("ci_host_stub: unsupported template syntax in " + name)
    prefix = "#" if name == "sources_cmake.inja" else "//"
    return prefix + " Synthetic, no game data, CI only.\n" + text


outputs = {"mcla_" + kind + ".h": render(kind + "_h.inja") for kind in ("init", "pch", "funcs")}
outputs.update({"mcla_" + kind + ".cpp": render(kind + "_cpp.inja")
                for kind in ("init", "register")})
outputs["sources.cmake"] = render("sources_cmake.inja")
# The SDK macro supplies weak hooks and strong __imp__ entry points. Host hooks
# can override the former; any call into a synthetic original must fail loudly.
outputs["mcla_ci_stubs.cpp"] = (
    '// Synthetic, no game data, CI only.\n#include "mcla_init.h"\n#include <cstdio>\n#include <cstdlib>\n'
    + "".join(
        f'DEFINE_REX_FUNC({symbol}) {{\n'
        '  (void)ctx; (void)base;\n'
        f'  std::fputs("CI guest stub called: {symbol}\\n", stderr);\n'
        '  std::abort();\n}\n' for symbol in symbols
    )
)
generated.mkdir(parents=True)
for name, text in outputs.items():
    (generated / name).write_text(text)
stamp = str(generated / "codegen.build.stamp")
stamp = stamp.replace("\\", "\\\\").replace("$", "$$").replace(" ", "\\ ").replace("#", "\\#")
(generated / "codegen.d").write_text(stamp + ":\n")
(generated / "codegen.build.stamp").touch()
print(f"Synthetic sources: {generated} ({len(symbols)} host-referenced guest symbols)")
PY
