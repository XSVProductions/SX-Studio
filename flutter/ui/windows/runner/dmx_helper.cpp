// The DMX output's own process on Windows:
//   sx_studio.exe --dmx-helper --dir <ShowXpress folder>
//
// Same job and stdin protocol as the Mac's sxh_dmx (packaging/mac/dmx/main.swift) and the old app's dmx_out.ps1:
//   first line printed: "OK <interface name>" or "ERR <why>" ("ERR none" = no interface), then one line per change
//   from stdin: z (all 0) | b:ch:v (raw byte) | k (keep-alive) | q (quit)
//   No command for 30 s or stdin closed -> all channels 0, interface closed, exit.
// A frame goes out as soon as a line arrives (at most 50 a second). With nothing new it is sent again every 40 ms.
// The glides (p: and s:) are not here: SX Studio works them out itself and sends bytes (helper_dmx.dart).
//
// Why a process of its own: Chauvet's driver (efk_hardware.dll) names the interface once per process. Asked again
// in the same process it answers "err_0", also after EFK_close and after the DLL was unloaded and loaded again
// (tried on a real D512S). A program that opens the interface a second time has to be a new one. The old app
// started a PowerShell child for every open, which is why it never met this.

#include "dmx_helper.h"

#include <windows.h>

#include <mmsystem.h>
#include <shellapi.h>

#include <cstdlib>
#include <cstring>
#include <string>

#pragma comment(lib, "winmm.lib")

namespace {

const int kChannels = 512 * 16;

// The old C# declared every call as returning `long` (64-bit), and the names as a pointer to UTF-16 text.
typedef long long (*FnL)();
typedef const wchar_t* (*FnP)();
typedef long long (*FnS)(unsigned char*);

HANDLE g_out = nullptr;
HANDLE g_line = nullptr;  // set by the reader for every line: the main loop sends the new frame at once
SRWLOCK g_lock = SRWLOCK_INIT;
unsigned char g_frame[kChannels];
bool g_running = true;
ULONGLONG g_last_command = 0;

void Say(const std::string& s) {
  const std::string line = s + "\n";
  DWORD n = 0;
  ::WriteFile(g_out, line.data(), static_cast<DWORD>(line.size()), &n, nullptr);
}

// A whole number from 0 to `max`, or -1.
int Num(const std::string& s, int max) {
  if (s.empty() || s.size() > 6) return -1;
  for (char c : s) {
    if (c < '0' || c > '9') return -1;
  }
  const int v = std::atoi(s.c_str());
  return v <= max ? v : -1;
}

void Apply(const std::string& line) {
  ::AcquireSRWLockExclusive(&g_lock);
  g_last_command = ::GetTickCount64();
  size_t at = 0;
  while (at < line.size()) {
    size_t end = line.find(' ', at);
    if (end == std::string::npos) end = line.size();
    const std::string t = line.substr(at, end - at);
    at = end + 1;
    if (t == "z") {
      std::memset(g_frame, 0, kChannels);
    } else if (t == "q") {
      g_running = false;
    } else if (t.rfind("b:", 0) == 0) {
      const size_t colon = t.find(':', 2);
      if (colon == std::string::npos) continue;
      const int ch = Num(t.substr(2, colon - 2), kChannels), v = Num(t.substr(colon + 1), 255);
      if (ch >= 1 && v >= 0) g_frame[ch - 1] = static_cast<unsigned char>(v);
    }
  }
  ::ReleaseSRWLockExclusive(&g_lock);
}

DWORD WINAPI Reader(LPVOID) {
  const HANDLE in = ::GetStdHandle(STD_INPUT_HANDLE);
  std::string pending;
  char buf[65536];
  DWORD n = 0;
  bool run = true;
  while (run && ::ReadFile(in, buf, sizeof(buf), &n, nullptr) && n > 0) {
    pending.append(buf, n);
    size_t nl;
    while ((nl = pending.find('\n')) != std::string::npos) {
      std::string line = pending.substr(0, nl);
      pending.erase(0, nl + 1);
      if (!line.empty() && line.back() == '\r') line.pop_back();
      Apply(line);
    }
    ::AcquireSRWLockShared(&g_lock);
    run = g_running;
    ::ReleaseSRWLockShared(&g_lock);
    ::SetEvent(g_line);
  }
  // stdin closed: SX Studio is gone, so the lights go out
  ::AcquireSRWLockExclusive(&g_lock);
  g_running = false;
  ::ReleaseSRWLockExclusive(&g_lock);
  ::SetEvent(g_line);
  return 0;
}

double Millis() {
  LARGE_INTEGER t, f;
  ::QueryPerformanceCounter(&t);
  ::QueryPerformanceFrequency(&f);
  return 1000.0 * static_cast<double>(t.QuadPart) / static_cast<double>(f.QuadPart);
}

int Run(const std::wstring& dir) {
  g_out = ::GetStdHandle(STD_OUTPUT_HANDLE);
  // the driver loads its helpers (efk_usb.dll, ftd2xx.dll) by bare name from its own folder
  ::SetDllDirectoryW(dir.c_str());
  const HMODULE lib = ::LoadLibraryW((dir + L"\\efk_hardware.dll").c_str());
  if (lib == nullptr) {
    Say("ERR The DMX output didn't start: Windows could not load efk_hardware.dll (error " + std::to_string(::GetLastError()) + ").");
    return 0;
  }
  const FnL check = reinterpret_cast<FnL>(::GetProcAddress(lib, "EFK_check_hardware"));
  const FnL open = reinterpret_cast<FnL>(::GetProcAddress(lib, "EFK_open"));
  const FnL close = reinterpret_cast<FnL>(::GetProcAddress(lib, "EFK_close"));
  const FnL stream = reinterpret_cast<FnL>(::GetProcAddress(lib, "EFK_stream_mode"));
  const FnP names = reinterpret_cast<FnP>(::GetProcAddress(lib, "EFK_get_name_of_interfaces"));
  const FnS send = reinterpret_cast<FnS>(::GetProcAddress(lib, "EFK_send_dmx"));
  if (!check || !open || !close || !stream || !names || !send) {
    Say("ERR The DMX output didn't start: efk_hardware.dll is not the driver SX Studio knows.");
    return 0;
  }

  check();
  const wchar_t* raw = names();
  std::wstring name = raw == nullptr ? L"" : raw;
  const bool err = name.rfind(L"err", 0) == 0;
  // .NET's Trim('|', ' ')
  const size_t first = name.find_first_not_of(L"| ");
  name = first == std::wstring::npos ? L"" : name.substr(first, name.find_last_not_of(L"| ") - first + 1);
  if (name.empty() || err) {
    Say("ERR none");
    return 0;
  }
  open();
  stream();
  ::CharUpperBuffW(&name[0], static_cast<DWORD>(name.size()));
  std::string utf8(::WideCharToMultiByte(CP_UTF8, 0, name.c_str(), static_cast<int>(name.size()), nullptr, 0, nullptr, nullptr), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, name.c_str(), static_cast<int>(name.size()), &utf8[0], static_cast<int>(utf8.size()), nullptr, nullptr);
  Say("OK " + utf8);

  // waits to the millisecond instead of Windows' usual 15.6 ms steps
  ::timeBeginPeriod(1);
  g_line = ::CreateEventW(nullptr, FALSE, FALSE, nullptr);
  g_last_command = ::GetTickCount64();
  ::CloseHandle(::CreateThread(nullptr, 0, Reader, nullptr, 0, nullptr));

  static unsigned char out[kChannels];
  while (true) {
    ::AcquireSRWLockExclusive(&g_lock);
    if (::GetTickCount64() - g_last_command > 30000) g_running = false;
    const bool run = g_running;
    std::memcpy(out, g_frame, kChannels);
    ::ReleaseSRWLockExclusive(&g_lock);
    if (!run) break;
    send(out);
    const double sent = Millis();
    // the next frame: when a line arrives, but not within 20 ms of this one. Lines that came together make one frame.
    if (::WaitForSingleObject(g_line, 40) == WAIT_OBJECT_0) {
      const double since = Millis() - sent;
      if (since < 20) ::Sleep(static_cast<DWORD>(20 - since));
    }
  }

  // lights out, then let ShowXpress have the interface again
  std::memset(out, 0, kChannels);
  for (int i = 0; i < 3; i++) {
    send(out);
    ::Sleep(30);
  }
  close();
  ::timeEndPeriod(1);
  return 0;
}

}  // namespace

int RunDmxHelperIfAsked() {
  int argc = 0;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) return -1;
  bool asked = false;
  std::wstring dir;
  for (int i = 1; i < argc; i++) {
    const std::wstring a = argv[i];
    if (a == L"--dmx-helper") {
      asked = true;
    } else if (a == L"--dir" && i + 1 < argc) {
      dir = argv[++i];
    }
  }
  ::LocalFree(argv);
  return asked ? Run(dir) : -1;
}
