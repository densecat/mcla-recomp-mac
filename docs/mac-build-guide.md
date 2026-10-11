# Building and running on macOS (Apple Silicon)

The game is recompiled to native arm64 code and uses Vulkan through the SDK's bundled MoltenVK. You need your own disc image of **Midnight Club: Los Angeles Complete Edition, USA/Europe, Xbox 360** (title id `545407F8`). No game code, assets or keys are in this repository. Extracted files and generated code stay on your machine; the executable and app you build are for you, not for sharing.

State: **builds in CI; first game run pending**. CI builds the patched SDK and runs its unit and PowerPC instruction tests without game data. A game build, launch, gameplay and performance still need verification on a Mac. See [known issues](known-issues.md#macos-apple-silicon).

## What you need

| | |
|---|---|
| Apple Silicon Mac | M1 or newer, running natively. Intel Macs and Rosetta builds are not supported. |
| macOS 13.3 or newer | The deployment target; your build machine must also support the Xcode or Command Line Tools version below. |
| Xcode 16 or newer, or its Command Line Tools | Apple clang 16 or newer. `xcode-select --install` installs the Command Line Tools. The scripts use `/usr/bin/clang` and `/usr/bin/clang++`, not Homebrew LLVM. |
| Git and Python 3.9 or newer | Provided by the Command Line Tools; check `git --version` and `python3 --version`. |
| CMake 3.25 or newer and Ninja | Install native [Homebrew](https://brew.sh) in `/opt/homebrew`, then `brew install cmake ninja`. |
| Disk | About 25 GB for the disc image, extracted game, SDK and build trees. |
| Internet | Needed to clone the SDK and fetch its build dependencies. |

All commands below run in Terminal with the repository as the current folder unless a step says otherwise.

## Build

```bash
git clone https://github.com/holdmysocks/mcla-recomp.git
cd mcla-recomp
scripts/make_mac.sh --iso "/path/to/your.iso"
```

The script checks the tools and offers to install missing CMake and Ninja through Homebrew. Add `--install-tools` to accept that installation without a question, or `--play` to launch after the build. It leaves **Midnight Club Los Angeles.command** in the repository folder for double-click launches.

The script runs these steps and reuses completed work when possible:

1. Check the native arm64 shell, Apple clang, CMake, Ninja, Git and Python.
2. Clone ReXGlue SDK v0.10.0 into `third_party/rexglue-sdk` and apply this project's patches.
3. Build and install the SDK under `third_party/rexglue-sdk/out/install/mac-arm64`, then check its architectures, signatures and dependencies.
4. Extract your disc into `game/`, which git ignores. `--iso` is unnecessary once `game/default.xex` exists.
5. Generate C++ under `generated/default/` and build `out/build/mac-arm64-release/mcla`, including the runtime libraries beside it.
6. Write the launcher and optionally start the game.

After a failure, fix the reported problem and rerun the same command. SDK and extraction logs are in `out/logs/`; codegen, configure and game build logs are `out/codegen.log`, `out/configure.log` and `out/build.log`.

Useful build options:

| Option | Effect |
|---|---|
| `--preset mac-arm64-release` | Default game build. `mac-arm64-debug` and `mac-arm64-relwithdebinfo` are also available. |
| `--jobs 4` | Limit parallel build jobs, useful if memory is tight. |
| `--sdk-only` | Stop after building, installing and checking the SDK; no disc image needed. |
| `--with-tests --ppc-bins /path/to/ppc-test-bins` | Also build SDK tests. Supply the SDK test `.bin` and `.map` files assembled on Linux or Windows, for example the `ppc-test-bins` CI artifact. The SDK's PowerPC assembler does not run on macOS. |

### By hand: 1. Get the SDK sources

From the repository folder:

```bash
git clone --recursive --branch v0.10.0 https://github.com/rexglue/rexglue-sdk.git third_party/rexglue-sdk
git -C third_party/rexglue-sdk apply ../../patches/rexglue-v0.10.0-mcla.patch
git -C third_party/rexglue-sdk/thirdparty/FFmpeg apply ../../../../patches/rexglue-ffmpeg-ps5-config.patch
```

The SDK must be v0.10.0 (`f5337cdc947ff6d4c4196737e2c807a48f2a1fc2`). The patches include the macOS port fixes. Do not substitute another SDK release or Homebrew MoltenVK.

### 2. Build and install the SDK

```bash
cd third_party/rexglue-sdk
cmake --preset mac-arm64 \
    -DREXGLUE_ENABLE_TRACY=OFF \
    -DCMAKE_C_COMPILER=/usr/bin/clang \
    -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.3
cmake --build out/build/mac-arm64 --config Release --parallel
cmake --install out/build/mac-arm64 --config Release
cd ../..
scripts/check_arm64.sh third_party/rexglue-sdk/out/install/mac-arm64
```

This is the long step, once. The Vulkan loader and MoltenVK are built from the SDK's dependencies and installed with it.

### 3. Extract your game

```bash
python3 scripts/extract_game.py "/path/to/your.iso"
```

The files are copied to `game/` without changing them. Never add this folder, the ISO, keys or `generated/default/` to git or CI.

### 4. Recompile and build

```bash
scripts/build_mac.sh
```

It runs codegen, configures with the installed SDK and builds the game. It accepts `--preset NAME` and `--jobs N`. For a build with debug symbols:

```bash
scripts/build_mac.sh --preset mac-arm64-relwithdebinfo --jobs 4
```

## Play

Double-click **Midnight Club Los Angeles.command**, made by `make_mac.sh`, or run the binary directly:

```bash
out/build/mac-arm64-release/mcla
```

The executable finds `game/` by searching its parent folders. Keep the build folder in the repository and launch the actual binary, not a symlink: the GPU plugin is located relative to the executable. Runtime libraries and the `vulkan/` folder must stay beside it.

Options go after the program name, for example:

```bash
out/build/mac-arm64-release/mcla --fullscreen=true --mcla_fps=60 --mcla_intro=fast
```

The frame-rate target defaults to 30; 60, 120 and 0 (uncapped) are also available. Mac gameplay and performance at these targets are unverified. Controller prompt `auto` currently uses Xbox glyphs on macOS; select `--mcla_button_prompts=playstation` for PlayStation glyphs.

The in-game pause menu has DISPLAY, PERFORMANCE and CONTROLS entries. For a bare binary, settings load from and save to `mcla.toml` next to the executable.

For a timed smoke run with three whole-screen screenshots:

```bash
scripts/smoke_mac.sh --seconds 120 --shots 3 --preset mac-arm64-release -- --mcla_intro=fast
```

The script stops the game at the end. It writes logs, screenshots, a performance CSV and architecture information under `out/runs/<timestamp>/`. Keep the game in front and grant the terminal app Screen Recording permission before capturing screenshots.

## MCLA.app

Package an existing build and launch it from Finder:

```bash
scripts/make_app_mac.sh
open MCLA.app
```

Use `scripts/make_app_mac.sh --preset mac-arm64-relwithdebinfo` to package that build instead. Packaging does not compile the game. It replaces the previous `MCLA.app` at the repository root with the executable, `librexruntime.dylib` and `librexgpu-xenos.dylib` under `Contents/MacOS`, the Vulkan loader and MoltenVK under `Contents/MacOS/vulkan/lib`, and the ICD manifest at `Contents/Resources/MoltenVK_icd.json`. No game data is copied into the bundle.

The manifest's library path is relative to Resources (`../MacOS/vulkan/lib/libMoltenVK.dylib`). Keeping the `icd.d` directory out of MacOS avoids codesign treating it as a nested bundle. Before Vulkan initializes, bundle launches set `VK_DRIVER_FILES` to this manifest if that variable is unset. An existing `VK_ICD_FILENAMES` override is copied into it instead, preserving the legacy override even when the SDK discovers another ICD. Bare binaries keep the SDK's original `vulkan/share/vulkan/icd.d` layout.

The script signs each dylib, then the executable, then the bundle with an ad-hoc signature, verifies it strictly, and runs `check_arm64.sh` on the bundle. No Developer ID or notarization is needed for this local build. You can repeat the checks:

```bash
codesign --verify --strict --verbose=2 MCLA.app
scripts/check_arm64.sh MCLA.app
otool -L MCLA.app/Contents/MacOS/mcla
otool -l MCLA.app/Contents/MacOS/mcla | grep -A2 LC_RPATH
```

The executable's rpath is `@executable_path`; dependencies must resolve to the bundle or system libraries. `check_arm64.sh` checks every Mach-O file, including the plugin and Vulkan libraries, for arm64-only architecture, a signature and resolved dependencies.

Keep **MCLA.app at the repository root**. The existing game-data search reaches `<repo>/game/default.xex` three levels above `Contents/MacOS`; moving the bundle to Applications breaks that automatic lookup.

Bundle launches load and save settings at `~/Library/Application Support/MCLA/mcla.toml` and default to a rotating log at `~/Library/Logs/MCLA/mcla.log`. The folders are created on startup, including when `--game_data_root` is supplied; if `HOME` is absent, the account's home directory is used. Explicit `--log_file`, `REX_LOG_FILE` or TOML `log_file` values take precedence. Bare-binary launches keep their existing config and default logs beside the executable. These are separate settings files; packaging does not migrate them.

Other default writes also stay outside the bundle: user data is under `~/.local/share/mcla` (or `$XDG_DATA_HOME/mcla`), with cache and shader cache beneath `cache/`. The crash tracer appends to the selected log and stderr; it creates no separate dump file. Performance CSVs, sampling profiles and shader dumps require explicit paths, and ImGui's automatic INI saving is disabled. Use paths outside the bundle for explicit output overrides. Bundle launch and signature persistence still need a real Mac run; repeat `codesign --verify --strict --verbose=2 MCLA.app` after quitting.

Automatic recovery with `scripts/play_loop_mac.sh` preserves the build directory's `MCLA_STRICT_FP` setting when rebuilding. For sampling reports, `scripts/profile_report.py --bin` accepts the build directory, `MCLA.app`, or `MCLA.app/Contents/MacOS`; it also searches the corresponding `vulkan/lib` directory for loader and MoltenVK symbols.

## Updating

```bash
git pull
scripts/make_mac.sh
```

The script detects changed patches, restores its SDK checkout to the pinned release and reapplies them, then rebuilds the SDK. It also forces code regeneration when the installed recompiler changes. Keep local SDK edits elsewhere because this update flow restores tracked SDK files and cleans untracked source files.

If you use the app, rerun `scripts/make_app_mac.sh` after building; an existing bundle does not update itself. Use the same `--preset` when building and packaging a non-default configuration.

## If something goes wrong

| Symptom | What to do |
|---|---|
| Rosetta or translated-tool error | Turn off "Open using Rosetta" in Terminal's Get Info window and open a new shell. `uname -m` must say `arm64`; `sysctl -n sysctl.proc_translated` must not say `1` (the key may be absent on a native process). Use CMake and Ninja from `/opt/homebrew`, not Intel tools from `/usr/local`. |
| `cmake` or `ninja` is missing or has no arm64 slice | Run `brew install cmake ninja` with native Homebrew and put `/opt/homebrew/bin` on `PATH`. `lipo -archs "$(command -v cmake)"` and the same command for `ninja` must include `arm64`. |
| Apple clang is missing or too old | Install Xcode 16 or newer or matching Command Line Tools; check `/usr/bin/clang++ --version` and `xcode-select -p`. |
| `build_mac.sh` says "Delete the folder ... and run this again" | Its cache check found a different compiler, architecture, deployment target, SDK prefix, old `REXSDK_DIR`, missing sysroot or translated CMake host. Delete only the build folder named in the message (normally `out/build/mac-arm64-release`), then rerun the build. The script deliberately does not reuse incompatible cached objects. |
| SDK configure reports a non-arm64 host | Fix the shell and CMake architecture first, then delete the SDK build folder named in the message (`third_party/rexglue-sdk/out/build/mac-arm64`) and rerun `make_mac.sh`. |
| `codegen failed` or `build failed` | Check `game/default.xex` and the supported release, then read `out/codegen.log` or `out/build.log`. Reduce `--jobs` if the compiler ran out of memory. |
| Vulkan cannot find a driver, or loads an unexpected one | `VK_DRIVER_FILES` (or legacy `VK_ICD_FILENAMES` for bundle launches) overrides the bundled ICD. Run `unset VK_DRIVER_FILES VK_ICD_FILENAMES` in the launching shell and retry. Do not point them at a Homebrew driver. For bare binaries, confirm `vulkan/share/vulkan/icd.d/MoltenVK_icd.json` and both `vulkan/lib/` dylibs exist beside `mcla`; in the app, the JSON is at `Contents/Resources/MoltenVK_icd.json` and the dylibs are under `Contents/MacOS/vulkan/lib`. |
| Runtime library missing or packaging check fails | Rerun `scripts/build_mac.sh` with the matching `--preset` to stage the runtime files again, then package again. Read the unresolved dependency reported by `check_arm64.sh`; it must not depend on the SDK build tree or Homebrew. |
| Smoke screenshots are blank or show no windows | Give Terminal (or the app hosting the shell) Screen Recording permission in System Settings > Privacy & Security. Restart that app if requested, and keep the game window in front. Screenshots capture the whole screen. |
| App cannot find game data | Keep `MCLA.app` beside `game/` at the repository root. The bundle contains no game files. |
| Settings differ between launcher and app | The launcher uses the build folder's `mcla.toml`; the app uses `~/Library/Application Support/MCLA/mcla.toml`. |

For a startup failure, capture an explicit log:

```bash
out/build/mac-arm64-release/mcla --log_file="$PWD/out/run.log" --log_level=info
```

For LLDB, use the symbol-enabled preset and pass the runtime's fault and thread-control signals through:

```bash
lldb -- out/build/mac-arm64-relwithdebinfo/mcla
```

At the LLDB prompt:

```text
process handle SIGSEGV SIGBUS SIGUSR1 SIGUSR2 -s false -p true
run
```

Send the relevant log and `scripts/check_arm64.sh out/build/mac-arm64-release` output with the Mac model, macOS version and a description of what happened. Do not send game files, keys or generated game source.
