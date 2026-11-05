#pragma once

#include "common.h"
#include "stream.h"

#include <audioclient.h>

#include <atomic>
#include <future>
#include <mutex>
#include <thread>
#include <vector>

namespace wa {

// Plays PCM16 mono written by the caller into a ring buffer; plays silence when the ring
// is empty so the endpoint (e.g. CABLE Input) always receives a continuous stream.
class RenderStream final : public Stream {
public:
    RenderStream(int32_t id, std::wstring deviceId, uint32_t sampleRate, uint32_t capacityMs);
    ~RenderStream() override;

    void start();  // throws WaError
    void stop() override;

    int32_t write(const uint8_t* pcm, int32_t bytes);  // bytes accepted
    void clear();
    void setGain(float gain);
    int32_t bufferedMs();

private:
    void run(std::promise<void>& opened);
    void loop(IAudioClient* client, IAudioRenderClient* rc, HANDLE ev, UINT32 bufferFrames);
    void pull(int16_t* out, UINT32 frames);

    const std::wstring deviceId_;
    const uint32_t rate_;

    std::mutex ringMutex_;
    std::vector<int16_t> ring_;
    size_t readPos_ = 0;
    size_t count_ = 0;

    std::atomic<float> gain_{1.0f};
    std::atomic<uint32_t> deviceQueued_{0};  // frames in the WASAPI buffer after the last fill
    std::atomic<bool> stop_{false};
    std::thread thread_;
};

}  // namespace wa
