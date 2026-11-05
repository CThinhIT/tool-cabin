#include "devices.h"

#include <propidl.h>
#include <propsys.h>
#include <tlhelp32.h>

#include <algorithm>
#include <cwctype>
#include <set>

// PKEY_Device_FriendlyName, defined locally to avoid INITGUID games.
static const PROPERTYKEY kFriendlyName = {
    {0xa45c254e, 0xdf1c, 0x4efd, {0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0}}, 14};

ComPtr<IMMDeviceEnumerator> enumerator() {
    ComPtr<IMMDeviceEnumerator> e;
    HR(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&e)));
    return e;
}

std::wstring deviceId(IMMDevice* dev) {
    LPWSTR id = nullptr;
    std::wstring s;
    if (SUCCEEDED(dev->GetId(&id)) && id) {
        s = id;
        CoTaskMemFree(id);
    }
    return s;
}

std::wstring deviceName(IMMDevice* dev) {
    ComPtr<IPropertyStore> ps;
    if (FAILED(dev->OpenPropertyStore(STGM_READ, &ps))) return L"?";
    PROPVARIANT pv;
    PropVariantInit(&pv);
    std::wstring name = L"?";
    if (SUCCEEDED(ps->GetValue(kFriendlyName, &pv)) && pv.vt == VT_LPWSTR && pv.pwszVal) {
        name = pv.pwszVal;
    }
    PropVariantClear(&pv);
    return name;
}

static std::wstring defaultId(IMMDeviceEnumerator* e, EDataFlow flow, ERole role) {
    ComPtr<IMMDevice> d;
    if (FAILED(e->GetDefaultAudioEndpoint(flow, role, &d))) return L"";
    return deviceId(d.Get());
}

std::vector<DeviceInfo> listDevices(EDataFlow flow) {
    auto e = enumerator();
    ComPtr<IMMDeviceCollection> col;
    HR(e->EnumAudioEndpoints(flow, DEVICE_STATE_ACTIVE, &col));
    UINT n = 0;
    HR(col->GetCount(&n));
    const std::wstring defConsole = defaultId(e.Get(), flow, eConsole);
    const std::wstring defComm = defaultId(e.Get(), flow, eCommunications);
    std::vector<DeviceInfo> out;
    for (UINT i = 0; i < n; ++i) {
        ComPtr<IMMDevice> d;
        HR(col->Item(i, &d));
        DeviceInfo info;
        info.id = deviceId(d.Get());
        info.name = deviceName(d.Get());
        info.isDefault = info.id == defConsole;
        info.isDefaultComm = info.id == defComm;
        out.push_back(std::move(info));
    }
    return out;
}

ComPtr<IMMDevice> findDevice(EDataFlow flow, const std::wstring& sel, std::wstring* nameOut) {
    auto e = enumerator();
    ComPtr<IMMDevice> dev;
    const wchar_t* flowName = flow == eCapture ? L"capture" : L"render";
    if (sel.empty() || sel == L"default") {
        HR(e->GetDefaultAudioEndpoint(flow, eConsole, &dev));
    } else if (sel == L"comm") {
        HR(e->GetDefaultAudioEndpoint(flow, eCommunications, &dev));
    } else {
        auto list = listDevices(flow);
        std::wstring id;
        bool numeric = std::all_of(sel.begin(), sel.end(), [](wchar_t c) { return std::iswdigit(c) != 0; });
        if (numeric) {
            size_t idx = std::stoul(sel);
            if (idx >= list.size()) {
                throw AppError{L"No " + std::wstring(flowName) + L" device with index " + sel +
                               L". Run: audio_probe list"};
            }
            id = list[idx].id;
        } else {
            for (const auto& d : list) {
                if (d.id == sel) id = d.id;
            }
            if (id.empty()) {
                const std::wstring needle = lower(sel);
                std::vector<const DeviceInfo*> matches;
                for (const auto& d : list) {
                    if (lower(d.name).find(needle) != std::wstring::npos) matches.push_back(&d);
                }
                if (matches.empty()) {
                    throw AppError{L"No active " + std::wstring(flowName) + L" device matches \"" + sel +
                                   L"\". Run: audio_probe list"};
                }
                if (matches.size() > 1) {
                    std::wstring msg = L"Device selector \"" + sel + L"\" matches several devices:";
                    for (const auto* d : matches) msg += L"\n    " + d->name;
                    throw AppError{msg + L"\n  Use the index shown by: audio_probe list"};
                }
                id = matches[0]->id;
            }
        }
        HR(e->GetDevice(id.c_str(), &dev));
    }
    if (nameOut) *nameOut = deviceName(dev.Get());
    return dev;
}

std::vector<ProcInfo> listProcesses() {
    std::vector<ProcInfo> out;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return out;
    PROCESSENTRY32W pe{};
    pe.dwSize = sizeof(pe);
    if (Process32FirstW(snap, &pe)) {
        do {
            out.push_back({pe.th32ProcessID, pe.th32ParentProcessID, pe.szExeFile});
        } while (Process32NextW(snap, &pe));
    }
    CloseHandle(snap);
    return out;
}

std::map<DWORD, std::wstring> processNameMap() {
    std::map<DWORD, std::wstring> m;
    for (const auto& p : listProcesses()) m[p.pid] = p.exe;
    return m;
}

std::wstring normalizeExe(const std::wstring& exe) {
    std::wstring s = lower(exe);
    if (s.size() < 4 || s.compare(s.size() - 4, 4, L".exe") != 0) s += L".exe";
    return s;
}

DWORD findRootPid(const std::wstring& exe, size_t* count) {
    const std::wstring want = normalizeExe(exe);
    auto procs = listProcesses();
    std::set<DWORD> pids;
    for (const auto& p : procs) {
        if (lower(p.exe) == want) pids.insert(p.pid);
    }
    if (count) *count = pids.size();
    if (pids.empty()) return 0;
    for (const auto& p : procs) {
        if (pids.count(p.pid) && !pids.count(p.ppid)) return p.pid;
    }
    return *pids.begin();
}

DWORD resolvePid(const Args& args) {
    std::wstring pidStr = args.get(L"--pid");
    if (!pidStr.empty()) {
        DWORD pid = static_cast<DWORD>(std::stoul(pidStr));
        auto names = processNameMap();
        auto it = names.find(pid);
        if (it == names.end()) throw AppError{L"No running process with PID " + pidStr};
        logf(L"Target: PID %lu (%ls)\n", pid, it->second.c_str());
        return pid;
    }
    std::wstring name = args.get(L"--name");
    if (!name.empty()) {
        size_t count = 0;
        DWORD pid = findRootPid(name, &count);
        if (!pid) throw AppError{L"No running process named " + normalizeExe(name)};
        logf(L"Target: %ls -> %zu process(es), using root PID %lu\n", normalizeExe(name).c_str(), count, pid);
        return pid;
    }
    throw AppError{L"Need --pid <pid> or --name <exe>, e.g. --name Discord.exe"};
}
