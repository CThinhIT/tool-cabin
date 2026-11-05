#include "capture.h"

#include "devices.h"
#include "wav.h"

#include <audioclient.h>
#include <audioclientactivationparams.h>
#include <avrt.h>
#include <mmdeviceapi.h>
#include <wrl/implements.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <functional>

using Microsoft::WRL::ClassicCom;
using Microsoft::WRL::FtmBase;
using Microsoft::WRL::Make;
using Microsoft::WRL::RuntimeClass;
using Microsoft::WRL::RuntimeClassFlags;

namespace {

constexpr REFERENCE_TIME kBufferHns = 2'000'000;  // 200 ms

// ActivateAudioInterfaceAsync needs an agile completion handler (FtmBase = free-threaded marshaler).
class ActivateHandler
    : public RuntimeClass<RuntimeClassFlags<ClassicCom>, FtmBase, IActivateAudioInterfaceCompletionHandler> {
public:
    ActivateHandler() : done_(CreateEventW(nullptr, TRUE, FALSE, nullptr)) {}
    ~ActivateHandler() override {
        if (done_) CloseHandle(done_);
    }

    STDMETHOD(ActivateCompleted)(IActivateAudioInterfaceAsyncOperation* op) override {
        HRESULT hrActivate = E_FAIL;
        ComPtr<IUnknown> unk;
        HRESULT hr = op->GetActivateResult(&hrActivate, &unk);
        if (SUCCEEDED(hr)) hr = hrActivate;
        if (SUCCEEDED(hr)) hr = unk.As(&client_);
        result_ = hr;
        SetEvent(done_);
        return S_OK;
    }

    HRESULT wait(ComPtr<IAudioClient>& out, DWORD ms) {
        if (WaitForSingleObject(done_, ms) != WAIT_OBJECT_0) return HRESULT_FROM_WIN32(ERROR_TIMEOUT);
        out = client_;
        return result_;
    }

private:
    HANDLE done_;
    HRESULT result_ = E_FAIL;
    ComPtr<IAudioClient> client_;
};

ComPtr<IAudioClient> activateProcessLoopback(DWORD pid, bool exclude) {
    AUDIOCLIENT_ACTIVATION_PARAMS params = {};
    params.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
    params.ProcessLoopbackParams.TargetProcessId = pid;
    params.ProcessLoopbackParams.ProcessLoopbackMode =
        exclude ? PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE : PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;

    PROPVARIANT pv = {};
    pv.vt = VT_BLOB;
    pv.blob.cbSize = sizeof(params);
    pv.blob.pBlobData = reinterpret_cast<BYTE*>(&params);

    auto handler = Make<ActivateHandler>();
    ComPtr<IActivateAudioInterfaceAsyncOperation> op;
    HR(ActivateAudioInterfaceAsync(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, __uuidof(IAudioClient), &pv,
                                   handler.Get(), &op));
    ComPtr<IAudioClient> client;
    HR(handler->wait(client, 5000));
    return client;
}

ComPtr<IAudioClient> activateEndpoint(IMMDevice* dev) {
    ComPtr<IAudioClient> c;
    HR(dev->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(c.GetAddressOf())));
    return c;
}

WAVEFORMATEX pcm16(uint32_t rate, uint16_t ch) {
    WAVEFORMATEX wf = {};
    wf.wFormatTag = WAVE_FORMAT_PCM;
    wf.nChannels = ch;
    wf.nSamplesPerSec = rate;
    wf.wBitsPerSample = 16;
    wf.nBlockAlign = static_cast<WORD>(ch * 2);
    wf.nAvgBytesPerSec = rate * wf.nBlockAlign;
    return wf;
}

enum class SampleType { Int16, Int32, Float32 };

struct Opened {
    ComPtr<IAudioClient> client;
    uint32_t rate;
    uint16_t channels;
    SampleType type;
    std::wstring how;
    std::wstring source;
};

Opened openCapture(const CaptureConfig& cfg) {
    std::function<ComPtr<IAudioClient>()> make;
    DWORD baseFlags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK;
    std::wstring source;

    switch (cfg.kind) {
        case SourceKind::Endpoint: {
            std::wstring name;
            auto dev = findDevice(eCapture, cfg.device, &name);
            source = L"capture device \"" + name + L"\"";
            make = [dev] { return activateEndpoint(dev.Get()); };
            break;
        }
        case SourceKind::EndpointLoopback: {
            std::wstring name;
            auto dev = findDevice(eRender, cfg.device, &name);
            source = L"loopback of render device \"" + name + L"\"";
            baseFlags |= AUDCLNT_STREAMFLAGS_LOOPBACK;
            make = [dev] { return activateEndpoint(dev.Get()); };
            break;
        }
        case SourceKind::Process: {
            wchar_t buf[96];
            swprintf_s(buf, L"process loopback PID %lu (%ls tree)", cfg.pid,
                       cfg.excludeTree ? L"EXCLUDE" : L"INCLUDE");
            source = buf;
            baseFlags |= AUDCLNT_STREAMFLAGS_LOOPBACK;
            const DWORD pid = cfg.pid;
            const bool ex = cfg.excludeTree;
            make = [pid, ex] { return activateProcessLoopback(pid, ex); };
            break;
        }
    }

    struct Attempt {
        uint32_t rate;
        uint16_t ch;
        bool autoconvert;
    };
    std::vector<Attempt> attempts = {{cfg.rate, cfg.channels, true}, {cfg.rate, cfg.channels, false}};
    if (cfg.kind == SourceKind::Process) attempts.push_back({48000, 2, false});

    for (const auto& at : attempts) {
        auto c = make();
        WAVEFORMATEX wf = pcm16(at.rate, at.ch);
        DWORD flags = baseFlags;
        if (at.autoconvert) flags |= AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
        HRESULT hr = c->Initialize(AUDCLNT_SHAREMODE_SHARED, flags, kBufferHns, 0, &wf, nullptr);
        if (SUCCEEDED(hr)) {
            return {c, at.rate, at.ch, SampleType::Int16,
                    at.autoconvert ? L"PCM16 via AUTOCONVERTPCM" : L"PCM16 (accepted as-is)", source};
        }
        logf(L"[%ls] Initialize %u Hz %u ch PCM16%ls failed: %ls\n", cfg.label.c_str(), at.rate, at.ch,
             at.autoconvert ? L" +AUTOCONVERTPCM" : L"", hrText(hr).c_str());
    }

    if (cfg.kind != SourceKind::Process) {
        // Last resort: the device mix format (usually 48 kHz float stereo).
        auto c = make();
        WAVEFORMATEX* mix = nullptr;
        HR(c->GetMixFormat(&mix));
        SampleType type = SampleType::Int16;
        uint16_t fmtTag = mix->wFormatTag;
        if (fmtTag == WAVE_FORMAT_EXTENSIBLE) {
            fmtTag = static_cast<uint16_t>(reinterpret_cast<WAVEFORMATEXTENSIBLE*>(mix)->SubFormat.Data1);
        }
        if (fmtTag == WAVE_FORMAT_IEEE_FLOAT && mix->wBitsPerSample == 32) type = SampleType::Float32;
        else if (fmtTag == WAVE_FORMAT_PCM && mix->wBitsPerSample == 32) type = SampleType::Int32;
        else if (!(fmtTag == WAVE_FORMAT_PCM && mix->wBitsPerSample == 16)) {
            CoTaskMemFree(mix);
            throw AppError{L"Unsupported device mix format"};
        }
        const uint32_t rate = mix->nSamplesPerSec;
        const uint16_t ch = mix->nChannels;
        HRESULT hr = c->Initialize(AUDCLNT_SHAREMODE_SHARED, baseFlags, kBufferHns, 0, mix, nullptr);
        CoTaskMemFree(mix);
        HR(hr);
        return {c, rate, ch, type, L"device mix format (no conversion)", source};
    }
    throw AppError{L"Could not open the capture stream in any format"};
}

struct SecondStats {
    double sumSq = 0;
    int32_t peak = 0;
    uint64_t samples = 0;
    uint32_t packets = 0;
    uint32_t discontinuities = 0;
    uint64_t paddedFrames = 0;
    void reset() { *this = SecondStats{}; }
};

void toInt16(const BYTE* data, UINT32 frames, uint16_t ch, SampleType type, std::vector<int16_t>& out) {
    const size_t n = static_cast<size_t>(frames) * ch;
    out.resize(n);
    switch (type) {
        case SampleType::Int16:
            std::memcpy(out.data(), data, n * 2);
            break;
        case SampleType::Int32: {
            const int32_t* s = reinterpret_cast<const int32_t*>(data);
            for (size_t i = 0; i < n; ++i) out[i] = static_cast<int16_t>(s[i] >> 16);
            break;
        }
        case SampleType::Float32: {
            const float* s = reinterpret_cast<const float*>(data);
            for (size_t i = 0; i < n; ++i) {
                float v = std::max(-1.0f, std::min(1.0f, s[i]));
                out[i] = static_cast<int16_t>(std::lround(v * 32767.0f));
            }
            break;
        }
    }
}

}  // namespace

void runCapture(const CaptureConfig& cfg) {
    ComInit com;
    Opened o = openCapture(cfg);
    const wchar_t* tag = cfg.label.c_str();
    logf(L"[%ls] source : %ls\n", tag, o.source.c_str());
    logf(L"[%ls] format : %u Hz, %u ch, %ls\n", tag, o.rate, o.channels, o.how.c_str());
    logf(L"[%ls] output : %ls%ls\n", tag, cfg.outPath.c_str(), cfg.padSilence ? L"  (silence-padded to wall clock)" : L"");

    HANDLE ev = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    HR(o.client->SetEventHandle(ev));
    ComPtr<IAudioCaptureClient> cap;
    HR(o.client->GetService(IID_PPV_ARGS(&cap)));

    WavWriter wav(cfg.outPath, o.rate, o.channels);
    DWORD taskIndex = 0;
    HANDLE mmcss = AvSetMmThreadCharacteristicsW(L"Audio", &taskIndex);

    HR(o.client->Start());
    const double t0 = nowSeconds();
    double nextReport = 1.0;
    uint64_t framesWritten = 0, framesFromDevice = 0, paddedTotal = 0;
    uint64_t packetsTotal = 0, discTotal = 0, silentFlagPackets = 0;
    int secondsWithSound = 0, secondsReported = 0;
    SecondStats sec;
    std::vector<int16_t> pcm;

    while (!g_stop) {
        WaitForSingleObject(ev, 20);
        const double elapsed = nowSeconds() - t0;
        if (cfg.seconds > 0 && elapsed >= cfg.seconds) break;

        bool gotPacket = false;
        UINT32 next = 0;
        HRESULT hr;
        while (SUCCEEDED(hr = cap->GetNextPacketSize(&next)) && next > 0) {
            BYTE* data = nullptr;
            UINT32 frames = 0;
            DWORD flags = 0;
            HR(cap->GetBuffer(&data, &frames, &flags, nullptr, nullptr));
            if (flags & AUDCLNT_BUFFERFLAGS_SILENT) {
                pcm.assign(static_cast<size_t>(frames) * o.channels, 0);
                ++silentFlagPackets;
            } else {
                toInt16(data, frames, o.channels, o.type, pcm);
            }
            if (flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY) {
                ++sec.discontinuities;
                ++discTotal;
            }
            HR(cap->ReleaseBuffer(frames));

            wav.write(pcm.data(), pcm.size());
            for (int16_t s : pcm) {
                sec.sumSq += static_cast<double>(s) * s;
                int32_t a = s < 0 ? -static_cast<int32_t>(s) : s;
                if (a > sec.peak) sec.peak = a;
            }
            sec.samples += pcm.size();
            ++sec.packets;
            ++packetsTotal;
            framesWritten += frames;
            framesFromDevice += frames;
            gotPacket = true;
        }
        if (FAILED(hr)) HR(hr);

        if (cfg.padSilence && !gotPacket) {
            const uint64_t expected = static_cast<uint64_t>(elapsed * o.rate);
            if (expected > framesWritten + o.rate / 5) {  // >200 ms behind and nothing arriving
                const uint64_t pad = expected - framesWritten;
                wav.writeSilence(pad);
                framesWritten += pad;
                sec.paddedFrames += pad;
                paddedTotal += pad;
            }
        }

        if (elapsed >= nextReport) {
            const double rms = sec.samples ? std::sqrt(sec.sumSq / static_cast<double>(sec.samples)) / 32768.0 : 0.0;
            const double rmsDb = toDbfs(rms);
            const bool sound = sec.samples > 0 && rmsDb > -60.0;
            if (sound) ++secondsWithSound;
            ++secondsReported;
            const wchar_t* note = sec.packets == 0 ? L"NO DATA" : (sound ? L"" : L"silence");
            logf(L"[%ls] %5.0fs  rms %6.1f dBFS  peak %6.1f dBFS  pkts %3u  pad %4.0f ms  disc %u  %ls\n", tag,
                 nextReport, rmsDb, toDbfs(sec.peak / 32768.0), sec.packets,
                 1000.0 * static_cast<double>(sec.paddedFrames) / o.rate, sec.discontinuities, note);
            sec.reset();
            nextReport += 1.0;
        }
    }

    o.client->Stop();
    wav.close();
    if (mmcss) AvRevertMmThreadCharacteristics(mmcss);
    CloseHandle(ev);

    const double wall = nowSeconds() - t0;
    const double devSec = static_cast<double>(framesFromDevice) / o.rate;
    logf(L"[%ls] SUMMARY  wall %.1f s | device audio %.2f s (%.2f%% of wall) | padded %.2f s | packets %llu | "
         L"discontinuities %llu | silent-flag packets %llu | seconds with sound %d/%d\n",
         tag, wall, devSec, wall > 0 ? 100.0 * devSec / wall : 0.0, static_cast<double>(paddedTotal) / o.rate,
         static_cast<unsigned long long>(packetsTotal), static_cast<unsigned long long>(discTotal),
         static_cast<unsigned long long>(silentFlagPackets), secondsWithSound, secondsReported);
}
