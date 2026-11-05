#include "render.h"

#include "devices.h"
#include "wav.h"

#include <audioclient.h>
#include <audiopolicy.h>
#include <avrt.h>

#include <algorithm>
#include <cmath>

namespace {
constexpr double kPi = 3.14159265358979323846;
constexpr uint32_t kToneRate = 24000;  // same rate as the AI's TTS output
}  // namespace

void runPlay(const PlayConfig& cfg) {
    ComInit com;
    std::wstring name;
    auto dev = findDevice(eRender, cfg.device, &name);

    WavData src;
    const bool tone = cfg.inPath.empty();
    if (tone) {
        src.rate = kToneRate;
        src.channels = 1;
    } else {
        src = readWav(cfg.inPath);
    }
    const uint64_t fileFrames = tone ? 0 : src.samples.size() / src.channels;
    if (!tone && fileFrames == 0) throw AppError{cfg.inPath + L" has no audio"};

    uint64_t limit = UINT64_MAX;
    if (cfg.seconds > 0) limit = static_cast<uint64_t>(cfg.seconds * src.rate);
    else if (!tone && !cfg.loop) limit = fileFrames;

    ComPtr<IAudioClient> client;
    HR(dev->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(client.GetAddressOf())));
    WAVEFORMATEX wf = {};
    wf.wFormatTag = WAVE_FORMAT_PCM;
    wf.nChannels = src.channels;
    wf.nSamplesPerSec = src.rate;
    wf.wBitsPerSample = 16;
    wf.nBlockAlign = static_cast<WORD>(src.channels * 2);
    wf.nAvgBytesPerSec = src.rate * wf.nBlockAlign;
    HR(client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                          AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                              AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                          1'000'000 /* 100 ms */, 0, &wf, nullptr));
    UINT32 bufFrames = 0;
    HR(client->GetBufferSize(&bufFrames));
    HANDLE ev = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    HR(client->SetEventHandle(ev));
    ComPtr<IAudioRenderClient> rc;
    HR(client->GetService(IID_PPV_ARGS(&rc)));

    // Opt this stream out of Windows' "communications activity" ducking (ARCHITECTURE.md 4.3).
    bool duckOptOut = false;
    ComPtr<IAudioSessionControl> sc;
    if (SUCCEEDED(client->GetService(IID_PPV_ARGS(&sc)))) {
        ComPtr<IAudioSessionControl2> sc2;
        if (SUCCEEDED(sc.As(&sc2))) duckOptOut = SUCCEEDED(sc2->SetDuckingPreference(TRUE));
    }

    if (tone) {
        logf(L"Playing %ls %.0f Hz tone to \"%ls\"\n", cfg.beep ? L"beeping" : L"continuous", cfg.toneHz, name.c_str());
    } else {
        logf(L"Playing %ls (%.1f s) to \"%ls\"\n", cfg.inPath.c_str(), static_cast<double>(fileFrames) / src.rate,
             name.c_str());
    }
    logf(L"  stream: %u Hz, %u ch, PCM16 via AUTOCONVERTPCM | buffer %u frames (%.0f ms) | ducking opt-out: %ls\n",
         src.rate, src.channels, bufFrames, 1000.0 * bufFrames / src.rate, duckOptOut ? L"yes" : L"no");
    if (limit == UINT64_MAX) logf(L"  Ctrl+C to stop.\n");

    uint64_t pos = 0;
    auto fill = [&](UINT32 frames) -> UINT32 {
        BYTE* data = nullptr;
        HR(rc->GetBuffer(frames, &data));
        int16_t* out = reinterpret_cast<int16_t*>(data);
        UINT32 n = 0;
        for (; n < frames && pos < limit; ++n, ++pos) {
            for (uint16_t c = 0; c < src.channels; ++c) {
                double v;
                if (tone) {
                    const bool on = !cfg.beep || (pos % src.rate) < src.rate / 10;
                    v = on ? 0.3 * std::sin(2.0 * kPi * cfg.toneHz * static_cast<double>(pos) / src.rate) : 0.0;
                } else {
                    v = src.samples[static_cast<size_t>((pos % fileFrames) * src.channels + c)] / 32768.0;
                }
                v = std::max(-1.0, std::min(1.0, v * cfg.gain));
                out[n * src.channels + c] = static_cast<int16_t>(std::lround(v * 32767.0));
            }
        }
        HR(rc->ReleaseBuffer(n, 0));
        return n;
    };

    DWORD taskIndex = 0;
    HANDLE mmcss = AvSetMmThreadCharacteristicsW(L"Audio", &taskIndex);
    bool done = fill(bufFrames) < bufFrames;
    HR(client->Start());
    const double t0 = nowSeconds();
    double nextReport = 5.0;

    while (!g_stop) {
        WaitForSingleObject(ev, 200);
        UINT32 padding = 0;
        HR(client->GetCurrentPadding(&padding));
        if (!done) {
            const UINT32 avail = bufFrames - padding;
            if (avail > 0 && fill(avail) < avail) done = true;
        } else if (padding == 0) {
            break;
        }
        const double t = nowSeconds() - t0;
        if (t >= nextReport) {
            logf(L"  playing... %.0f s\n", t);
            nextReport += 5.0;
        }
    }
    client->Stop();
    if (mmcss) AvRevertMmThreadCharacteristics(mmcss);
    CloseHandle(ev);
    logf(L"Done: %.1f s of audio sent to \"%ls\".\n", static_cast<double>(pos) / src.rate, name.c_str());
}
