#include "sessions.h"

#include "devices.h"

#include <audiopolicy.h>

#include <cstdio>
#include <set>
#include <vector>

namespace wa {

namespace {

struct SessionEntry {
    std::wstring deviceId;
    std::wstring deviceName;
    DWORD pid = 0;
    DWORD rootPid = 0;
    std::wstring exe;
    bool system = false;
    AudioSessionState state = AudioSessionStateInactive;
    float volume = 0.0f;
    BOOL mute = FALSE;
    ComPtr<ISimpleAudioVolume> vol;
};

std::vector<SessionEntry> enumerateSessions() {
    const auto procs = snapshotProcesses();
    auto e = createEnumerator();
    ComPtr<IMMDeviceCollection> col;
    WA_HR(e->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &col));
    UINT n = 0;
    WA_HR(col->GetCount(&n));
    std::vector<SessionEntry> out;
    for (UINT i = 0; i < n; ++i) {
        ComPtr<IMMDevice> dev;
        if (FAILED(col->Item(i, &dev))) continue;
        ComPtr<IAudioSessionManager2> mgr;
        if (FAILED(dev->Activate(__uuidof(IAudioSessionManager2), CLSCTX_ALL, nullptr,
                                 reinterpret_cast<void**>(mgr.GetAddressOf())))) {
            continue;
        }
        ComPtr<IAudioSessionEnumerator> se;
        if (FAILED(mgr->GetSessionEnumerator(&se))) continue;
        int count = 0;
        se->GetCount(&count);
        const std::wstring devId = deviceId(dev.Get());
        const std::wstring devName = deviceName(dev.Get());
        for (int j = 0; j < count; ++j) {
            ComPtr<IAudioSessionControl> c;
            if (FAILED(se->GetSession(j, &c))) continue;
            ComPtr<IAudioSessionControl2> c2;
            if (FAILED(c.As(&c2))) continue;
            SessionEntry s;
            c->GetState(&s.state);
            if (s.state == AudioSessionStateExpired) continue;
            s.deviceId = devId;
            s.deviceName = devName;
            c2->GetProcessId(&s.pid);  // may return AUDCLNT_S_NO_SINGLE_PROCESS; pid is still set
            s.system = c2->IsSystemSoundsSession() == S_OK;
            const auto it = procs.find(s.pid);
            s.exe = s.system ? L"(system sounds)" : (it != procs.end() ? it->second.exe : L"?");
            s.rootPid = s.system ? 0 : treeRoot(s.pid, procs);
            if (SUCCEEDED(c.As(&s.vol))) {
                s.vol->GetMasterVolume(&s.volume);
                s.vol->GetMute(&s.mute);
            }
            out.push_back(std::move(s));
        }
    }
    return out;
}

const char* stateName(AudioSessionState s) {
    switch (s) {
        case AudioSessionStateActive: return "active";
        case AudioSessionStateInactive: return "inactive";
        case AudioSessionStateExpired: return "expired";
    }
    return "?";
}

bool inTree(const SessionEntry& s, DWORD rootPid) {
    return !s.system && s.vol && (s.rootPid == rootPid || s.pid == rootPid);
}

std::wstring backupPath() {
    wchar_t buf[MAX_PATH];
    const DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", buf, MAX_PATH);
    std::wstring dir = (n > 0 && n < MAX_PATH) ? std::wstring(buf) : std::wstring(L".");
    dir += L"\\trans_app";
    CreateDirectoryW(dir.c_str(), nullptr);
    return dir + L"\\volume_backup.txt";
}

struct BackupLine {
    std::wstring deviceId;
    std::wstring exe;  // lower case
    float volume;
};

std::vector<BackupLine> readBackup(const std::wstring& path) {
    std::vector<BackupLine> out;
    FILE* f = nullptr;
    if (_wfopen_s(&f, path.c_str(), L"r, ccs=UTF-8") != 0 || !f) return out;
    wchar_t line[2048];
    while (fgetws(line, 2048, f)) {
        std::wstring s = line;
        while (!s.empty() && (s.back() == L'\n' || s.back() == L'\r')) s.pop_back();
        const size_t a = s.find(L'\t');
        const size_t b = a == std::wstring::npos ? a : s.find(L'\t', a + 1);
        if (b == std::wstring::npos) continue;
        out.push_back({s.substr(0, a), s.substr(a + 1, b - a - 1), static_cast<float>(_wtof(s.substr(b + 1).c_str()))});
    }
    fclose(f);
    return out;
}

}  // namespace

std::string listSessionsJson() {
    std::string json = "[";
    char num[32];
    for (const auto& s : enumerateSessions()) {
        if (json.size() > 1) json += ',';
        json += "{\"pid\":" + std::to_string(s.pid);
        json += ",\"exe\":";
        appendJsonString(json, toUtf8(s.exe));
        json += ",\"rootPid\":" + std::to_string(s.rootPid);
        json += ",\"system\":";
        json += s.system ? "true" : "false";
        json += ",\"state\":";
        appendJsonString(json, stateName(s.state));
        snprintf(num, sizeof(num), "%.4f", s.volume);
        json += ",\"volume\":";
        json += num;
        json += ",\"muted\":";
        json += s.mute ? "true" : "false";
        json += ",\"deviceId\":";
        appendJsonString(json, toUtf8(s.deviceId));
        json += ",\"deviceName\":";
        appendJsonString(json, toUtf8(s.deviceName));
        json += '}';
    }
    json += ']';
    return json;
}

float treeVolume(DWORD rootPid) {
    float active = -1.0f, any = -1.0f;
    for (const auto& s : enumerateSessions()) {
        if (!inTree(s, rootPid)) continue;
        if (s.volume > any) any = s.volume;
        if (s.state == AudioSessionStateActive && s.volume > active) active = s.volume;
    }
    return active >= 0.0f ? active : any;
}

int32_t setTreeVolume(DWORD rootPid, float volume) {
    if (volume < 0.0f) volume = 0.0f;
    if (volume > 1.0f) volume = 1.0f;
    auto sessions = enumerateSessions();
    std::vector<SessionEntry*> matched;
    for (auto& s : sessions) {
        if (inTree(s, rootPid)) matched.push_back(&s);
    }
    if (matched.empty()) return 0;

    // Windows persists per-app volume across restarts, so keep the ORIGINAL value once.
    const std::wstring path = backupPath();
    if (readBackup(path).empty()) {
        FILE* f = nullptr;
        if (_wfopen_s(&f, path.c_str(), L"w, ccs=UTF-8") != 0 || !f) {
            throw WaError("Cannot write the volume backup " + toUtf8(path) + "; refusing to change volume");
        }
        std::set<std::wstring> seen;
        for (const auto* s : matched) {
            const std::wstring key = s->deviceId + L"\t" + lower(s->exe);
            if (!seen.insert(key).second) continue;
            fwprintf(f, L"%ls\t%.4f\n", key.c_str(), s->volume);
        }
        fclose(f);
    }
    for (auto* s : matched) WA_HR(s->vol->SetMasterVolume(volume, nullptr));
    return static_cast<int32_t>(matched.size());
}

int32_t restoreVolumes() {
    const std::wstring path = backupPath();
    const auto lines = readBackup(path);
    if (lines.empty()) return 0;
    auto sessions = enumerateSessions();
    int32_t restored = 0;
    for (const auto& l : lines) {
        for (auto& s : sessions) {
            if (s.vol && !s.system && s.deviceId == l.deviceId && lower(s.exe) == l.exe) {
                if (SUCCEEDED(s.vol->SetMasterVolume(l.volume, nullptr))) ++restored;
            }
        }
    }
    // Keep the backup when the app is not running yet; the next call will retry.
    if (restored > 0) DeleteFileW(path.c_str());
    return restored;
}

}  // namespace wa
