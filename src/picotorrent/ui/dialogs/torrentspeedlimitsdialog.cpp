#include "torrentspeedlimitsdialog.hpp"

#include <limits>

#include "../translator.hpp"

using pt::UI::Dialogs::TorrentSpeedLimitsDialog;

TorrentSpeedLimitsDialog::TorrentSpeedLimitsDialog(wxWindow* parent, int downKiB, int upKiB)
    : wxDialog(parent, wxID_ANY, i18n("speed_limits"), wxDefaultPosition, wxDefaultSize, wxDEFAULT_DIALOG_STYLE)
{
    int const max = std::numeric_limits<int>::max() / 1024;

    m_down = new wxSpinCtrl(this, wxID_ANY, wxEmptyString, wxDefaultPosition, wxDefaultSize, wxSP_ARROW_KEYS, 0, max, downKiB);
    m_up = new wxSpinCtrl(this, wxID_ANY, wxEmptyString, wxDefaultPosition, wxDefaultSize, wxSP_ARROW_KEYS, 0, max, upKiB);

    auto grid = new wxFlexGridSizer(3, FromDIP(7), FromDIP(10));
    grid->AddGrowableCol(1, 1);
    grid->Add(new wxStaticText(this, wxID_ANY, i18n("download_limit")), 0, wxALIGN_CENTER_VERTICAL);
    grid->Add(m_down, 1, wxEXPAND);
    grid->Add(new wxStaticText(this, wxID_ANY, i18n("kibs")), 0, wxALIGN_CENTER_VERTICAL);
    grid->Add(new wxStaticText(this, wxID_ANY, i18n("upload_limit")), 0, wxALIGN_CENTER_VERTICAL);
    grid->Add(m_up, 1, wxEXPAND);
    grid->Add(new wxStaticText(this, wxID_ANY, i18n("kibs")), 0, wxALIGN_CENTER_VERTICAL);

    auto hint = new wxStaticText(this, wxID_ANY, i18n("speed_limits_hint"));

    auto buttons = new wxBoxSizer(wxHORIZONTAL);
    auto ok = new wxButton(this, wxID_OK, i18n("ok"));
    ok->SetDefault();
    buttons->Add(ok);
    buttons->Add(new wxButton(this, wxID_CANCEL, i18n("cancel")), 0, wxLEFT, FromDIP(7));

    auto sizer = new wxBoxSizer(wxVERTICAL);
    sizer->Add(grid, 0, wxEXPAND | wxLEFT | wxTOP | wxRIGHT, FromDIP(11));
    sizer->Add(hint, 0, wxLEFT | wxTOP | wxRIGHT, FromDIP(11));
    sizer->Add(buttons, 0, wxALIGN_RIGHT | wxALL, FromDIP(11));

    SetSizerAndFit(sizer);
    m_down->SetFocus();
}
