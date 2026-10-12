// Guest crash tracer.
//
// When recompiled code faults on the guest null page, log the host call stack
// with each frame mapped back to the guest function it belongs to. Needs no
// debug symbols: host function addresses come from the dispatch table.

#include "generated/default/mcla_init.h"

#include "mcla_app.h"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstdint>
#include <string>
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
#include <fcntl.h>
#include <unistd.h>
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
// The fault handler runs on the faulting thread, which may hold a logging lock
// or the heap lock, so it must not log, allocate or format with the C library.
// It formats into stack buffers and write(2)s them to stderr and, when the log
// file is known at install time, to a descriptor opened then.
std::atomic<bool> g_reported{false};
static_assert(std::atomic<bool>::is_always_lock_free, "needed in a signal handler");
int g_log_fd = -1;

class LineBuffer {
 public:
  void Str(const char* text) {
    while (*text && length_ < sizeof(data_) - 1) {
      data_[length_++] = *text++;
    }
  }
  // At least min_digits digits, more if the value needs them.
  void Hex(uint64_t value, int min_digits) {
    int digits = 1;
    while (digits < 16 && (value >> (digits * 4)) != 0) {
      ++digits;
    }
    digits = std::max(digits, min_digits);
    for (int shift = (digits - 1) * 4; shift >= 0 && length_ < sizeof(data_) - 1; shift -= 4) {
      data_[length_++] = "0123456789ABCDEF"[(value >> shift) & 0xF];
    }
  }
  void Dec(uint64_t value) {
    char digits[20];
    int count = 0;
    do {
      digits[count++] = static_cast<char>('0' + value % 10);
      value /= 10;
    } while (value);
    while (count && length_ < sizeof(data_) - 1) {
      data_[length_++] = digits[--count];
    }
  }
  void Write() {
    data_[length_++] = '\n';
    WriteAll(STDERR_FILENO);
    if (g_log_fd >= 0) {
      WriteAll(g_log_fd);
    }
    length_ = 0;
  }

 private:
  void WriteAll(int fd) const {
    size_t done = 0;
    while (done < length_) {
      ssize_t n = write(fd, data_ + done, length_ - done);
      if (n < 0 && errno == EINTR) {
        continue;
      }
      if (n <= 0) {
        break;
      }
      done += static_cast<size_t>(n);
    }
  }
  // One spare byte for the newline.
  char data_[192];
  size_t length_ = 0;
};

// Note: on Apple each guest function is a weak musttail thunk plus an __imp__
// body (pch_h.inja) and the dispatch table points at the thunk, so a pc is
// attributed to the nearest thunk below it. Hooked functions may be misattributed.
bool OnPosixFault(rex::arch::Exception* ex, void*) {
  if (ex->code() != rex::arch::Exception::Code::kAccessViolation) {
    return false;
  }
  uint64_t fault = ex->fault_address();
  if (fault < g_guest_base || fault >= g_guest_base + kNullPageSize) {
    return false;
  }
  if (g_reported.exchange(true)) {
    return false;
  }
  uint64_t pc = ex->pc();
  LineBuffer line;
  line.Str("guest null-page access at guest 0x");
  line.Hex(static_cast<uint32_t>(fault - g_guest_base), 8);
  line.Str(", host pc 0x");
  line.Hex(pc, 16);
  line.Write();
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
  line.Str("host stack (innermost first):");
  line.Write();
  auto log_frame = [&line](int frame, uint64_t address) {
    uintptr_t offset = 0;
    line.Str("  #");
    line.Dec(static_cast<uint64_t>(frame));
    line.Str(frame < 10 ? "  " : " ");
    if (uint32_t guest = GuestFunctionFor(static_cast<uintptr_t>(address), &offset)) {
      line.Str("sub_");
      line.Hex(guest, 8);
      line.Str(" +0x");
      line.Hex(offset, 1);
      line.Str(" (host)");
    } else {
      line.Str("host 0x");
      line.Hex(address, 16);
    }
    line.Write();
  };
  log_frame(0, pc);
  // Frame records: [fp] is the previous fp, [fp + 8] the return address.
  uintptr_t fp = static_cast<uintptr_t>(context->x[29]);
  uintptr_t last_fp = 0;
  int frame = 1;
  for (; frame < 32; ++frame) {
    // fp > stack_high - 16 instead of fp + 16 > stack_high: no wrap near UINTPTR_MAX.
    if (stack_high < stack_low + 16 || (fp & 0xF) != 0 || fp <= last_fp || fp < stack_low ||
        fp > stack_high - 16) {
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
  // Opened here because open(2) is not worth risking inside the handler. Only
  // an explicit log_file is known; otherwise the trace goes to stderr alone.
  std::string log_path = REXCVAR_GET(log_file);
  if (g_log_fd < 0 && !log_path.empty()) {
    g_log_fd = open(log_path.c_str(), O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0644);
  }
  rex::arch::ExceptionHandler::Install(OnPosixFault, nullptr);
#endif
  if (REXCVAR_GET(mcla_test_null_write)) {
    REXLOG_WARN("mcla_test_null_write: writing to guest address 0");
    *reinterpret_cast<volatile uint8_t*>(g_guest_base) = 0;
  }
  StartProfilerIfRequested();
}
