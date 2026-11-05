#include "wav.h"

#include "common.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace {

void put16(uint8_t* p, uint16_t v) {
    p[0] = static_cast<uint8_t>(v);
    p[1] = static_cast<uint8_t>(v >> 8);
}
void put32(uint8_t* p, uint32_t v) {
    for (int i = 0; i < 4; ++i) p[i] = static_cast<uint8_t>(v >> (8 * i));
}
uint16_t get16(const uint8_t* p) { return static_cast<uint16_t>(p[0] | (p[1] << 8)); }
uint32_t get32(const uint8_t* p) {
    return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
           (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}

}  // namespace

WavWriter::WavWriter(const std::wstring& path, uint32_t rate, uint16_t channels)
    : rate_(rate), ch_(channels) {
    if (_wfopen_s(&f_, path.c_str(), L"wb") != 0 || !f_) {
        f_ = nullptr;
        throw AppError{L"Cannot create " + path};
    }
    writeHeader();
}

WavWriter::~WavWriter() { close(); }

void WavWriter::writeHeader() {
    uint8_t h[44];
    const uint32_t data = bytes_ > 0xFFFFFFF0ull ? 0xFFFFFFF0u : static_cast<uint32_t>(bytes_);
    std::memcpy(h, "RIFF", 4);
    put32(h + 4, 36 + data);
    std::memcpy(h + 8, "WAVEfmt ", 8);
    put32(h + 16, 16);
    put16(h + 20, 1);  // PCM
    put16(h + 22, ch_);
    put32(h + 24, rate_);
    put32(h + 28, rate_ * ch_ * 2);
    put16(h + 32, static_cast<uint16_t>(ch_ * 2));
    put16(h + 34, 16);
    std::memcpy(h + 36, "data", 4);
    put32(h + 40, data);
    _fseeki64(f_, 0, SEEK_SET);
    fwrite(h, 1, sizeof(h), f_);
    _fseeki64(f_, 0, SEEK_END);
    fflush(f_);
}

void WavWriter::write(const int16_t* samples, size_t count) {
    if (!f_ || count == 0) return;
    fwrite(samples, sizeof(int16_t), count, f_);
    bytes_ += count * sizeof(int16_t);
    sinceHeader_ += count * sizeof(int16_t);
    if (sinceHeader_ >= static_cast<uint64_t>(rate_) * ch_ * 2) {
        sinceHeader_ = 0;
        writeHeader();
    }
}

void WavWriter::writeSilence(uint64_t frames) {
    static const int16_t zeros[4096] = {};
    uint64_t samples = frames * ch_;
    while (samples > 0) {
        size_t n = static_cast<size_t>(std::min<uint64_t>(samples, 4096));
        write(zeros, n);
        samples -= n;
    }
}

void WavWriter::close() {
    if (!f_) return;
    writeHeader();
    fclose(f_);
    f_ = nullptr;
}

WavData readWav(const std::wstring& path) {
    FILE* f = nullptr;
    if (_wfopen_s(&f, path.c_str(), L"rb") != 0 || !f) throw AppError{L"Cannot open " + path};
    std::vector<uint8_t> buf;
    uint8_t tmp[65536];
    size_t n;
    while ((n = fread(tmp, 1, sizeof(tmp), f)) > 0) buf.insert(buf.end(), tmp, tmp + n);
    fclose(f);

    if (buf.size() < 12 || std::memcmp(buf.data(), "RIFF", 4) != 0 || std::memcmp(buf.data() + 8, "WAVE", 4) != 0) {
        throw AppError{path + L" is not a RIFF/WAVE file"};
    }
    uint16_t tag = 0, channels = 0, bits = 0;
    uint32_t rate = 0;
    const uint8_t* data = nullptr;
    size_t dataLen = 0;
    size_t pos = 12;
    while (pos + 8 <= buf.size()) {
        const uint8_t* ck = buf.data() + pos;
        uint32_t len = get32(ck + 4);
        size_t avail = std::min<size_t>(len, buf.size() - pos - 8);
        if (std::memcmp(ck, "fmt ", 4) == 0 && avail >= 16) {
            tag = get16(ck + 8);
            channels = get16(ck + 10);
            rate = get32(ck + 12);
            bits = get16(ck + 22);
            if (tag == 0xFFFE && avail >= 40) tag = get16(ck + 8 + 24);  // SubFormat.Data1
        } else if (std::memcmp(ck, "data", 4) == 0) {
            data = ck + 8;
            dataLen = avail;
        }
        pos += 8 + static_cast<size_t>(len) + (len & 1);
    }
    if (!data || !channels || !rate) throw AppError{path + L": missing fmt or data chunk"};

    WavData out;
    out.rate = rate;
    out.channels = channels;
    if (tag == 1 && bits == 16) {
        out.samples.resize(dataLen / 2);
        std::memcpy(out.samples.data(), data, out.samples.size() * 2);
    } else if (tag == 1 && bits == 24) {
        out.samples.resize(dataLen / 3);
        for (size_t i = 0; i < out.samples.size(); ++i) {
            out.samples[i] = static_cast<int16_t>(get16(data + i * 3 + 1));
        }
    } else if (tag == 3 && bits == 32) {
        out.samples.resize(dataLen / 4);
        for (size_t i = 0; i < out.samples.size(); ++i) {
            float v;
            std::memcpy(&v, data + i * 4, 4);
            v = std::max(-1.0f, std::min(1.0f, v));
            out.samples[i] = static_cast<int16_t>(std::lround(v * 32767.0f));
        }
    } else {
        throw AppError{path + L": unsupported WAV encoding (need PCM 16/24-bit or float 32-bit)"};
    }
    return out;
}
