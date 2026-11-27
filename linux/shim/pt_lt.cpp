#include "pt_lt.h"

#include <chrono>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <thread>
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
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/peer_info.hpp>
#include <libtorrent/write_resume_data.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/bencode.hpp>
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
    std::string resume_dir;
    int pending = 0;   /* resume-data requests not answered yet */

    explicit pt_session(lt::settings_pack sp) : ses(std::move(sp)) {}

    // Drain alerts; the only one we keep is the DHT node count.
    void pump()
    {
        std::vector<lt::alert *> alerts;
        ses.pop_alerts(&alerts);
        for (lt::alert *a : alerts)
        {
            if (auto *rd = lt::alert_cast<lt::save_resume_data_alert>(a))
            {
                if (pending > 0) { --pending; }
                if (!resume_dir.empty())
                {
                    std::ostringstream key;
                    lt::info_hash_t const &ih = rd->params.info_hashes;
                    if (ih.has_v2()) { key << ih.v2; } else { key << ih.v1; }
                    std::vector<char> buf = lt::write_resume_data_buf(rd->params);
                    std::ofstream out(resume_dir + "/" + key.str() + ".resume", std::ios::binary | std::ios::trunc);
                    out.write(buf.data(), static_cast<std::streamsize>(buf.size()));
                }
            }
            else if (lt::alert_cast<lt::save_resume_data_failed_alert>(a))
            {
                if (pending > 0) { --pending; }
            }
            else if (auto *st = lt::alert_cast<lt::session_stats_alert>(a))
            {
                static int idx = lt::find_metric_idx("dht.dht_nodes");
                if (idx >= 0) { dht_nodes = static_cast<int>(st->counters()[static_cast<size_t>(idx)]); }
            }
        }
    }
};

static std::string hash_key(lt::info_hash_t const &ih)
{
    std::ostringstream o;
    if (ih.has_v2()) { o << ih.v2; } else { o << ih.v1; }
    return o.str();
}

/* If a resume file exists for this torrent, continue from it (progress, paused state, priorities, limits). */
static void apply_resume(pt_session *s, lt::add_torrent_params &p)
{
    if (s->resume_dir.empty()) { return; }
    lt::info_hash_t ih = p.ti ? p.ti->info_hashes() : p.info_hashes;
    std::ifstream in(s->resume_dir + "/" + hash_key(ih) + ".resume", std::ios::binary);
    if (!in) { return; }
    std::vector<char> buf((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    lt::error_code ec;
    lt::add_torrent_params rp = lt::read_resume_data(buf, ec);
    if (ec) { return; }
    if (!rp.ti) { rp.ti = p.ti; }
    if (rp.save_path.empty()) { rp.save_path = p.save_path; }
    p = std::move(rp);
}

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
        apply_resume(s, p);
        s->torrents.push_back(s->ses.add_torrent(std::move(p)));
        return 0;
    }
    catch (std::exception const &e) { set_err(err, errlen, e.what()); return 1; }
}

extern "C" int pt_peek(const char *path, char *name, int namelen, pt_file *out, int max, char *err, int errlen)
{
    try
    {
        lt::add_torrent_params p = lt::load_torrent_file(path);
        if (!p.ti) { set_err(err, errlen, "no metadata"); return -1; }
        if (name && namelen > 0) { std::snprintf(name, static_cast<size_t>(namelen), "%s", p.ti->name().c_str()); }
        lt::file_storage const &fs = p.ti->layout();
        int n = 0;
        for (lt::file_index_t f : fs.file_range())
        {
            if (n >= max) { break; }
            std::memset(&out[n], 0, sizeof(pt_file));
            copy(out[n].path, sizeof(out[n].path), fs.file_path(f));
            out[n].size = fs.file_size(f);
            out[n].priority = 4;
            ++n;
        }
        return n;
    }
    catch (std::exception const &e) { set_err(err, errlen, e.what()); return -1; }
}

extern "C" int pt_add_torrent_file_ex(pt_session *s, const char *path, const char *save_path, const int32_t *prio, int nprio, char *err, int errlen)
{
    try
    {
        lt::add_torrent_params p = lt::load_torrent_file(path);
        p.save_path = save_path;
        for (int i = 0; i < nprio; ++i) { p.file_priorities.push_back(lt::download_priority_t(static_cast<std::uint8_t>(prio[i]))); }
        apply_resume(s, p);
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
    apply_resume(s, p);
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
    out->sequential = (ts.flags & lt::torrent_flags::sequential_download) ? 1 : 0;
    return 0;
}

extern "C" void pt_pause(pt_session *s, int i) { if (i >= 0 && i < (int)s->torrents.size()) { s->torrents[i].unset_flags(lt::torrent_flags::auto_managed); s->torrents[i].pause(); } }
extern "C" void pt_resume(pt_session *s, int i) { if (i >= 0 && i < (int)s->torrents.size()) { s->torrents[i].set_flags(lt::torrent_flags::auto_managed); s->torrents[i].resume(); } }
extern "C" void pt_recheck(pt_session *s, int i) { if (i >= 0 && i < (int)s->torrents.size()) { s->torrents[i].force_recheck(); } }

extern "C" void pt_remove(pt_session *s, int i, int delete_files)
{
    if (i < 0 || i >= (int)s->torrents.size()) { return; }
    if (!s->resume_dir.empty())
    {
        lt::torrent_status ts = s->torrents[i].status();
        std::remove((s->resume_dir + "/" + hash_key(ts.info_hashes) + ".resume").c_str());
    }
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

extern "C" void pt_queue_move(pt_session *s, int i, int where)
{
    if (i < 0 || i >= (int)s->torrents.size()) { return; }
    lt::torrent_handle &h = s->torrents[i];
    switch (where)
    {
    case 0: h.queue_position_up(); break;
    case 1: h.queue_position_down(); break;
    case 2: h.queue_position_top(); break;
    default: h.queue_position_bottom(); break;
    }
}

extern "C" void pt_set_sequential(pt_session *s, int i, int on)
{
    if (i < 0 || i >= (int)s->torrents.size()) { return; }
    if (on) { s->torrents[i].set_flags(lt::torrent_flags::sequential_download); }
    else { s->torrents[i].unset_flags(lt::torrent_flags::sequential_download); }
}

extern "C" void pt_set_limits(pt_session *s, int i, int down, int up)
{
    if (i < 0 || i >= (int)s->torrents.size()) { return; }
    s->torrents[i].set_download_limit(down > 0 ? down : -1);
    s->torrents[i].set_upload_limit(up > 0 ? up : -1);
}

extern "C" void pt_force_announce(pt_session *s, int i)
{
    if (i < 0 || i >= (int)s->torrents.size()) { return; }
    s->torrents[i].force_reannounce();
    s->torrents[i].force_dht_announce();
}

extern "C" int pt_magnet(pt_session *s, int i, char *out, int outlen)
{
    if (i < 0 || i >= (int)s->torrents.size()) { return 1; }
    lt::torrent_status ts = s->torrents[i].status();
    lt::add_torrent_params p;
    p.info_hashes = ts.info_hashes;
    p.name = ts.name;
    for (lt::announce_entry const &ae : s->torrents[i].trackers()) { p.trackers.push_back(ae.url); }
    copy(out, static_cast<size_t>(outlen), lt::make_magnet_uri(p));
    return 0;
}

extern "C" int pt_export(pt_session *s, int i, const char *path)
{
    if (i < 0 || i >= (int)s->torrents.size()) { return 1; }
    std::shared_ptr<const lt::torrent_info> ti = s->torrents[i].torrent_file();
    if (!ti) { return 1; }
    lt::add_torrent_params p;
    p.ti = std::make_shared<lt::torrent_info>(*ti);
    lt::entry e = lt::write_torrent_file(p);
    std::vector<char> buf;
    lt::bencode(std::back_inserter(buf), e);
    FILE *f = std::fopen(path, "wb");
    if (!f) { return 1; }
    size_t w = std::fwrite(buf.data(), 1, buf.size(), f);
    std::fclose(f);
    return w == buf.size() ? 0 : 1;
}

extern "C" int pt_create(const char *source, const char *out_path, int version, int is_private, const char *comment, const char *trackers, char *err, int errlen)
{
    try
    {
        std::string src = source;
        while (src.size() > 1 && src.back() == '/') { src.pop_back(); }
        std::string parent = src.substr(0, src.find_last_of('/') == std::string::npos ? 0 : src.find_last_of('/'));
        if (parent.empty()) { parent = "."; }

        lt::create_flags_t flags{};
        if (version == 1) { flags = lt::create_torrent::v1_only; }
        else if (version == 2) { flags = lt::create_torrent::v2_only; }
        std::vector<lt::create_file_entry> entries = lt::list_files(src, flags);
        if (entries.empty()) { set_err(err, errlen, "nothing to add: the folder is empty"); return 1; }
        lt::create_torrent ct(std::move(entries), 0, flags);
        lt::error_code ec;
        lt::set_piece_hashes(ct, parent, ec);
        if (ec) { set_err(err, errlen, ec.message()); return 1; }
        if (comment && *comment) { ct.set_comment(comment); }
        ct.set_priv(is_private != 0);
        ct.set_creator("PicoTorrent");
        std::istringstream in(trackers ? trackers : "");
        std::string line;
        int tier = 0;
        while (std::getline(in, line))
        {
            while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) { line.pop_back(); }
            if (!line.empty()) { ct.add_tracker(line, tier++); }
        }
        lt::entry e = ct.generate();
        std::vector<char> buf;
        lt::bencode(std::back_inserter(buf), e);
        FILE *f = std::fopen(out_path, "wb");
        if (!f) { set_err(err, errlen, std::string("cannot write ") + out_path); return 1; }
        size_t w = std::fwrite(buf.data(), 1, buf.size(), f);
        std::fclose(f);
        return w == buf.size() ? 0 : 1;
    }
    catch (std::exception const &e) { set_err(err, errlen, e.what()); return 1; }
}

extern "C" void pt_apply_settings(pt_session *s, const pt_settings *st)
{
    lt::settings_pack sp;
    std::string port = std::to_string(st->listen_port > 0 ? st->listen_port : 6881);
    sp.set_str(lt::settings_pack::listen_interfaces, "0.0.0.0:" + port + ",[::]:" + port);
    sp.set_int(lt::settings_pack::download_rate_limit, st->down_limit);
    sp.set_int(lt::settings_pack::upload_rate_limit, st->up_limit);
    sp.set_bool(lt::settings_pack::enable_dht, st->dht != 0);
    sp.set_bool(lt::settings_pack::enable_lsd, st->lsd != 0);
    sp.set_bool(lt::settings_pack::enable_upnp, st->nat != 0);
    sp.set_bool(lt::settings_pack::enable_natpmp, st->nat != 0);
    sp.set_int(lt::settings_pack::active_downloads, st->active_downloads > 0 ? st->active_downloads : -1);
    sp.set_int(lt::settings_pack::active_seeds, st->active_seeds > 0 ? st->active_seeds : -1);
    sp.set_int(lt::settings_pack::active_limit, -1);
    int type = lt::settings_pack::none;
    if (st->proxy_type == 1) { type = lt::settings_pack::socks5; }
    else if (st->proxy_type == 2) { type = lt::settings_pack::http; }
    sp.set_int(lt::settings_pack::proxy_type, type);
    sp.set_str(lt::settings_pack::proxy_hostname, st->proxy_host);
    sp.set_int(lt::settings_pack::proxy_port, st->proxy_port);
    sp.set_bool(lt::settings_pack::proxy_peer_connections, st->proxy_type != 0);
    sp.set_bool(lt::settings_pack::proxy_hostnames, st->proxy_type != 0);
    s->ses.apply_settings(sp);
}

extern "C" void pt_set_file_priority(pt_session *s, int i, int file, int prio)
{
    if (i < 0 || i >= (int)s->torrents.size() || file < 0) { return; }
    s->torrents[i].file_priority(lt::file_index_t(file), lt::download_priority_t(static_cast<std::uint8_t>(prio)));
}

extern "C" void pt_set_resume_dir(pt_session *s, const char *dir) { s->resume_dir = dir; }

extern "C" void pt_request_resume(pt_session *s)
{
    for (lt::torrent_handle &h : s->torrents)
    {
        if (!h.is_valid()) { continue; }
        h.save_resume_data();
        ++s->pending;
    }
}

extern "C" int pt_flush_resume(pt_session *s, int timeout_ms)
{
    auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
    while (s->pending > 0 && std::chrono::steady_clock::now() < end)
    {
        s->pump();
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    return s->pending;
}

extern "C" int pt_dht_nodes(pt_session *s)
{
    s->ses.post_session_stats();
    s->pump();
    return s->dht_nodes;
}
