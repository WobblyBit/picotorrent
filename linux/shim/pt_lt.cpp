#include "pt_lt.h"

#include <cstdio>
#include <cstring>
#include <sstream>
#include <string>
#include <vector>

#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/load_torrent.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/version.hpp>

namespace lt = libtorrent;

struct pt_session
{
    lt::session ses;
    std::vector<lt::torrent_handle> torrents;

    explicit pt_session(lt::settings_pack sp) : ses(std::move(sp)) {}
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

    if (ts.info_hashes.has_v1()) { std::ostringstream o; o << ts.info_hashes.v1; copy(out->hash_v1, sizeof(out->hash_v1), o.str()); }
    if (ts.info_hashes.has_v2()) { std::ostringstream o; o << ts.info_hashes.v2; copy(out->hash_v2, sizeof(out->hash_v2), o.str()); }

    out->state = static_cast<int32_t>(ts.state);
    out->paused = (ts.flags & lt::torrent_flags::paused) ? 1 : 0;
    out->progress = ts.progress;
    out->total_wanted = ts.total_wanted;
    out->total_done = ts.total_wanted_done;
    out->num_peers = ts.num_peers;
    out->num_seeds = ts.num_seeds;
    return 0;
}
