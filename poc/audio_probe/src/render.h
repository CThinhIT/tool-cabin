#pragma once

#include "common.h"

struct PlayConfig {
    std::wstring device;  // render device selector
    std::wstring inPath;  // WAV file; empty -> generated tone
    double toneHz = 440;
    bool beep = false;    // tone only: 100 ms beep once per second (for latency checks)
    double seconds = 0;   // 0 = whole file once (or until Ctrl+C for tone / --loop)
    double gain = 1.0;
    bool loop = false;
};

// Blocking. Streams PCM to one specific output device (e.g. "CABLE Input" or the headphones).
void runPlay(const PlayConfig& cfg);
