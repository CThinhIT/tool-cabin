#pragma once

#include <cstdint>
#include <string>

namespace wa {

// A capture or render stream that owns one audio thread.
class Stream {
public:
    explicit Stream(int32_t id) : id_(id) {}
    virtual ~Stream() = default;
    Stream(const Stream&) = delete;
    Stream& operator=(const Stream&) = delete;

    int32_t id() const { return id_; }

    // Idempotent. Blocks until the audio thread has exited.
    virtual void stop() = 0;

protected:
    const int32_t id_;
};

// Implemented in win_audio.cpp. Copies `bytes` to heap memory owned by the receiver and
// invokes the registered callback; drops the event when none is registered.
void postEvent(int32_t stream, int32_t kind, int64_t value, const void* bytes, int32_t size);
void postText(int32_t stream, int32_t kind, int64_t value, const std::string& utf8);

}  // namespace wa
