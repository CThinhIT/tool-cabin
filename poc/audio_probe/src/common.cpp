#include "common.h"

#include <audioclient.h>

#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cwctype>
#include <mutex>

std::atomic<bool> g_stop{false};

static std::mutex g_logMutex;

void logf(const wchar_t* fmt, ...) {
    std::lock_guard<std::mutex> lock(g_logMutex);
    va_list ap;
    va_start(ap, fmt);
    vfwprintf(stdout, fmt, ap);
    va_end(ap);
    fflush(stdout);
}

std::wstring hrText(HRESULT hr) {
    struct Known {
        HRESULT hr;
        const wchar_t* name;
    };
    static const Known known[] = {
        {AUDCLNT_E_UNSUPPORTED_FORMAT, L"AUDCLNT_E_UNSUPPORTED_FORMAT"},
        {AUDCLNT_E_DEVICE_INVALIDATED, L"AUDCLNT_E_DEVICE_INVALIDATED"},
        {AUDCLNT_E_DEVICE_IN_USE, L"AUDCLNT_E_DEVICE_IN_USE"},
        {AUDCLNT_E_INVALID_STREAM_FLAG, L"AUDCLNT_E_INVALID_STREAM_FLAG"},
        {AUDCLNT_E_ENDPOINT_CREATE_FAILED, L"AUDCLNT_E_ENDPOINT_CREATE_FAILED"},
        {AUDCLNT_E_SERVICE_NOT_RUNNING, L"AUDCLNT_E_SERVICE_NOT_RUNNING"},
        {AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED, L"AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED"},
        {AUDCLNT_E_BUFFER_SIZE_ERROR, L"AUDCLNT_E_BUFFER_SIZE_ERROR"},
        {AUDCLNT_E_WRONG_ENDPOINT_TYPE, L"AUDCLNT_E_WRONG_ENDPOINT_TYPE"},
        {AUDCLNT_E_NOT_INITIALIZED, L"AUDCLNT_E_NOT_INITIALIZED"},
        {AUDCLNT_E_ALREADY_INITIALIZED, L"AUDCLNT_E_ALREADY_INITIALIZED"},
        {AUDCLNT_E_EVENTHANDLE_NOT_SET, L"AUDCLNT_E_EVENTHANDLE_NOT_SET"},
        {E_NOTIMPL, L"E_NOTIMPL"},
        {E_INVALIDARG, L"E_INVALIDARG"},
        {E_ACCESSDENIED, L"E_ACCESSDENIED"},
    };
    wchar_t buf[32];
    swprintf_s(buf, L"0x%08X", static_cast<unsigned>(hr));
    std::wstring s = buf;
    for (const auto& k : known) {
        if (k.hr == hr) return s + L" " + k.name;
    }
    wchar_t* msg = nullptr;
    FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                       FORMAT_MESSAGE_IGNORE_INSERTS,
                   nullptr, static_cast<DWORD>(hr), 0, reinterpret_cast<LPWSTR>(&msg), 0,
                   nullptr);
    if (msg) {
        std::wstring m = msg;
        LocalFree(msg);
        while (!m.empty() && (m.back() == L'\n' || m.back() == L'\r' || m.back() == L' ')) {
            m.pop_back();
        }
        s += L" " + m;
    }
    return s;
}

bool Args::has(const wchar_t* name) const {
    for (const auto& a : v_) {
        if (a == name) return true;
    }
    return false;
}

std::wstring Args::get(const wchar_t* name, const std::wstring& def) const {
    for (size_t i = 0; i + 1 < v_.size(); ++i) {
        if (v_[i] == name) return v_[i + 1];
    }
    return def;
}

double Args::num(const wchar_t* name, double def) const {
    std::wstring s = get(name);
    if (s.empty()) return def;
    wchar_t* end = nullptr;
    double d = wcstod(s.c_str(), &end);
    if (end == s.c_str() || *end != L'\0') {
        throw AppError{std::wstring(L"Invalid number for ") + name + L": " + s};
    }
    return d;
}

std::wstring lower(std::wstring s) {
    for (auto& c : s) c = static_cast<wchar_t>(std::towlower(c));
    return s;
}

double nowSeconds() {
    static const double freq = [] {
        LARGE_INTEGER f;
        QueryPerformanceFrequency(&f);
        return static_cast<double>(f.QuadPart);
    }();
    LARGE_INTEGER t;
    QueryPerformanceCounter(&t);
    return static_cast<double>(t.QuadPart) / freq;
}

double toDbfs(double linear) {
    if (linear <= 0.0) return -99.9;
    double db = 20.0 * std::log10(linear);
    return db < -99.9 ? -99.9 : db;
}
