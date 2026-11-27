#include "pt_lt.h"

#include <cstdio>
#include <cstring>
#include <sstream>
#include <string>
#include <vector>

#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/load_torrent.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/session_stats.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/peer_info.hpp>
#include <libtorrent/announce_entry.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/version.hpp>

namespace lt = libtorrent;

struct pt_session
{
    lt::session ses;
    std::vector<lt::torrent_handle> torrents;
    int dht_nodes = 0;

    explicit pt_session(lt::settings_pack sp) : ses(std::move(sp)) {}

    // Drain alerts; the only one we keep is the DHT node count.
    void pump()
    {
        std::vector<lt::alert *> alerts;
        ses.pop_alerts(&alerts);
        for (lt::alert *a : alerts)
        {
            if (auto *st = lt::alert_cast<lt::session_stats_alert>(a))
            {
                static int idx = lt::find_metric_idx("dht.dht_nodes");
                if (idx >= 0) { dht_nodes = static_cast<int>(st->counters()[static_cast<size_t>(idx)]); }
            }
        }
    }
};

static void set_err(char *err, int errlen, std::string const &msg)
{
    if (err && errlen > 0) { std::snprintf(err, static_cast<size_t>(errlen), "%s", msg.c_str()); }
}

static void copy(char *dst, size_t cap, std::string const &s)
{
    std::snprintf(dst, cap, "%s", s.c_str());
}

extern "C" const char *pt_version(void) { return LIBTORRENT_VERSION; }

extern "C" pt_session *pt_session_new(void)
{
    lt::settings_pack sp;
    sp.set_int(lt::settings_pack::alert_mask, lt::alert::all_categories);
    sp.set_str(lt::settings_pack::user_agent, "PicoTorrent-Linux/0");
    sp.set_str(lt::settings_pack::listen_interfaces, "0.0.0.0:6881,[::]:6881");
    return new pt_session(std::move(sp));
}

extern "C" void pt_session_free(pt_session *s) { delete s; }

extern "C" int pt_add_torrent_file(pt_session *s, const char *path, const char *save_path, char *err, int errlen)
{
    try
    {
        lt::add_torrent_params p = lt::load_torrent_file(path);
        p.save_path = save_path;
        s->torrents.push_back(s->ses.add_torrent(std::move(p)));
        return 0;
    }
    catch (std::exception const &e) { set_err(err, errlen, e.what()); return 1; }
}

extern "C" int pt_add_magnet(pt_session *s, const char *uri, const char *save_path, char *err, int errlen)
{
    lt::error_code ec;
    lt::add_torrent_params p = lt::parse_magnet_uri(uri, ec);
    if (ec) { set_err(err, errlen, ec.message()); return 1; }
    p.save_path = save_path;
    s->torrents.push_back(s->ses.add_torrent(std::move(p)));
    return 0;
}

extern "C" int pt_torrent_count(pt_session *s) { return static_cast<int>(s->torrents.size()); }

extern "C" int pt_torrent_status(pt_session *s, int index, pt_status *out)
{
    if (index < 0 || index >= static_cast<int>(s->torrents.size())) { return 1; }

    lt::torrent_status ts = s->torrents[static_cast<size_t>(index)].status();
    std::memset(out, 0, sizeof(*out));

    copy(out->name, sizeof(out->name), ts.name);
    copy(out->save_path, sizeof(out->save_path), ts.save_path);
    if (ts.errc) { copy(out->error, sizeof(out->error), ts.errc.message()); }

    if (ts.info_hashes.has_v1()) { std::ostringstream o; o << ts.info_hashes.v1; copy(out->hash_v1, sizeof(out->hash_v1), o.str()); }
    if (ts.info_hashes.has_v2()) { std::ostringstream o; o << ts.info_hashes.v2; copy(out->hash_v2, sizeof(out->hash_v2), o.str()); }

    out->state = static_cast<int32_t>(ts.state);
    out->paused = (ts.flags & lt::torrent_flags::paused) ? 1 : 0;
    out->auto_managed = (ts.flags & lt::torrent_flags::auto_managed) ? 1 : 0;
    out->queue_position = static_cast<int32_t>(ts.queue_position);
    out->download_rate = ts.download_payload_rate;
    out->upload_rate = ts.upload_payload_rate;
    out->num_peers = ts.num_peers;
    out->num_seeds = ts.num_seeds;
    out->list_peers = ts.list_peers;
    out->list_seeds = ts.list_seeds;
    out->progress = ts.progress;
    out->availability = ts.distributed_copies;
    out->total_wanted = ts.total_wanted;
    out->total_done = ts.total_wanted_done;
    out->all_time_download = ts.all_time_download;
    out->all_time_upload = ts.all_time_upload;
    out->added_time = static_cast<int64_t>(ts.added_time);
    out->completed_time = static_cast<int64_t>(ts.completed_time);
    return 0;
}

extern "C" void pt_pause(pt_session *s, int i) { if (i >= 0 && i < (int)s->torrents.size()) { s->torrents[i].unset_flags(lt::torrent_flags::auto_managed); s->torrents[i].pause(); } }
extern "C" void pt_resume(pt_session *s, int i) { if (i >= 0 && i < (int)s->torrents.size()) { s->torrents[i].set_flags(lt::torrent_flags::auto_managed); s->torrents[i].resume(); } }
extern "C" void pt_recheck(pt_session *s, int i) { if (i >= 0 && i < (int)s->torrents.size()) { s->torrents[i].force_recheck(); } }

extern "C" void pt_remove(pt_session *s, int i, int delete_files)
{
    if (i < 0 || i >= (int)s->torrents.size()) { return; }
    s->ses.remove_torrent(s->torrents[i], delete_files ? lt::session::delete_files : lt::remove_flags_t{});
    s->torrents.erase(s->torrents.begin() + i);
}

extern "C" int pt_files(pt_session *s, int i, pt_file *out, int max)
{
    if (i < 0 || i >= (int)s->torrents.size()) { return 0; }
    lt::torrent_handle &h = s->torrents[i];
    std::shared_ptr<const lt::torrent_info> ti = h.torrent_file();
    if (!ti) { return 0; }
    lt::file_storage const &fs = ti->layout();
    std::vector<std::int64_t> prog = h.file_progress(lt::torrent_handle::piece_granularity);
    std::vector<lt::download_priority_t> prio = h.get_file_priorities();
    int n = 0;
    for (lt::file_index_t f : fs.file_range())
    {
        if (n >= max) { break; }
        size_t k = static_cast<size_t>(static_cast<int>(f));
        std::memset(&out[n], 0, sizeof(pt_file));
        copy(out[n].path, sizeof(out[n].path), fs.file_path(f));
        out[n].size = fs.file_size(f);
        out[n].done = k < prog.size() ? prog[k] : 0;
        out[n].priority = k < prio.size() ? static_cast<int>(static_cast<std::uint8_t>(prio[k])) : 4;
        ++n;
    }
    return n;
}

extern "C" int pt_peers(pt_session *s, int i, pt_peer *out, int max)
{
    if (i < 0 || i >= (int)s->torrents.size()) { return 0; }
    std::vector<lt::peer_info> peers;
    s->torrents[i].get_peer_info(peers);
    int n = 0;
    for (lt::peer_info const &p : peers)
    {
        if (n >= max) { break; }
        std::memset(&out[n], 0, sizeof(pt_peer));
        copy(out[n].ip, sizeof(out[n].ip), p.remote_endpoint().address().to_string() + ":" + std::to_string(p.remote_endpoint().port()));
        copy(out[n].client, sizeof(out[n].client), p.client);
        out[n].down_rate = p.down_speed;
        out[n].up_rate = p.up_speed;
        out[n].progress = p.progress;
        out[n].incoming = (p.flags & lt::peer_info::outgoing_connection) ? 0 : 1;
        ++n;
    }
    return n;
}

extern "C" int pt_trackers(pt_session *s, int i, pt_tracker *out, int max)
{
    if (i < 0 || i >= (int)s->torrents.size()) { return 0; }
    int n = 0;
    for (lt::announce_entry const &ae : s->torrents[i].trackers())
    {
        if (n >= max) { break; }
        std::memset(&out[n], 0, sizeof(pt_tracker));
        copy(out[n].url, sizeof(out[n].url), ae.url);
        out[n].tier = ae.tier;
        for (lt::announce_endpoint const &ep : ae.endpoints)
        {
            for (lt::protocol_version v : {lt::protocol_version::V1, lt::protocol_version::V2})
            {
                lt::announce_infohash const &ai = ep.info_hashes[v];
                if (ai.fails == 0 && !ai.last_error && ai.scrape_complete >= 0) { out[n].working = 1; }
                if (ai.fails > out[n].fails) { out[n].fails = ai.fails; }
                if (out[n].message[0] == 0 && !ai.message.empty()) { copy(out[n].message, sizeof(out[n].message), ai.message); }
                if (out[n].message[0] == 0 && ai.last_error) { copy(out[n].message, sizeof(out[n].message), ai.last_error.message()); }
            }
        }
        ++n;
    }
    return n;
}

extern "C" int pt_dht_nodes(pt_session *s)
{
    s->ses.post_session_stats();
    s->pump();
    return s->dht_nodes;
}
