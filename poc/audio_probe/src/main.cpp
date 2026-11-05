// audio_probe - Phase 1 PoC (docs/ARCHITECTURE.md section 11).
// Proves, without Flutter, that we can capture the mic and one app's audio at the same time,
// play audio into a specific device (VB-Cable), and control another app's session volume.

#include "capture.h"
#include "common.h"
#include "devices.h"
#include "render.h"
#include "sessions.h"

#include <fcntl.h>
#include <io.h>

#include <exception>
#include <thread>

namespace {

BOOL WINAPI onCtrl(DWORD type) {
    if (type == CTRL_C_EVENT || type == CTRL_BREAK_EVENT || type == CTRL_CLOSE_EVENT) {
        g_stop = true;
        return TRUE;
    }
    return FALSE;
}

void usage() {
    logf(
        L"audio_probe - WASAPI proof of concept for the Vi<->En translator (Phase 1)\n"
        L"\n"
        L"  list                                   devices, audio sessions (PID / exe), call-app process trees\n"
        L"  rec-mic   [--device SEL] [--out mic.wav]\n"
        L"  rec-dev   (same as rec-mic; for the fallback plan, e.g. --device \"CABLE-B Output\")\n"
        L"  rec-loopback [--device SEL] [--out loopback.wav]   whole mix of an output device\n"
        L"  rec-app   (--name Discord.exe | --pid N) [--exclude] [--out app.wav] [--no-pad]\n"
        L"  rec-both  --mic SEL (--name Discord.exe | --pid N) [--out-mic mic.wav] [--out-app app.wav]\n"
        L"  play      [--in file.wav | --tone HZ [--beep]] [--device SEL] [--gain 1.0] [--loop]\n"
        L"  volume    (--name exe | --pid N) [--set 0..1]    |    volume --restore\n"
        L"\n"
        L"Common capture options: --seconds N (default: until Ctrl+C), --rate 16000, --channels 1\n"
        L"SEL = index from `list`, part of the device name (e.g. \"CABLE Input\"), \"default\" or \"comm\".\n"
        L"rec-app follows the WHOLE process tree of the root process (Discord runs many Discord.exe).\n");
}

const wchar_t* flags(const DeviceInfo& d) {
    if (d.isDefault && d.isDefaultComm) return L"[default, comm]";
    if (d.isDefault) return L"[default]";
    if (d.isDefaultComm) return L"[comm]";
    return L"";
}

int cmdList(const Args& args) {
    const bool showIds = args.has(L"--ids");
    for (EDataFlow flow : {eCapture, eRender}) {
        logf(L"\n=== %ls devices ===\n", flow == eCapture ? L"Capture (input)" : L"Render (output)");
        auto list = listDevices(flow);
        for (size_t i = 0; i < list.size(); ++i) {
            logf(L"  %2zu  %-60ls %ls\n", i, list[i].name.c_str(), flags(list[i]));
            if (showIds) logf(L"      %ls\n", list[i].id.c_str());
        }
        if (list.empty()) logf(L"  (none)\n");
    }

    logf(L"\n=== Audio sessions (render) ===\n");
    std::wstring lastDev;
    for (const auto& s : listSessions()) {
        if (s.deviceId != lastDev) {
            logf(L"  %ls\n", s.deviceName.c_str());
            lastDev = s.deviceId;
        }
        logf(L"      PID %-6lu %-24ls %-8ls vol %.2f%ls\n", s.pid, s.exe.c_str(), stateName(s.state), s.volume,
             s.mute ? L" MUTED" : L"");
    }

    logf(L"\n=== Call apps (process tree roots for rec-app) ===\n");
    for (const wchar_t* exe : {L"Discord.exe", L"Zalo.exe", L"chrome.exe", L"msedge.exe", L"firefox.exe"}) {
        size_t count = 0;
        DWORD root = findRootPid(exe, &count);
        if (root) logf(L"  %-12ls root PID %-6lu (%zu processes)\n", exe, root, count);
    }
    bool vbcable = false;
    for (const auto& d : listDevices(eRender)) {
        if (lower(d.name).find(L"cable input") != std::wstring::npos) vbcable = true;
    }
    logf(L"\nVB-Cable (\"CABLE Input\"): %ls\n", vbcable ? L"installed" : L"NOT FOUND - install it for the play/CABLE tests");
    if (!showIds) logf(L"(add --ids to print device ids)\n");
    return 0;
}

CaptureConfig commonCapture(const Args& a) {
    CaptureConfig c;
    c.seconds = a.num(L"--seconds", 0);
    c.rate = static_cast<uint32_t>(a.num(L"--rate", 16000));
    c.channels = static_cast<uint16_t>(a.num(L"--channels", 1));
    return c;
}

int run(const std::wstring& cmd, const Args& a) {
    if (cmd == L"list") return cmdList(a);

    if (cmd == L"rec-mic" || cmd == L"rec-dev") {
        CaptureConfig c = commonCapture(a);
        c.kind = SourceKind::Endpoint;
        c.device = a.get(L"--device");
        c.outPath = a.get(L"--out", cmd == L"rec-mic" ? L"mic.wav" : L"dev.wav");
        c.label = cmd == L"rec-mic" ? L"mic" : L"dev";
        runCapture(c);
        return 0;
    }
    if (cmd == L"rec-loopback") {
        CaptureConfig c = commonCapture(a);
        c.kind = SourceKind::EndpointLoopback;
        c.device = a.get(L"--device");
        c.outPath = a.get(L"--out", L"loopback.wav");
        c.label = L"loop";
        c.padSilence = !a.has(L"--no-pad");
        runCapture(c);
        return 0;
    }
    if (cmd == L"rec-app") {
        CaptureConfig c = commonCapture(a);
        c.kind = SourceKind::Process;
        c.pid = resolvePid(a);
        c.excludeTree = a.has(L"--exclude");
        c.outPath = a.get(L"--out", L"app.wav");
        c.label = L"app";
        c.padSilence = !a.has(L"--no-pad");
        runCapture(c);
        return 0;
    }
    if (cmd == L"rec-both") {
        CaptureConfig mic = commonCapture(a);
        mic.kind = SourceKind::Endpoint;
        mic.device = a.get(L"--mic");
        mic.outPath = a.get(L"--out-mic", L"mic.wav");
        mic.label = L"mic";
        CaptureConfig app = commonCapture(a);
        app.kind = SourceKind::Process;
        app.pid = resolvePid(a);
        app.excludeTree = a.has(L"--exclude");
        app.outPath = a.get(L"--out-app", L"app.wav");
        app.label = L"app";
        app.padSilence = !a.has(L"--no-pad");

        std::atomic<int> failures{0};
        auto worker = [&failures](CaptureConfig cfg) {
            try {
                runCapture(cfg);
            } catch (const HrError& e) {
                logf(L"[%ls] ERROR %ls\n       at %ls\n", cfg.label.c_str(), hrText(e.hr).c_str(), e.what.c_str());
                ++failures;
                g_stop = true;
            } catch (const AppError& e) {
                logf(L"[%ls] ERROR %ls\n", cfg.label.c_str(), e.msg.c_str());
                ++failures;
                g_stop = true;
            }
        };
        std::thread t1(worker, mic), t2(worker, app);
        t1.join();
        t2.join();
        return failures ? 2 : 0;
    }
    if (cmd == L"play") {
        PlayConfig p;
        p.device = a.get(L"--device");
        p.inPath = a.get(L"--in");
        p.toneHz = a.num(L"--tone", 440);
        p.beep = a.has(L"--beep");
        p.seconds = a.num(L"--seconds", 0);
        p.gain = a.num(L"--gain", 1.0);
        p.loop = a.has(L"--loop");
        runPlay(p);
        return 0;
    }
    if (cmd == L"volume") return cmdVolume(a);
    if (cmd == L"help" || cmd == L"--help" || cmd == L"-h") {
        usage();
        return 0;
    }
    logf(L"Unknown command: %ls\n\n", cmd.c_str());
    usage();
    return 1;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
    _setmode(_fileno(stdout), _O_U8TEXT);
    _setmode(_fileno(stderr), _O_U8TEXT);
    SetConsoleCtrlHandler(onCtrl, TRUE);
    if (argc < 2) {
        usage();
        return 1;
    }
    ComInit com;
    try {
        return run(argv[1], Args(std::vector<std::wstring>(argv + 2, argv + argc)));
    } catch (const HrError& e) {
        logf(L"ERROR %ls\n      at %ls\n", hrText(e.hr).c_str(), e.what.c_str());
    } catch (const AppError& e) {
        logf(L"ERROR %ls\n", e.msg.c_str());
    } catch (const std::exception& e) {
        logf(L"ERROR %hs\n", e.what());
    }
    return 2;
}
