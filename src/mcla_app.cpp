#include "generated/default/mcla_init.h"

#include "mcla_app.h"

#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <string>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <unistd.h>
#endif
#ifdef __APPLE__
#include <sys/sysctl.h>
#endif

#include <rex/cvar.h>
#include <rex/filesystem.h>
#include <rex/filesystem/vfs.h>
#include <rex/logging.h>
#include <rex/runtime.h>
#include <rex/system/gpu_plugin.h>

REXCVAR_DEFINE_STRING(mcla_gpu_backend, "any", "MCLA",
                      "Graphics backend for the Xenos GPU plugin: any, vulkan or d3d12");


std::unique_ptr<rex::system::IAudioSystem> CreateMclaAudioSystem(
    rex::runtime::FunctionDispatcher* function_dispatcher);

// Started with no options (a double-click on mcla.exe), the game should just
// run: find the extracted game next to the executable or, as the build leaves
// it, in the repository a few folders up, and load the Xenos GPU plugin.
void MclaApp::OnConfigurePaths(rex::PathConfig& paths) {
#ifdef __APPLE__
  // Inside a .app bundle the executable folder is part of the signed bundle,
  // so settings live in Application Support. Without HOME, keep the default.
  const char* home = std::getenv("HOME");
  if (home && *home &&
      rex::filesystem::GetExecutablePath().string().find("/Contents/MacOS/") !=
          std::string::npos) {
    paths.config_path = std::filesystem::path(home) /
                        "Library/Application Support/MCLA/mcla.toml";
    std::error_code ec;
    std::filesystem::create_directories(paths.config_path.parent_path(), ec);
    // Keep the menu's save path alive for the lifetime of the application.
    static std::string settings_path;
    settings_path = paths.config_path.string();
    extern const char* g_mcla_settings_path;
    g_mcla_settings_path = settings_path.c_str();
  }
#endif
  if (!paths.game_data_root.empty()) {
    return;
  }
  std::filesystem::path folder = rex::filesystem::GetExecutableFolder();
  for (int level = 0; level < 5 && !folder.empty(); ++level) {
    std::error_code error;
    if (std::filesystem::exists(folder / "game" / "default.xex", error)) {
      paths.game_data_root = folder / "game";
      return;
    }
    if (folder == folder.parent_path()) {
      break;
    }
    folder = folder.parent_path();
  }
}

void MclaApp::OnPreSetup(rex::RuntimeConfig& config) {
  config.audio_factory = &CreateMclaAudioSystem;
  if (config.gpu_plugin.empty()) {
    config.gpu_plugin = "xenos";
  }

  // Left to the SDK when "any"; it then loads the plugin named by --gpu_plugin
  // with its own default backend.
  std::string backend = REXCVAR_GET(mcla_gpu_backend);
  if (backend != "any") {
    config.graphics = rex::system::LoadGpuPlugin("xenos", backend);
    if (!config.graphics) {
      REXLOG_ERROR("could not load the xenos GPU plugin with backend '{}'", backend);
    }
  }
}

void MclaApp::OnPostSetup() {
  ConfigureFrameTiming();

  // Host facts for bug reports. proc_translated 1 means running under Rosetta.
#if defined(__aarch64__) || defined(_M_ARM64)
  const char* host_arch = "arm64";
#else
  const char* host_arch = "x86_64";
#endif
#ifdef __APPLE__
  int translated = -1;
  size_t translated_size = sizeof(translated);
  if (sysctlbyname("sysctl.proc_translated", &translated, &translated_size, nullptr, 0) != 0) {
    translated = -1;
  }
  std::string translated_text = std::to_string(translated);
#else
  std::string translated_text = "n/a";
#endif
#ifdef _WIN32
  SYSTEM_INFO system_info;
  GetSystemInfo(&system_info);
  long page_size = static_cast<long>(system_info.dwPageSize);
#else
  long page_size = sysconf(_SC_PAGESIZE);
#endif
  REXLOG_INFO("host: arch={} proc_translated={} page_size={} guest_membase=0x{:X}", host_arch,
              translated_text, page_size,
              static_cast<uint64_t>(reinterpret_cast<uintptr_t>(runtime()->virtual_membase())));

  // The game probes for loose city data on a "t:" drive that retail consoles
  // do not have. Give it a device so the probes fail with "not found" rather
  // than "no such device". LARecomp does the same.
  if (runtime() && runtime()->file_system()) {
    runtime()->file_system()->RegisterSymbolicLink("t:", "\\Device\\Harddisk0\\Partition1");
  }
}
