#include "render_stream.h"

#include "devices.h"
#include "win_audio.h"

#include <audiopolicy.h>
#include <avrt.h>

#include <algorithm>
#include <cmath>
#include <cstring>

namespace wa {

namespace {
// WASAPI buffer. Small, because translated speech is already late; the ring buffer absorbs
// bursts from the network. The audio engine period is 10 ms, so 40 ms leaves headroom.
constexpr REFERENCE_TIME kBufferHns = 400'000;  // 40 ms
}  // namespace

RenderStream::RenderStream(int32_t id, std::wstring deviceId, uint32_t sampleRate, uint32_t capacityMs)
    : Stream(id),
      deviceId_(std::move(deviceId)),
      rate_(sampleRate),
      ring_(std::max<size_t>(static_cast<size_t>(sampleRate) * capacityMs / 1000, 1)) {}

RenderStream::~RenderStream() { stop(); }

void RenderStream::start() {
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

void RenderStream::stop() {
    stop_ = true;
    if (thread_.joinable() && thread_.get_id() != std::this_thread::get_id()) thread_.join();
}

int32_t RenderStream::write(const uint8_t* pcm, int32_t bytes) {
    if (!pcm || bytes <= 0) return 0;
    const size_t samples = static_cast<size_t>(bytes) / 2;
    std::lock_guard<std::mutex> lock(ringMutex_);
    const size_t cap = ring_.size();
    const size_t n = std::min(samples, cap - count_);
    size_t writePos = (readPos_ + count_) % cap;
    const size_t first = std::min(n, cap - writePos);
    std::memcpy(ring_.data() + writePos, pcm, first * 2);
    if (n > first) std::memcpy(ring_.data(), pcm + first * 2, (n - first) * 2);
    count_ += n;
    return static_cast<int32_t>(n * 2);
}

void RenderStream::clear() {
    std::lock_guard<std::mutex> lock(ringMutex_);
    readPos_ = 0;
    count_ = 0;
}

void RenderStream::setGain(float gain) { gain_ = std::max(0.0f, std::min(8.0f, gain)); }

int32_t RenderStream::bufferedMs() {
    size_t queued;
    {
        std::lock_guard<std::mutex> lock(ringMutex_);
        queued = count_;
    }
    queued += deviceQueued_.load();
    return static_cast<int32_t>(queued * 1000 / rate_);
}

void RenderStream::pull(int16_t* out, UINT32 frames) {
    size_t n;
    {
        std::lock_guard<std::mutex> lock(ringMutex_);
        const size_t cap = ring_.size();
        n = std::min<size_t>(frames, count_);
        const size_t first = std::min(n, cap - readPos_);
        std::memcpy(out, ring_.data() + readPos_, first * 2);
        if (n > first) std::memcpy(out + first, ring_.data(), (n - first) * 2);
        readPos_ = (readPos_ + n) % cap;
        count_ -= n;
    }
    std::fill(out + n, out + frames, int16_t{0});
    const float g = gain_.load();
    if (g != 1.0f) {
        for (size_t i = 0; i < n; ++i) {
            const float v = static_cast<float>(out[i]) * g;
            out[i] = static_cast<int16_t>(std::lround(std::max(-32768.0f, std::min(32767.0f, v))));
        }
    }
}

void RenderStream::run(std::promise<void>& opened) {
    ComInit com;
    ComPtr<IAudioClient> client;
    ComPtr<IAudioRenderClient> rc;
    HANDLE ev = nullptr;
    UINT32 bufferFrames = 0;
    try {
        if (FAILED(com.hr)) throw WaError("CoInitializeEx failed: " + hrText(com.hr), com.hr);
        auto dev = openDevice(eRender, deviceId_);
        WA_HR(dev->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                            reinterpret_cast<void**>(client.GetAddressOf())));
        WAVEFORMATEX wf = {};
        wf.wFormatTag = WAVE_FORMAT_PCM;
        wf.nChannels = 1;
        wf.nSamplesPerSec = rate_;
        wf.wBitsPerSample = 16;
        wf.nBlockAlign = 2;
        wf.nAvgBytesPerSec = rate_ * 2;
        WA_HR(client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                                 AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                                     AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                                 kBufferHns, 0, &wf, nullptr));
        WA_HR(client->GetBufferSize(&bufferFrames));
        ev = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (!ev) throw WaError("CreateEvent failed", HRESULT_FROM_WIN32(GetLastError()));
        WA_HR(client->SetEventHandle(ev));
        WA_HR(client->GetService(IID_PPV_ARGS(&rc)));

        // Opt out of Windows' "communications activity" ducking (ARCHITECTURE.md 4.3).
        ComPtr<IAudioSessionControl> sc;
        if (SUCCEEDED(client->GetService(IID_PPV_ARGS(&sc)))) {
            ComPtr<IAudioSessionControl2> sc2;
            if (SUCCEEDED(sc.As(&sc2))) sc2->SetDuckingPreference(TRUE);
        }

        BYTE* data = nullptr;
        WA_HR(rc->GetBuffer(bufferFrames, &data));
        WA_HR(rc->ReleaseBuffer(bufferFrames, AUDCLNT_BUFFERFLAGS_SILENT));
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
        loop(client.Get(), rc.Get(), ev, bufferFrames);
    } catch (const WaError& e) {
        postText(id_, WA_EVENT_ERROR, e.hr(), e.what());
    } catch (const std::exception& e) {
        postText(id_, WA_EVENT_ERROR, E_FAIL, e.what());
    }
    client->Stop();
    deviceQueued_ = 0;
    if (mmcss) AvRevertMmThreadCharacteristics(mmcss);
    CloseHandle(ev);
}

void RenderStream::loop(IAudioClient* client, IAudioRenderClient* rc, HANDLE ev, UINT32 bufferFrames) {
    while (!stop_) {
        WaitForSingleObject(ev, 100);
        UINT32 padding = 0;
        WA_HR(client->GetCurrentPadding(&padding));
        const UINT32 avail = bufferFrames - padding;
        if (avail > 0) {
            BYTE* data = nullptr;
            WA_HR(rc->GetBuffer(avail, &data));
            pull(reinterpret_cast<int16_t*>(data), avail);
            WA_HR(rc->ReleaseBuffer(avail, 0));
        }
        deviceQueued_ = padding + avail;
    }
}

}  // namespace wa
