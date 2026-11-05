#pragma once

#include "common.h"

#include <audiopolicy.h>

struct SessionInfo {
    std::wstring deviceId;
    std::wstring deviceName;
    DWORD pid = 0;
    std::wstring exe;
    bool system = false;
    AudioSessionState state = AudioSessionStateInactive;
    float volume = 0.0f;
    BOOL mute = FALSE;
    ComPtr<ISimpleAudioVolume> vol;
};

// Render sessions on every active output device.
std::vector<SessionInfo> listSessions();

const wchar_t* stateName(AudioSessionState s);

// audio_probe volume (--pid N | --name exe) [--set 0..1] | --restore
int cmdVolume(const Args& args);
