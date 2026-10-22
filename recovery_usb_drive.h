#pragma once

#include <functional>

class Device;

void UsbDriveMenu(Device* device, const std::function<bool()>& device_mode);
