#include "pieceprogressbar.hpp"

#include "../../core/configuration.hpp"

#include <wx/dcbuffer.h>
#include <wx/colour.h>

namespace lt = libtorrent;
using pt::UI::Widgets::PieceProgressBar;

PieceProgressBar::PieceProgressBar(wxWindow* parent, wxWindowID id, bool isDarkMode, lt::typed_bitfield<lt::piece_index_t> field)
    : wxPanel(parent, id, wxDefaultPosition, wxSize(-1, parent->FromDIP(6)), wxTAB_TRAVERSAL | wxNO_BORDER | wxBG_STYLE_PAINT),
    m_bitfield(field)
{
    Connect(wxEVT_ERASE_BACKGROUND, wxEraseEventHandler(PieceProgressBar::OnEraseBackground));
    Connect(wxEVT_PAINT, wxPaintEventHandler(PieceProgressBar::OnPaint));
    Connect(wxEVT_SIZE, wxSizeEventHandler(PieceProgressBar::OnSize));
    m_bgColor = isDarkMode ? wxColour(58, 58, 58) : wxColour(224, 224, 224);   // quiet track
}

void PieceProgressBar::UpdateBitfield(lt::typed_bitfield<lt::piece_index_t> const& field)
{
    m_bitfield = field;
    Refresh();
}

void PieceProgressBar::OnEraseBackground(wxEraseEvent&)
{
}

void PieceProgressBar::OnSize(wxSizeEvent&)
{
    Refresh();
}

void PieceProgressBar::OnPaint(wxPaintEvent&)
{
    wxBufferedPaintDC dc(this);
    RenderProgress(dc);
}

void PieceProgressBar::RenderProgress(wxDC& dc)
{
    static wxColor bar("#35b1e1");

    if (m_bitfield.size() > 0)
    {
        wxBitmap prg(m_bitfield.size(), this->GetClientSize().GetHeight());
        wxMemoryDC memDC;

        memDC.SelectObject(prg);
        memDC.SetBrush(m_bgColor);
        memDC.SetPen(*wxTRANSPARENT_PEN);
        memDC.DrawRectangle({ 0, 0 }, prg.GetSize());

        memDC.SetPen(bar);

        for (int idx = 0; idx < m_bitfield.size(); idx++)
        {
            lt::piece_index_t pcs{ idx };

            if (m_bitfield[pcs])
            {
                memDC.DrawLine(idx, 0, idx, prg.GetHeight());
            }
        }

        dc.StretchBlit(
            { 0, 0 },
            this->GetClientSize(),
            &memDC,
            { 0, 0 },
            prg.GetSize());
    }
    else
    {
        dc.SetBrush(m_bgColor);
        dc.SetPen(*wxTRANSPARENT_PEN);
        dc.DrawRectangle(this->GetClientRect());
    }
}
