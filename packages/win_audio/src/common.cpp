#include "common.h"

#include <audioclient.h>

#include <cstdio>
#include <cwctype>

namespace wa {

std::string hrText(HRESULT hr) {
    struct Known {
        HRESULT hr;
        const char* name;
    };
    static const Known known[] = {
        {AUDCLNT_E_UNSUPPORTED_FORMAT, "AUDCLNT_E_UNSUPPORTED_FORMAT"},
        {AUDCLNT_E_DEVICE_INVALIDATED, "AUDCLNT_E_DEVICE_INVALIDATED (device unplugged or disabled)"},
        {AUDCLNT_E_DEVICE_IN_USE, "AUDCLNT_E_DEVICE_IN_USE"},
        {AUDCLNT_E_INVALID_STREAM_FLAG, "AUDCLNT_E_INVALID_STREAM_FLAG"},
        {AUDCLNT_E_ENDPOINT_CREATE_FAILED, "AUDCLNT_E_ENDPOINT_CREATE_FAILED"},
        {AUDCLNT_E_SERVICE_NOT_RUNNING, "AUDCLNT_E_SERVICE_NOT_RUNNING"},
        {AUDCLNT_E_BUFFER_SIZE_ERROR, "AUDCLNT_E_BUFFER_SIZE_ERROR"},
        {AUDCLNT_E_WRONG_ENDPOINT_TYPE, "AUDCLNT_E_WRONG_ENDPOINT_TYPE"},
        {AUDCLNT_E_NOT_INITIALIZED, "AUDCLNT_E_NOT_INITIALIZED"},
        {HRESULT_FROM_WIN32(ERROR_NOT_FOUND), "E_NOTFOUND (no such device)"},
        {E_NOTIMPL, "E_NOTIMPL"},
        {E_INVALIDARG, "E_INVALIDARG"},
        {E_ACCESSDENIED, "E_ACCESSDENIED"},
    };
    char buf[16];
    snprintf(buf, sizeof(buf), "0x%08X", static_cast<unsigned>(hr));
    std::string s = buf;
    for (const auto& k : known) {
        if (k.hr == hr) return s + " " + k.name;
    }
    wchar_t* msg = nullptr;
    FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                   nullptr, static_cast<DWORD>(hr), 0, reinterpret_cast<LPWSTR>(&msg), 0, nullptr);
    if (msg) {
        std::wstring m = msg;
        LocalFree(msg);
        while (!m.empty() && (m.back() == L'\n' || m.back() == L'\r' || m.back() == L' ')) m.pop_back();
        s += " " + toUtf8(m);
    }
    return s;
}

std::string toUtf8(const std::wstring& w) {
    if (w.empty()) return {};
    const int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
    std::string out(static_cast<size_t>(n), '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), out.data(), n, nullptr, nullptr);
    return out;
}

std::wstring fromUtf8(const char* s) {
    if (!s || !*s) return {};
    const int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, nullptr, 0);
    if (n <= 1) return {};
    std::wstring out(static_cast<size_t>(n - 1), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s, -1, out.data(), n);
    return out;
}

std::wstring lower(std::wstring s) {
    for (auto& c : s) c = static_cast<wchar_t>(std::towlower(c));
    return s;
}

int64_t nowUs() {
    static const int64_t freq = [] {
        LARGE_INTEGER f;
        QueryPerformanceFrequency(&f);
        return static_cast<int64_t>(f.QuadPart);
    }();
    LARGE_INTEGER t;
    QueryPerformanceCounter(&t);
    // Split to avoid overflow of t * 1e6.
    const int64_t sec = t.QuadPart / freq;
    const int64_t rem = t.QuadPart % freq;
    return sec * 1'000'000 + rem * 1'000'000 / freq;
}

void appendJsonString(std::string& out, const std::string& utf8) {
    out += '"';
    for (const char ch : utf8) {
        const auto c = static_cast<unsigned char>(ch);
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out += buf;
                } else {
                    out += ch;
                }
        }
    }
    out += '"';
}

}  // namespace wa
