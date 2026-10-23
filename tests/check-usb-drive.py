#!/usr/bin/env python3
import json
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
    check_protocol(repo, out, compiler, source)


def check_protocol(repo, out, compiler, source):
    # Run the production socket reader and sharing flow, including failure recovery.
    helper = out / "helper.sh"
    helper.write_text(r'''case $1 in
recover) echo stopped >"$TEST_PHASE"; echo stopped ;;
volumes) echo public:179_32 ;;
mounts) echo /storage/card ;;
session)
    echo gated >"$TEST_PHASE"
    printf 'log|gate_gadget: acknowledged\ngated\n'
    IFS= read -r request || exit 1
    if [ "$request" = start ]; then
        [ -f "$TEST_PHASE.unmounted" ] || exit 1
        [ "$TEST_MODE" != eof ] || exit 1
        if [ "$TEST_MODE" = start_error ]; then
            printf 'log|failed: bind_udc\nerror|setup||bind_udc\n'
        else
            echo ready >"$TEST_PHASE"
            printf 'log|bind_udc: bound ff300000.usb\nready|0|none\n'
        fi
        IFS= read -r request || exit 1
    fi
    [ "$request" = stop ] || exit 1
    if [ "$TEST_MODE" = cleanup_error ]; then
        printf 'log|failed: close_drive\nerror|cleanup||close_drive\n'
        exit 1
    fi
    echo stopped >"$TEST_PHASE"
    printf 'log|stopped\nstopped\n'
    ;;
*) exit 1 ;;
esac
''')
    harness = r'''
#include <algorithm>
#include <cassert>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <functional>
#include <linux/input.h>
#include <mutex>
#include <string>
#include <sys/socket.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>
#include <vector>
#include "recovery_emmc_strings.h"

namespace android { namespace base {
std::string Trim(const std::string& text) {
  auto first=text.find_first_not_of(" \t\r\n");
  return first==std::string::npos ? "" : text.substr(first, text.find_last_not_of(" \t\r\n")-first+1);
}
std::vector<std::string> Split(const std::string& text, const std::string& separator) {
  std::vector<std::string> result;
  size_t first=0, next;
  while ((next=text.find(separator, first))!=std::string::npos) {
    result.push_back(text.substr(first, next-first)); first=next+separator.size();
  }
  result.push_back(text.substr(first)); return result;
}
std::string StringPrintf(const char* format, ...) {
  char text[4096];
  va_list args; va_start(args, format); vsnprintf(text, sizeof(text), format, args); va_end(args);
  return text;
}
std::string role="host";
int role_writes=0;
bool ReadFileToString(const char*, std::string* text) { *text=role; return true; }
bool WriteStringToFile(const std::string& text, const char*) { role=text; ++role_writes; return true; }
}}
std::string phase() { std::ifstream input(getenv("TEST_PHASE")); std::string text; input>>text; return text; }
std::string mode() { return getenv("TEST_MODE"); }
struct VolumeInfo { std::string mId="public:179_32", mPath="/storage/card"; };
struct VolumeManager {
  std::mutex mutex;
  static VolumeManager* Instance() { static VolumeManager manager; return &manager; }
  void getVolumeInfo(std::vector<VolumeInfo>& volumes) {
    std::lock_guard<std::mutex> lock(mutex); assert(phase()=="gated"); volumes.push_back({});
  }
  bool volumeUnmount(const std::string&) {
    std::lock_guard<std::mutex> lock(mutex); assert(phase()=="gated");
    std::ofstream(std::string(getenv("TEST_PHASE"))+".unmounted")<<"yes";
    return mode()!="unmount_error";
  }
  std::unique_lock<std::mutex> lockForUsbDrive() { return std::unique_lock<std::mutex>(mutex); }
};
struct RecoveryUI {
  int shared=0, failures=0, retries=0, confirmations=0;
  size_t confirmation=1;
  size_t ShowMenu(const std::vector<std::string>& headers, const std::vector<std::string>& items,
                  size_t, bool, const std::function<int(int, bool)>& handler) {
    if (headers[0]==emmc_strings::usb_title) {
      assert(headers[2]==emmc_strings::usb_wifi && headers[3]==emmc_strings::usb_charging);
      ++confirmations; return confirmation;
    }
    if (items[0]==emmc_strings::usb_drive_stop) {
      assert(phase()=="ready" && handler(KEY_BACK, true)==0 && handler(KEY_A, true)==0); ++shared;
    } else if (items[0]==emmc_strings::usb_drive_retry) {
      assert(headers[0].find("close_drive")!=std::string::npos); ++retries;
    } else {
      assert(phase()=="stopped");
      assert(headers[0].find(mode()=="start_error" ? "bind_udc" :
                             mode()=="unmount_error" ? "unmount_volumes" : "start")!=std::string::npos);
      ++failures;
    }
    return 0;
  }
  void Print(const char*, ...) {}
};
struct Device {
  RecoveryUI ui;
  RecoveryUI* GetUI() { return &ui; }
  int HandleMenuKey(int key, bool) { return key; }
};
'''
    production = source[source.index("class UsbDriveHelper {"):
                        source.index("// CancelWaitKey")]
    production += source[source.index("static std::string decode_mount_path("):
                         source.index("void UsbDriveMenu(")]
    production = production.replace('"/system/bin/sh", "/system/etc/recovery-usb-drive.sh"',
                                    '"/bin/sh", ' + json.dumps(str(helper)))
    recovery = (repo / "recovery.cpp").read_text()
    production += recovery[recovery.index("static const char kOtgMode[]"):
                           recovery.index("static InstallResult apply_update_menu(")]
    harness += production + r'''
int main() {
  Device device;
  assert(usb_device_mode(&device, false));
  assert(android::base::role=="host" && android::base::role_writes==0);
  device.ui.confirmation=0;
  assert(!usb_device_mode(&device, false));
  assert(android::base::role_writes==0);
  device.ui.confirmation=1;
  assert(usb_device_mode(&device));
  assert(android::base::role=="peripheral" && android::base::role_writes==1);
  assert(usb_device_mode(&device, false));
  assert(device.ui.confirmations==3 && android::base::role_writes==1);
  assert(usb_drive_error("error|busy|/data|unmount_disk").find("/data")!=std::string::npos);
  assert(usb_drive_error("error|changed||check_drive").find("check_drive")!=std::string::npos);
  UsbDrive drive{"mmcblk1", 2, 33554432, "0123456789abcdef0123456789abcdef", "none", false};
  share_usb_drive(&device, drive, false);
  assert(device.ui.shared==int(mode()=="normal" || mode()=="cleanup_error"));
  assert(device.ui.failures==int(mode()=="start_error" || mode()=="unmount_error" || mode()=="eof"));
  assert(device.ui.retries==int(mode()=="cleanup_error"));
  assert(phase()=="stopped");
}
'''
    (out / "protocol.cpp").write_text(harness)
    subprocess.run([compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror", "-pthread",
                    "-I" + str(out), str(out / "protocol.cpp"), "-o", str(out / "protocol")],
                   check=True)
    for mode in ["normal", "start_error", "cleanup_error", "unmount_error", "eof"]:
        result = subprocess.run([str(out / "protocol")], check=True, timeout=10,
                                env={**os.environ, "TEST_MODE": mode,
                                     "TEST_PHASE": str(out / ("phase-" + mode))},
                                capture_output=True, text=True)
        assert "recovery-usb-drive: log|gate_gadget: acknowledged" in result.stdout
        if mode in ["normal", "cleanup_error"]:
            assert "recovery-usb-drive: log|bind_udc: bound" in result.stdout
        if mode in ["start_error", "cleanup_error"]:
            assert "recovery-usb-drive: log|failed:" in result.stdout
    print("Recovery role confirmation, gated unmount, log forwarding, errors, Stop and journal retry passed")


if __name__ == "__main__":
    main()
