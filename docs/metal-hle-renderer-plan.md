# Native Metal renderer by replacing the game's Direct3D layer

Plan for getting Midnight Club: Los Angeles Complete Edition to run at a sustained 30 FPS on Apple Silicon (first target: M1 Pro, 1280×720), by intercepting the game's statically linked Xbox 360 Direct3D library and implementing it on Metal, instead of emulating the Xbox 360 GPU.

Phase 0 is a reverse-engineering feasibility study. Its assignment is written out in full in [Phase 0](#phase-0-feasibility-reverse-engineering) so it can be handed to a reverse-engineering agent as-is.

## 1. Where things stand

Branch `claude/vibrant-gates-bg7wos` ([PR #1](https://github.com/densecat/mcla-recomp-mac/pull/1)). Everything below is committed.

**Working:**
- The game's CPU code is statically recompiled to native arm64 (ReXGlue SDK v0.10.0, `patches/rexglue-v0.10.0-mcla.patch`).
- `make_mac.sh` builds it; it runs with no Rosetta.
- Two GPU backends exist, both emulating the Xbox 360 GPU (Xenos): command processor, EDRAM, resolves.
  - **Vulkan via MoltenVK** is the default: title screen at about 4 FPS.
  - **Native Metal** (`patches/rexglue-v0.10.0-metal.patch`, `--mcla_gpu_backend=metal`) renders the title screen correctly: about 80 ms per frame at ~3,700 draws, about 105 ms at ~6,850 draws.

**Measured on the native Metal backend** (title screen, M1 Pro):

| Finding | Evidence |
|---|---|
| The guest issues 3,700–7,000 draws per frame, depending on the random title-screen location. | `draw_calls` counter |
| The GPU is busy most of the frame but mostly idle inside that time. | Fragment occupancy about 14%. The ALU limiter averages about 14%. Texture, buffer, bandwidth and cache limiters are all low. |
| So the cost is per-draw and per-pass overhead of the emulation, not shading throughput. | About 165 render passes and about 370 draws per pass. EDRAM transfers and resolves run as compute passes. |
| CPU and GPU largely serialise. | The command thread waits about 80–100 ms per frame before uploading into guest pages the GPU is still reading. |
| Tuning the emulation has given about 25% so far, with diminishing returns. | See the `patches/README.md` rows for the Metal patch. |

**Conclusion:** emulating Xenos on a tile-based GPU carries a structural cost that tuning is unlikely to bring to 30 FPS on an M1 Pro.

## 2. The idea

Every Xbox 360 game statically links Microsoft's Direct3D library from the XDK, and Rockstar's RAGE engine (`grcDevice`, `grc*`) is written on top of it. In our recompilation those library functions are ordinary recompiled functions at fixed guest addresses.

If the D3D entry points the game uses are replaced with host implementations that drive Metal directly, all of the following disappear:
- the PM4 command processor and command-buffer parsing
- EDRAM emulation (ownership transfers, dumps, host-depth stores)
- write-watch on vertex and index memory, since buffers get known create and lock calls
- per-draw emulation state

The renderer becomes a native Metal renderer fed by the game's own D3D calls:
- Render targets become ordinary Metal textures.
- Resolves (`D3DDevice_Resolve`) become blits.
- Draws can be batched and state cached as a native port would.

The game's shaders stay Xbox 360 microcode. They're translated once, ahead of time or on first use, with the shader translator we already have (Xenos microcode → SPIR-V → SPIRV-Cross → MSL). Other recompilation projects report taking this route for Xbox 360 titles; ReXGlue forks have started on it too (for example `CadenKalez/rexglue-sdk-macOS`, unfinished).

## 3. Rules that apply to every phase

- **Game data stays private.** Never add game files, the ISO, keys, `generated/default/`, disassembly listings, shader binaries, textures or anything else derived from the game's data to git or CI.
  - Guest addresses and short descriptions of functions are fine: the repo already records hook addresses in `config/*.toml`.
  - Analysis that reads the game binary or the generated code happens only on the owner's machine.
  - Whether any of it may be sent to a cloud model is the owner's decision.
- **Other platforms don't change.** The x86 PC and PS5 builds keep their behaviour. New code is macOS-only and opt-in until it passes acceptance: a backend name such as `--mcla_gpu_backend=hle`, or a separate host module.
- **Keep fallbacks.** The Vulkan and native Metal Xenos backends remain available for regression comparison.
- **Commit hygiene.** No AI model names in commits or files.
- **SDK changes go in patch files.** Regenerate `patches/rexglue-v0.10.0-mcla.patch` or `patches/rexglue-v0.10.0-metal.patch` from a git worktree of the SDK at `f5337cdc`, or add a new patch file, and keep the `patches/README.md` rows current. Host code is in `src/`, hooks in `config/*.toml`, scripts in `scripts/`.

## 4. Known starting points

These are already in the repo:

| What | Where |
|---|---|
| `grcDevice::BeginTiledRendering` = `sub_8217A470` (the main scene is drawn as two predicated tiles on the console; `mcla_single_tile` makes it one) | `config/render_perf.toml`, `src/render_perf.cpp` |
| Surface (render target) creation `sub_82410D70`, EDRAM tile limit check at `0x82410E34` | `config/render_perf.toml` |
| `D3DDevice_BlockOnFence` = `sub_82411E98`, its fence poll `sub_82412F98` | `config/render_perf.toml` |
| The swap's present interval write at `0x82419AA0` (inside the D3D swap path) | `config/frame_timing.toml` |
| Engine timer `sub_821BDA90`; frame-delta hooks | `config/frame_timing.toml` |
| How a host hook replaces or intercepts guest code: `[[midasm_hook]]` (registers in, optional `jump_address_on_true`), `REX_HOOK` / `REX_HOOK_RAW` in the SDK's `include/rex/hook.h` | 37 existing hooks in `config/*.toml` |
| Recompiled game code (local only, never commit) | `generated/default/` |
| Game files (local only) | `game/` |
| GPU-side reference for what each D3D call ultimately emits | The SDK's Xenos command processor (`src/graphics/command_processor.cpp`), register definitions (`include/rex/graphics/registers.h`) and the Metal and Vulkan backends |

Guest addresses in the D3D range seen so far cluster around `0x8240_0000–0x8242_0000`, which suggests where the D3D library sits in the image. That's an inference only; Phase 0 must confirm it.

## Phase 0: Feasibility reverse engineering

**Goal:** decide, with evidence, whether MCLA's rendering can be driven entirely, or nearly entirely, through intercepted D3D calls, and size the work. This phase is read-only analysis plus optional instrumentation runs. No renderer code.

### Assignment for the reverse-engineering agent

**Inputs, all local:**
- `game/default.xex`, the original executable.
- `generated/default/*.cpp`, the recompiled C++ with functions named `sub_XXXXXXXX` by guest address.
- `config/*.toml`, existing hooks and function hints.
- The SDK sources in `third_party/rexglue-sdk/`.
- The build in `out/build/mac-arm64-release/` (`mcla` and the GPU plugin).
- `scripts/` for launching (`scripts/smoke_mac.sh`, `scripts/make_mac.sh`).

**Tasks:**

1. **Locate the D3D library.**
   - Find the statically linked Xbox 360 Direct3D functions.
   - Suggested anchors:
     - **Ring write pointer.** Functions that write the GPU ring-buffer write pointer through MMIO (`CP_RB_WPTR`; the SDK's `graphics_system.cpp` handles the MMIO range). This is the D3D "kick-off" path.
     - **Fence code.** `D3DDevice_BlockOnFence` (`sub_82411E98`) and its neighbours.
     - **Swap.** The function containing `0x82419AA0`.
     - **Surface creation.** `sub_82410D70`.
     - **Kernel imports used only by D3D.** For example `VdSetGraphicsInterruptCallback`, `VdInitializeRingBuffer`, `VdEnableRingBufferRPtrWriteBack`, `VdSwap`, `VdGetCurrentDisplayInformation`.
     - **PM4 packet building.** Code that writes type-0 and type-3 packet headers into the command buffer (the opcodes match `ExecutePacketType3_*` in the SDK command processor).
   - Walk callers and callees from these anchors to map the library.

2. **Identify the API surface the game uses.** Names follow public Xbox 360 D3D (D3D9-like) naming. For each function, record:
   - guest address and probable name
   - argument registers and meaning
   - the device and state structure fields it touches
   - the PM4 packets or registers it ends up writing

   Cover at least:
   - **Device:** device creation and reset.
   - **Resources:** `CreateTexture`, `CreateVertexBuffer`, `CreateIndexBuffer`, `CreateSurface` / render-target creation, plus lock/unlock or the XDK's physical-memory resource setup (`XGSetTextureHeader`-style header initialisation).
   - **Shaders and state:** `CreateVertexShader` / `CreatePixelShader`; `SetVertexShader` / `SetPixelShader`; shader constants (`SetVertexShaderConstantF` and similar); `SetTexture`; sampler states; render states; `SetRenderTarget` / `SetDepthStencilSurface`; `SetViewport` / `SetScissorRect`; `SetStreamSource` / `SetIndices` / `SetVertexDeclaration`.
   - **Draws:** `DrawPrimitive` / `DrawIndexedPrimitive` / `DrawVertices` / `DrawIndexedVertices` / `DrawPrimitiveUP`-style immediate draws.
   - **Other:** `Clear`; `Resolve`; `Swap` / `Present`; fences (`InsertFence`, `BlockOnFence`, `IsFencePending`); predicated tiling (`BeginTiling` / `EndTiling`); queries.
   - **Engine side:** the RAGE wrappers (`grcDevice::*`, `grcTexture*`, `grcRenderTarget*`, `grcEffect*`) that call into the library. Name what you can confirm.

3. **Measure what the title screen and a short gameplay section actually call.**
   - Add temporary counting hooks: `[[midasm_hook]]` entries at function entry, calling a host function that increments counters. Put these in a scratch config, not committed, or behind a cvar.
   - Record:
     - calls per frame for each identified function
     - distinct shader objects created and bound
     - render targets and resolves per frame
     - draws per frame by draw function
   - The goal is the minimum API set needed for the title screen, then for a race.

4. **Look for paths that bypass D3D.** For each, say where it happens and how often:
   - code that writes PM4 packets itself (precompiled command buffers, `BeginCommandBuffer`-style recording and replay, direct register writes)
   - CPU access to EDRAM-dependent data
   - memexport (shaders writing memory) and GPU-written data the CPU reads back
   - occlusion queries and predication
   - tessellation
   - render-to-texture tricks that depend on EDRAM aliasing (one surface reinterpreted as another format)

5. **Shaders.**
   - Where shader microcode lives: in the XEX, in RPF archives, or built at runtime.
   - How it reaches `Create*Shader`, and the container format (Xenos microcode with constant tables).
   - Whether all shaders are available at load time, so they can be translated ahead of time.
   - How constants and samplers are bound (constant-buffer layout, boolean and loop constants).

6. **Resources.**
   - How textures and vertex buffers are described: header layout (fetch-constant style), tiled versus linear, endianness, formats used.
   - Whether the CPU rewrites vertex or index data per frame (dynamic buffers) and how: lock flags, ring allocation.

7. **Render targets and resolves.** The main frame's render-target setup:
   - formats and MSAA
   - the predicated tiling sequence
   - every resolve: what is resolved where, and in what format
   - which later passes sample the resolved textures (post-processing chain)

**Deliverables:** a report in `docs/re/d3d-surface.md`, plus a machine-readable table `docs/re/d3d-functions.csv`. Neither may contain game code, disassembly listings or data. The CSV columns:

```
guest_address, probable_name, confidence (confirmed/likely/guess), args, notes, title_calls_per_frame, race_calls_per_frame
```

The report must answer:
- **A.** Can every draw, resource and state change in the title screen and in a race be expressed through the identified functions? List every exception, with frequency.
- **B.** How many distinct functions must be implemented for (i) the title screen and (ii) a race?
- **C.** Are the shaders available ahead of time, and in what form?
- **D.** What depends on EDRAM behaviour (aliasing, tiling, resolve formats)?
- **E.** An estimate of implementation size, and the largest risk.

Label every finding Confirmed (with evidence: guest address, call counts, a log excerpt), Hypothesis, or Missing evidence.

**Gate.** Continue to Phase 1 only if:
- the title screen and a race need no more than a manageable set of entry points (about 100 or fewer), and
- any bypasses are rare enough to emulate locally, for example by replaying captured PM4 for one function.

Otherwise, stay on the Xenos emulation path: tune the native Metal backend, or port xenia-edge's Metal backend.

## Phase 1: Architecture

Write this design once Phase 0 passes, as `docs/re/hle-renderer-design.md`, and have it independently reviewed before coding.

**Interception.**
- Replace each identified D3D entry point with a host function, using `REX_HOOK` or a function-entry `[[midasm_hook]]` with `jump_address_on_true` to the function's return.
- Keep the original guest functions callable, for fallback and for A/B comparison against the Xenos path.

**State tracker.**
- A host-side mirror of the D3D device state: render states, samplers, textures, streams, shaders and constants.
- Dirty tracking feeds Metal render pipeline states, depth-stencil states and argument buffers (Metal 3) or argument tables (Metal 4, `@available(macOS 26)`).

**Resources.**
- **Textures:** Metal textures created at create time. Untiling and format conversion reuse the SDK's texture-load compute shaders (SPIR-V → MSL, already working in the Metal backend), or run on the CPU at upload.
- **Buffers:** Metal buffers.
  - Static buffers are uploaded once.
  - Dynamic buffers use per-frame ring allocation driven by the game's lock and unlock calls, instead of write-watch on 16 KiB pages.
  - Big-endian vertex data is swapped on upload, or fetched as in today's translated shaders.

**Shaders.**
- Xenos microcode → `SpirvShaderTranslator` → SPIRV-Cross → MSL. This chain is already proven in the native Metal backend: about 130 pipelines, 0 failures on the title screen.
- Translate at create time and cache to disk (`MTLBinaryArchive`, or the Metal 4 pipeline dataset).
- Constant layout follows the D3D constant model instead of the Xenos register file.

**Render targets.**
- Ordinary Metal textures at full resolution, with MSAA where the game asks for it. D24S8 becomes `Depth32Float_Stencil8`.
- No EDRAM.
- Predicated tiling collapses to one pass (as `mcla_single_tile` already does).
- `Resolve` becomes a blit or MSAA resolve into the destination texture, with format conversion where needed.

**Synchronisation.**
- Fences map to `MTLSharedEvent` values.
- `BlockOnFence` waits on the event; the existing `mcla_fence_yield` behaviour stays.
- Frames in flight: 2.

**Presentation.** `CAMetalLayer` through the existing Metal presenter (`src/ui/metal/`).

**Fallback for bypasses.** For a function that builds PM4 itself, either capture and replay its packets through the existing Xenos Metal backend, or implement that function's effect directly. Decide per case from the Phase 0 data.

## Phase 2: Title-screen prototype

**Scope:** the title screen through the HLE renderer:
- city
- cars
- post-processing
- logo
- PRESS prompt

**Pass conditions:**
- **Correctness.** Frames match the native Metal backend and Vulkan visually: `--metal_dump_frame` dumps for Metal, window captures for Vulkan.
  - The title screen picks random locations, so compare like with like: same location, or a fixed checkpoint added for testing.
- **Native path.** Draws reach Metal directly. `vmmap` shows no Vulkan or MoltenVK, and a Metal System Trace shows the HLE renderer's labelled encoders.
- **Frame rate.** A sustained 30 FPS or better in the title scene, measured in-run (see [Measurement](#measurement)).
- **No new crashes or hangs** across 20 launches.

**Stop or change course if** the prototype isn't clearly faster than the native Metal Xenos backend. In that case, find the cause before expanding.

## Phase 3: Booting game

Extend through:
- menus
- loading transitions
- the garage and saves
- free roam
- races

Keep the native Metal Xenos backend as fallback, selectable per run.

Add each D3D function only when a measured path needs it. Log any unimplemented entry point the game calls, and count it, but never skip it silently.

## Phase 4: Verified playable port

The acceptance checklist from `docs/mac-build-guide.md` and `docs/known-issues.md`:
- menus
- a race
- garage and save
- 15 minutes of free roam
- fullscreen and resize
- quit within 5 s
- the crash test `--mcla_test_null_write=true` (ends within 5 s, leaves a stack in the log)
- 20 launch and exit cycles
- a 30-minute representative session at a sustained 30 FPS at 1280×720, with:
  - no skipped effects
  - no placeholder draws
  - correct game speed

Then package and sign `MCLA.app` and update the docs.

## Measurement

These lessons are already learned on this project:

- **Same scene for both settings.** The title screen chooses random locations, so separate runs are not comparable. Compare settings inside one run: `--metal_ab_period=N` alternates the option under test every N swaps. `scripts/ab_pairs.py perf.csv N` pairs adjacent blocks with matching draw counts.
- **Quiet, unoccluded machine.**
  - Keep the game window unoccluded; capture it by window ID (`screencapture -l`).
  - Stop other GPU and CPU work.
  - Keep the Mac plugged in: low battery throttles it.
- **Counters.** `REX_PERF_LOG_CSV=<file>` writes per-frame counters: draws, passes, pass-end reasons, upload bytes and causes, waits, Metal-specific counters.
- **GPU time.** `--metal_gpu_labels=true` plus `xcrun xctrace record --template 'Metal System Trace' --instrument 'Metal GPU Counters'` attributes GPU time by encoder and pipeline, and gives the limiter percentages.
  - Always run `xctrace` with a hard timeout, and always kill the game afterwards. A hung recorder once left the game running for three hours.
- **Frame comparisons.** `--metal_dump_frame=N --metal_dump_every=true --metal_dump_path=<dir>` writes presented frames as PNG, also while the display is asleep.

## Roles

- **Lead (planning and integration):**
  - owns this plan, the gates and acceptance
  - reviews every finding and diff before it lands
  - builds, measures and commits
- **Reverse-engineering agent:** runs Phase 0 with this document as its brief, and later answers targeted questions about specific functions. It reports evidence, not conclusions without evidence.
- **Implementation:** Phase 1 onwards, one owner per file group, integrated in dependency order:
  1. interception
  2. state tracker
  3. resources
  4. shaders
  5. render targets and resolves
  6. presentation
- **Independent review:**
  - one review of the Phase 1 design before coding
  - one after the Phase 2 prototype
  - reviewers must not be the authors

## Risks

| Risk | Effect | Mitigation |
|---|---|---|
| RAGE or MCLA builds PM4 command buffers itself for some passes | Those passes can't be intercepted at the API | Phase 0 task 4; replay through the Xenos backend for those calls |
| Effects rely on EDRAM aliasing (one surface reinterpreted as another format) | Plain Metal textures give wrong results | Phase 0 task 7; emulate the specific reinterpretation with a copy |
| Shaders use memexport or rely on Xenos-specific behaviour | Translation or semantics gaps | The existing translator already handles memexport into a buffer; test early |
| Scale of the D3D surface | Months of work | Phase 0 gate on entry-point count; build only what is measured as needed |
| Shader translation and pipeline compile stalls | Hitches | Translate at load, cache to disk |
| Legal | Xbox 360 XDK libraries aren't available or redistributable | Implement from observed behaviour and public documentation; never copy XDK code |

## Current fallbacks, unchanged by this plan

- **Vulkan through MoltenVK:** the default.
- **Native Metal emulating Xenos:** `--mcla_gpu_backend=metal`. Its cvars are documented in `patches/README.md` (Metal patch rows).
