#include "capture_stream.h"

#include "devices.h"
#include "win_audio.h"

#include <audioclientactivationparams.h>
#include <avrt.h>
#include <wrl/implements.h>

#include <algorithm>
#include <cstring>
#include <vector>

using Microsoft::WRL::ClassicCom;
using Microsoft::WRL::FtmBase;
using Microsoft::WRL::Make;
using Microsoft::WRL::RuntimeClass;
using Microsoft::WRL::RuntimeClassFlags;

namespace wa {

namespace {

constexpr REFERENCE_TIME kBufferHns = 2'000'000;  // 200 ms WASAPI buffer

// ActivateAudioInterfaceAsync needs an agile completion handler (FtmBase).
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
        if (!done_) return E_OUTOFMEMORY;
        if (WaitForSingleObject(done_, ms) != WAIT_OBJECT_0) return HRESULT_FROM_WIN32(ERROR_TIMEOUT);
        out = client_;
        return result_;
    }

private:
    HANDLE done_;
    HRESULT result_ = E_FAIL;
    ComPtr<IAudioClient> client_;
};

ComPtr<IAudioClient> activateProcessLoopback(DWORD pid) {
    AUDIOCLIENT_ACTIVATION_PARAMS params = {};
    params.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
    params.ProcessLoopbackParams.TargetProcessId = pid;
    params.ProcessLoopbackParams.ProcessLoopbackMode = PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;

    PROPVARIANT pv = {};
    pv.vt = VT_BLOB;
    pv.blob.cbSize = sizeof(params);
    pv.blob.pBlobData = reinterpret_cast<BYTE*>(&params);

    auto handler = Make<ActivateHandler>();
    if (!handler) throw WaError("Out of memory", E_OUTOFMEMORY);
    ComPtr<IActivateAudioInterfaceAsyncOperation> op;
    WA_HR(ActivateAudioInterfaceAsync(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, __uuidof(IAudioClient), &pv,
                                      handler.Get(), &op));
    ComPtr<IAudioClient> client;
    WA_HR(handler->wait(client, 5000));
    return client;
}

ComPtr<IAudioClient> activateEndpoint(IMMDevice* dev) {
    ComPtr<IAudioClient> c;
    WA_HR(dev->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(c.GetAddressOf())));
    return c;
}

WAVEFORMATEX pcm16Mono(uint32_t rate) {
    WAVEFORMATEX wf = {};
    wf.wFormatTag = WAVE_FORMAT_PCM;
    wf.nChannels = 1;
    wf.nSamplesPerSec = rate;
    wf.wBitsPerSample = 16;
    wf.nBlockAlign = 2;
    wf.nAvgBytesPerSec = rate * 2;
    return wf;
}

}  // namespace

CaptureStream::CaptureStream(int32_t id, CaptureParams params) : Stream(id), p_(std::move(params)) {}

CaptureStream::~CaptureStream() { stop(); }

void CaptureStream::start() {
    std::promise<void> opened;
    auto result = opened.get_future();
    thread_ = std::thread([this, pr = std::move(opened)]() mutable { run(pr); });
    try {
        result.get();
    } catch (...) {
        thread_.join();
        throw;
    }
}

void CaptureStream::stop() {
    stop_ = true;
    if (thread_.joinable() && thread_.get_id() != std::this_thread::get_id()) thread_.join();
}

ComPtr<IAudioClient> CaptureStream::activate() {
    switch (p_.source) {
        case WA_SOURCE_DEVICE: return activateEndpoint(openDevice(eCapture, p_.deviceId).Get());
        case WA_SOURCE_DEVICE_LOOPBACK: return activateEndpoint(openDevice(eRender, p_.deviceId).Get());
        case WA_SOURCE_PROCESS:
            if (p_.pid == 0) throw WaError("Process loopback needs a process id", E_INVALIDARG);
            return activateProcessLoopback(p_.pid);
        default: throw WaError("Unknown capture source " + std::to_string(p_.source), E_INVALIDARG);
    }
}

ComPtr<IAudioClient> CaptureStream::open() {
    DWORD baseFlags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK;
    if (p_.source != WA_SOURCE_DEVICE) baseFlags |= AUDCLNT_STREAMFLAGS_LOOPBACK;
    const WAVEFORMATEX wf = pcm16Mono(p_.sampleRate);

    // 1) Ask WASAPI to convert to our format (verified for mic and process loopback, T2/T3).
    // 2) The device may natively accept it.
    HRESULT last = E_FAIL;
    for (const bool autoconvert : {true, false}) {
        auto client = activate();  // Initialize() works only once per client
        DWORD flags = baseFlags;
        if (autoconvert) flags |= AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
        last = client->Initialize(AUDCLNT_SHAREMODE_SHARED, flags, kBufferHns, 0, &wf, nullptr);
        if (SUCCEEDED(last)) return client;
    }
    throw WaError("Cannot open the capture stream as " + std::to_string(p_.sampleRate) +
                      " Hz mono PCM16: " + hrText(last),
                  last);
}

void CaptureStream::run(std::promise<void>& opened) {
    ComInit com;
    ComPtr<IAudioClient> client;
    ComPtr<IAudioCaptureClient> cap;
    HANDLE ev = nullptr;
    try {
        if (FAILED(com.hr)) throw WaError("CoInitializeEx failed: " + hrText(com.hr), com.hr);
        client = open();
        ev = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (!ev) throw WaError("CreateEvent failed", HRESULT_FROM_WIN32(GetLastError()));
        WA_HR(client->SetEventHandle(ev));
        WA_HR(client->GetService(IID_PPV_ARGS(&cap)));
        WA_HR(client->Start());
    } catch (...) {
        if (ev) CloseHandle(ev);
        opened.set_exception(std::current_exception());
        return;
    }
    opened.set_value();

    DWORD taskIndex = 0;
    HANDLE mmcss = AvSetMmThreadCharacteristicsW(L"Audio", &taskIndex);
    try {
        loop(client.Get(), cap.Get(), ev);
    } catch (const WaError& e) {
        postText(id_, WA_EVENT_ERROR, e.hr(), e.what());
    } catch (const std::exception& e) {
        postText(id_, WA_EVENT_ERROR, E_FAIL, e.what());
    }
    client->Stop();
    if (mmcss) AvRevertMmThreadCharacteristics(mmcss);
    CloseHandle(ev);
}

void CaptureStream::loop(IAudioClient* /*client*/, IAudioCaptureClient* cap, HANDLE ev) {
    const uint32_t rate = p_.sampleRate;
    const size_t frameSamples = static_cast<size_t>(rate) * p_.frameMs / 1000;
    const bool padSilence = p_.source == WA_SOURCE_PROCESS;
    std::vector<int16_t> acc;
    acc.reserve(frameSamples * 3);
    const int64_t t0 = nowUs();
    uint64_t produced = 0;  // samples since start, real + padded
    int64_t discontinuities = 0;

    while (!stop_) {
        WaitForSingleObject(ev, 20);

        bool gotPacket = false;
        UINT32 next = 0;
        HRESULT hr;
        while (SUCCEEDED(hr = cap->GetNextPacketSize(&next)) && next > 0) {
            BYTE* data = nullptr;
            UINT32 frames = 0;
            DWORD flags = 0;
            WA_HR(cap->GetBuffer(&data, &frames, &flags, nullptr, nullptr));
            const size_t old = acc.size();
            acc.resize(old + frames);
            if (flags & AUDCLNT_BUFFERFLAGS_SILENT) {
                std::fill(acc.begin() + static_cast<ptrdiff_t>(old), acc.end(), int16_t{0});
            } else {
                std::memcpy(acc.data() + old, data, static_cast<size_t>(frames) * 2);
            }
            if (flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY) ++discontinuities;
            WA_HR(cap->ReleaseBuffer(frames));
            produced += frames;
            gotPacket = true;
        }
        if (FAILED(hr)) throw WaError("Capture failed: " + hrText(hr), hr);

        if (padSilence && !gotPacket) {
            const auto expected = static_cast<uint64_t>((nowUs() - t0) * static_cast<int64_t>(rate) / 1'000'000);
            if (expected > produced + rate / 5) {  // >200 ms behind and nothing arriving
                acc.resize(acc.size() + static_cast<size_t>(expected - produced), int16_t{0});
                produced = expected;
            }
        }

        size_t offset = 0;
        while (acc.size() - offset >= frameSamples) {
            postEvent(id_, WA_EVENT_AUDIO, nowUs(), acc.data() + offset, static_cast<int32_t>(frameSamples * 2));
            offset += frameSamples;
        }
        if (offset > 0) acc.erase(acc.begin(), acc.begin() + static_cast<ptrdiff_t>(offset));

        if (discontinuities > 0) {
            postEvent(id_, WA_EVENT_DISCONTINUITY, discontinuities, nullptr, 0);
            discontinuities = 0;
        }
    }
}

}  // namespace wa
