#pragma once

#include "common.h"
#include "stream.h"

#include <audioclient.h>

#include <atomic>
#include <future>
#include <thread>

namespace wa {

struct CaptureParams {
    int32_t source = 0;     // WA_SOURCE_*
    std::wstring deviceId;  // empty = default device
    DWORD pid = 0;          // WA_SOURCE_PROCESS
    uint32_t sampleRate = 16000;
    uint32_t frameMs = 100;
};

// Captures PCM16 mono at params.sampleRate and posts WA_EVENT_AUDIO frames of frameMs.
//
// Process loopback delivers no packets while the target app is silent, so that source is
// padded with silence to wall-clock time (otherwise the AI would see time jump).
class CaptureStream final : public Stream {
public:
    CaptureStream(int32_t id, CaptureParams params);
    ~CaptureStream() override;

    // Opens the stream on its own MTA thread and waits for the result. Throws WaError.
    void start();
    void stop() override;

private:
    void run(std::promise<void>& opened);
    void loop(IAudioClient* client, IAudioCaptureClient* cap, HANDLE ev);
    ComPtr<IAudioClient> open();
    ComPtr<IAudioClient> activate();

    const CaptureParams p_;
    std::atomic<bool> stop_{false};
    std::thread thread_;
};

}  // namespace wa
