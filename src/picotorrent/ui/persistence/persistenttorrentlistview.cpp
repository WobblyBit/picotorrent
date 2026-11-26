#include "persistenttorrentlistview.hpp"

#include <map>

#include <nlohmann/json.hpp>

#include "../models/torrentlistmodel.hpp"
#include "../torrentlistview.hpp"

using json = nlohmann::json;
using pt::UI::TorrentListView;
using pt::UI::Models::TorrentListModel;
using pt::UI::Persistence::PersistentTorrentListView;

static std::map<TorrentListModel::Columns, std::string> ColumnNames =
{
    { TorrentListModel::Columns::Name,          "Col_Name" },
    { TorrentListModel::Columns::QueuePosition, "Col_QueuePosition" },
    { TorrentListModel::Columns::Size,          "Col_Size" },
    { TorrentListModel::Columns::SizeRemaining, "Col_SizeRemaining" },
    { TorrentListModel::Columns::Status,        "Col_Status" },
    { TorrentListModel::Columns::Progress,      "Col_Progress" },
    { TorrentListModel::Columns::ETA,           "Col_ETA" },
    { TorrentListModel::Columns::DownloadSpeed, "Col_DownloadSpeed" },
    { TorrentListModel::Columns::UploadSpeed,   "Col_UploadSpeed" },
    { TorrentListModel::Columns::Availability,  "Col_Availability" },
    { TorrentListModel::Columns::Ratio,         "Col_Ratio" },
    { TorrentListModel::Columns::Seeds,         "Col_Seeds" },
    { TorrentListModel::Columns::Peers,         "Col_Peers" },
    { TorrentListModel::Columns::AddedOn,       "Col_AddedOn" },
    { TorrentListModel::Columns::CompletedOn,   "Col_CompletedOn" },
    { TorrentListModel::Columns::Label,         "Col_Label" },
    { TorrentListModel::Columns::TorrentVersion, "Col_TorrentVersion" },
};

PersistentTorrentListView::PersistentTorrentListView(TorrentListView* tlv)
    : wxPersistentWindow<TorrentListView>(tlv),
    m_tlv(tlv)
{
}

wxString PersistentTorrentListView::GetKind() const
{
    return "torrentViewCtrl";
}

bool PersistentTorrentListView::Restore()
{
    wxString hiddenJson;
    wxString modelsJson;
    wxString widthsJson;

    if (!RestoreValue("Hidden", &hiddenJson)
        || !RestoreValue("Models", &modelsJson)
        || !RestoreValue("Widths", &widthsJson))
    {
        return false;
    }

    json hidden;
    json models;
    json widths;

    try
    {
        hidden = json::parse(hiddenJson.ToStdString());
        models = json::parse(modelsJson.ToStdString());
        widths = json::parse(widthsJson.ToStdString());
    }
    catch (std::exception)
    {
        return false;
    }

    // The three arrays describe the saved columns, index by index. The set of columns can differ
    // from today's (a column was added or removed since), so match by model column id instead of
    // discarding the whole layout: saved columns keep their order, width and visibility, and
    // columns that were not saved yet are added at the end, hidden.
    if (hidden.size() != models.size() || widths.size() != models.size())
    {
        return false;
    }

    std::map<int64_t, wxDataViewColumn*> current;

    for (uint32_t i = m_tlv->GetColumnCount(); i > 0; i--)
    {
        auto col = m_tlv->GetColumnAt(i - 1);
        current[static_cast<int64_t>(col->GetModelColumn())] = col;
        m_tlv->DeleteColumn(col);
    }

    // DeleteColumn does not free the column, so every column is re-appended below.
    for (size_t i = 0; i < models.size(); i++)
    {
        auto iter = current.find(models[i].get<int64_t>());
        if (iter == current.end()) { continue; }   // a column that no longer exists

        auto col = iter->second;
        current.erase(iter);

        m_tlv->AppendColumn(col);
        col->SetHidden(hidden[i].get<bool>());
        col->SetWidth(widths[i].get<int>());
    }

    for (auto& [model, col] : current)
    {
        m_tlv->AppendColumn(col);
        col->SetHidden(true);
    }

    int sortIndex = -1;
    bool sortAscending = false;

    if (RestoreValue("SortIndex", &sortIndex)
        && RestoreValue("SortAscending", &sortAscending))
    {
        if (sortIndex >= 0 && sortIndex < static_cast<int>(m_tlv->GetColumnCount()))
        {
            m_tlv->GetColumn(sortIndex)->SetSortOrder(sortAscending);
        }
    }

    return true;
}

void PersistentTorrentListView::Save() const
{
    if (auto sortingColumn = m_tlv->GetSortingColumn())
    {
        SaveValue("SortIndex", m_tlv->GetColumnIndex(sortingColumn));
        SaveValue("SortAscending", sortingColumn->IsSortOrderAscending());
    }

    json hidden;
    json models;
    json widths;

    // subtract one from the column count since we have a fake column
    // at the very end

    for (uint32_t i = 0; i < m_tlv->GetColumnCount() - 1; i++)
    {
        auto col = m_tlv->GetColumnAt(i);

        hidden.push_back(col->IsHidden());
        models.push_back(col->GetModelColumn());
        widths.push_back(col->GetWidth());
    }

    SaveValue("Hidden", hidden.dump());
    SaveValue("Models", models.dump());
    SaveValue("Widths", widths.dump());
}

PersistentTorrentListView* wxCreatePersistentObject(TorrentListView* lv)
{
    return new PersistentTorrentListView(lv);
}
