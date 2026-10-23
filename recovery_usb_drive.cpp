#include "recovery_usb_drive.h"

#include <errno.h>
#include <linux/input.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <android-base/parseint.h>
#include <android-base/stringprintf.h>
#include <android-base/strings.h>
#include <volume_manager/VolumeManager.h>

#include "recovery_emmc_strings.h"
#include "recovery_ui/device.h"
#include "recovery_ui/ui.h"

using android::volmgr::VolumeInfo;
using android::volmgr::VolumeManager;

class UsbDriveHelper {
 public:
  ~UsbDriveHelper() {
    if (output_ != nullptr) {
      shutdown(fileno(output_), SHUT_WR);
      fclose(output_);
    }
    if (child_ != -1) TEMP_FAILURE_RETRY(waitpid(child_, nullptr, 0));
  }

  bool Start(const std::vector<std::string>& args) {
    std::vector<const char*> argv{ "/system/bin/sh", "/system/etc/recovery-usb-drive.sh" };
    for (const auto& arg : args) argv.push_back(arg.c_str());
    argv.push_back(nullptr);
    int sockets[2];
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sockets) == -1) return false;
    child_ = fork();
    if (child_ == 0) {
      close(sockets[0]);
      if (dup2(sockets[1], STDIN_FILENO) == -1 || dup2(sockets[1], STDOUT_FILENO) == -1) _exit(1);
      close(sockets[1]);
      execv(argv[0], const_cast<char* const*>(argv.data()));
      _exit(1);
    }
    close(sockets[1]);
    if (child_ == -1) {
      close(sockets[0]);
      return false;
    }
    output_ = fdopen(sockets[0], "r");
    if (output_ == nullptr) close(sockets[0]);
    return output_ != nullptr;
  }

  bool Read(std::string* line) {
    if (output_ == nullptr) return false;
    char* buffer = nullptr;
    size_t capacity = 0;
    ssize_t length;
    while ((length = getline(&buffer, &capacity, output_)) > 0) {
      *line = android::base::Trim(std::string(buffer, length));
      // Helper stdout is our socket; copy progress into recovery.log before parsing replies.
      printf("recovery-usb-drive: %s\n", line->c_str());
      fflush(stdout);
      if (line->compare(0, 4, "log|") != 0) break;
    }
    free(buffer);
    return length > 0;
  }

  bool Command(const std::string& command, std::string* line) {
    if (output_ == nullptr) return false;
    std::string request = command + "\n";
    const char* data = request.c_str();
    size_t remaining = request.size();
    while (remaining > 0) {
      ssize_t sent = TEMP_FAILURE_RETRY(send(fileno(output_), data, remaining, MSG_NOSIGNAL));
      if (sent <= 0) return false;
      data += sent;
      remaining -= sent;
    }
    return Read(line);
  }

  bool Wait() {
    int status;
    bool ok = child_ != -1 && TEMP_FAILURE_RETRY(waitpid(child_, &status, 0)) == child_ &&
              WIFEXITED(status) && WEXITSTATUS(status) == 0;
    child_ = -1;
    return ok;
  }

 private:
  pid_t child_ = -1;
  FILE* output_ = nullptr;
};

static bool run_usb_drive(const std::vector<std::string>& args, std::vector<std::string>* lines) {
  UsbDriveHelper helper;
  if (!helper.Start(args)) return false;
  std::string line;
  while (helper.Read(&line)) lines->push_back(line);
  return helper.Wait();
}

static const char* usb_drive_reason(const std::string& reason) {
  if (reason == "system") return emmc_strings::usb_drive_system_ro;
  if (reason == "unknown") return emmc_strings::usb_drive_unknown_ro;
  if (reason == "locked") return emmc_strings::usb_drive_locked_ro;
  if (reason == "unlock") return emmc_strings::usb_drive_unlock_ro;
  return "";
}

static std::string usb_drive_error(const std::string& response) {
  auto fields = android::base::Split(response, "|");
  std::string error = emmc_strings::usb_drive_failed;
  if (fields.size() >= 2 && fields[1] == "busy") {
    error = android::base::StringPrintf(emmc_strings::usb_drive_busy,
                                        fields.size() > 2 ? fields[2].c_str() : "");
  }
  if (fields.size() >= 2 && fields[1] == "changed") error = emmc_strings::usb_drive_changed;
  if (fields.size() >= 2 && fields[1] == "cleanup") error = emmc_strings::usb_drive_cleanup;
  if (fields.size() > 3 && !fields[3].empty()) {
    error += "\n" + android::base::StringPrintf(emmc_strings::usb_drive_step, fields[3].c_str());
  }
  return error;
}

struct UsbDrive {
  std::string disk;
  int slot;
  uint64_t sectors;
  std::string cid;
  std::string forced;
  bool boot;

  std::string Label() const {
    auto size = android::base::StringPrintf(emmc_strings::usb_drive_size,
                                            static_cast<double>(sectors) / 2097152);
    return slot == 3 ? android::base::StringPrintf(emmc_strings::usb_drive_emmc, size.c_str())
                     : android::base::StringPrintf(emmc_strings::usb_drive_sd, slot, size.c_str());
  }
};

// CancelWaitKey wakes ShowMenu with KEY_AGAIN, which this page treats as Refresh.
class UsbDriveCountdown {
 public:
  explicit UsbDriveCountdown(RecoveryUI* ui)
      : thread_([this, ui] {
          std::unique_lock<std::mutex> lock(mutex_);
          for (int tick = 0; tick < 5; ++tick) {
            if (condition_.wait_for(lock, std::chrono::seconds(1), [this] { return done_; })) break;
            ui->CancelWaitKey();
          }
        }) {}

  ~UsbDriveCountdown() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      done_ = true;
    }
    condition_.notify_one();
    thread_.join();
  }

 private:
  std::mutex mutex_;
  std::condition_variable condition_;
  bool done_ = false;
  std::thread thread_;
};

static bool confirm_usb_drive(Device* device) {
  auto ui = device->GetUI();
  auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  UsbDriveCountdown countdown(ui);
  for (;;) {
    auto left = deadline - std::chrono::steady_clock::now();
    int seconds = left > decltype(left)::zero()
                      ? std::chrono::duration_cast<std::chrono::seconds>(left).count() + 1
                      : 0;
    auto confirm = seconds > 0
                       ? android::base::StringPrintf(emmc_strings::usb_drive_countdown, seconds)
                       : std::string(emmc_strings::usb_drive_continue);
    auto key_handler = [device, seconds](int key, bool visible) {
      if (key == KEY_AGAIN) return Device::kRefresh;
      int action = device->HandleMenuKey(key, visible);
      // The confirmation is visible, but cannot receive focus during the countdown.
      if (seconds > 0 && (action == Device::kHighlightUp || action == Device::kHighlightDown))
        return Device::kNoAction;
      return action;
    };
    size_t chosen =
        ui->ShowMenu({ emmc_strings::usb_drive_warning }, { emmc_strings::emmc_cancel, confirm }, 0,
                     true, key_handler, true);
    if (chosen == static_cast<size_t>(Device::kRefresh)) continue;
    // Touch input can select a row directly; it must obey the same elapsed-time gate.
    if (chosen == 1 && seconds > 0) continue;
    return chosen == 1;
  }
}

static std::string decode_mount_path(const std::string& path) {
  std::string result;
  for (size_t i = 0; i < path.size(); ++i) {
    if (path[i] == '\\' && i + 3 < path.size() && path[i + 1] >= '0' && path[i + 1] <= '7' &&
        path[i + 2] >= '0' && path[i + 2] <= '7' && path[i + 3] >= '0' && path[i + 3] <= '7') {
      result +=
          static_cast<char>((path[i + 1] - '0') * 64 + (path[i + 2] - '0') * 8 + path[i + 3] - '0');
      i += 3;
    } else {
      result += path[i];
    }
  }
  return result;
}

static bool unmount_usb_drive(const UsbDrive& drive, std::string* error) {
  std::vector<std::string> ids, points;
  if (!run_usb_drive({ "volumes", drive.disk, drive.cid }, &ids) ||
      !run_usb_drive({ "mounts", drive.disk, drive.cid }, &points)) {
    *error = emmc_strings::usb_drive_changed;
    return false;
  }
  for (auto& point : points) point = decode_mount_path(point);
  std::vector<VolumeInfo> volumes;
  auto manager = VolumeManager::Instance();
  manager->getVolumeInfo(volumes);
  for (const auto& volume : volumes) {
    if (std::find(ids.begin(), ids.end(), volume.mId) == ids.end() &&
        std::find(points.begin(), points.end(), volume.mPath) == points.end())
      continue;
    if (!manager->volumeUnmount(volume.mId)) {
      *error = android::base::StringPrintf(emmc_strings::usb_drive_busy, volume.mPath.c_str());
      return false;
    }
  }
  return true;
}

static void share_usb_drive(Device* device, const UsbDrive& drive, bool read_only) {
  auto ui = device->GetUI();
  auto key_handler =
      std::bind(&Device::HandleMenuKey, device, std::placeholders::_1, std::placeholders::_2);
  {
    auto volume_lock = VolumeManager::Instance()->lockForUsbDrive();
    std::vector<std::string> recovered;
    while (!run_usb_drive({ "recover" }, &recovered)) {
      std::string error = recovered.empty() ? "error|cleanup||recover" : recovered.back();
      ui->ShowMenu({ usb_drive_error(error) }, { emmc_strings::usb_drive_retry }, 0, true,
                   key_handler);
      recovered.clear();
    }
  }
  UsbDriveHelper helper;
  std::string response;
  if (!helper.Start({ "session", drive.disk, drive.cid, read_only ? "1" : "0" }) ||
      !helper.Read(&response)) {
    response = "error|setup||helper";
  }
  // Init owns the old gadget until this reply. VolumeManager unmounts take their own lock.
  std::string failure;
  bool prepared = response == "gated" && unmount_usb_drive(drive, &failure);
  if (response == "gated" && !prepared) {
    printf("recovery-usb-drive: failed: unmount_volumes: %s\n", failure.c_str());
    failure += "\n" + android::base::StringPrintf(emmc_strings::usb_drive_step, "unmount_volumes");
  }
  // VolumeManager probes briefly mount new filesystems. Keep them out until all LUNs close.
  auto volume_lock = VolumeManager::Instance()->lockForUsbDrive();
  if (prepared && !helper.Command("start", &response)) response = "error|setup||start";
  auto fields = android::base::Split(response, "|");
  bool shared = fields.size() == 3 && fields[0] == "ready";
  if (!shared && failure.empty()) failure = usb_drive_error(response);
  if (shared) {
    std::vector<std::string> headers{ android::base::StringPrintf(emmc_strings::usb_drive_sharing,
                                                                  drive.Label().c_str()) };
    if (fields[1] == "1") headers.push_back(emmc_strings::usb_drive_ro_on);
    if (fields[2] != "none") headers.push_back(usb_drive_reason(fields[2]));
    ui->ShowMenu(headers, { emmc_strings::usb_drive_stop }, 0, false, [](int, bool) { return 0; });
  }
  for (;;) {
    bool replied = helper.Command("stop", &response);
    if (replied && response == "stopped") break;
    // A lost helper may have left LUNs open. Keep recovery blocked until cleanup succeeds.
    if (!replied) {
      helper.Wait();
      std::vector<std::string> result;
      if (run_usb_drive({ "recover" }, &result) && result == std::vector<std::string>{ "stopped" })
        break;
      response = result.empty() ? "error|cleanup||recover" : result.back();
    }
    ui->ShowMenu({ usb_drive_error(response) }, { emmc_strings::usb_drive_retry }, 0, true,
                 key_handler);
  }
  if (!shared) ui->ShowMenu({ failure }, { emmc_strings::emmc_back }, 0, true, key_handler);
}

void UsbDriveMenu(Device* device, const std::function<bool()>& confirm_device_mode) {
  auto ui = device->GetUI();
  auto key_handler = [device](int key, bool visible) {
    return key == KEY_AGAIN ? Device::kRefresh : device->HandleMenuKey(key, visible);
  };
  bool read_only = false;
  ui->ShowText(true);
  for (;;) {
    std::vector<std::string> lines;
    bool found = run_usb_drive({ "list" }, &lines);
    std::vector<UsbDrive> drives;
    for (const auto& line : lines) {
      auto fields = android::base::Split(line, "|");
      if (fields.size() != 6) continue;
      UsbDrive drive{ fields[0], 0, 0, fields[3], fields[4], fields[5] == "1" };
      if (!android::base::ParseInt(fields[1], &drive.slot, 1, 3) ||
          !android::base::ParseUint(fields[2], &drive.sectors) || drive.sectors == 0)
        continue;
      drives.push_back(drive);
    }
    std::sort(drives.begin(), drives.end(),
              [](const auto& a, const auto& b) { return a.slot < b.slot; });
    std::vector<std::string> headers{ emmc_strings::usb_drive_title };
    if (!found)
      headers.push_back(emmc_strings::usb_drive_failed);
    else if (drives.empty())
      headers.push_back(emmc_strings::usb_drive_empty);
    std::vector<std::string> items;
    for (const auto& drive : drives) {
      auto label = drive.Label();
      if (drive.forced != "none") {
        label = android::base::StringPrintf(emmc_strings::usb_drive_read_only, label.c_str());
        headers.push_back(usb_drive_reason(drive.forced));
      }
      items.push_back(label);
    }
    items.push_back(read_only ? emmc_strings::usb_drive_ro_on : emmc_strings::usb_drive_ro_off);
    items.push_back(emmc_strings::emmc_refresh);
    items.push_back(emmc_strings::emmc_back);
    size_t chosen = ui->ShowMenu(headers, items, 0, true, key_handler, true);
    if (chosen == drives.size()) {
      read_only = !read_only;
      continue;
    }
    if (chosen == drives.size() + 1 || chosen == static_cast<size_t>(Device::kRefresh)) continue;
    if (chosen >= drives.size()) return;
    const auto& drive = drives[chosen];
    if (!confirm_device_mode()) continue;
    std::vector<std::string> warning{ android::base::StringPrintf(emmc_strings::usb_drive_confirm,
                                                                  drive.Label().c_str()),
                                      emmc_strings::usb_drive_cable };
    if (drive.forced != "none") warning.push_back(usb_drive_reason(drive.forced));
    if (ui->ShowMenu(warning, { emmc_strings::emmc_cancel, emmc_strings::usb_drive_share }, 0, true,
                     key_handler) != 1)
      continue;
    bool writable = !read_only && drive.forced == "none";
    if (((drive.slot == 3 && writable) || (drive.slot != 3 && drive.boot)) &&
        !confirm_usb_drive(device))
      continue;
    share_usb_drive(device, drive, read_only);
  }
}
