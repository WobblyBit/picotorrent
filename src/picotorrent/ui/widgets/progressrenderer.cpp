#include "progressrenderer.hpp"

#include <algorithm>
#include <memory>

#include <wx/graphics.h>

using pt::UI::Widgets::ProgressRenderer;

ProgressRenderer::ProgressRenderer()
    : wxDataViewCustomRenderer("long", wxDATAVIEW_CELL_INERT, wxALIGN_CENTER_VERTICAL),
    m_percent(0)
{
}

bool ProgressRenderer::SetValue(wxVariant const& value)
{
    m_percent = (std::max)(0L, (std::min)(100L, value.GetLong()));
    return true;
}

bool ProgressRenderer::GetValue(wxVariant& value) const
{
    value = m_percent;
    return true;
}

wxSize ProgressRenderer::GetSize() const
{
    return GetView()->FromDIP(wxSize(100, 16));
}

bool ProgressRenderer::Render(wxRect cell, wxDC* dc, int)
{
    auto const view = GetView();
    bool const dark = wxSystemSettings::GetAppearance().IsDark();

    wxString const text = wxString::Format("%ld%%", m_percent);
    dc->SetFont(view->GetFont());
    wxSize const textSize = dc->GetTextExtent("100%");

    int const gap = view->FromDIP(6);
    int const pad = view->FromDIP(4);
    int const barH = view->FromDIP(5);

    wxRect bar(cell.x + pad, cell.y + (cell.height - barH) / 2, cell.width - 2 * pad - gap - textSize.x, barH);
    if (bar.width < view->FromDIP(10)) { bar.width = cell.width - 2 * pad; }

    wxColour const track = dark ? wxColour(58, 58, 58) : wxColour(224, 224, 224);
    wxColour const accent = m_percent >= 100 ? wxColour(61, 186, 120) : wxColour(53, 177, 225);

    std::unique_ptr<wxGraphicsContext> gc(wxGraphicsContext::CreateFromUnknownDC(*dc));
    if (gc)
    {
        gc->SetPen(*wxTRANSPARENT_PEN);
        gc->SetBrush(wxBrush(track));
        gc->DrawRoundedRectangle(bar.x, bar.y, bar.width, bar.height, barH / 2.0);

        int const fill = bar.width * static_cast<int>(m_percent) / 100;
        if (fill > 0)
        {
            gc->SetBrush(wxBrush(accent));
            gc->DrawRoundedRectangle(bar.x, bar.y, (std::max)(fill, barH), bar.height, barH / 2.0);
        }
    }
    else
    {
        dc->SetPen(*wxTRANSPARENT_PEN);
        dc->SetBrush(wxBrush(track));
        dc->DrawRectangle(bar);
        dc->SetBrush(wxBrush(accent));
        dc->DrawRectangle(bar.x, bar.y, bar.width * static_cast<int>(m_percent) / 100, bar.height);
    }

    if (bar.width < cell.width - 2 * pad)   // room left for the number
    {
        dc->SetTextForeground(wxSystemSettings::GetColour(wxSYS_COLOUR_GRAYTEXT));
        dc->DrawText(text, cell.x + cell.width - pad - dc->GetTextExtent(text).x, cell.y + (cell.height - textSize.y) / 2);
    }

    return true;
}
