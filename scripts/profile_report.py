#!/usr/bin/env python3
"""Summarise a sampling profile written with --mcla_profile.

Usage: profile_report.py <profile.txt> [--bin DIR] [--symbolizer PATH] [--top N] [--threads N]

Samples in recompiled game code are already named by guest function. Samples
in DLLs, dylibs or the mcla executable are module+offset; they are resolved
with llvm-symbolizer against the binaries (and their debug symbols) in --bin.
"""
import argparse
import collections
import os
import struct
import subprocess


def macho_text_address(binary):
    # llvm-symbolizer's --relative-address adds the image base for PE only.
    # Our arm64-only Mach-O binaries need their unslid __TEXT address added.
    try:
        with open(binary, "rb") as f:
            header = f.read(32)
            if len(header) != 32 or header[:4] != b"\xcf\xfa\xed\xfe":
                return None
            commands, size = struct.unpack_from("<II", header, 16)
            end = 32 + size
            for _ in range(commands):
                start = f.tell()
                if start + 8 > end:
                    break
                cmd, length = struct.unpack("<II", f.read(8))
                if length < 8 or start + length > end:
                    break
                if cmd == 0x19 and length >= 72:  # LC_SEGMENT_64
                    name, address = struct.unpack("<16sQ", f.read(24))
                    if name.rstrip(b"\0") == b"__TEXT":
                        return address
                f.seek(start + length)
    except (OSError, struct.error):
        pass
    return None


def symbolize(symbolizer, binary, offsets):
    if not (symbolizer and os.path.exists(binary)):
        return {}
    base = macho_text_address(binary)
    # Linkage names also allow the Mach-O symbol table to work without a dSYM.
    functions = "linkage" if base is not None else "short"
    text = "\n".join(hex((base or 0) + o) for o in offsets) + "\n"
    try:
        out = subprocess.run([symbolizer, f"--obj={binary}", "--relative-address", f"--functions={functions}",
                              "--no-inlines", "--demangle"],
                             input=text, capture_output=True, text=True, timeout=600).stdout
    except (OSError, subprocess.TimeoutExpired):
        return {}
    names = {}
    blocks = out.strip().split("\n\n")
    for offset, block in zip(offsets, blocks):
        first = block.strip().splitlines()[0] if block.strip() else "??"
        names[offset] = first
    return names


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("profile")
    ap.add_argument("--bin", default=None, help="Build directory, .app bundle or Contents/MacOS directory")
    ap.add_argument("--symbolizer", default=None)
    ap.add_argument("--top", type=int, default=25)
    ap.add_argument("--threads", type=int, default=3)
    args = ap.parse_args()

    per_thread = collections.defaultdict(collections.Counter)
    header = ""
    by_module = collections.defaultdict(set)
    with open(args.profile) as f:
        for line in f:
            if line.startswith("#"):
                header = line.strip()
                continue
            tid, n, where = line.rstrip("\n").split("\t")
            per_thread[int(tid)][where] += int(n)
            if where.startswith("module "):
                _, mod, off = where.split(" ")
                by_module[mod].add(int(off, 16))

    resolved = {}
    for mod, offsets in by_module.items():
        if args.bin:
            binary = os.path.join(args.bin, mod)
            for folder in ("", "vulkan/lib", "Contents/MacOS", "Contents/MacOS/vulkan/lib"):
                candidate = os.path.join(args.bin, folder, mod)
                if os.path.isfile(candidate):
                    binary = candidate
                    break
            names = symbolize(args.symbolizer, binary, sorted(offsets))
            for off, name in names.items():
                if name and name != "??":
                    resolved[(mod, off)] = name

    def label(where):
        if where.startswith("module "):
            _, mod, off = where.split(" ")
            name = resolved.get((mod, int(off, 16)))
            return f"{mod}!{name}" if name else f"{mod} (unresolved)"
        return where

    print(header)
    rounds = int(header.split("rounds=")[1].split()[0]) if "rounds=" in header else 0
    # Rank threads by samples outside the OS wait modules (also when unresolved).
    def busy(counter):
        waits = ("ntdll.dll", "win32u.dll", "libsystem_kernel.dylib", "libsystem_pthread.dylib")
        return sum(n for w, n in counter.items() if not any(mod in w for mod in waits))

    ranked = sorted(per_thread.items(), key=lambda kv: -busy(kv[1]))
    for tid, counter in ranked[:args.threads]:
        total = sum(counter.values())
        merged = collections.Counter()
        for where, n in counter.items():
            merged[label(where)] += n
        active = busy(counter)
        share = f"{100 * active / rounds:.0f}% of wall time running" if rounds else ""
        print(f"\nthread {tid}: {total} samples, {share}")
        kinds = collections.Counter()
        for where, n in merged.items():
            kinds[where.split("!")[0].split(" ")[0] if not where.startswith("guest") else "guest code"] += n
        print("  by module: " + ", ".join(f"{k} {100 * v / total:.0f}%" for k, v in kinds.most_common(6)))
        for where, n in merged.most_common(args.top):
            print(f"  {100 * n / total:5.1f}%  {where[:110]}")


if __name__ == "__main__":
    main()
