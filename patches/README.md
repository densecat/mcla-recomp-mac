# Patches to the ReXGlue SDK

Apply to ReXGlue v0.10.0 (`f5337cdc947ff6d4c4196737e2c807a48f2a1fc2`), from the SDK checkout:

```
git apply ../../patches/rexglue-v0.10.0-mcla.patch
git -C thirdparty/FFmpeg apply ../../../../patches/rexglue-ffmpeg-ps5-config.patch
```

They were separate files at first; they are combined now because several touch the same build files and would not apply independently.

## rexglue-v0.10.0-mcla.patch

| Change | Files | Affects |
|---|---|---|
| Vblank timer resync: the guest tick count can step backwards, which made an unsigned difference wrap and fire vblank interrupts without end | `src/graphics/graphics_system.cpp` | all platforms |
| Per-frame counters kept in Release builds, and their CSV path taken from `REX_PERF_LOG_CSV` (the GPU plugin has its own copy of the logger state, so a path set by the host never reached it) | `CMakeLists.txt`, `src/core/CMakeLists.txt`, `src/system/CMakeLists.txt`, `src/core/perf/counter.cpp` | all platforms |
| Debug-only register lookup removed from every GPU register write in Release builds | `src/graphics/command_processor.cpp` | all platforms |
| Unit tests build on macOS: they link xxHash (`hash_test` includes it through `rex/hash.h`, which the runtime libraries link only privately), compare file times without printing them (Apple's libc++ counts them in `__int128`, which Catch2 cannot print), and the depfile test's expected strings keep their backslashes (`"has\ space"` was an invalid escape that dropped it) | `tests/unit/CMakeLists.txt`, `tests/unit/codegen/codegen_writer_test.cpp`, `tests/unit/codegen/output_stamp_test.cpp` | test builds only, all platforms |
| Guest memory barriers: `sync`, `lwsync`, `eieio` and `ptesync` emit `REX_SYNC()` and friends, `dmb ish` on arm64 (whose loads and stores can be reordered, unlike x86's) and nothing on x86; `isync` emits `dmb ish; isb` on arm64 (the guest's branch before it may be folded away by the compiler) and a compiler barrier elsewhere instead of throwing as unimplemented; the `lwarx` reservation load is volatile. `REX_GUEST_BARRIERS=0` turns the barriers off for measurement | `src/codegen/builders/system.cpp`, `src/codegen/builders/helpers.h`, `src/codegen/builders.h`, `src/codegen/instruction_dispatch.cpp`, `resources/templates/codegen/pch_h.inja`, `resources/templates/test/ppc_config_h.inja` | barriers arm64 only; `isync` and the volatile load all platforms |
| `mtfsf` set the FPSCR fields in reverse order, so `mtfsf 0x01` (rounding mode) changed nothing and `mtfsf 0x80` overwrote it | `src/codegen/builders/system.cpp` | all platforms |
| Rounding mode read back by `mffs` used the x86 encoding, swapping up and down on arm64; the arm64 FPCR access takes a 64-bit operand and orders against memory | `include/rex/platform/fpscr.h`, `include/rex/ppc/context.h` | arm64 |
| A fault no handler claims goes on to the handler installed before ours (guest SEH; if that handler returns, ours stays installed) or else takes the default action, instead of re-faulting forever | `src/core/exception_handler_posix.cpp` | macOS only |
| Thread priorities map onto Darwin's `SCHED_OTHER` range (the raw values were outside the `SCHED_FIFO` range) and read back as the value set; creation flags pass `ThreadPriority` values | `src/core/threading_posix.cpp`, `src/system/xthread.cpp` | macOS only |
| Hot-page deadlines: 0 means none, so a page is no longer read as hot once the host has been up for 2^31 ms (about 24.9 days, even with the feature off); expired deadlines are cleared | `include/rex/graphics/shared_memory.h`, `src/graphics/shared_memory.cpp` | all platforms |
| Write-watch on hosts with pages larger than the guest's (16 KiB on Apple Silicon and PS5): whether to watch a host page, and what access to restore, is judged from every 4 KiB guest page it holds, not only the first, so CPU writes to a writable page behind a read-only one are no longer missed by the GPU cache | `include/rex/system/xmemory.h`, `src/system/xmemory.cpp` | 16 KiB-page hosts (unchanged with 4 KiB pages) |
| PPC instruction tests: x86 flags only on x86, `REXGLUE_PPC_PREBUILT_DIR` to use test binaries assembled elsewhere (the bundled PowerPC binutils run only on Linux and Windows), and new `mtfsf`, rounding and barrier tests | `tests/ppc/CMakeLists.txt`, `cmake/ppc_test_pipeline.cmake`, `tests/ppc/asm/instr_mtfsf.s`, `tests/ppc/asm/instr_fadd_rounding.s`, `tests/ppc/asm/instr_sync.s` | test builds only |
| PS5 platform: everything else. Platform detection, libc and libc++ differences, anonymous shared memory with a shared-object address reservation at a kernel-chosen base, 16 KiB host pages, signals without realtime signals, no X11/Wayland/RenderDoc, static runtime and GPU libraries, no desktop install rules | the remaining files | PS5 only, behind `REX_PLATFORM_PS5` or `if(PS5)` |

Details of the PS5 changes are in `docs/ps5-port-plan.md`.

## rexglue-ffmpeg-ps5-config.patch

FFmpeg selects a configuration header per platform. This adds `config_ps5_x86_64.h`, generated from the Linux x86-64 one with `HAVE_MALLOC_H`, `CONFIG_ICONV`, `HAVE_MEMALIGN`, `HAVE_SCHED_GETAFFINITY` and `HAVE_LINUX_PERF_EVENT_H` turned off, and selects it for `__PROSPERO__`.
