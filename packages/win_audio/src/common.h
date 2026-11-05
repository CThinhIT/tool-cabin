#pragma once

#include <windows.h>
#include <objbase.h>
#include <wrl/client.h>

#include <cstdint>
#include <stdexcept>
#include <string>

namespace wa {

using Microsoft::WRL::ComPtr;

// Internal failures are thrown as WaError and turned into wa_last_error() text or an
// error event at the C API boundary. Messages are UTF-8.
class WaError : public std::runtime_error {
public:
    explicit WaError(const std::string& msg, HRESULT hr = E_FAIL) : std::runtime_error(msg), hr_(hr) {}
    HRESULT hr() const { return hr_; }

private:
    HRESULT hr_;
};

// "0x88890004 AUDCLNT_E_DEVICE_INVALIDATED" or the system message.
std::string hrText(HRESULT hr);

std::string toUtf8(const std::wstring& w);
std::wstring fromUtf8(const char* s);  // nullptr -> L""
std::wstring lower(std::wstring s);

// QueryPerformanceCounter in microseconds.
int64_t nowUs();

// Appends a JSON string literal (with quotes) for a UTF-8 string.
void appendJsonString(std::string& out, const std::string& utf8);

// COM for the current thread, multithreaded apartment.
struct ComInit {
    HRESULT hr;
    ComInit() : hr(CoInitializeEx(nullptr, COINIT_MULTITHREADED)) {}
    ~ComInit() {
        if (SUCCEEDED(hr)) CoUninitialize();
    }
    ComInit(const ComInit&) = delete;
    ComInit& operator=(const ComInit&) = delete;
};

}  // namespace wa

#define WA_HR(expr)                                                                     \
    do {                                                                                \
        const HRESULT hr__ = (expr);                                                    \
        if (FAILED(hr__)) throw ::wa::WaError(std::string(#expr) + " failed: " + ::wa::hrText(hr__), hr__); \
    } while (0)
