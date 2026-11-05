#pragma once

#include "common.h"

#include <cstdint>
#include <string>

namespace wa {

// JSON array, see wa_list_sessions().
std::string listSessionsJson();

// Highest volume among the sessions of the tree (active sessions preferred); -1 if none.
float treeVolume(DWORD rootPid);

// See wa_session_set_volume / wa_session_restore.
int32_t setTreeVolume(DWORD rootPid, float volume);
int32_t restoreVolumes();

}  // namespace wa
