#pragma once

#include <string>

#include <wx/utils.h>

namespace pt
{
    // Optional PICOTORRENT_INSTANCE_ID gives a separate single-instance identity (and IPC
    // service name), so a test copy can run next to the normal one. Unset: unchanged.
    inline std::string InstanceSuffix()
    {
        wxString id;
        return wxGetEnv("PICOTORRENT_INSTANCE_ID", &id) && !id.empty() ? "-" + id.ToStdString() : std::string();
    }
}
