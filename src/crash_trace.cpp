// Guest crash tracer.
//
// When recompiled code faults on the guest null page, log the host call stack
// with each frame mapped back to the guest function it belongs to. Needs no
// debug symbols: host function addresses come from the dispatch table.

#include "generated/default/mcla_init.h"

#include "mcla_app.h"

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <utility>
#include <vector>

#include <rex/cvar.h>
#include <rex/logging.h>
#include <rex/runtime.h>
#include <rex/system/function_dispatcher.h>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <rex/exception_handler.h>
#ifdef __APPLE__
#include <pthread.h>
#endif
#endif

REXCVAR_DEFINE_BOOL(mcla_test_null_write, false, "MCLA",
                    "DEV ONLY: write to guest address 0 once the crash trace is installed, to "
                    "test the crash tracer. Crashes the game");

namespace {

constexpr uint32_t kCodeBegin = 0x82130000;
constexpr uint32_t kCodeEnd = 0x827CD054;
constexpr uintptr_t kNullPageSize = 0x10000;
// Largest plausible distance from a function's entry to an address inside it.
constexpr uintptr_t kMaxFunctionSpan = 0x80000;

// Host address of guest address 0. Not a constant: macOS picks it at run time.
uintptr_t g_guest_base = 0;

std::vector<std::pair<uintptr_t, uint32_t>> g_host_to_guest;

uint32_t GuestFunctionFor(uintptr_t host_pc, uintptr_t* offset) {
  auto it = std::upper_bound(g_host_to_guest.begin(), g_host_to_guest.end(),
                             std::make_pair(host_pc, UINT32_MAX));
  if (it == g_host_to_guest.begin()) {
    return 0;
  }
  --it;
  if (host_pc - it->first > kMaxFunctionSpan) {
    return 0;
  }
  *offset = host_pc - it->first;
  return it->second;
}

#ifdef _WIN32
LONG CALLBACK OnException(EXCEPTION_POINTERS* info) {
  static LONG reported = 0;
  const EXCEPTION_RECORD* record = info->ExceptionRecord;
  if (record->ExceptionCode != EXCEPTION_ACCESS_VIOLATION || record->NumberParameters < 2) {
    return EXCEPTION_CONTINUE_SEARCH;
  }
  uintptr_t fault = record->ExceptionInformation[1];
  if (fault < g_guest_base || fault >= g_guest_base + kNullPageSize) {
    return EXCEPTION_CONTINUE_SEARCH;
  }
  if (InterlockedExchange(&reported, 1)) {
    return EXCEPTION_CONTINUE_SEARCH;
  }

  REXLOG_ERROR("guest null-page {} at guest 0x{:08X}; host stack (innermost first):",
               record->ExceptionInformation[0] ? "write" : "read",
               static_cast<uint32_t>(fault - g_guest_base));
  CONTEXT context = *info->ContextRecord;
  for (int frame = 0; frame < 32 && context.Rip; ++frame) {
    uintptr_t offset = 0;
    if (uint32_t guest = GuestFunctionFor(context.Rip, &offset)) {
      REXLOG_ERROR("  #{:<2} sub_{:08X} +0x{:X} (host)", frame, guest, offset);
    } else {
      REXLOG_ERROR("  #{:<2} host 0x{:016X}", frame, static_cast<uint64_t>(context.Rip));
    }
    DWORD64 image_base = 0;
    PRUNTIME_FUNCTION function = RtlLookupFunctionEntry(context.Rip, &image_base, nullptr);
    if (!function) {
      // Leaf function: return address is at the top of the stack.
      context.Rip = *reinterpret_cast<DWORD64*>(context.Rsp);
      context.Rsp += 8;
      continue;
    }
    void* handler_data = nullptr;
    DWORD64 establisher = 0;
    RtlVirtualUnwind(UNW_FLAG_NHANDLER, image_base, context.Rip, function, &context,
                     &handler_data, &establisher, nullptr);
  }
  return EXCEPTION_CONTINUE_SEARCH;
}
#else
// Note: on Apple each guest function is a weak musttail thunk plus an __imp__
// body (pch_h.inja) and the dispatch table points at the thunk, so a pc is
// attributed to the nearest thunk below it. Hooked functions may be misattributed.
bool OnPosixFault(rex::arch::Exception* ex, void*) {
  static std::atomic<bool> reported{false};
  if (ex->code() != rex::arch::Exception::Code::kAccessViolation) {
    return false;
  }
  uint64_t fault = ex->fault_address();
  if (fault < g_guest_base || fault >= g_guest_base + kNullPageSize) {
    return false;
  }
  if (reported.exchange(true)) {
    return false;
  }
  uint64_t pc = ex->pc();
  REXLOG_ERROR("guest null-page access at guest 0x{:08X}, host pc 0x{:016X}",
               static_cast<uint32_t>(fault - g_guest_base), pc);
#if defined(__aarch64__)
  auto* context = ex->thread_context();
  uintptr_t stack_low = 0;
  uintptr_t stack_high = UINTPTR_MAX;
#ifdef __APPLE__
  // The stack address is the top of the stack. Bound the walk so a bad frame
  // pointer cannot fault here: there is no SA_NODEFER, so that kills the process.
  pthread_t self = pthread_self();
  stack_high = reinterpret_cast<uintptr_t>(pthread_get_stackaddr_np(self));
  stack_low = stack_high - pthread_get_stacksize_np(self);
#endif
  REXLOG_ERROR("host stack (innermost first):");
  auto log_frame = [](int frame, uint64_t address) {
    uintptr_t offset = 0;
    if (uint32_t guest = GuestFunctionFor(static_cast<uintptr_t>(address), &offset)) {
      REXLOG_ERROR("  #{:<2} sub_{:08X} +0x{:X} (host)", frame, guest, offset);
    } else {
      REXLOG_ERROR("  #{:<2} host 0x{:016X}", frame, address);
    }
  };
  log_frame(0, pc);
  // Frame records: [fp] is the previous fp, [fp + 8] the return address.
  uintptr_t fp = static_cast<uintptr_t>(context->x[29]);
  uintptr_t last_fp = 0;
  int frame = 1;
  for (; frame < 32; ++frame) {
    if ((fp & 0xF) != 0 || fp <= last_fp || fp < stack_low || fp + 16 > stack_high) {
      break;
    }
    const uintptr_t* record = reinterpret_cast<const uintptr_t*>(fp);
    uintptr_t return_address = record[1];
    if (!return_address) {
      break;
    }
    log_frame(frame, return_address);
    last_fp = fp;
    fp = record[0];
  }
#endif
  // Decline: the SDK chains on and the process crashes.
  return false;
}
#endif

}  // namespace

// Guest function containing a host address inside recompiled code, or 0.
uint32_t MclaGuestFunctionForHostPc(uintptr_t host_pc) {
  uintptr_t offset = 0;
  return GuestFunctionFor(host_pc, &offset);
}

void MclaApp::InstallCrashTrace() {
  g_guest_base = reinterpret_cast<uintptr_t>(runtime()->virtual_membase());
  auto* dispatcher = runtime()->function_dispatcher();
  g_host_to_guest.clear();
  for (uint32_t address = kCodeBegin; address < kCodeEnd; address += 4) {
    if (auto* function = dispatcher->GetFunction(address)) {
      g_host_to_guest.emplace_back(reinterpret_cast<uintptr_t>(function), address);
    }
  }
  std::sort(g_host_to_guest.begin(), g_host_to_guest.end());
  REXLOG_INFO("crash trace: {} guest functions mapped", g_host_to_guest.size());
#ifdef _WIN32
  AddVectoredExceptionHandler(1, OnException);
#else
  rex::arch::ExceptionHandler::Install(OnPosixFault, nullptr);
#endif
  if (REXCVAR_GET(mcla_test_null_write)) {
    REXLOG_WARN("mcla_test_null_write: writing to guest address 0");
    *reinterpret_cast<volatile uint8_t*>(g_guest_base) = 0;
  }
  StartProfilerIfRequested();
}
