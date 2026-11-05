#include "sessions.h"

#include "devices.h"

#include <cstdio>
#include <set>

std::vector<SessionInfo> listSessions() {
    auto names = processNameMap();
    auto e = enumerator();
    ComPtr<IMMDeviceCollection> col;
    HR(e->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &col));
    UINT n = 0;
    HR(col->GetCount(&n));
    std::vector<SessionInfo> out;
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
            SessionInfo s;
            s.deviceId = devId;
            s.deviceName = devName;
            c2->GetProcessId(&s.pid);  // may be AUDCLNT_S_NO_SINGLE_PROCESS; pid is still filled
            s.system = c2->IsSystemSoundsSession() == S_OK;
            c->GetState(&s.state);
            auto it = names.find(s.pid);
            s.exe = s.system ? L"(system sounds)" : (it != names.end() ? it->second : L"?");
            if (SUCCEEDED(c.As(&s.vol))) {
                s.vol->GetMasterVolume(&s.volume);
                s.vol->GetMute(&s.mute);
            }
            out.push_back(std::move(s));
        }
    }
    return out;
}

const wchar_t* stateName(AudioSessionState s) {
    switch (s) {
        case AudioSessionStateActive: return L"Active";
        case AudioSessionStateInactive: return L"Inactive";
        case AudioSessionStateExpired: return L"Expired";
    }
    return L"?";
}

static std::wstring backupPath() {
    wchar_t buf[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", buf, MAX_PATH);
    std::wstring dir = (n > 0 && n < MAX_PATH) ? std::wstring(buf) : std::wstring(L".");
    dir += L"\\audio_probe";
    CreateDirectoryW(dir.c_str(), nullptr);
    return dir + L"\\volume_backup.txt";
}

struct BackupLine {
    std::wstring deviceId;
    std::wstring exe;
    float volume;
};

static std::vector<BackupLine> readBackup(const std::wstring& path) {
    std::vector<BackupLine> out;
    FILE* f = nullptr;
    if (_wfopen_s(&f, path.c_str(), L"r, ccs=UTF-8") != 0 || !f) return out;
    wchar_t line[2048];
    while (fgetws(line, 2048, f)) {
        std::wstring s = line;
        while (!s.empty() && (s.back() == L'\n' || s.back() == L'\r')) s.pop_back();
        size_t a = s.find(L'\t');
        size_t b = a == std::wstring::npos ? a : s.find(L'\t', a + 1);
        if (b == std::wstring::npos) continue;
        out.push_back({s.substr(0, a), s.substr(a + 1, b - a - 1),
                       static_cast<float>(_wtof(s.substr(b + 1).c_str()))});
    }
    fclose(f);
    return out;
}

static int restoreVolumes() {
    const std::wstring path = backupPath();
    auto lines = readBackup(path);
    if (lines.empty()) {
        logf(L"No volume backup at %ls - nothing to restore.\n", path.c_str());
        return 0;
    }
    auto sessions = listSessions();
    int restored = 0;
    for (const auto& l : lines) {
        for (auto& s : sessions) {
            if (s.vol && s.deviceId == l.deviceId && lower(s.exe) == l.exe) {
                s.vol->SetMasterVolume(l.volume, nullptr);
                logf(L"  restored %ls (PID %lu) on %ls -> %.2f\n", s.exe.c_str(), s.pid, s.deviceName.c_str(),
                     l.volume);
                ++restored;
            }
        }
    }
    if (restored == 0) {
        logf(L"Backup found but no matching session is open right now (start the app, then retry).\n"
             L"Backup kept at %ls\n",
             path.c_str());
        return 1;
    }
    DeleteFileW(path.c_str());
    logf(L"Restored %d session(s); backup removed.\n", restored);
    return 0;
}

int cmdVolume(const Args& args) {
    if (args.has(L"--restore")) return restoreVolumes();

    DWORD pid = 0;
    std::wstring exe;
    if (!args.get(L"--pid").empty()) {
        pid = static_cast<DWORD>(std::stoul(args.get(L"--pid")));
    } else if (!args.get(L"--name").empty()) {
        exe = normalizeExe(args.get(L"--name"));
    } else {
        throw AppError{L"volume: need --pid <pid> or --name <exe> (or --restore)"};
    }

    auto sessions = listSessions();
    std::vector<SessionInfo*> matched;
    for (auto& s : sessions) {
        if (!s.vol || s.system) continue;
        if ((pid && s.pid == pid) || (!exe.empty() && lower(s.exe) == exe)) matched.push_back(&s);
    }
    if (matched.empty()) {
        logf(L"No audio session for that process. An app gets a session only after it has played sound\n"
             L"(e.g. join a voice call first). Run: audio_probe list\n");
        return 1;
    }
    for (const auto* s : matched) {
        logf(L"  %-16ls PID %-6lu %-8ls vol=%.2f mute=%d  on %ls\n", s->exe.c_str(), s->pid,
             stateName(s->state), s->volume, s->mute, s->deviceName.c_str());
    }

    const std::wstring setStr = args.get(L"--set");
    if (setStr.empty()) return 0;
    float v = static_cast<float>(args.num(L"--set", 1.0));
    if (v < 0.0f) v = 0.0f;
    if (v > 1.0f) v = 1.0f;

    // Windows persists per-app volume across restarts, so keep the ORIGINAL value once.
    const std::wstring path = backupPath();
    if (readBackup(path).empty()) {
        FILE* f = nullptr;
        if (_wfopen_s(&f, path.c_str(), L"w, ccs=UTF-8") == 0 && f) {
            std::set<std::wstring> seen;
            for (const auto* s : matched) {
                std::wstring key = s->deviceId + L"\t" + lower(s->exe);
                if (!seen.insert(key).second) continue;
                fwprintf(f, L"%ls\t%.4f\n", key.c_str(), s->volume);
            }
            fclose(f);
            logf(L"Original volume saved to %ls\n", path.c_str());
        } else {
            throw AppError{L"Cannot write volume backup " + path + L" - refusing to change volume."};
        }
    } else {
        logf(L"Backup already exists (keeping the original values): %ls\n", path.c_str());
    }
    for (auto* s : matched) HR(s->vol->SetMasterVolume(v, nullptr));
    logf(L"Set %zu session(s) to %.2f. Undo with: audio_probe volume --restore\n", matched.size(), v);
    return 0;
}
