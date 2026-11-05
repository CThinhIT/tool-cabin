#pragma once

#include "common.h"

#include <mmdeviceapi.h>

namespace wa {

// Posts WA_EVENT_DEVICES_CHANGED (stream 0) when an endpoint is added, removed, changes
// state or becomes default. The Dart side debounces and re-lists.
ComPtr<IMMNotificationClient> makeDeviceNotifier();

}  // namespace wa
