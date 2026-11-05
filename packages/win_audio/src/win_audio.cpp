// C API boundary: no exception crosses it. Failures set wa_last_error() for the calling
// thread and return 0 / -1 / NULL.
#include "win_audio.h"

#include "capture_stream.h"
#include "com_worker.h"
#include "common.h"
#include "device_notifier.h"
#include "devices.h"
#include "render_stream.h"
#include "sessions.h"

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <vector>

namespace {

using wa::ComPtr;

// Heap-allocated and never destroyed: static destructors run under the loader lock at
// process exit, where joining threads or releasing COM objects can deadlock.
struct Globals {
    std::atomic<WaEventCallback> callback{nullptr};
    std::mutex mutex;  // guards everything below
    std::unique_ptr<wa::ComWorker> worker;
    ComPtr<IMMDeviceEnumerator> notifyEnumerator;
    ComPtr<IMMNotificationClient> notifier;
    std::map<int32_t, std::shared_ptr<wa::Stream>> streams;
    int32_t nextId = 1;
};

Globals& g() {
    static Globals* globals = new Globals();
    return *globals;
}

thread_local std::string t_lastError;

wa::ComWorker& worker() {
    std::lock_guard<std::mutex> lock(g().mutex);
    if (!g().worker) g().worker = std::make_unique<wa::ComWorker>();
    return *g().worker;
}

template <typename T, typename F>
T guarded(T onError, F&& body) {
    t_lastError.clear();
    try {
        return body();
    } catch (const std::exception& e) {
        t_lastError = e.what();
    } catch (...) {
        t_lastError = "unknown error";
    }
    return onError;
}

char* dupString(const std::string& s) {
    auto* out = static_cast<char*>(std::malloc(s.size() + 1));
    if (!out) throw wa::WaError("Out of memory", E_OUTOFMEMORY);
    std::memcpy(out, s.c_str(), s.size() + 1);
    return out;
}

int32_t registerStream(const std::shared_ptr<wa::Stream>& s) {
    std::lock_guard<std::mutex> lock(g().mutex);
    g().streams[s->id()] = s;
    return s->id();
}

int32_t newId() {
    std::lock_guard<std::mutex> lock(g().mutex);
    return g().nextId++;
}

template <typename T>
std::shared_ptr<T> findStream(int32_t id) {
    std::lock_guard<std::mutex> lock(g().mutex);
    auto it = g().streams.find(id);
    if (it == g().streams.end()) return nullptr;
    return std::dynamic_pointer_cast<T>(it->second);
}

}  // namespace

namespace wa {

void postEvent(int32_t stream, int32_t kind, int64_t value, const void* bytes, int32_t size) {
    const WaEventCallback cb = g().callback.load();
    if (!cb) return;
    uint8_t* data = nullptr;
    if (bytes && size > 0) {
        data = static_cast<uint8_t*>(std::malloc(static_cast<size_t>(size)));
        if (!data) return;
        std::memcpy(data, bytes, static_cast<size_t>(size));
    } else {
        size = 0;
    }
    cb(stream, kind, value, data, size);
}

void postText(int32_t stream, int32_t kind, int64_t value, const std::string& utf8) {
    postEvent(stream, kind, value, utf8.data(), static_cast<int32_t>(utf8.size()));
}

}  // namespace wa

extern "C" {

WA_API int32_t wa_init(WaEventCallback callback) {
    return guarded<int32_t>(-1, [&] {
        g().callback = callback;
        worker().run([] {
            std::lock_guard<std::mutex> lock(g().mutex);
            if (g().notifier) return;
            auto e = wa::createEnumerator();
            auto n = wa::makeDeviceNotifier();
            WA_HR(e->RegisterEndpointNotificationCallback(n.Get()));
            g().notifyEnumerator = e;
            g().notifier = n;
        });
        return 0;
    });
}

WA_API void wa_shutdown(void) {
    guarded<int>(0, [] {
        g().callback = nullptr;  // nothing reaches the caller from here on
        std::map<int32_t, std::shared_ptr<wa::Stream>> streams;
        std::unique_ptr<wa::ComWorker> w;
        {
            std::lock_guard<std::mutex> lock(g().mutex);
            streams.swap(g().streams);
            w = std::move(g().worker);
        }
        for (auto& [id, s] : streams) s->stop();
        if (w) {
            w->run([] {
                ComPtr<IMMDeviceEnumerator> e;
                ComPtr<IMMNotificationClient> n;
                {
                    std::lock_guard<std::mutex> lock(g().mutex);
                    e.Swap(g().notifyEnumerator);
                    n.Swap(g().notifier);
                }
                if (e && n) e->UnregisterEndpointNotificationCallback(n.Get());
            });
        }
        return 0;  // `w` joins its thread here
    });
}

WA_API const char* wa_last_error(void) { return t_lastError.c_str(); }

WA_API void wa_free(void* ptr) { std::free(ptr); }

WA_API int64_t wa_now_us(void) { return wa::nowUs(); }

WA_API char* wa_list_devices(int32_t flow) {
    return guarded<char*>(nullptr, [&] {
        if (flow != WA_FLOW_RENDER && flow != WA_FLOW_CAPTURE) throw wa::WaError("flow must be 0 or 1");
        std::string json;
        worker().run([&] { json = wa::listDevicesJson(flow == WA_FLOW_RENDER ? eRender : eCapture); });
        return dupString(json);
    });
}

WA_API char* wa_list_sessions(void) {
    return guarded<char*>(nullptr, [] {
        std::string json;
        worker().run([&] { json = wa::listSessionsJson(); });
        return dupString(json);
    });
}

WA_API uint32_t wa_find_root_pid(const char* exe) {
    return guarded<uint32_t>(0, [&] {
        if (!exe || !*exe) throw wa::WaError("exe name is empty");
        return static_cast<uint32_t>(wa::findRootPid(wa::fromUtf8(exe)));
    });
}

WA_API int32_t wa_capture_start(int32_t source, const char* device_id, uint32_t pid, int32_t sample_rate,
                                int32_t frame_ms) {
    return guarded<int32_t>(0, [&] {
        if (sample_rate < 8000 || sample_rate > 48000) throw wa::WaError("sample_rate must be 8000..48000");
        if (frame_ms < 10 || frame_ms > 1000) throw wa::WaError("frame_ms must be 10..1000");
        wa::CaptureParams p;
        p.source = source;
        p.deviceId = wa::fromUtf8(device_id);
        p.pid = pid;
        p.sampleRate = static_cast<uint32_t>(sample_rate);
        p.frameMs = static_cast<uint32_t>(frame_ms);
        auto s = std::make_shared<wa::CaptureStream>(newId(), std::move(p));
        s->start();
        return registerStream(s);
    });
}

WA_API int32_t wa_render_start(const char* device_id, int32_t sample_rate, int32_t capacity_ms) {
    return guarded<int32_t>(0, [&] {
        if (sample_rate < 8000 || sample_rate > 48000) throw wa::WaError("sample_rate must be 8000..48000");
        if (capacity_ms < 100 || capacity_ms > 600000) throw wa::WaError("capacity_ms must be 100..600000");
        auto s = std::make_shared<wa::RenderStream>(newId(), wa::fromUtf8(device_id),
                                                    static_cast<uint32_t>(sample_rate),
                                                    static_cast<uint32_t>(capacity_ms));
        s->start();
        return registerStream(s);
    });
}

WA_API int32_t wa_render_write(int32_t stream, const uint8_t* pcm, int32_t bytes) {
    auto s = findStream<wa::RenderStream>(stream);
    return s ? s->write(pcm, bytes) : -1;
}

WA_API void wa_render_clear(int32_t stream) {
    if (auto s = findStream<wa::RenderStream>(stream)) s->clear();
}

WA_API void wa_render_set_gain(int32_t stream, float gain) {
    if (auto s = findStream<wa::RenderStream>(stream)) s->setGain(gain);
}

WA_API int32_t wa_render_buffered_ms(int32_t stream) {
    auto s = findStream<wa::RenderStream>(stream);
    return s ? s->bufferedMs() : -1;
}

WA_API void wa_stream_stop(int32_t stream) {
    guarded<int>(0, [&] {
        std::shared_ptr<wa::Stream> s;
        {
            std::lock_guard<std::mutex> lock(g().mutex);
            auto it = g().streams.find(stream);
            if (it == g().streams.end()) return 0;
            s = it->second;
            g().streams.erase(it);
        }
        s->stop();
        wa::postEvent(stream, WA_EVENT_STOPPED, 0, nullptr, 0);
        return 0;
    });
}

WA_API float wa_session_volume(uint32_t root_pid) {
    return guarded<float>(-1.0f, [&] {
        float v = -1.0f;
        worker().run([&] { v = wa::treeVolume(root_pid); });
        return v;
    });
}

WA_API int32_t wa_session_set_volume(uint32_t root_pid, float volume) {
    return guarded<int32_t>(-1, [&] {
        int32_t n = 0;
        worker().run([&] { n = wa::setTreeVolume(root_pid, volume); });
        return n;
    });
}

WA_API int32_t wa_session_restore(void) {
    return guarded<int32_t>(-1, [] {
        int32_t n = 0;
        worker().run([&] { n = wa::restoreVolumes(); });
        return n;
    });
}

}  // extern "C"
