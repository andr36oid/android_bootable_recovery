#pragma once

#include <functional>

class Device;

void UsbDriveMenu(Device* device, const std::function<bool()>& confirm_device_mode);
