#pragma once

#include "common.h"

#include <mmdeviceapi.h>

#include <map>

struct DeviceInfo {
    std::wstring id;
    std::wstring name;
    bool isDefault = false;      // default for eConsole
    bool isDefaultComm = false;  // default for eCommunications
};

struct ProcInfo {
    DWORD pid;
    DWORD ppid;
    std::wstring exe;
};

ComPtr<IMMDeviceEnumerator> enumerator();
std::wstring deviceId(IMMDevice* dev);
std::wstring deviceName(IMMDevice* dev);

// Active devices only, in the order Windows enumerates them (= the index used by --device N).
std::vector<DeviceInfo> listDevices(EDataFlow flow);

// selector: "" / "default" -> console default, "comm" -> communications default,
// a number -> index from `list`, an exact device id, or a case-insensitive name substring.
ComPtr<IMMDevice> findDevice(EDataFlow flow, const std::wstring& selector, std::wstring* nameOut);

std::vector<ProcInfo> listProcesses();
std::map<DWORD, std::wstring> processNameMap();

// "discord" / "Discord.exe" -> "discord.exe"
std::wstring normalizeExe(const std::wstring& exe);

// Root of the process tree for an exe name (the instance whose parent is not the same exe).
// Returns 0 when no such process runs. `count` receives the number of matching processes.
DWORD findRootPid(const std::wstring& exe, size_t* count);

// --pid <n> or --name <exe>; prints what it resolved to.
DWORD resolvePid(const Args& args);
