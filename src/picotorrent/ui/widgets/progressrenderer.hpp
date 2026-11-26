#pragma once

#include <wx/wxprec.h>
#ifndef WX_PRECOMP
#include <wx/wx.h>
#endif
#include <wx/dataview.h>

namespace pt::UI::Widgets
{
    // A slim, rounded progress bar for the torrent list: a quiet track, an accent fill and a
    // small percentage. Complete torrents turn green. The model value is 0..100.
    class ProgressRenderer : public wxDataViewCustomRenderer
    {
    public:
        ProgressRenderer();

        bool SetValue(wxVariant const& value) override;
        bool GetValue(wxVariant& value) const override;
        wxSize GetSize() const override;
        bool Render(wxRect cell, wxDC* dc, int state) override;

    private:
        long m_percent;
    };
}
