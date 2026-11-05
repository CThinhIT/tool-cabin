#include "device_notifier.h"

#include "stream.h"
#include "win_audio.h"

#include <wrl/implements.h>

using Microsoft::WRL::ClassicCom;
using Microsoft::WRL::Make;
using Microsoft::WRL::RuntimeClass;
using Microsoft::WRL::RuntimeClassFlags;

namespace wa {

namespace {

// value of the event: what happened (informational only).
enum : int64_t { kStateChanged = 1, kAdded = 2, kRemoved = 3, kDefaultChanged = 4 };

class DeviceNotifier : public RuntimeClass<RuntimeClassFlags<ClassicCom>, IMMNotificationClient> {
public:
    STDMETHOD(OnDeviceStateChanged)(LPCWSTR, DWORD) override { return post(kStateChanged); }
    STDMETHOD(OnDeviceAdded)(LPCWSTR) override { return post(kAdded); }
    STDMETHOD(OnDeviceRemoved)(LPCWSTR) override { return post(kRemoved); }
    STDMETHOD(OnDefaultDeviceChanged)(EDataFlow, ERole role, LPCWSTR) override {
        // Fired once per role; report the console role only.
        return role == eConsole ? post(kDefaultChanged) : S_OK;
    }
    STDMETHOD(OnPropertyValueChanged)(LPCWSTR, const PROPERTYKEY) override { return S_OK; }

private:
    static HRESULT post(int64_t what) {
        postEvent(0, WA_EVENT_DEVICES_CHANGED, what, nullptr, 0);
        return S_OK;
    }
};

}  // namespace

ComPtr<IMMNotificationClient> makeDeviceNotifier() {
    ComPtr<IMMNotificationClient> n = Make<DeviceNotifier>();
    if (!n) throw WaError("Out of memory", E_OUTOFMEMORY);
    return n;
}

}  // namespace wa
