#include "devices.h"

#include <propidl.h>
#include <propsys.h>
#include <tlhelp32.h>

namespace wa {

// PKEY_Device_FriendlyName, defined locally to avoid INITGUID games.
static const PROPERTYKEY kFriendlyName = {
    {0xa45c254e, 0xdf1c, 0x4efd, {0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0}}, 14};

ComPtr<IMMDeviceEnumerator> createEnumerator() {
    ComPtr<IMMDeviceEnumerator> e;
    WA_HR(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&e)));
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
    if (SUCCEEDED(ps->GetValue(kFriendlyName, &pv)) && pv.vt == VT_LPWSTR && pv.pwszVal) name = pv.pwszVal;
    PropVariantClear(&pv);
    return name;
}

static std::wstring defaultId(IMMDeviceEnumerator* e, EDataFlow flow, ERole role) {
    ComPtr<IMMDevice> d;
    if (FAILED(e->GetDefaultAudioEndpoint(flow, role, &d))) return L"";
    return deviceId(d.Get());
}

ComPtr<IMMDevice> openDevice(EDataFlow flow, const std::wstring& id) {
    auto e = createEnumerator();
    ComPtr<IMMDevice> dev;
    if (id.empty()) {
        WA_HR(e->GetDefaultAudioEndpoint(flow, eConsole, &dev));
        return dev;
    }
    const HRESULT hr = e->GetDevice(id.c_str(), &dev);
    if (FAILED(hr)) throw WaError("Audio device not found (unplugged?): " + toUtf8(id) + " - " + hrText(hr), hr);
    DWORD state = 0;
    WA_HR(dev->GetState(&state));
    if (state != DEVICE_STATE_ACTIVE) {
        throw WaError("Audio device \"" + toUtf8(deviceName(dev.Get())) + "\" is not active (unplugged or disabled)",
                      HRESULT_FROM_WIN32(ERROR_NOT_FOUND));
    }
    return dev;
}

std::string listDevicesJson(EDataFlow flow) {
    auto e = createEnumerator();
    ComPtr<IMMDeviceCollection> col;
    WA_HR(e->EnumAudioEndpoints(flow, DEVICE_STATE_ACTIVE, &col));
    UINT n = 0;
    WA_HR(col->GetCount(&n));
    const std::wstring defConsole = defaultId(e.Get(), flow, eConsole);
    const std::wstring defComm = defaultId(e.Get(), flow, eCommunications);
    std::string json = "[";
    for (UINT i = 0; i < n; ++i) {
        ComPtr<IMMDevice> d;
        if (FAILED(col->Item(i, &d))) continue;
        const std::wstring id = deviceId(d.Get());
        if (json.size() > 1) json += ',';
        json += "{\"id\":";
        appendJsonString(json, toUtf8(id));
        json += ",\"name\":";
        appendJsonString(json, toUtf8(deviceName(d.Get())));
        json += ",\"isDefault\":";
        json += id == defConsole ? "true" : "false";
        json += ",\"isDefaultComm\":";
        json += id == defComm ? "true" : "false";
        json += '}';
    }
    json += ']';
    return json;
}

std::map<DWORD, ProcInfo> snapshotProcesses() {
    std::map<DWORD, ProcInfo> out;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return out;
    PROCESSENTRY32W pe{};
    pe.dwSize = sizeof(pe);
    if (Process32FirstW(snap, &pe)) {
        do {
            out[pe.th32ProcessID] = {pe.th32ProcessID, pe.th32ParentProcessID, pe.szExeFile};
        } while (Process32NextW(snap, &pe));
    }
    CloseHandle(snap);
    return out;
}

DWORD treeRoot(DWORD pid, const std::map<DWORD, ProcInfo>& procs) {
    auto self = procs.find(pid);
    if (self == procs.end()) return pid;
    const std::wstring exe = lower(self->second.exe);
    DWORD cur = pid;
    for (int guard = 0; guard < 64; ++guard) {  // guard against parent-PID reuse cycles
        const auto parent = procs.find(procs.at(cur).ppid);
        if (parent == procs.end() || parent->first == cur || lower(parent->second.exe) != exe) break;
        cur = parent->first;
    }
    return cur;
}

DWORD findRootPid(const std::wstring& exe) {
    std::wstring want = lower(exe);
    if (want.size() < 4 || want.compare(want.size() - 4, 4, L".exe") != 0) want += L".exe";
    const auto procs = snapshotProcesses();
    std::map<DWORD, int> treeSizes;
    for (const auto& [pid, p] : procs) {
        if (lower(p.exe) == want) ++treeSizes[treeRoot(pid, procs)];
    }
    DWORD best = 0;
    int bestSize = 0;
    for (const auto& [root, size] : treeSizes) {
        if (size > bestSize) {
            best = root;
            bestSize = size;
        }
    }
    return best;
}

}  // namespace wa
