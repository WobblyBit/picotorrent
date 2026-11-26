#pragma once

#include <wx/wxprec.h>
#ifndef WX_PRECOMP
#include <wx/wx.h>
#endif

#include <wx/spinctrl.h>

namespace pt
{
namespace UI
{
namespace Dialogs
{
    // Per-torrent speed limits in KiB/s. 0 means unlimited.
    class TorrentSpeedLimitsDialog : public wxDialog
    {
    public:
        TorrentSpeedLimitsDialog(wxWindow* parent, int downKiB, int upKiB);

        int DownloadKiB() const { return m_down->GetValue(); }
        int UploadKiB() const { return m_up->GetValue(); }

    private:
        wxSpinCtrl* m_down;
        wxSpinCtrl* m_up;
    };
}
}
}
