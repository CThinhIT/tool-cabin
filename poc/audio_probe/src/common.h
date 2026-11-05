#pragma once

#include <windows.h>
#include <objbase.h>
#include <wrl/client.h>

#include <atomic>
#include <string>
#include <vector>

using Microsoft::WRL::ComPtr;

// Set by Ctrl+C; every capture/render loop polls it.
extern std::atomic<bool> g_stop;

// Thread-safe printf to stdout (wide format string, use %ls for wide strings).
void logf(const wchar_t* fmt, ...);

// "0x88890008 AUDCLNT_E_UNSUPPORTED_FORMAT" or the system message.
std::wstring hrText(HRESULT hr);

struct HrError {
    HRESULT hr;
    std::wstring what;
};

struct AppError {
    std::wstring msg;
};

#define HR(expr)                                            \
    do {                                                    \
        HRESULT hr__ = (expr);                              \
        if (FAILED(hr__)) throw HrError{hr__, L"" #expr};   \
    } while (0)

struct ComInit {
    HRESULT hr;
    ComInit() : hr(CoInitializeEx(nullptr, COINIT_MULTITHREADED)) {}
    ~ComInit() {
        if (SUCCEEDED(hr)) CoUninitialize();
    }
    ComInit(const ComInit&) = delete;
    ComInit& operator=(const ComInit&) = delete;
};

// Minimal "--name value" / "--flag" parser.
class Args {
public:
    explicit Args(std::vector<std::wstring> v) : v_(std::move(v)) {}
    bool has(const wchar_t* name) const;
    std::wstring get(const wchar_t* name, const std::wstring& def = L"") const;
    double num(const wchar_t* name, double def) const;

private:
    std::vector<std::wstring> v_;
};

std::wstring lower(std::wstring s);
double nowSeconds();  // QueryPerformanceCounter, seconds
double toDbfs(double linear);  // 1.0 == full scale; floors at -99.9
