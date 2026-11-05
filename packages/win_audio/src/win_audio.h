// C API of the win_audio plugin (docs/ARCHITECTURE.md section 3.3).
//
// C++ does audio I/O only. Every format is fixed by the caller:
//   capture -> PCM16 little-endian mono at `sample_rate`, delivered in frames of `frame_ms`;
//   render  <- PCM16 little-endian mono at `sample_rate`.
// WASAPI converts to and from the device format (AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM).
//
// Strings are UTF-8. Every char* / uint8_t* handed to the caller (return values and
// callback `data`) is heap memory that the caller must release with wa_free().
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#if defined(WA_BUILDING_DLL)
#define WA_API __declspec(dllexport)
#else
#define WA_API __declspec(dllimport)
#endif
#else
#define WA_API
#endif

// --- Event kinds delivered through WaEventCallback ------------------------------------

// One capture frame. data = PCM16LE mono, size = bytes, value = wa_now_us() when the frame
// was completed.
#define WA_EVENT_AUDIO 1
// The stream failed and has stopped (e.g. device unplugged). data = UTF-8 message.
// value = HRESULT. Call wa_stream_stop() to release it.
#define WA_EVENT_ERROR 2
// The stream was stopped by wa_stream_stop().
#define WA_EVENT_STOPPED 3
// WASAPI reported data discontinuities (dropped capture data). value = count since the last
// event of this kind.
#define WA_EVENT_DISCONTINUITY 4
// An audio endpoint was added, removed, enabled, disabled or became default. stream = 0.
#define WA_EVENT_DEVICES_CHANGED 5

// Called from internal audio threads. Must not block. The callee owns `data` (may be NULL)
// and must release it with wa_free().
typedef void (*WaEventCallback)(int32_t stream, int32_t kind, int64_t value, uint8_t* data,
                                int32_t size);

// --- Capture sources -------------------------------------------------------------------

#define WA_SOURCE_DEVICE 0           // a capture endpoint (microphone, or CABLE-B Output)
#define WA_SOURCE_PROCESS 1          // process loopback, INCLUDE the tree of `pid`
#define WA_SOURCE_DEVICE_LOOPBACK 2  // everything a render endpoint plays

// --- Device flows for wa_list_devices -----------------------------------------------------

#define WA_FLOW_RENDER 0
#define WA_FLOW_CAPTURE 1

// --- Lifecycle -------------------------------------------------------------------------

// Registers the event callback and the device-change listener. Returns 0 on success,
// -1 on error (see wa_last_error). Safe to call again to replace the callback.
WA_API int32_t wa_init(WaEventCallback callback);

// Stops every stream, unregisters the callback. After this no callback is invoked.
WA_API void wa_shutdown(void);

// Message of the last failed call made from the calling thread. Valid until the next call.
WA_API const char* wa_last_error(void);

WA_API void wa_free(void* ptr);

// Monotonic clock (QueryPerformanceCounter) in microseconds; same clock as event timestamps.
WA_API int64_t wa_now_us(void);

// --- Devices and sessions --------------------------------------------------------------

// JSON array of active endpoints: [{"id","name","isDefault","isDefaultComm"}].
// NULL on error.
WA_API char* wa_list_devices(int32_t flow);

// JSON array of render audio sessions on all active endpoints:
// [{"pid","exe","rootPid","system","state","volume","muted","deviceId","deviceName"}].
// rootPid = the top process of the same exe (pass it to wa_capture_start). NULL on error.
WA_API char* wa_list_sessions(void);

// Root PID of the process tree of a running exe, e.g. "Discord.exe" (case-insensitive,
// ".exe" optional). Works before the app has an audio session. 0 if not running.
WA_API uint32_t wa_find_root_pid(const char* exe);

// --- Capture ---------------------------------------------------------------------------

// device_id: endpoint id from wa_list_devices, or NULL/"" for the default device.
// pid: only for WA_SOURCE_PROCESS.
// Returns a stream id > 0, or 0 on error (see wa_last_error).
WA_API int32_t wa_capture_start(int32_t source, const char* device_id, uint32_t pid,
                                int32_t sample_rate, int32_t frame_ms);

// --- Render ----------------------------------------------------------------------------

// Opens a render stream that plays whatever is written into its ring buffer and silence
// otherwise. capacity_ms = ring buffer size. Returns a stream id > 0, or 0 on error.
WA_API int32_t wa_render_start(const char* device_id, int32_t sample_rate, int32_t capacity_ms);

// Appends PCM16LE mono samples. Returns the number of bytes accepted (less than `bytes` when
// the ring buffer is full), or -1 if the stream does not exist.
WA_API int32_t wa_render_write(int32_t stream, const uint8_t* pcm, int32_t bytes);

// Drops everything not yet played.
WA_API void wa_render_clear(int32_t stream);

// Linear gain applied while playing (0..8).
WA_API void wa_render_set_gain(int32_t stream, float gain);

// Audio queued but not yet heard: ring buffer + WASAPI buffer, in ms. -1 if no such stream.
WA_API int32_t wa_render_buffered_ms(int32_t stream);

// --- Any stream ------------------------------------------------------------------------

// Stops a capture or render stream and releases it. Blocks until its thread has exited.
WA_API void wa_stream_stop(int32_t stream);

// --- Per-app volume (ISimpleAudioVolume) -----------------------------------------------

// Volume (0..1) of the audio sessions of the process tree rooted at root_pid; the highest
// one if there are several. -1 if the tree has no session.
WA_API float wa_session_volume(uint32_t root_pid);

// Sets the volume of every session of the tree. The ORIGINAL volumes are saved to
// %LOCALAPPDATA%\trans_app\volume_backup.txt first (only if no backup exists yet), because
// Windows remembers per-app volume across restarts. Returns sessions changed, -1 on error.
WA_API int32_t wa_session_set_volume(uint32_t root_pid, float volume);

// Restores the volumes saved by wa_session_set_volume and deletes the backup when at least
// one session was restored. Returns sessions restored (0 = nothing to restore), -1 on error.
WA_API int32_t wa_session_restore(void);

#ifdef __cplusplus
}  // extern "C"
#endif
