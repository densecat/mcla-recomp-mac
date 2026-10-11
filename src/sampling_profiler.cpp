// Built-in sampling profiler (development aid, Windows and macOS arm64).
//
// --mcla_profile=<file> starts a thread that waits --mcla_profile_delay
// seconds, then for --mcla_profile_seconds samples the instruction pointer of
// every other thread about once a millisecond. Samples inside recompiled game
// code are attributed to their guest function through the dispatch table;
// everything else is written as module + offset for scripts/profile_report.py
// to symbolise.

#include "generated/default/mcla_init.h"

#include "mcla_app.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include <rex/cvar.h>
#include <rex/logging.h>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <tlhelp32.h>
#elif defined(__APPLE__) && defined(__aarch64__)
#include <chrono>
#include <dlfcn.h>
#include <limits.h>
#include <mach/mach.h>
#include <mach/arm/thread_status.h>
#endif

REXCVAR_DEFINE_STRING(mcla_profile, "", "MCLA", "Write a sampling profile to this file");
REXCVAR_DEFINE_INT32(mcla_profile_delay, 40, "MCLA", "Seconds to wait before sampling")
    .range(0, 3600);
REXCVAR_DEFINE_INT32(mcla_profile_seconds, 15, "MCLA", "Seconds to sample for").range(1, 600);

// Defined in crash_trace.cpp.
uint32_t MclaGuestFunctionForHostPc(uintptr_t host_pc);

#ifdef _WIN32
namespace {

struct Sample {
  uint32_t thread_id;
  uint64_t pc;
};

std::vector<uint32_t> OtherThreadIds() {
  std::vector<uint32_t> ids;
  const DWORD pid = GetCurrentProcessId();
  const DWORD self = GetCurrentThreadId();
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
  if (snapshot == INVALID_HANDLE_VALUE) {
    return ids;
  }
  THREADENTRY32 entry{};
  entry.dwSize = sizeof entry;
  if (Thread32First(snapshot, &entry)) {
    do {
      if (entry.th32OwnerProcessID == pid && entry.th32ThreadID != self) {
        ids.push_back(entry.th32ThreadID);
      }
    } while (Thread32Next(snapshot, &entry));
  }
  CloseHandle(snapshot);
  return ids;
}

void RunProfile(std::string path, int delay_s, int seconds) {
  Sleep(static_cast<DWORD>(delay_s) * 1000);

  std::vector<std::pair<uint32_t, HANDLE>> threads;
  for (uint32_t id : OtherThreadIds()) {
    HANDLE h = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION,
                          FALSE, id);
    if (h) {
      threads.emplace_back(id, h);
    }
  }

  // Nothing may allocate or log between SuspendThread and ResumeThread: the
  // suspended thread could be holding the heap or logger lock.
  std::vector<Sample> samples;
  samples.resize(static_cast<size_t>(seconds) * 1100 * threads.size());
  size_t count = 0;
  const ULONGLONG end = GetTickCount64() + static_cast<ULONGLONG>(seconds) * 1000;
  uint64_t rounds = 0;
  while (GetTickCount64() < end && count + threads.size() <= samples.size()) {
    for (auto& [id, handle] : threads) {
      if (SuspendThread(handle) == static_cast<DWORD>(-1)) {
        continue;
      }
      CONTEXT context;
      context.ContextFlags = CONTEXT_CONTROL;
      if (GetThreadContext(handle, &context)) {
        samples[count++] = {id, context.Rip};
      }
      ResumeThread(handle);
    }
    ++rounds;
    Sleep(1);
  }
  for (auto& [id, handle] : threads) {
    CloseHandle(handle);
  }

  // Aggregate: (thread, location) -> hits. A location is a guest function,
  // or module+offset.
  std::map<std::pair<uint32_t, std::string>, uint32_t> hits;
  char buffer[MAX_PATH + 32];
  for (size_t i = 0; i < count; ++i) {
    const uint64_t pc = samples[i].pc;
    std::string where;
    if (uint32_t guest = MclaGuestFunctionForHostPc(static_cast<uintptr_t>(pc))) {
      std::snprintf(buffer, sizeof buffer, "guest sub_%08X", guest);
      where = buffer;
    } else {
      HMODULE module = nullptr;
      if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                                 GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                             reinterpret_cast<LPCSTR>(pc), &module) &&
          module) {
        char name[MAX_PATH];
        GetModuleFileNameA(module, name, sizeof name);
        const char* base = std::strrchr(name, '\\');
        std::snprintf(buffer, sizeof buffer, "module %s 0x%llX", base ? base + 1 : name,
                      static_cast<unsigned long long>(pc - reinterpret_cast<uint64_t>(module)));
      } else {
        std::snprintf(buffer, sizeof buffer, "unknown 0x%llX", static_cast<unsigned long long>(pc));
      }
      where = buffer;
    }
    ++hits[{samples[i].thread_id, where}];
  }

  if (FILE* f = std::fopen(path.c_str(), "w")) {
    std::fprintf(f, "# rounds=%llu seconds=%d threads=%zu samples=%zu\n",
                 static_cast<unsigned long long>(rounds), seconds, threads.size(), count);
    for (const auto& [key, n] : hits) {
      std::fprintf(f, "%u\t%u\t%s\n", key.first, n, key.second.c_str());
    }
    std::fclose(f);
  }
  REXLOG_INFO("profile: {} samples over {} rounds written to {}", count, rounds, path);
}

}  // namespace
#elif defined(__APPLE__) && defined(__aarch64__)
namespace {

struct Sample {
  uint32_t thread_id;
  uint64_t pc;
};

void RunProfile(std::string path, int delay_s, int seconds) {
  std::this_thread::sleep_for(std::chrono::seconds(delay_s));

  std::vector<thread_t> threads;
  thread_act_array_t list = nullptr;
  mach_msg_type_number_t size = 0;
  const mach_port_t task = mach_task_self();
  const mach_port_t self = mach_thread_self();
  if (task_threads(task, &list, &size) == KERN_SUCCESS) {
    for (mach_msg_type_number_t i = 0; i < size; ++i) {
      if (list[i] != self) {
        threads.push_back(list[i]);
      } else {
        mach_port_deallocate(task, list[i]);
      }
    }
    vm_deallocate(task, reinterpret_cast<vm_address_t>(list), size * sizeof(thread_t));
  }
  mach_port_deallocate(task, self);

  // Nothing may allocate, lock or log between thread_suspend and thread_resume:
  // the suspended thread could be holding the heap or logger lock.
  std::vector<Sample> samples;
  samples.resize(static_cast<size_t>(seconds) * 1100 * threads.size());
  size_t count = 0;
  const auto end = std::chrono::steady_clock::now() + std::chrono::seconds(seconds);
  uint64_t rounds = 0;
  while (std::chrono::steady_clock::now() < end && count + threads.size() <= samples.size()) {
    for (thread_t thread : threads) {
      arm_thread_state64_t state{};
      mach_msg_type_number_t state_size = ARM_THREAD_STATE64_COUNT;
      if (thread_suspend(thread) != KERN_SUCCESS) {
        continue;
      }
      if (thread_get_state(thread, ARM_THREAD_STATE64,
                           reinterpret_cast<thread_state_t>(&state), &state_size) == KERN_SUCCESS) {
        samples[count++] = {thread, arm_thread_state64_get_pc(state)};
      }
      thread_resume(thread);
    }
    ++rounds;
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  for (thread_t thread : threads) {
    mach_port_deallocate(task, thread);
  }

  // Aggregate only after all sampled threads have been resumed.
  std::map<std::pair<uint32_t, std::string>, uint32_t> hits;
  char buffer[PATH_MAX + 32];
  for (size_t i = 0; i < count; ++i) {
    const uint64_t pc = samples[i].pc;
    if (uint32_t guest = MclaGuestFunctionForHostPc(static_cast<uintptr_t>(pc))) {
      std::snprintf(buffer, sizeof buffer, "guest sub_%08X", guest);
    } else {
      Dl_info module{};
      if (dladdr(reinterpret_cast<const void*>(pc), &module) && module.dli_fname) {
        const char* base = std::strrchr(module.dli_fname, '/');
        std::snprintf(buffer, sizeof buffer, "module %s 0x%llX",
                      base ? base + 1 : module.dli_fname,
                      static_cast<unsigned long long>(pc - reinterpret_cast<uintptr_t>(module.dli_fbase)));
      } else {
        std::snprintf(buffer, sizeof buffer, "unknown 0x%llX", static_cast<unsigned long long>(pc));
      }
    }
    ++hits[{samples[i].thread_id, buffer}];
  }

  if (FILE* f = std::fopen(path.c_str(), "w")) {
    std::fprintf(f, "# rounds=%llu seconds=%d threads=%zu samples=%zu\n",
                 static_cast<unsigned long long>(rounds), seconds, threads.size(), count);
    for (const auto& [key, n] : hits) {
      std::fprintf(f, "%u\t%u\t%s\n", key.first, n, key.second.c_str());
    }
    std::fclose(f);
  }
  REXLOG_INFO("profile: {} samples over {} rounds written to {}", count, rounds, path);
}

}  // namespace
#endif

void MclaApp::StartProfilerIfRequested() {
#if defined(_WIN32) || (defined(__APPLE__) && defined(__aarch64__))
  std::string path = REXCVAR_GET(mcla_profile);
  if (path.empty()) {
    return;
  }
  std::thread(RunProfile, path, static_cast<int>(REXCVAR_GET(mcla_profile_delay)),
              static_cast<int>(REXCVAR_GET(mcla_profile_seconds)))
      .detach();
#endif
}
