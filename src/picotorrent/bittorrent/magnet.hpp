#pragma once

#include <string>

#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/announce_entry.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/write_resume_data.hpp>

namespace pt
{
namespace BitTorrent
{
    // libtorrent 2.1 (ABI 4) removed make_magnet_uri(torrent_handle) and
    // torrent_handle::torrent_file_with_hashes(). These helpers rebuild the
    // equivalent from the handle's current state.
    inline libtorrent::add_torrent_params ParamsFromHandle(libtorrent::torrent_handle const& handle)
    {
        libtorrent::torrent_status st = handle.status();

        libtorrent::add_torrent_params atp;
        atp.ti = handle.torrent_file();
        atp.info_hashes = st.info_hashes;
        atp.name = st.name;

        for (auto const& ae : handle.trackers())
        {
            atp.trackers.push_back(ae.url);
            atp.tracker_tiers.push_back(ae.tier);
        }

        return atp;
    }

    inline std::string MagnetUri(libtorrent::torrent_handle const& handle)
    {
        return libtorrent::make_magnet_uri(ParamsFromHandle(handle));
    }
}
}
