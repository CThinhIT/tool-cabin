#pragma once

#include "common.h"

#include <mmdeviceapi.h>

#include <map>
#include <string>

namespace wa {

ComPtr<IMMDeviceEnumerator> createEnumerator();
std::wstring deviceId(IMMDevice* dev);
std::wstring deviceName(IMMDevice* dev);

// id empty -> the default console device of `flow`. Throws if the device is not active.
ComPtr<IMMDevice> openDevice(EDataFlow flow, const std::wstring& id);

// [{"id","name","isDefault","isDefaultComm"}] for active devices.
std::string listDevicesJson(EDataFlow flow);

struct ProcInfo {
    DWORD pid = 0;
    DWORD ppid = 0;
    std::wstring exe;
};

std::map<DWORD, ProcInfo> snapshotProcesses();

// Walks up the parents while they run the same exe, e.g. a Discord.exe audio child -> the
// top Discord.exe. Returns pid itself when it has no such parent.
DWORD treeRoot(DWORD pid, const std::map<DWORD, ProcInfo>& procs);

// Root of the tree of `exe` ("discord" / "Discord.exe"); 0 when no such process runs.
// With several separate trees, the one with the most processes wins.
DWORD findRootPid(const std::wstring& exe);

}  // namespace wa
