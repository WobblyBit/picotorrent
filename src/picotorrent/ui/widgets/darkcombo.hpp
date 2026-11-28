#pragma once

#include <windows.h>
#include <commctrl.h>
#include <uxtheme.h>
#include <wx/wx.h>

#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "uxtheme.lib")

namespace pt::UI::Widgets
{
    // In dark mode the themed native list (the drop-down of a wxChoice / wxComboBox, and wxListBox)
    // paints its highlighted row white with white text. Switch the list to classic drawing, which
    // uses the system highlight colours, and colour its other rows dark through WM_CTLCOLORLISTBOX.
    namespace detail
    {
        constexpr COLORREF kBack = RGB(32, 32, 32);
        constexpr COLORREF kText = RGB(255, 255, 255);

        inline LRESULT CALLBACK ParentProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp, UINT_PTR, DWORD_PTR)
        {
            if (msg == WM_CTLCOLORLISTBOX)
            {
                static HBRUSH brush = CreateSolidBrush(kBack);
                HDC dc = reinterpret_cast<HDC>(wp);
                SetTextColor(dc, kText);
                SetBkColor(dc, kBack);
                return reinterpret_cast<LRESULT>(brush);
            }

            return DefSubclassProc(hwnd, msg, wp, lp);
        }

        inline void Fix(HWND list, HWND parent)
        {
            if (!list || !parent) { return; }
            SetWindowTheme(list, L"", L"");
            SetWindowSubclass(parent, ParentProc, 1, 0);
        }
    }

    // Applies the fix to every choice, combo box and list box below (and including) root.
    inline void FixDarkLists(wxWindow* root)
    {
        if (!wxSystemSettings::GetAppearance().IsDark()) { return; }

        for (wxWindow* w : root->GetChildren())
        {
            FixDarkLists(w);

            if (wxDynamicCast(w, wxChoice) || wxDynamicCast(w, wxComboBox))
            {
                COMBOBOXINFO info{ sizeof(info) };
                if (GetComboBoxInfo(reinterpret_cast<HWND>(w->GetHWND()), &info))
                {
                    detail::Fix(info.hwndList, reinterpret_cast<HWND>(w->GetParent()->GetHWND()));
                }
            }
            else if (wxDynamicCast(w, wxListBox))
            {
                detail::Fix(reinterpret_cast<HWND>(w->GetHWND()), reinterpret_cast<HWND>(w->GetParent()->GetHWND()));
            }
        }
    }
}
