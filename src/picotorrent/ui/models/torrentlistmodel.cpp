#include "torrentlistmodel.hpp"

#include <boost/log/trivial.hpp>
#include <fmt/format.h>
#include <fmt/xchar.h>
#include <wx/bmpbndl.h>

#include "../../bittorrent/torrenthandle.hpp"
#include "../../bittorrent/torrentstatus.hpp"
#include "../../core/utils.hpp"
#include "../filters/torrentfilter.hpp"
#include "../translator.hpp"

using pt::BitTorrent::TorrentHandle;
using pt::BitTorrent::TorrentStatus;
using pt::UI::Models::TorrentListModel;

// Small badges drawn with shapes only: wx's SVG rasteriser ignores <text>.
// v1 = legacy (grey), v2 = v2 only (teal), hybrid = carries both hashes (v1 | v2).
static const char* const VersionSvg[3] =
{
    // v1
    R"svg(<svg xmlns="http://www.w3.org/2000/svg" width="24" height="13" viewBox="0 0 24 13">
<rect x="0.5" y="0.5" width="23" height="12" rx="6" fill="none" stroke="#8a949e" stroke-width="1"/>
<g fill="none" stroke="#8a949e" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">
<polyline points="6.65,3.5 9.65,9.5 12.65,3.5"/><polyline points="15.4,5 17.4,3 17.4,10"/></g></svg>)svg",
    // hybrid: the v1 and v2 glyphs side by side, each in its own colour
    R"svg(<svg xmlns="http://www.w3.org/2000/svg" width="46" height="13" viewBox="0 0 46 13">
<rect x="0.5" y="0.5" width="45" height="12" rx="6" fill="none" stroke="#6fb0ad" stroke-width="1"/>
<g fill="none" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">
<g stroke="#8a949e"><polyline points="6,3.5 9,9.5 12,3.5"/><polyline points="14.75,5 16.75,3 16.75,10"/></g>
<path d="M21.5 3 V10" stroke="#6fb0ad" stroke-width="1" stroke-opacity="0.6"/>
<g stroke="#26a69a"><polyline points="26.5,3.5 29.5,9.5 32.5,3.5"/><path d="M34.75 5 Q34.75 3 37.25 3 Q39.75 3 39.75 5 Q39.75 6.5 34.75 10 L40.25 10"/></g></g></svg>)svg",
    // v2
    R"svg(<svg xmlns="http://www.w3.org/2000/svg" width="24" height="13" viewBox="0 0 24 13">
<rect x="0.5" y="0.5" width="23" height="12" rx="6" fill="none" stroke="#26a69a" stroke-width="1"/>
<g fill="none" stroke="#26a69a" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">
<polyline points="5.15,3.5 8.15,9.5 11.15,3.5"/><path d="M13.4 5 Q13.4 3 15.9 3 Q18.4 3 18.4 5 Q18.4 6.5 13.4 10 L18.9 10"/></g></svg>)svg",
};
static const int VersionBadgeWidth[3] = { 24, 46, 24 };   // DIP, at height 13 (the SVGs are drawn at that size)

// 1 = v1 only (legacy), 2 = hybrid, 3 = v2 only; 0 = unknown
static int VersionRank(pt::BitTorrent::TorrentStatus const& s)
{
    if (s.hasV1 && s.hasV2) { return 2; }
    return s.hasV2 ? 3 : (s.hasV1 ? 1 : 0);
}

TorrentListModel::TorrentListModel()
    : m_filter(nullptr),
    m_filterLabelId(-1)
{
}

TorrentListModel::~TorrentListModel()
{
}

void TorrentListModel::AddTorrent(pt::BitTorrent::TorrentHandle* torrent)
{
    m_torrents.insert({ torrent->InfoHash(), torrent });
    ApplyFilter();
}

void TorrentListModel::ClearFilter()
{
    m_filter = nullptr;
    ApplyFilter();
}

void TorrentListModel::ClearLabelFilter()
{
    m_filterLabelId = -1;
    ApplyFilter();
}

void TorrentListModel::SetFilter(std::unique_ptr<pt::UI::Filters::TorrentFilter> filter)
{
    m_filter = std::move(filter);
    ApplyFilter();
}

void TorrentListModel::SetLabelFilter(int labelId)
{
    m_filterLabelId = labelId;
    ApplyFilter();
}

int TorrentListModel::GetRowIndex(TorrentHandle* torrent)
{
    return std::distance(
        m_filtered.begin(),
        std::find(
            m_filtered.begin(),
            m_filtered.end(), torrent->InfoHash()));
}

TorrentHandle* TorrentListModel::GetTorrentFromItem(wxDataViewItem const& item)
{
    uint32_t row = this->GetRow(item);
    auto const& hash = m_filtered.at(row);
    return m_torrents.at(hash);
}

void TorrentListModel::RemoveTorrent(lt::info_hash_t const& hash)
{
    m_torrents.erase(hash);

    auto iter = std::find(
        m_filtered.begin(),
        m_filtered.end(),
        hash);

    if (iter != m_filtered.end())
    {
        auto dist = std::distance(m_filtered.begin(), iter);
        m_filtered.erase(iter);
        RowDeleted(dist);
    }
}

void TorrentListModel::UpdateTorrents(std::vector<TorrentHandle*> torrents)
{
    ApplyFilter(torrents);
}

void TorrentListModel::SetBackgroundColorEnabled(bool enabled)
{
    m_backgroundColorEnabled = enabled;
    Reset(m_filtered.size());
}

int TorrentListModel::Compare(const wxDataViewItem& item1, const wxDataViewItem& item2, unsigned int column, bool ascending) const
{
    auto const& hash1 = m_filtered.at(GetRow(item1));
    auto const& hash2 = m_filtered.at(GetRow(item2));

    auto const& lfind = m_torrents.find(hash1);
    auto const& rfind = m_torrents.find(hash2);

    if (lfind == m_torrents.end()
        || rfind == m_torrents.end())
    {
        BOOST_LOG_TRIVIAL(warning) << "Invalid compare";
        return 0;
    }

    auto const& lhs = lfind->second->Status();
    auto const& rhs = rfind->second->Status();

    auto hashSort = [](bool ascending, TorrentStatus const& l, TorrentStatus const& r) -> int
    {
        if (l.infoHash < r.infoHash) { return ascending ? -1 :  1; }
        if (l.infoHash > r.infoHash) { return ascending ?  1 : -1; }
        return 0;
    };

    auto nameSort = [&hashSort](bool ascending, TorrentStatus const& l, TorrentStatus const& r) -> int
    {
        auto compvalue = _strcmpi(l.name.c_str(),r.name.c_str());
        if (compvalue < 0) { return ascending ? -1 : 1; }
        else if (compvalue == 0) { return hashSort(ascending, l, l); }
        else{ return ascending ? 1 : -1; }
    };

    switch (column)
    {
    case Columns::Name:
    {
        return nameSort(ascending, lhs, rhs);
    }
    case Columns::QueuePosition:
    {
        if (lhs.queuePosition < rhs.queuePosition)  { return ascending ? -1 :  1; }
        if (lhs.queuePosition > rhs.queuePosition)  { return ascending ?  1 : -1; }
        if (lhs.queuePosition == rhs.queuePosition) { return hashSort(ascending, lhs, rhs); }
        break;
    }
    case Columns::Size:
    {
        if (lhs.totalWanted < rhs.totalWanted) { return ascending ? -1 :  1; }
        if (lhs.totalWanted > rhs.totalWanted) { return ascending ?  1 : -1; }
        if (lhs.totalWanted == rhs.totalWanted) { return hashSort(ascending, lhs, rhs); }
        break;
    }
    case Columns::SizeRemaining:
    {
        if (lhs.totalWantedRemaining < rhs.totalWantedRemaining) { return ascending ? -1 : 1; }
        if (lhs.totalWantedRemaining > rhs.totalWantedRemaining) { return ascending ? 1 : -1; }
        if (lhs.totalWantedRemaining == rhs.totalWantedRemaining) { return hashSort(ascending, lhs, rhs); }
        break;
    }
    case Columns::Status:
    {
        if (lhs.state < rhs.state) { return ascending ? -1 : 1; }
        if (lhs.state > rhs.state) { return ascending ? 1 : -1; }
        if (lhs.state == rhs.state) { return hashSort(ascending, lhs, rhs); }
        break;
    }
    case Columns::Progress:
    {
        if (lhs.progress < rhs.progress) { return ascending ? -1 : 1; }
        if (lhs.progress > rhs.progress) { return ascending ? 1 : -1; }
        if (lhs.progress == rhs.progress) { return hashSort(ascending, lhs, rhs); }
        break;
    }
    case Columns::ETA:
    {
        if (lhs.eta < rhs.eta) { return ascending ? -1 : 1; }
        if (lhs.eta > rhs.eta) { return ascending ? 1 : -1; }
        if (lhs.eta == rhs.eta) { return hashSort(ascending, lhs, rhs); }
        break;
    }
    case Columns::DownloadSpeed:
    {
        if (lhs.downloadPayloadRate < rhs.downloadPayloadRate) { return ascending ? -1 : 1; }
        if (lhs.downloadPayloadRate > rhs.downloadPayloadRate) { return ascending ? 1 : -1; }
        if (lhs.downloadPayloadRate == rhs.downloadPayloadRate) { return hashSort(ascending, lhs, rhs); }
        break;
    }
    case Columns::UploadSpeed:
    {
        if (lhs.uploadPayloadRate < rhs.uploadPayloadRate) { return ascending ? -1 : 1; }
        if (lhs.uploadPayloadRate > rhs.uploadPayloadRate) { return ascending ? 1 : -1; }
        if (lhs.uploadPayloadRate == rhs.uploadPayloadRate) { return hashSort(ascending, lhs, rhs); }
        break;
    }
    case Columns::Availability:
    {
        if (lhs.availability < rhs.availability) { return ascending ? -1 : 1; }
        if (lhs.availability > rhs.availability) { return ascending ? 1 : -1; }
        if (lhs.availability == rhs.availability) { return hashSort(ascending, lhs, rhs); }
        break;
    }
    case Columns::Ratio:
    {
        if (lhs.ratio < rhs.ratio) { return ascending ? -1 : 1; }
        if (lhs.ratio > rhs.ratio) { return ascending ? 1 : -1; }
        if (lhs.ratio == rhs.ratio) { return hashSort(ascending, lhs, rhs); }
        break;
    }
    case Columns::AddedOn:
    {
        if (lhs.addedOn < rhs.addedOn) { return ascending ? -1 : 1; }
        if (lhs.addedOn > rhs.addedOn) { return ascending ? 1 : -1; }
        if (lhs.addedOn == rhs.addedOn) { return hashSort(ascending, lhs, rhs); }
        break;
    }
    case Columns::CompletedOn:
    {
        if (lhs.completedOn < rhs.completedOn) { return ascending ? -1 : 1; }
        if (lhs.completedOn > rhs.completedOn) { return ascending ? 1 : -1; }
        if (lhs.completedOn == rhs.completedOn) { return hashSort(ascending, lhs, rhs); }
        break;
    }
    case Columns::Label:
    {
        if (lhs.labelName < rhs.labelName) { return ascending ? -1 : 1; }
        if (lhs.labelName > rhs.labelName) { return ascending ? 1 : -1; }
        if (lhs.labelName == rhs.labelName) { return nameSort(ascending, lhs, rhs); }
        break;
    }
    case Columns::TorrentVersion:
    {
        if (VersionRank(lhs) < VersionRank(rhs)) { return ascending ? -1 : 1; }
        if (VersionRank(lhs) > VersionRank(rhs)) { return ascending ? 1 : -1; }
        return nameSort(ascending, lhs, rhs);
    }
    }

    return 0;
}

bool TorrentListModel::GetAttrByRow(unsigned int row, unsigned int col, wxDataViewItemAttr& attr) const
{
    auto const& hash = m_filtered.at(row);
    BitTorrent::TorrentHandle* torrent = m_torrents.at(hash);

    // torrent has a label and a color
    if (torrent->Label() > 0
        && m_labelsColors.find(torrent->Label()) != m_labelsColors.end()
        && m_backgroundColorEnabled)
    {
        attr.SetBackgroundColour(
            m_labelsColors.at(
                torrent->Label()));
    }

    switch (col)
    {
    case Columns::Status:
    {
        BitTorrent::TorrentStatus  status = torrent->Status();

        if (status.state == TorrentStatus::State::Error)
        {
            attr.SetColour(*wxRED);
            return true;
        }

        return false;
    }
    }

    return false;
}

unsigned int TorrentListModel::GetCount() const
{
    return m_filtered.size();
}

void TorrentListModel::GetValueByRow(wxVariant& variant, uint32_t row, uint32_t col) const
{
    if (row >= m_filtered.size())
    {
        BOOST_LOG_TRIVIAL(warning) << "Row out of range (" << row << ", size: " << m_filtered.size() << ")";
        return;
    }

    auto const& hash = m_filtered.at(row);
    auto findTorrent = m_torrents.find(hash);

    if (findTorrent == m_torrents.end())
    {
        BOOST_LOG_TRIVIAL(warning) << "Could not find torrent by hash";
        return;
    }

    BitTorrent::TorrentHandle* torrent = findTorrent->second;
    BitTorrent::TorrentStatus  status = torrent->Status();

    switch (col)
    {
    case Columns::Name:
    {
        variant = Utils::toStdWString(status.name);
        break;
    }
    case Columns::QueuePosition:
    {
        variant = status.queuePosition < 0
            ? "-"
            : std::to_string(status.queuePosition + 1);
        break;
    }
    case Columns::Size:
    {
        variant = Utils::toHumanFileSize(status.totalWanted);
        break;
    }
    case Columns::SizeRemaining:
    {
        variant = status.totalWantedRemaining <= 0
            ? L"-"
            : Utils::toHumanFileSize(status.totalWantedRemaining);
        break;
    }
    case Columns::Status:
    {
        switch (status.state)
        {
        case TorrentStatus::State::CheckingFiles:
        case TorrentStatus::State::DownloadingChecking:
            variant = i18n("state_downloading_checking");
            break;

        case TorrentStatus::State::CheckingResumeData:
            variant = i18n("state_checking_resume_data");
            break;

        case TorrentStatus::State::Downloading:
            variant = i18n("state_downloading");
            break;

        case TorrentStatus::State::DownloadingMetadata:
            variant = i18n("state_downloading_metadata");
            break;

        case TorrentStatus::State::DownloadingPaused:
            variant = i18n("state_downloading_paused");
            break;

        case TorrentStatus::State::DownloadingQueued:
            variant = i18n("state_downloading_queued");
            break;

        case TorrentStatus::State::Error:
            if (status.errorDetails.empty())
            {
                variant = fmt::format(
                    i18n("state_error"),
                    Utils::toStdWString(status.error).c_str());
            }
            else
            {
                variant = fmt::format(
                    i18n("state_error_details"),
                    Utils::toStdWString(status.error).c_str(),
                    Utils::toStdWString(status.errorDetails).c_str());
            }

            break;

        case TorrentStatus::State::Unknown:
            variant = i18n("state_unknown");
            break;

        case TorrentStatus::State::Uploading:
            variant = i18n("state_uploading");
            break;

        case TorrentStatus::State::UploadingPaused:
            variant = i18n("state_uploading_paused");
            break;

        case TorrentStatus::State::UploadingQueued:
            variant = i18n("state_uploading_queued");
            break;
        default:
            variant = "-";
            break;
        }

        break;
    }
    case Columns::Progress:
    {
        variant = static_cast<long>(status.progress * 100);
        break;
    }
    case Columns::ETA:
    {
        variant = "-";

        if (status.paused || status.eta.count() <= 0)
        {
            break;
        }

        std::chrono::hours hours_left = std::chrono::duration_cast<std::chrono::hours>(status.eta);
        std::chrono::minutes min_left = std::chrono::duration_cast<std::chrono::minutes>(status.eta - hours_left);
        std::chrono::seconds sec_left = std::chrono::duration_cast<std::chrono::seconds>(status.eta - hours_left - min_left);

        if (hours_left.count() <= 0)
        {
            if (min_left.count() <= 0)
            {
                variant = fmt::format(i18n("eta_s_format"), sec_left.count());
                break;
            }

            variant = fmt::format(i18n("eta_ms_format"), min_left.count(), sec_left.count());
            break;
        }

        variant = fmt::format(
            i18n("eta_hms_format"),
            hours_left.count(),
            min_left.count(),
            sec_left.count());

        break;
    }
    case Columns::DownloadSpeed:
    {
        variant = "-";

        if (status.paused || status.state == TorrentStatus::Uploading || status.downloadPayloadRate == 0)
        {
            break;
        }

        variant = fmt::format(
            i18n("per_second_format"),
            Utils::toHumanFileSize(status.downloadPayloadRate));

        break;
    }
    case Columns::UploadSpeed:
    {
        variant = "-";

        if (status.paused || status.uploadPayloadRate == 0)
        {
            break;
        }

        variant = fmt::format(
            i18n("per_second_format"),
            Utils::toHumanFileSize(status.uploadPayloadRate));

        break;
    }
    case Columns::Availability:
    {
        variant = "-";

        if (status.paused || status.availability < 0)
        {
            break;
        }

        variant = fmt::format("{:.3f}", status.availability);

        break;
    }
    case Columns::Ratio:
    {
        variant = fmt::format("{:.3f}", status.ratio);
        break;
    }
    case Columns::Seeds:
    {
        variant = "-";

        if (status.paused)
        {
            break;
        }

        variant = fmt::format(
            i18n("d_of_d"),
            status.seedsCurrent,
            status.seedsTotal);

        break;
    }
    case Columns::Peers:
    {
        variant = "-";

        if (status.paused)
        {
            break;
        }

        variant = fmt::format(
            i18n("d_of_d"),
            status.peersCurrent,
            status.peersTotal);

        break;
    }
    case Columns::AddedOn:
    {
        variant = wxDateTime(status.addedOn).FormatISOCombined(' ');
        break;
    }
    case Columns::CompletedOn:
    {
        variant = status.completedOn.IsValid()
            ? wxDateTime(status.completedOn).FormatISOCombined(' ')
            : "-";

        break;
    }
    case Columns::Label:
    {
        auto lbl = m_labels.find(torrent->Label());

        if (torrent->Label() < 0 || lbl == m_labels.end())
        {
            variant << wxDataViewIconText("-");
            break;
        }

        wxIcon ic = wxNullIcon;
        auto [name, _] = lbl->second;
        auto labelIcon = m_labelsIcons.find(torrent->Label());

        if (labelIcon != m_labelsIcons.end())
        {
            ic = labelIcon->second;
        }

        variant << wxDataViewIconText(
            Utils::toStdWString(name), ic);

        break;
    }
    case Columns::TorrentVersion:
    {
        int rank = VersionRank(status);
        if (rank == 0) { variant << wxBitmap(); break; }

        wxBitmap& bmp = m_versionBitmaps[rank - 1];
        if (!bmp.IsOk())
        {
            bmp = wxBitmapBundle::FromSVG(VersionSvg[rank - 1], wxSize(VersionBadgeWidth[rank - 1], 13))
                .GetBitmap(wxWindow::FromDIP(wxSize(VersionBadgeWidth[rank - 1], 13), nullptr));
        }

        variant << bmp;
        break;
    }
    }
}

void TorrentListModel::UpdateLabels(std::map<int, std::tuple<std::string, std::string>> const& labels, int size)
{
    std::vector<BitTorrent::TorrentHandle*> torrents;

    for (auto const& infoHash : m_filtered)
    {
        // if this torrent has a label which have changed color, we need to update it
        auto torrent = m_torrents.at(infoHash);

        // skip torrent if no label
        if (torrent->Label() < 0) { continue; }

        auto oldLabel = m_labels.find(torrent->Label());
        auto label = labels.find(torrent->Label());

        // color has changed
        if (oldLabel != m_labels.end()
            && label != labels.end()
            && oldLabel->second != label->second)
        {
            torrents.push_back(torrent);
            continue;
        }

        // color was removed
        if (oldLabel != m_labels.end()
            && label == labels.end())
        {
            torrents.push_back(torrent);
            continue;
        }

        // color was added
        if (oldLabel == m_labels.end()
            && label != labels.end())
        {
            torrents.push_back(torrent);
            continue;
        }
    }

    m_labels = labels;
    m_labelsColors.clear();
    m_labelsIcons.clear();

    for (auto const& [id, nv] : m_labels)
    {
        auto [name, color] = nv;

        if (color.empty()) { continue; }

        m_labelsColors.insert({ id, wxColor(color) });

        wxBitmap bmp(size, size);

        {
            wxMemoryDC dc;
            wxDCBrushChanger dcbc(dc, m_labelsColors.at(id));
            dc.SelectObject(bmp);
            dc.Clear();
        }

        wxIcon ic;
        ic.CopyFromBitmap(bmp);

        m_labelsIcons.insert({ id, ic });
    }

    for (auto const& torrent : torrents)
    {
        auto iter = std::find(
            m_filtered.begin(),
            m_filtered.end(),
            torrent->InfoHash());

        auto dist = std::distance(
            m_filtered.begin(),
            iter);

        RowChanged(dist);
    }
}

void TorrentListModel::ApplyFilter()
{
    std::vector<TorrentHandle*> filter;
    for (auto const& [hash, torrent] : m_torrents)
    {
        filter.push_back(torrent);
    }
    ApplyFilter(filter);
}

void TorrentListModel::ApplyFilter(std::vector<pt::BitTorrent::TorrentHandle*> torrents)
{
    const std::function<bool(TorrentHandle*)> show = [this](TorrentHandle* torrent)
    {
        // if both label id and filter function is set - this function must check that
        // the torrent both has the label and is included in the filter function
        // otherwise, check each
        if (m_filter && m_filterLabelId > 0)
        {
            return m_filter->Includes(*torrent) && torrent->Label() == m_filterLabelId;
        }
        else if (m_filter)
        {
            return m_filter->Includes(*torrent);
        }
        else if (m_filterLabelId > 0)
        {
            return torrent->Label() == m_filterLabelId;
        }

        return true;
    };

    for (auto torrent : torrents)
    {
        auto iter = std::find(
            m_filtered.begin(),
            m_filtered.end(),
            torrent->InfoHash());

        auto dist = std::distance(
            m_filtered.begin(),
            iter);

        // the torrent is not in the list of filtered torrents
        if (iter == m_filtered.end())
        {
            // but we want to show it according to the filters
            if (show(torrent))
            {
                // so show it
                m_filtered.push_back(torrent->InfoHash());
                RowAppended();
            }
        }
        // the torrent *is* in the list of filtered torrents
        else
        {
            // but we don't want to show it
            if (!show(torrent))
            {
                // so delete it
                m_filtered.erase(iter);
                RowDeleted(dist);
            }
            // and we still want to show it
            else
            {
                // so update it
                RowChanged(dist);
            }
        }
    }
}
