#pragma once

#include "common.h"

enum class SourceKind {
    Endpoint,          // a capture device (real mic, or "CABLE-B Output" in the fallback plan)
    EndpointLoopback,  // everything a render device plays (whole mix)
    Process,           // process loopback: one process tree only
};

struct CaptureConfig {
    SourceKind kind = SourceKind::Endpoint;
    std::wstring device;  // selector, for Endpoint / EndpointLoopback
    DWORD pid = 0;        // for Process
    bool excludeTree = false;
    uint32_t rate = 16000;
    uint16_t channels = 1;
    double seconds = 0;  // 0 = until Ctrl+C
    std::wstring outPath;
    std::wstring label;  // prefix for log lines, e.g. "mic" / "app"
    bool padSilence = false;  // keep the WAV aligned with wall-clock when no packets arrive
};

// Blocking. Prints a status line every second and a summary at the end. Throws on error.
void runCapture(const CaptureConfig& cfg);
