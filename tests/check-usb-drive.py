#!/usr/bin/env python3
import os
from pathlib import Path
import subprocess
import sys


def main():
    repo = Path(__file__).resolve().parent.parent
    android = Path(sys.argv[1]).resolve()
    out = Path(sys.argv[2]).resolve()
    out.mkdir(parents=True, exist_ok=True)
    subprocess.run([sys.executable, str(repo / "tools/recovery_emmc_strings.py"),
                    str(repo / "res/values/strings.xml"), str(out / "recovery_emmc_strings.h")],
                   check=True)
    compiler = os.environ.get("CXX", "clang++")
    flags = [compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror",
             "-D__printflike(a,b)=__attribute__((format(printf,a,b)))",
             "-I" + str(out), "-I" + str(repo / "recovery_ui/include"),
             "-I" + str(repo / "volume_manager/include"),
             "-I" + str(android / "system/core/base/include")]
    # Compile the production UI against the actual Android/recovery declarations.
    subprocess.run(flags + ["-fsyntax-only", str(repo / "recovery_usb_drive.cpp")], check=True)
    source = (repo / "recovery_usb_drive.cpp").read_text()
    countdown = source[source.index("class UsbDriveCountdown {"):
                       source.index("static std::string decode_mount_path(")]
    decode = source[source.index("static std::string decode_mount_path("):
                    source.index("static bool unmount_usb_drive(")]
    # Exercise the unchanged production countdown with a small, scripted UI.
    harness = r'''
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <functional>
#include <linux/input.h>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include "recovery_emmc_strings.h"

namespace android { namespace base {
std::string StringPrintf(const char* format, int seconds) {
  char text[128];
  snprintf(text, sizeof(text), format, seconds);
  return text;
}
}}

struct RecoveryUI {
  int mode = 0;
  int calls = 0;
  bool tick = false;
  std::vector<std::string> labels;
  std::mutex mutex;
  std::condition_variable condition;
  void CancelWaitKey() {
    std::lock_guard<std::mutex> lock(mutex);
    tick = true;
    condition.notify_one();
  }
  size_t ShowMenu(const std::vector<std::string>&, const std::vector<std::string>& items,
                  size_t initial, bool menu_only, const std::function<int(int, bool)>& handler,
                  bool refreshable);
};

struct Device {
  static constexpr int kRefresh=-10, kNoAction=-1, kHighlightUp=-2, kHighlightDown=-3,
                       kGoBack=-5, kInvokeItem=-4;
  RecoveryUI ui;
  RecoveryUI* GetUI() { return &ui; }
  int HandleMenuKey(int key, bool) {
    if (key==KEY_UP) return kHighlightUp;
    if (key==KEY_DOWN) return kHighlightDown;
    if (key==KEY_BACK) return kGoBack;
    return kInvokeItem;
  }
};

size_t RecoveryUI::ShowMenu(const std::vector<std::string>&,
                           const std::vector<std::string>& items, size_t initial,
                           bool menu_only, const std::function<int(int, bool)>& handler,
                           bool refreshable) {
  assert(initial==0 && menu_only && refreshable);
  assert(items[0]==emmc_strings::emmc_cancel);
  ++calls;
  labels.push_back(items[1]);
  if (mode==0) return 0;
  if (mode==1) return static_cast<size_t>(handler(KEY_BACK, true));
  if (items[1]==emmc_strings::usb_drive_continue) {
    assert(handler(KEY_DOWN, true)==Device::kHighlightDown);
    std::unique_lock<std::mutex> lock(mutex);
    assert(!condition.wait_for(lock, std::chrono::milliseconds(1100), [this] { return tick; }));
    return 1;
  }
  assert(handler(KEY_DOWN, true)==Device::kNoAction);
  assert(handler(KEY_UP, true)==Device::kNoAction);
  if (calls==1) return 1;  // A touch on the disabled confirmation must not bypass the timer.
  std::unique_lock<std::mutex> lock(mutex);
  condition.wait(lock, [this] { return tick; });
  tick = false;
  return static_cast<size_t>(handler(KEY_AGAIN, true));
}
'''
    harness += countdown + decode + r'''
int main() {
  Device device;
  auto begin=std::chrono::steady_clock::now();
  assert(!confirm_usb_drive(&device));
  assert(device.ui.labels[0]=="Continue (5)");
  assert(std::chrono::steady_clock::now()-begin < std::chrono::seconds(1));
  device.ui.mode=1;
  assert(!confirm_usb_drive(&device));
  device.ui.mode=2;
  device.ui.calls=0;
  device.ui.labels.clear();
  begin=std::chrono::steady_clock::now();
  assert(confirm_usb_drive(&device));
  assert(std::chrono::steady_clock::now()-begin >= std::chrono::seconds(5));
  for (int second=1; second<=5; ++second) {
    auto label="Continue (" + std::to_string(second) + ")";
    bool seen=false;
    for (const auto& item : device.ui.labels) seen |= item==label;
    assert(seen);
  }
  assert(decode_mount_path("/storage/My\\040Card")=="/storage/My Card");
  assert(decode_mount_path("/a\\134b\\011c")=="/a\\b\tc");
  assert(decode_mount_path("/data")=="/data");
  puts("Recovery C++ syntax, five-second gate, Cancel, B and mount-path checks passed");
}
'''
    (out / "countdown.cpp").write_text(harness)
    subprocess.run([compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror", "-pthread",
                    "-I" + str(out), str(out / "countdown.cpp"), "-o", str(out / "countdown")],
                   check=True)
    subprocess.run([str(out / "countdown")], check=True)


if __name__ == "__main__":
    main()
