#include "torrentlistview.hpp"

#include <wx/persist.h>

#include "../bittorrent/torrenthandle.hpp"
#include "models/torrentlistmodel.hpp"
#include "persistence/persistenttorrentlistview.hpp"
#include "translator.hpp"
#include "widgets/progressrenderer.hpp"

using pt::UI::TorrentListView;
using pt::UI::Models::TorrentListModel;

TorrentListView::TorrentListView(wxWindow* parent, wxWindowID id, pt::UI::Models::TorrentListModel* model)
    : wxDataViewCtrl(parent, id, wxDefaultPosition, wxDefaultSize, wxDV_MULTIPLE, wxDefaultValidator, "TorrentListView"),
    m_model(model)
{
    this->AssociateModel(m_model);
    m_model->DecRef();

    auto defaultFlags = wxDATAVIEW_COL_REORDERABLE | wxDATAVIEW_COL_RESIZABLE | wxDATAVIEW_COL_SORTABLE;

    m_columns.push_back(
        ColumnMetadata(
            new wxDataViewColumn(
                i18n("name"),
                new wxDataViewTextRenderer(),
                TorrentListModel::Columns::Name,
                FromDIP(180),
                wxALIGN_NOT,
                defaultFlags)));

    m_columns.push_back(
        ColumnMetadata(
            new wxDataViewColumn(
                i18n("queue_position"),
                new wxDataViewTextRenderer(),
                TorrentListModel::Columns::QueuePosition,
                FromDIP(30),
                wxALIGN_RIGHT,
                defaultFlags)));

    m_columns.push_back(
        ColumnMetadata(
            new wxDataViewColumn(
                i18n("size"),
                new wxDataViewTextRenderer(),
                TorrentListModel::Columns::Size,
                FromDIP(80),
                wxALIGN_RIGHT,
                defaultFlags)));

    m_columns.push_back(
        ColumnMetadata(
            new wxDataViewColumn(
                i18n("size_remaining"),
                new wxDataViewTextRenderer(),
                TorrentListModel::Columns::SizeRemaining,
                FromDIP(80),
                wxALIGN_RIGHT,
                defaultFlags),
            true));

    m_columns.push_back(
        ColumnMetadata(
            new wxDataViewColumn(
                i18n("status"),
                new wxDataViewTextRenderer(),
                TorrentListModel::Columns::Status,
                FromDIP(120),
                wxALIGN_NOT,
                defaultFlags)));

    m_columns.push_back(
        ColumnMetadata(
            new wxDataViewColumn(
                i18n("progress"),
                new Widgets::ProgressRenderer(),
                TorrentListModel::Columns::Progress,
                FromDIP(100),
                wxALIGN_NOT,
                defaultFlags)));

    m_columns.push_back(
        ColumnMetadata(
            new wxDataViewColumn(
                i18n("eta"),
                new wxDataViewTextRenderer(),
                TorrentListModel::Columns::ETA,
                FromDIP(80),
                wxALIGN_RIGHT,
                defaultFlags)));

    m_columns.push_back(
        ColumnMetadata(
            new wxDataViewColumn(
                i18n("dl"),
                new wxDataViewTextRenderer(),
                TorrentListModel::Columns::DownloadSpeed,
                FromDIP(80),
                wxALIGN_RIGHT,
                defaultFlags)));

    m_columns.push_back(
        ColumnMetadata(
            new wxDataViewColumn(
                i18n("ul"),
                new wxDataViewTextRenderer(),
                TorrentListModel::Columns::UploadSpeed,
                FromDIP(80),
                wxALIGN_RIGHT,
                defaultFlags)));

    m_columns.push_back(
        ColumnMetadata(
            new wxDataViewColumn(
                i18n("availability"),
                new wxDataViewTextRenderer(),
                TorrentListModel::Columns::Availability,
                FromDIP(80),
                wxALIGN_RIGHT,
                defaultFlags)));

    m_columns.push_back(
        ColumnMetadata(
            new wxDataViewColumn(
                i18n("ratio"),
                new wxDataViewTextRenderer(),
                TorrentListModel::Columns::Ratio,
                FromDIP(80),
                wxALIGN_RIGHT,
                defaultFlags)));

    m_columns.push_back(
        ColumnMetadata(
            new wxDataViewColumn(
                i18n("seeds"),
                new wxDataViewTextRenderer(),
                TorrentListModel::Columns::Seeds,
                FromDIP(80),
                wxALIGN_RIGHT,
                wxDATAVIEW_COL_REORDERABLE | wxDATAVIEW_COL_RESIZABLE)));

    m_columns.push_back(
        ColumnMetadata(
            new wxDataViewColumn(
                i18n("peers"),
                new wxDataViewTextRenderer(),
                TorrentListModel::Columns::Peers,
                FromDIP(80),
                wxALIGN_RIGHT,
                wxDATAVIEW_COL_REORDERABLE | wxDATAVIEW_COL_RESIZABLE)));

    m_columns.push_back(
        ColumnMetadata(
            new wxDataViewColumn(
                i18n("added_on"),
                new wxDataViewTextRenderer(),
                TorrentListModel::Columns::AddedOn,
                FromDIP(120),
                wxALIGN_RIGHT,
                defaultFlags)));

    m_columns.push_back(
        ColumnMetadata(
            new wxDataViewColumn(
                i18n("completed_on"),
                new wxDataViewTextRenderer(),
                TorrentListModel::Columns::CompletedOn,
                FromDIP(120),
                wxALIGN_RIGHT,
                defaultFlags)));

    m_columns.push_back(
        ColumnMetadata(
            new wxDataViewColumn(
                i18n("label"),
                new wxDataViewIconTextRenderer(),
                TorrentListModel::Columns::Label,
                FromDIP(80),
                wxALIGN_LEFT,
                defaultFlags),
            true));

    m_columns.push_back(
        ColumnMetadata(
            new wxDataViewColumn(
                i18n("torrent_version"),
                new wxDataViewBitmapRenderer(),
                TorrentListModel::Columns::TorrentVersion,
                FromDIP(60),
                wxALIGN_CENTER,
                defaultFlags),
            true));

    /*
    nameCol->GetRenderer()->EnableEllipsize(wxELLIPSIZE_END);
    statusCol->GetRenderer()->EnableEllipsize(wxELLIPSIZE_END);*/

    // Just add all columns. The persistence manager will set the saved
    // widths, order and hidden attributes. Otherwise we use our defaults.
    for (auto const& cmd : m_columns)
    {
        InsertColumn(GetColumnCount(), cmd.column);
    }

    if (!wxPersistenceManager::Get().RegisterAndRestore(this))
    {
        for (auto const& cmd : m_columns)
        {
            cmd.column->SetHidden(cmd.hidden);
        }
    }

    // insert the "fake" column last, always
    AppendColumn(new wxDataViewColumn(wxEmptyString, new wxDataViewTextRenderer(), TorrentListModel::Columns::_Max, 0, wxALIGN_CENTER, 0));

    // Keyboard accelerators
    std::vector<wxAcceleratorEntry> entries =
    {
        wxAcceleratorEntry(wxACCEL_CTRL,   int('A'),   ptID_KEY_SELECT_ALL),
        wxAcceleratorEntry(wxACCEL_NORMAL, WXK_DELETE, ptID_KEY_DELETE),
        wxAcceleratorEntry(wxACCEL_SHIFT,  WXK_DELETE, ptID_KEY_DELETE_FILES),
    };

    this->SetAcceleratorTable(wxAcceleratorTable(static_cast<int>(entries.size()), entries.data()));

    this->Bind(wxEVT_DATAVIEW_COLUMN_HEADER_RIGHT_CLICK, &TorrentListView::ShowHeaderContextMenu, this);

    this->Bind(
        wxEVT_MENU,
        [&](wxCommandEvent&)
        {
            wxDataViewItemArray items;
            this->GetSelections(items);

            if (items.IsEmpty()) { return; }

            for (wxDataViewItem& item : items)
            {
                m_model->GetTorrentFromItem(item)->Remove();
            }
        },
        ptID_KEY_DELETE);

    this->Bind(
        wxEVT_MENU,
        [&](wxCommandEvent&)
        {
            wxDataViewItemArray items;
            this->GetSelections(items);

            if (items.IsEmpty()) { return; }

            if (wxMessageBox(
                i18n("confirm_remove_description"),
                i18n("confirm_remove"),
                wxOK | wxCANCEL | wxICON_INFORMATION,
                m_parent) != wxOK) {
                return;
            }

            for (wxDataViewItem& item : items)
            {
                m_model->GetTorrentFromItem(item)->RemoveFiles();
            }
        },
        ptID_KEY_DELETE_FILES);

    this->Bind(
        wxEVT_MENU,
        [&](wxCommandEvent&)
        {
            this->SelectAll();
            wxPostEvent(
                GetParent(),
                wxCommandEvent(wxEVT_DATAVIEW_SELECTION_CHANGED, this->GetId()));
        },
        ptID_KEY_SELECT_ALL);
}

TorrentListView::~TorrentListView()
{
}

// Menu ids for the column items are fixed (base + model column), so a menu that is
// refilled on every open needs its handler bound only once.
static const int ColumnMenuIdBase = 31000;

void TorrentListView::FillColumnsMenu(wxMenu* menu)
{
    while (menu->GetMenuItemCount() > 0)
    {
        menu->Destroy(menu->FindItemByPosition(0));
    }

    // Do not iterate through the last column since it is the one we
    // append to prevent the last real column to stretch

    for (size_t i = 0; i < GetColumnCount() - 1; i++)
    {
        auto col = GetColumnAt(i);
        auto item = menu->AppendCheckItem(ColumnMenuIdBase + static_cast<int>(col->GetModelColumn()), col->GetTitle());
        item->Check(!col->IsHidden());
    }
}

void TorrentListView::BindColumnsMenu(wxMenu* menu)
{
    menu->Bind(
        wxEVT_MENU,
        [this](wxCommandEvent& evt)
        {
            int const modelColumn = evt.GetId() - ColumnMenuIdBase;

            for (size_t c = 0; c + 1 < GetColumnCount(); c++)
            {
                auto col = GetColumnAt(c);
                if (static_cast<int>(col->GetModelColumn()) == modelColumn)
                {
                    col->SetHidden(!col->IsHidden());
                    break;
                }
            }
        },
        ColumnMenuIdBase,
        ColumnMenuIdBase + 1000);
}

void TorrentListView::ShowHeaderContextMenu(wxCommandEvent&)
{
    wxMenu menu;
    FillColumnsMenu(&menu);
    BindColumnsMenu(&menu);
    PopupMenu(&menu);
}
