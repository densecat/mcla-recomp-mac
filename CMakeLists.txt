# mcla - ReXGlue Recompiled Project
#
# SDK boilerplate lives in generated/rexglue.cmake.

cmake_minimum_required(VERSION 3.25)
project(mcla LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

option(MCLA_STRICT_FP "Use strict floating-point semantics for arm64 game code" OFF)

include(generated/rexglue.cmake)

# Sources
set(MCLA_SOURCES
    src/main.cpp
    src/mcla_app.cpp
    src/crash_trace.cpp
    src/audio_fallback.cpp
    src/frame_timing.cpp
    src/render_perf.cpp
    src/perf_options.cpp
    src/button_prompts.cpp
    src/settings_menu.cpp
    src/sampling_profiler.cpp
    src/code_pointer_scan.cpp
)

if(WIN32)
    add_executable(mcla WIN32 ${MCLA_SOURCES})
else()
    add_executable(mcla ${MCLA_SOURCES})
endif()

rexglue_setup_target(mcla)

# On arm64 clang may fuse a multiply and an add into one FMA, which x86-64
# builds never do, so results would drift from PC and the console. Same flag as
# ps5/game/build.sh. Set on the targets so the precompiled header matches.
if(APPLE AND CMAKE_OSX_ARCHITECTURES)
    if(CMAKE_OSX_ARCHITECTURES MATCHES "arm64")
        set(MCLA_TARGET_ARM64 TRUE)
    endif()
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
    set(MCLA_TARGET_ARM64 TRUE)
endif()
if(MCLA_TARGET_ARM64)
    set(MCLA_ARM64_FP_OPTIONS -ffp-contract=off)
    if(MCLA_STRICT_FP)
        # Keep FP operations across guest rounding-mode changes (FPCR writes).
        list(APPEND MCLA_ARM64_FP_OPTIONS -ffp-model=strict)
    endif()
    target_compile_options(mcla PRIVATE ${MCLA_ARM64_FP_OPTIONS})
    # mcla_recomp exists only after codegen.
    if(TARGET mcla_recomp)
        target_compile_options(mcla_recomp PRIVATE ${MCLA_ARM64_FP_OPTIONS})
    endif()
elseif(MCLA_STRICT_FP)
    message(STATUS "MCLA_STRICT_FP is ignored on non-arm64 targets")
endif()

if(WIN32)
    # timeBeginPeriod for the frame limiter.
    target_link_libraries(mcla PRIVATE winmm)
endif()
