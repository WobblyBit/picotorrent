// Headless smoke test for the libtorrent 2.1 port: magnet export from a handle
// and .torrent round trip. No network, no UI.
#include <cstdio>
#include <filesystem>
#include <exception>
#include <string>

#include <libtorrent/bencode.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/load_torrent.hpp>
#include <libtorrent/session.hpp>

#include "../src/picotorrent/bittorrent/magnet.hpp"

namespace lt = libtorrent;

static int failures = 0;
#define CHECK(c) do { if (!(c)) { std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); ++failures; } } while (0)

static int run();
int main()
{
    try { return run(); }
    catch (std::exception const& e) { std::printf("EXCEPTION: %s\n", e.what()); return 2; }
}

static int run()
{
    // Build a tiny single-file torrent in memory.
    lt::create_torrent ct({lt::create_file_entry("smoke.bin", 16384)}, 16384, lt::create_torrent::v1_only);
    ct.set_hash(lt::piece_index_t{0}, lt::hasher("smoke").final());
    ct.add_tracker("http://tracker.invalid/announce");

    std::vector<char> buf;
    lt::bencode(std::back_inserter(buf), ct.generate());

    lt::add_torrent_params atp = lt::load_torrent_buffer(buf);
    CHECK(atp.ti && atp.ti->name() == "smoke.bin");

    // Headless session: nothing listens, nothing announces.
    lt::settings_pack sp;
    sp.set_str(lt::settings_pack::listen_interfaces, "");
    sp.set_bool(lt::settings_pack::enable_dht, false);
    sp.set_bool(lt::settings_pack::enable_lsd, false);
    sp.set_bool(lt::settings_pack::enable_upnp, false);
    sp.set_bool(lt::settings_pack::enable_natpmp, false);
    lt::session ses(sp);

    atp.save_path = std::filesystem::temp_directory_path().string();
    atp.flags |= lt::torrent_flags::paused;
    atp.flags &= ~lt::torrent_flags::auto_managed;
    lt::torrent_handle th = ses.add_torrent(atp);
    CHECK(th.is_valid());

    // Magnet from handle must round trip through the parser.
    std::string uri = pt::BitTorrent::MagnetUri(th);
    CHECK(uri.rfind("magnet:?xt=urn:btih:", 0) == 0);

    lt::error_code ec;
    lt::add_torrent_params parsed = lt::parse_magnet_uri(uri, ec);
    CHECK(!ec);
    CHECK(parsed.info_hashes == th.status().info_hashes);
    CHECK(parsed.name == "smoke.bin");
    CHECK(parsed.trackers.size() == 1 && parsed.trackers[0] == "http://tracker.invalid/announce");

    std::printf(failures ? "FAILED (%d)\n" : "OK\n", failures);
    return failures ? 1 : 0;
}
