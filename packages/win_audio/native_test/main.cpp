// Console smoke test of the win_audio C API (no Flutter). Calls the DLL exactly like the
// Dart bindings do and checks frame sizes / rates.
//
//   win_audio_smoke                       list, mic 2 s, render silence 1 s
//   win_audio_smoke --pid N               + process loopback of PID N (tree) 2 s
//   win_audio_smoke --render-device ID    render to that device id instead of the default
//   win_audio_smoke --tone                render a quiet 440 Hz tone instead of silence
#include "win_audio.h"

#include <windows.h>

#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <vector>

namespace {

struct Counters {
    int frames = 0;
    int badSize = 0;
    int errors = 0;
    int stopped = 0;
    int discontinuities = 0;
    double sumSq = 0;
    long long samples = 0;
};

std::mutex g_mutex;
std::map<int32_t, Counters> g_counters;
std::atomic<int> g_deviceEvents{0};
int32_t g_expectedFrameBytes = 3200;  // 100 ms at 16 kHz mono PCM16

void onEvent(int32_t stream, int32_t kind, int64_t value, uint8_t* data, int32_t size) {
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        Counters& c = g_counters[stream];
        switch (kind) {
            case WA_EVENT_AUDIO: {
                ++c.frames;
                if (size != g_expectedFrameBytes) ++c.badSize;
                const auto* s = reinterpret_cast<const int16_t*>(data);
                for (int i = 0; i < size / 2; ++i) c.sumSq += static_cast<double>(s[i]) * s[i];
                c.samples += size / 2;
                break;
            }
            case WA_EVENT_ERROR:
                ++c.errors;
                std::printf("  [stream %d] ERROR 0x%08llX: %.*s\n", stream, static_cast<unsigned long long>(value),
                            size, reinterpret_cast<const char*>(data));
                break;
            case WA_EVENT_STOPPED: ++c.stopped; break;
            case WA_EVENT_DISCONTINUITY: c.discontinuities += static_cast<int>(value); break;
            case WA_EVENT_DEVICES_CHANGED: ++g_deviceEvents; break;
            default: std::printf("  unknown event kind %d\n", kind);
        }
    }
    wa_free(data);
}

double dbfs(const Counters& c) {
    if (c.samples == 0 || c.sumSq <= 0) return -99.9;
    return 20.0 * std::log10(std::sqrt(c.sumSq / static_cast<double>(c.samples)) / 32768.0);
}

int g_failures = 0;
void check(bool ok, const char* what) {
    std::printf("  %s %s\n", ok ? "PASS" : "FAIL", what);
    if (!ok) ++g_failures;
}

std::string arg(int argc, char** argv, const char* name) {
    for (int i = 1; i + 1 < argc; ++i) {
        if (std::strcmp(argv[i], name) == 0) return argv[i + 1];
    }
    return {};
}

bool flag(int argc, char** argv, const char* name) {
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], name) == 0) return true;
    }
    return false;
}

void printJson(const char* title, char* json) {
    std::printf("%s\n  %s\n", title, json ? json : wa_last_error());
    wa_free(json);
}

void captureTest(const char* title, int32_t source, const char* device, uint32_t pid) {
    std::printf("\n== %s ==\n", title);
    const int32_t id = wa_capture_start(source, device, pid, 16000, 100);
    if (id == 0) {
        std::printf("  start failed: %s\n", wa_last_error());
        check(false, "capture started");
        return;
    }
    Sleep(2000);
    wa_stream_stop(id);
    Sleep(50);  // let the STOPPED event arrive
    Counters c;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        c = g_counters[id];
    }
    std::printf("  frames %d (expect ~20) | wrong size %d | errors %d | disc %d | rms %.1f dBFS\n", c.frames,
                c.badSize, c.errors, c.discontinuities, dbfs(c));
    check(c.frames >= 17 && c.frames <= 21, "about 10 frames per second");
    check(c.badSize == 0, "every frame is 3200 bytes (100 ms, 16 kHz, mono, PCM16)");
    check(c.errors == 0, "no error event");
    check(c.stopped == 1, "one STOPPED event after wa_stream_stop");
}

}  // namespace

int main(int argc, char** argv) {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    SetConsoleOutputCP(CP_UTF8);

    std::printf("== init ==\n");
    check(wa_init(&onEvent) == 0, "wa_init");
    const int64_t t0 = wa_now_us();
    Sleep(10);
    check(wa_now_us() - t0 >= 9000, "wa_now_us advances");

    printJson("\n== capture devices ==", wa_list_devices(WA_FLOW_CAPTURE));
    printJson("\n== render devices ==", wa_list_devices(WA_FLOW_RENDER));
    printJson("\n== sessions ==", wa_list_sessions());

    check(wa_list_devices(7) == nullptr, "invalid flow is rejected");
    std::printf("  (error text: %s)\n", wa_last_error());
    check(wa_capture_start(WA_SOURCE_DEVICE, "no-such-device", 0, 16000, 100) == 0, "unknown device id is rejected");
    std::printf("  (error text: %s)\n", wa_last_error());
    check(wa_capture_start(WA_SOURCE_PROCESS, nullptr, 0, 16000, 100) == 0, "process loopback without pid is rejected");

    const uint32_t discord = wa_find_root_pid("discord");
    std::printf("\n  wa_find_root_pid(\"discord\") = %u\n", discord);
    check(wa_find_root_pid("no_such_app_xyz.exe") == 0, "find_root_pid of a missing exe is 0");

    captureTest("capture: default microphone", WA_SOURCE_DEVICE, nullptr, 0);

    const std::string pidArg = arg(argc, argv, "--pid");
    if (!pidArg.empty()) {
        const auto pid = static_cast<uint32_t>(std::stoul(pidArg));
        captureTest(("capture: process loopback PID " + pidArg).c_str(), WA_SOURCE_PROCESS, nullptr, pid);
        std::printf("  session volume of tree %u: %.2f\n", pid, wa_session_volume(pid));
    }

    std::printf("\n== render ==\n");
    const std::string dev = arg(argc, argv, "--render-device");
    const int32_t r = wa_render_start(dev.empty() ? nullptr : dev.c_str(), 24000, 30000);
    if (r == 0) {
        std::printf("  start failed: %s\n", wa_last_error());
        check(false, "render started");
    } else {
        const bool tone = flag(argc, argv, "--tone");
        std::vector<int16_t> pcm(24000);  // 1 s at 24 kHz
        for (size_t i = 0; i < pcm.size(); ++i) {
            pcm[i] = tone ? static_cast<int16_t>(0.05 * 32767 * std::sin(2 * 3.14159265 * 440 * i / 24000.0)) : 0;
        }
        const int32_t accepted = wa_render_write(r, reinterpret_cast<const uint8_t*>(pcm.data()), 48000);
        check(accepted == 48000, "1 s written to the ring buffer");
        const int32_t b0 = wa_render_buffered_ms(r);
        Sleep(500);
        const int32_t b1 = wa_render_buffered_ms(r);
        std::printf("  buffered %d ms -> %d ms after 500 ms\n", b0, b1);
        check(b0 >= 950 && b0 <= 1100, "buffered ~1000 ms right after the write");
        check(b1 >= 400 && b1 <= 650, "about 500 ms consumed in 500 ms (real time)");
        wa_render_set_gain(r, 0.5f);
        wa_render_clear(r);
        Sleep(100);
        const int32_t b2 = wa_render_buffered_ms(r);
        check(b2 <= 60, "clear() drops the queue (only the WASAPI buffer remains)");

        std::vector<uint8_t> big(24000 * 2 * 31);  // 31 s > 30 s capacity
        const int32_t acc2 = wa_render_write(r, big.data(), static_cast<int32_t>(big.size()));
        check(acc2 == 24000 * 2 * 30, "a full ring buffer accepts only its capacity");
        wa_render_clear(r);
        wa_stream_stop(r);
        check(wa_render_write(r, big.data(), 2) == -1, "writing to a stopped stream returns -1");
    }

    wa_shutdown();
    std::printf("\n%s (%d failure%s). Device-change events seen: %d\n", g_failures ? "FAILED" : "ALL PASSED",
                g_failures, g_failures == 1 ? "" : "s", g_deviceEvents.load());
    return g_failures ? 1 : 0;
}
