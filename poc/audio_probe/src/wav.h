#pragma once

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

// PCM16 WAV writer. The header is rewritten about once per second so the file stays
// playable even if the process is killed.
class WavWriter {
public:
    WavWriter(const std::wstring& path, uint32_t rate, uint16_t channels);
    ~WavWriter();
    WavWriter(const WavWriter&) = delete;
    WavWriter& operator=(const WavWriter&) = delete;

    void write(const int16_t* samples, size_t count);  // count = samples, not frames
    void writeSilence(uint64_t frames);
    void close();

private:
    void writeHeader();

    FILE* f_ = nullptr;
    uint32_t rate_;
    uint16_t ch_;
    uint64_t bytes_ = 0;
    uint64_t sinceHeader_ = 0;
};

struct WavData {
    uint32_t rate = 0;
    uint16_t channels = 0;
    std::vector<int16_t> samples;  // interleaved PCM16 (converted from 24-bit / float if needed)
};

WavData readWav(const std::wstring& path);
