#include "session.hpp"

#include <filesystem>
#include <queue>

#include <boost/log/trivial.hpp>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/entry.hpp>
#include <libtorrent/extensions/smart_ban.hpp>
#include <libtorrent/extensions/ut_metadata.hpp>
#include <libtorrent/extensions/ut_pex.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/session_stats.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/write_resume_data.hpp>
#include <wx/sstream.h>
#include <wx/wfstream.h>
#include <wx/zipstrm.h>

#include <regex>
#include <sstream>
#include <thread>

#include "magnet.hpp"
#include "../core/configuration.hpp"
#include "../core/database.hpp"
#include "../core/environment.hpp"
#include "../core/utils.hpp"
#include "../buildinfo.hpp"
#include "addparams.hpp"
#include "semver.hpp"
#include "sessionstatistics.hpp"
#include "torrenthandle.hpp"
#include "torrentstatistics.hpp"

namespace fs = std::filesystem;
namespace lt = libtorrent;
using pt::BitTorrent::Session;

wxDEFINE_EVENT(ptEVT_SESSION_DEBUG_MESSAGE, wxCommandEvent);
wxDEFINE_EVENT(ptEVT_SESSION_STATISTICS, pt::BitTorrent::SessionStatisticsEvent);
wxDEFINE_EVENT(ptEVT_TORRENT_ADDED, wxCommandEvent);
wxDEFINE_EVENT(ptEVT_TORRENT_FINISHED, wxCommandEvent);
wxDEFINE_EVENT(ptEVT_TORRENT_METADATA_FOUND, pt::BitTorrent::MetadataFoundEvent);
wxDEFINE_EVENT(ptEVT_TORRENT_REMOVED, pt::BitTorrent::InfoHashEvent);
wxDEFINE_EVENT(ptEVT_TORRENT_STATISTICS, pt::BitTorrent::TorrentStatisticsEvent);
wxDEFINE_EVENT(ptEVT_TORRENTS_UPDATED, pt::BitTorrent::TorrentsUpdatedEvent);
wxDEFINE_EVENT(ptEVT_IPFILTER_UPDATED, wxThreadEvent);

static std::string str(lt::info_hash_t ih)
{
    std::stringstream ss;

    if (ih.has_v2())
    {
        ss << ih.v2;
    }
    else
    {
        ss << ih.v1;
    }

    return ss.str();
}

static lt::session_params getSessionParams(std::shared_ptr<pt::Core::Database> db)
{
    lt::session_params sp;

    auto stmt = db->CreateStatement("SELECT state_data FROM session_state ORDER BY timestamp DESC LIMIT 1");

    if (stmt->Read())
    {
        std::vector<char> stateData;
        stmt->GetBlob(0, stateData);

        lt::error_code ec;
        lt::bdecode_node node = lt::bdecode(stateData, ec);

        if (ec)
        {
            BOOST_LOG_TRIVIAL(warning) << "Failed to decode session state: " << ec;
        }
        else
        {
            sp = lt::read_session_params(node, lt::session::save_dht_state);
        }
    }

    return sp;
}

// A missing config key keeps libtorrent's own default instead of throwing.
static void SetInt(lt::settings_pack& sp, std::shared_ptr<pt::Core::Configuration> const& cfg, int name, char const* key)
{
    if (auto v = cfg->Get<int>(key)) { sp.set_int(name, v.value()); }
}

static void SetBool(lt::settings_pack& sp, std::shared_ptr<pt::Core::Configuration> const& cfg, int name, char const* key)
{
    if (auto v = cfg->Get<bool>(key)) { sp.set_bool(name, v.value()); }
}

static lt::settings_pack getSettingsPack(std::shared_ptr<pt::Core::Configuration> cfg)
{
    lt::settings_pack settings;
    settings.set_int(lt::settings_pack::alert_mask, lt::alert::all_categories);

    std::stringstream dhtNodes;
    std::stringstream ifaces;
    std::stringstream outfaces;

    for (auto const& node : cfg->GetDhtBootstrapNodes())
    {
        dhtNodes << "," << node.hostname << ":" << node.port;
    }

    for (auto const& li : cfg->GetListenInterfaces())
    {
        ifaces << "," << li.address << ":" << li.port;
        if (li.address == "0.0.0.0" || li.address == "[::]") continue;
        outfaces << "," << li.address;
    }

    if (dhtNodes.str().size() > 0)
    {
        settings.set_str(lt::settings_pack::dht_bootstrap_nodes, dhtNodes.str().substr(1));
    }

    if (ifaces.str().size() > 0)
    {
        settings.set_str(lt::settings_pack::listen_interfaces, ifaces.str().substr(1));
    }

    if (outfaces.str().size() > 0)
    {
        settings.set_str(lt::settings_pack::outgoing_interfaces, outfaces.str().substr(1));
    }

    // Features
    SetBool(settings, cfg, lt::settings_pack::enable_dht, "libtorrent.enable_dht");
    SetBool(settings, cfg, lt::settings_pack::enable_lsd, "libtorrent.enable_lsd");

    // Limits
    SetInt(settings, cfg, lt::settings_pack::active_checking, "libtorrent.active_checking");
    SetInt(settings, cfg, lt::settings_pack::active_dht_limit, "libtorrent.active_dht_limit");
    SetInt(settings, cfg, lt::settings_pack::active_downloads, "libtorrent.active_downloads");
    SetInt(settings, cfg, lt::settings_pack::active_limit, "libtorrent.active_limit");
    SetInt(settings, cfg, lt::settings_pack::active_lsd_limit, "libtorrent.active_lsd_limit");
    SetInt(settings, cfg, lt::settings_pack::active_seeds, "libtorrent.active_seeds");
    SetInt(settings, cfg, lt::settings_pack::active_tracker_limit, "libtorrent.active_tracker_limit");
    SetInt(settings, cfg, lt::settings_pack::allowed_fast_set_size, "libtorrent.allowed_fast_set_size");
    SetInt(settings, cfg, lt::settings_pack::auto_manage_interval, "libtorrent.auto_manage_interval");
    SetInt(settings, cfg, lt::settings_pack::connections_limit, "libtorrent.connections_limit");
    SetInt(settings, cfg, lt::settings_pack::connection_speed, "libtorrent.connection_speed");
    SetInt(settings, cfg, lt::settings_pack::inactive_down_rate, "libtorrent.inactive_down_rate");
    SetInt(settings, cfg, lt::settings_pack::inactive_up_rate, "libtorrent.inactive_up_rate");
    SetInt(settings, cfg, lt::settings_pack::seed_time_ratio_limit, "libtorrent.seed_time_ratio_limit");
    SetInt(settings, cfg, lt::settings_pack::share_ratio_limit, "libtorrent.share_ratio_limit");

    // Misc
    SetBool(settings, cfg, lt::settings_pack::allow_multiple_connections_per_ip, "libtorrent.allow_multiple_connections_per_ip");
    SetBool(settings, cfg, lt::settings_pack::auto_manage_prefer_seeds, "libtorrent.auto_manage_prefer_seeds");
    SetInt(settings, cfg, lt::settings_pack::auto_scrape_interval, "libtorrent.auto_scrape_interval");
    SetInt(settings, cfg, lt::settings_pack::auto_scrape_min_interval, "libtorrent.auto_scrape_min_interval");
    SetInt(settings, cfg, lt::settings_pack::checking_mem_usage, "libtorrent.checking_mem_usage");
    SetInt(settings, cfg, lt::settings_pack::choking_algorithm, "libtorrent.choking_algorithm");
    SetInt(settings, cfg, lt::settings_pack::seed_choking_algorithm, "libtorrent.seed_choking_algorithm");
    SetInt(settings, cfg, lt::settings_pack::disk_write_mode, "libtorrent.disk_write_mode");
    SetInt(settings, cfg, lt::settings_pack::disk_io_read_mode, "libtorrent.disk_io_read_mode");
    SetInt(settings, cfg, lt::settings_pack::disk_io_write_mode, "libtorrent.disk_io_write_mode");
    SetInt(settings, cfg, lt::settings_pack::aio_threads, "libtorrent.aio_threads");
    SetBool(settings, cfg, lt::settings_pack::dont_count_slow_torrents, "libtorrent.dont_count_slow_torrents");
    SetInt(settings, cfg, lt::settings_pack::file_pool_size, "libtorrent.file_pool_size");
    SetInt(settings, cfg, lt::settings_pack::hashing_threads, "libtorrent.hashing_threads");
    SetInt(settings, cfg, lt::settings_pack::inactivity_timeout, "libtorrent.inactivity_timeout");
    SetBool(settings, cfg, lt::settings_pack::incoming_starts_queued_torrents, "libtorrent.incoming_starts_queued_torrents");
    SetInt(settings, cfg, lt::settings_pack::initial_picker_threshold, "libtorrent.initial_picker_threshold");
    SetInt(settings, cfg, lt::settings_pack::listen_queue_size, "libtorrent.listen_queue_size");
    SetInt(settings, cfg, lt::settings_pack::max_allowed_in_request_queue, "libtorrent.max_allowed_in_request_queue");
    SetInt(settings, cfg, lt::settings_pack::max_failcount, "libtorrent.max_failcount");
    SetInt(settings, cfg, lt::settings_pack::max_out_request_queue, "libtorrent.max_out_request_queue");
    SetInt(settings, cfg, lt::settings_pack::max_peer_recv_buffer_size, "libtorrent.max_peer_recv_buffer_size");
    SetInt(settings, cfg, lt::settings_pack::max_queued_disk_bytes, "libtorrent.max_queued_disk_bytes");
    SetInt(settings, cfg, lt::settings_pack::max_rejects, "libtorrent.max_rejects");
    SetInt(settings, cfg, lt::settings_pack::min_reconnect_time, "libtorrent.min_reconnect_time");
    SetInt(settings, cfg, lt::settings_pack::mixed_mode_algorithm, "libtorrent.mixed_mode_algorithm");
    SetInt(settings, cfg, lt::settings_pack::mmap_file_size_cutoff, "libtorrent.mmap_file_size_cutoff");
    SetBool(settings, cfg, lt::settings_pack::no_atime_storage, "libtorrent.no_atime_storage");
    SetInt(settings, cfg, lt::settings_pack::peer_timeout, "libtorrent.peer_timeout");
    SetInt(settings, cfg, lt::settings_pack::peer_turnover, "libtorrent.peer_turnover");
    SetInt(settings, cfg, lt::settings_pack::peer_turnover_cutoff, "libtorrent.peer_turnover_cutoff");
    SetInt(settings, cfg, lt::settings_pack::peer_turnover_interval, "libtorrent.peer_turnover_interval");
    SetInt(settings, cfg, lt::settings_pack::predictive_piece_announce, "libtorrent.predictive_piece_announce");
    SetInt(settings, cfg, lt::settings_pack::rate_choker_initial_threshold, "libtorrent.rate_choker_initial_threshold");
    SetInt(settings, cfg, lt::settings_pack::request_timeout, "libtorrent.request_timeout");
    SetInt(settings, cfg, lt::settings_pack::send_buffer_low_watermark, "libtorrent.send_buffer_low_watermark");
    SetInt(settings, cfg, lt::settings_pack::send_buffer_watermark, "libtorrent.send_buffer_watermark");
    SetInt(settings, cfg, lt::settings_pack::send_buffer_watermark_factor, "libtorrent.send_buffer_watermark_factor");
    SetInt(settings, cfg, lt::settings_pack::send_not_sent_low_watermark, "libtorrent.send_not_sent_low_watermark");
    SetBool(settings, cfg, lt::settings_pack::strict_end_game_mode, "libtorrent.strict_end_game_mode");
    SetInt(settings, cfg, lt::settings_pack::suggest_mode, "libtorrent.suggest_mode");
    SetInt(settings, cfg, lt::settings_pack::torrent_connect_boost, "libtorrent.torrent_connect_boost");
    SetInt(settings, cfg, lt::settings_pack::unchoke_slots_limit, "libtorrent.unchoke_slots_limit");
    SetBool(settings, cfg, lt::settings_pack::use_parole_mode, "libtorrent.use_parole_mode");
    SetInt(settings, cfg, lt::settings_pack::whole_pieces_threshold, "libtorrent.whole_pieces_threshold");

    // Tracker things
    SetBool(settings, cfg, lt::settings_pack::announce_to_all_tiers, "libtorrent.announce_to_all_tiers");
    SetBool(settings, cfg, lt::settings_pack::announce_to_all_trackers, "libtorrent.announce_to_all_trackers");

    // Encryption
    lt::settings_pack::enc_policy in_policy = cfg->Get<bool>("libtorrent.require_incoming_encryption").value_or(false)
        ? lt::settings_pack::enc_policy::pe_forced
        : lt::settings_pack::enc_policy::pe_enabled;

    lt::settings_pack::enc_policy out_policy = cfg->Get<bool>("libtorrent.require_outgoing_encryption").value_or(false)
        ? lt::settings_pack::enc_policy::pe_forced
        : lt::settings_pack::enc_policy::pe_enabled;

    settings.set_int(lt::settings_pack::int_types::in_enc_policy, in_policy);
    settings.set_int(lt::settings_pack::int_types::out_enc_policy, out_policy);

    // Various
    SetBool(settings, cfg, lt::settings_pack::anonymous_mode, "libtorrent.anonymous_mode");
    SetInt(settings, cfg, lt::settings_pack::stop_tracker_timeout, "libtorrent.stop_tracker_timeout");

    settings.set_int(lt::settings_pack::download_rate_limit,
        cfg->Get<bool>("libtorrent.enable_download_rate_limit").value_or(false)
        ? cfg->Get<int>("libtorrent.download_rate_limit").value_or(0) * 1024
        : 0);

    settings.set_int(lt::settings_pack::upload_rate_limit,
        cfg->Get<bool>("libtorrent.enable_upload_rate_limit").value_or(false)
        ? cfg->Get<int>("libtorrent.upload_rate_limit").value_or(0) * 1024
        : 0);

    // Calculate user agent
    std::stringstream user_agent;
    user_agent << "PicoTorrent/" << pt::BuildInfo::version();

    // Calculate peer id
    semver::version v(pt::BuildInfo::version());
    std::stringstream peer_id;
    peer_id << "-PI" << v.getMajor() << std::setfill('0') << std::setw(2) << v.getMinor() << v.getPatch() << "-";

    settings.set_str(lt::settings_pack::user_agent, user_agent.str());
    settings.set_str(lt::settings_pack::peer_fingerprint, peer_id.str());

    // Proxy settings
    auto proxyType = static_cast<pt::Core::Configuration::ConnectionProxyType>(cfg->Get<int>("libtorrent.proxy_type").value_or(0));

    if (proxyType != pt::Core::Configuration::ConnectionProxyType::None)
    {
        settings.set_int(lt::settings_pack::proxy_type, static_cast<lt::settings_pack::proxy_type_t>(proxyType));
        settings.set_str(lt::settings_pack::proxy_hostname, cfg->Get<std::string>("libtorrent.proxy_host").value_or(""));
        SetInt(settings, cfg, lt::settings_pack::proxy_port, "libtorrent.proxy_port");
        settings.set_str(lt::settings_pack::proxy_username, cfg->Get<std::string>("libtorrent.proxy_username").value_or(""));
        settings.set_str(lt::settings_pack::proxy_password, cfg->Get<std::string>("libtorrent.proxy_password").value_or(""));
        SetBool(settings, cfg, lt::settings_pack::proxy_hostnames, "libtorrent.proxy_hostnames");
        SetBool(settings, cfg, lt::settings_pack::proxy_peer_connections, "libtorrent.proxy_peers");
        SetBool(settings, cfg, lt::settings_pack::proxy_tracker_connections, "libtorrent.proxy_trackers");
    }

    return settings;
}

bool ParseIPv4Address(std::string const& input, lt::address& output)
{
    // make 001.002.123.020 -> 1.2.123.20

    try
    {
        boost::asio::ip::address_v4::bytes_type bytes;

        size_t off = 0;
        size_t pos = input.find_first_of('.');

        for (size_t i = 0; i < bytes.size(); i++)
        {
            bytes[i] = (unsigned char)std::stoi(input.substr(off, pos - off));

            if (pos == std::string::npos)
            {
                break;
            }

            off = pos + 1;
            pos = input.find_first_of('.', off);
        }

        output = lt::address_v4(bytes);

        return true;
    }
    catch (std::exception const& ex)
    {
        BOOST_LOG_TRIVIAL(error) << "Failed to parse IPv4 address from string " << input << ": " << ex.what();
    }

    return false;
}

Session::Session(wxEvtHandler* parent, std::shared_ptr<pt::Core::Database> db, std::shared_ptr<pt::Core::Configuration> cfg, std::shared_ptr<pt::Core::Environment> env)
    : m_parent(parent),
    m_timer(new wxTimer(this, ptID_TIMER_SESSION)),
    m_resumeDataTimer(new wxTimer(this, ptID_TIMER_RESUME_DATA)),
    m_cfg(cfg),
    m_db(db),
    m_env(env)
{
    lt::ip_filter ipf;

    if (cfg->Get<bool>("ipfilter.enabled").value())
    {
        auto filePath = cfg->Get<std::string>("ipfilter.file_path");

        if (filePath.value().size() > 0)
        {
            BOOST_LOG_TRIVIAL(info) << "Blocking all connections and dispatching thread to build IP filter";

            ipf.add_rule(
                boost::asio::ip::make_address_v4("0.0.0.0"),
                boost::asio::ip::make_address_v4("255.255.255.255"),
                lt::ip_filter::blocked);

            m_filterLoader = std::thread(
                std::bind(
                    &Session::LoadIPFilter,
                    this,
                    filePath.value()));
        }
    }

    lt::session_params sp = getSessionParams(db);
    sp.settings = getSettingsPack(cfg);
    sp.ip_filter = ipf;

    m_session = std::make_unique<lt::session>(sp);
    m_session->add_extension(&lt::create_ut_metadata_plugin);
    m_session->add_extension(&lt::create_smart_ban_plugin);

    if (cfg->Get<bool>("libtorrent.enable_pex").value())
    {
        m_session->add_extension(lt::create_ut_pex_plugin);
    }

    m_session->set_alert_notify(
        [this]
        {
            this->CallAfter(std::bind(&Session::OnAlert, this));
        });

    this->LoadTorrents();

    m_timer->Start(1000, wxTIMER_CONTINUOUS);

    if (auto saveInterval = m_cfg->Get<int>("save_resume_data_interval"))
    {
        m_resumeDataTimer->Start(
            saveInterval.value_or(300) * 1000);
    }

    this->Bind(wxEVT_TIMER,
        [this](wxTimerEvent&)
        {
            m_session->post_dht_stats();
            m_session->post_session_stats();
            m_session->post_torrent_updates();
        },
        ptID_TIMER_SESSION);

    this->Bind(ptEVT_IPFILTER_UPDATED,
        [this](wxThreadEvent& evt)
        {
            lt::ip_filter ipf = evt.GetPayload<lt::ip_filter>();
            m_session->set_ip_filter(ipf);
            BOOST_LOG_TRIVIAL(info) << "IP filter applied";
        });

    this->Bind(wxEVT_TIMER, &Session::OnSaveResumeDataTimer, this, ptID_TIMER_RESUME_DATA);
}

Session::~Session()
{
    if (m_filterLoader.joinable()) m_filterLoader.join();

    m_session->set_alert_notify([] {});
    m_timer->Stop();
    m_resumeDataTimer->Stop();

    this->SaveState();
    this->SaveTorrents();
}

void Session::AddMetadataSearch(std::vector<libtorrent::info_hash_t> const& hashes)
{
    // To do a metadata search (ie. find a torrent file based on its info hash)
    // we add the torrent with just the info_hash and save_path set, and then
    // track it in our alert loop.

    fs::path tmp = fs::temp_directory_path();

    for (lt::info_hash_t const& hash : hashes)
    {
        if (m_torrents.find(hash) != m_torrents.end())
        {
            BOOST_LOG_TRIVIAL(warning) << "Cannot search for torrent - already in session";
            continue;
        }

        if (IsSearching(hash))
        {
            BOOST_LOG_TRIVIAL(warning) << "Already searching for info hash '" << str(hash) << "'";
            continue;
        }

        lt::add_torrent_params params;
        params.flags &= ~lt::torrent_flags::auto_managed;
        params.flags &= ~lt::torrent_flags::need_save_resume;
        params.flags &= ~lt::torrent_flags::paused;
        params.flags &= ~lt::torrent_flags::update_subscribe;
        params.flags |= lt::torrent_flags::upload_mode;

        params.info_hashes = hash;
        params.save_path = tmp.string();

        // Track this info hash internally to make sure
        // we do not emit any events for it.
        m_metadataSearches.insert({ hash, lt::torrent_handle() });

        m_session->async_add_torrent(params);
    }
}

void Session::AddTorrent(lt::add_torrent_params const& params)
{
    // If we are searching for metadata for this torrent, stop
    // that search and add this one instead.

    lt::info_hash_t res;
    if (IsSearching(params.info_hashes, res)
        && m_metadataRemoving.count(res) == 0)
    {
        m_session->remove_torrent(
            m_metadataSearches.at(res),
            lt::session::delete_files);
        m_metadataRemoving.insert(res);
    }

    m_session->async_add_torrent(params);
}

bool Session::HasTorrent(lt::info_hash_t const& hash)
{
    if (m_torrents.find(hash) != m_torrents.end())
    {
        return true;
    }

    if (IsSearching(hash))
    {
        return true;
    }

    return false;
}

void Session::RemoveMetadataSearch(std::vector<lt::info_hash_t> const& hashes)
{
    for (auto const& hash : hashes)
    {
        lt::info_hash_t res;
        if (IsSearching(hash, res)
            && m_metadataRemoving.count(res) == 0)
        {
            m_session->remove_torrent(
                m_metadataSearches.at(res),
                lt::session::delete_files);
            m_metadataRemoving.insert(res);
        }
    }
}

void Session::RemoveTorrent(pt::BitTorrent::TorrentHandle* torrent, lt::remove_flags_t flags)
{
    m_session->remove_torrent(torrent->WrappedHandle(), flags);
}

void Session::ReloadSettings()
{
    lt::settings_pack settings = getSettingsPack(m_cfg);
    m_session->apply_settings(settings);

    // loop through and remove torrents which labels
    // are not existent any more
    auto labels = m_cfg->GetLabels();

    std::vector<TorrentHandle*> updated;

    for (auto const& [infoHash, torrent] : m_torrents)
    {
        if (torrent->Label() < 0) { continue; }

        auto it = std::find_if(
            labels.begin(),
            labels.end(),
            [&](auto const& lbl) { return lbl.id == torrent->Label(); });

        if (it == labels.end())
        {
            torrent->ClearLabel();
            updated.push_back(torrent);
        }
    }

    if (updated.size() > 0)
    {
        TorrentsUpdatedEvent evtUpdated(ptEVT_TORRENTS_UPDATED);
        evtUpdated.SetData(updated);
        wxPostEvent(m_parent, evtUpdated);
    }

    if (auto saveInterval = m_cfg->Get<int>("save_resume_data_interval"))
    {
        m_resumeDataTimer->Stop();
        m_resumeDataTimer->Start(
            saveInterval.value_or(300) * 1000);
    }

    // reload ipfilters
}

void Session::OnAlert()
{
    std::vector<lt::alert*> alerts;
    m_session->pop_alerts(&alerts);

    for (lt::alert* alert : alerts)
    {
        switch (alert->type())
        {
        case lt::add_torrent_alert::alert_type:
        {
            lt::add_torrent_alert* ata = lt::alert_cast<lt::add_torrent_alert>(alert);

            if (ata->error)
            {
                BOOST_LOG_TRIVIAL(error) << "Failed to add torrent to session: " << ata->error;
                continue;
            }

            if (IsSearching(ata->handle.info_hashes()))
            {
                // Part of a metadata search - update the metadata search map
                // with the new handle, then ignore it.
                UpdateMetadataHandle(ata->handle.info_hashes(), ata->handle);
                continue;
            }

            // At this point, decide whether this is a new torrent or an existing one. Check the torrent table.
            std::string infoHash = str(ata->handle.info_hashes());

            TorrentHandle* handle = new TorrentHandle(this, ata->handle);
            handle->SetComment(ata->params.comment);

            AddParams* add = ata->params.userdata.get<AddParams>();
            if (add && add->labelId > 0) { handle->SetLabel(add->labelId, add->labelName, true); }

            m_torrents.insert({ ata->handle.info_hashes(), handle });

            auto stmt = m_db->CreateStatement("SELECT COUNT(*) FROM torrent WHERE info_hash = $1");
            stmt->Bind(1, infoHash);

            if (stmt->Read() && stmt->GetInt(0) == 0)
            {
                // torrent was not in session before, so insert it
                lt::torrent_status ts = ata->handle.status();

                stmt = m_db->CreateStatement("INSERT INTO torrent (info_hash, queue_position, label_id) VALUES ($1, $2, $3)");
                stmt->Bind(1, infoHash);
                stmt->Bind(2, static_cast<int>(ts.queue_position));
                stmt->Bind(3, (add && add->labelId > 0) ? std::optional(add->labelId) : std::nullopt);
                stmt->Execute();

                // at this point, trigger a save_resume_data for it
                ata->handle.save_resume_data(
                    lt::torrent_handle::flush_disk_cache
                    | lt::torrent_handle::save_info_dict);
            }

            // Announce it to the world
            wxCommandEvent torrentAdded(ptEVT_TORRENT_ADDED);
            torrentAdded.SetClientData(handle);
            wxPostEvent(m_parent, torrentAdded);

            break;
        }

        case lt::file_error_alert::alert_type:
        {
            lt::file_error_alert* fea = lt::alert_cast<lt::file_error_alert>(alert);

            auto torrent = m_torrents.at(fea->handle.info_hashes());

            TorrentsUpdatedEvent evtUpdated(ptEVT_TORRENTS_UPDATED);
            evtUpdated.SetData({ torrent });
            wxPostEvent(m_parent, evtUpdated);

            break;
        }

        case lt::listen_failed_alert::alert_type:
        {
            BOOST_LOG_TRIVIAL(warning) << alert->message();
            break;
        }

        case lt::listen_succeeded_alert::alert_type:
        {
            BOOST_LOG_TRIVIAL(info) << alert->message();
            break;
        }

        case lt::metadata_received_alert::alert_type:
        {
            lt::metadata_received_alert* mra = lt::alert_cast<lt::metadata_received_alert>(alert);
            lt::info_hash_t infoHash = mra->handle.info_hashes();

            lt::info_hash_t res;
            if (IsSearching(infoHash, res)
                && m_metadataRemoving.count(res) == 0)
            {
                // Create a non-const copy of the torrent_info

                auto tiConst = mra->handle.torrent_file();
                auto ti = std::make_shared<lt::torrent_info>(*tiConst.get());

                MetadataFoundEvent evt(ptEVT_TORRENT_METADATA_FOUND);
                evt.SetData(ti);
                wxPostEvent(this, evt);
                wxPostEvent(m_parent, evt);

                m_session->remove_torrent(mra->handle, lt::session::delete_files);
                m_metadataRemoving.insert(res);
            }
            else
            {
                if (mra->handle.need_save_resume_data())
                {
                    mra->handle.save_resume_data(
                        lt::torrent_handle::flush_disk_cache
                        | lt::torrent_handle::save_info_dict);
                }
            }

            break;
        }

        case lt::save_resume_data_alert::alert_type:
        {
            lt::save_resume_data_alert* srda = lt::alert_cast<lt::save_resume_data_alert>(alert);
            std::vector<char> buffer = lt::write_resume_data_buf(srda->params);

            {
                // Store the data
                auto stmt = m_db->CreateStatement("REPLACE INTO torrent_resume_data (info_hash, resume_data) VALUES (?, ?);");
                stmt->Bind(1, str(srda->handle.info_hashes()));
                stmt->Bind(2, buffer);
                stmt->Execute();
            }

            {
                // at this stage we can remove the magnet link
                auto stmt = m_db->CreateStatement("DELETE FROM torrent_magnet_uri  WHERE info_hash = ?;");
                stmt->Bind(1, str(srda->handle.info_hashes()));
                stmt->Execute();
            }

            break;
        }

        case lt::session_stats_alert::alert_type:
        {
            lt::session_stats_alert* ssa = lt::alert_cast<lt::session_stats_alert>(alert);
            lt::span<const int64_t> counters = ssa->counters();
            int idx = -1;

            SessionStatistics stats;

            if ((idx = lt::find_metric_idx("dht.dht_nodes")) >= 0)
            {
                stats.dhtNodes = counters[idx];
            }

            SessionStatisticsEvent evt(ptEVT_SESSION_STATISTICS);
            evt.SetData(stats);
            wxPostEvent(m_parent, evt);

            break;
        }

        case lt::state_update_alert::alert_type:
        {
            lt::state_update_alert* sua = lt::alert_cast<lt::state_update_alert>(alert);

            std::vector<TorrentHandle*> handles;
            TorrentStatistics stats = { 0 };

            for (lt::torrent_status const& status : sua->status)
            {
                if (IsSearching(status.info_hashes))
                {
                    continue;
                }

                stats.totalPayloadDownloadRate += status.download_payload_rate;
                stats.totalPayloadUploadRate += status.upload_payload_rate;

                if (status.state == lt::torrent_status::state_t::downloading)
                {
                    stats.isDownloadingAny = true;
                    stats.totalWanted += status.total_wanted;
                    stats.totalWantedDone += status.total_wanted_done;
                }

                auto handle = m_torrents.at(status.info_hashes);
                handle->BuildStatus(status);

                handles.push_back(handle);
            }

            TorrentStatisticsEvent evt(ptEVT_TORRENT_STATISTICS);
            evt.SetData(stats);
            wxPostEvent(m_parent, evt);

            TorrentsUpdatedEvent evtUpdated(ptEVT_TORRENTS_UPDATED);
            evtUpdated.SetData(handles);
            wxPostEvent(m_parent, evtUpdated);

            break;
        }

        case lt::storage_moved_failed_alert::alert_type:
        {
            lt::storage_moved_failed_alert* smfa = lt::alert_cast<lt::storage_moved_failed_alert>(alert);
            BOOST_LOG_TRIVIAL(error) << "Error when moving torrent storage: " << smfa->error;
            break;
        }

        case lt::torrent_checked_alert::alert_type:
        {
            lt::torrent_checked_alert* tca = lt::alert_cast<lt::torrent_checked_alert>(alert);

            auto torrentToResume = m_pauseAfterRecheck.find(tca->handle.info_hashes());

            if (torrentToResume != m_pauseAfterRecheck.end())
            {
                torrentToResume->second->Pause();
                m_pauseAfterRecheck.erase(torrentToResume);
            }

            break;
        }

        case lt::torrent_error_alert::alert_type:
        {
            BOOST_LOG_TRIVIAL(error) << "Torrent error: " << alert->message();
            break;
        }

        case lt::torrent_finished_alert::alert_type:
        {
            lt::torrent_finished_alert* tfa = lt::alert_cast<lt::torrent_finished_alert>(alert);
            lt::torrent_status const& ts = tfa->handle.status();

            // Only move from completed path if we have downloaded any payload
            // bytes, otherwise it's most likely a newly added torrent which we
            // had already downloaded.

            if (ts.total_payload_download <= 0)
            {
                break;
            }

            wxCommandEvent evt(ptEVT_TORRENT_FINISHED);
            evt.SetClientData(m_torrents.at(ts.info_hashes));
            wxPostEvent(m_parent, evt);

            if (auto shouldMove = m_cfg->Get<bool>("move_completed_downloads"))
            {
                if (shouldMove.value())
                {
                    auto onlyFromDefault = m_cfg->Get<bool>("move_completed_downloads_from_default_only");
                    auto movePath = m_cfg->Get<std::string>("move_completed_downloads_path");

                    if (onlyFromDefault.has_value()
                        && onlyFromDefault.value()
                        && ts.save_path != m_cfg->Get<std::string>("default_save_path").value())
                    {
                        break;
                    }

                    if (movePath.has_value())
                    {
                        tfa->handle.move_storage(movePath.value());
                    }
                }
            }

            break;
        }

        case lt::torrent_removed_alert::alert_type:
        {
            lt::torrent_removed_alert* tra = lt::alert_cast<lt::torrent_removed_alert>(alert);
            lt::info_hash_t res;

            if (IsSearching(tra->info_hashes, res)
                && m_metadataRemoving.count(res) > 0)
            {
                RemoveMetadataHandle(tra->info_hashes);
                m_metadataRemoving.erase(res);
                break;
            }

            auto handle = m_torrents.at(tra->info_hashes);

            InfoHashEvent evt(ptEVT_TORRENT_REMOVED);
            evt.SetData(tra->info_hashes);
            wxPostEvent(m_parent, evt);

            m_torrents.erase(tra->info_hashes);

            std::vector<std::string> statements =
            {
                "DELETE FROM torrent_resume_data WHERE info_hash = ?;",
                "DELETE FROM torrent_magnet_uri  WHERE info_hash = ?;",
                "DELETE FROM torrent             WHERE info_hash = ?;",
            };

            for (std::string const& sql : statements)
            {
                auto stmt = m_db->CreateStatement(sql);
                stmt->Bind(1, str(tra->info_hashes));
                stmt->Execute();
            }

            // The UI still holds this pointer until it has handled the removed
            // event posted above, so free it only after that (same FIFO queue).
            m_parent->CallAfter([handle]() { delete handle; });

            break;
        }
        }
    }
}

void Session::OnSaveResumeDataTimer(wxTimerEvent&)
{
    // save resume data for all torrents which need it
    int saved = 0;

    for (auto const& [hash, torrent] : m_torrents)
    {
        lt::torrent_handle& th = torrent->WrappedHandle();
        if (th.need_save_resume_data())
        {
            saved++;

            th.save_resume_data(
                lt::torrent_handle::flush_disk_cache
                | lt::torrent_handle::save_info_dict);
        }
    }

    BOOST_LOG_TRIVIAL(info) << saved << " torrent(s) needed to save resume data";
}

bool Session::IsSearching(lt::info_hash_t hash)
{
    lt::info_hash_t t;
    return IsSearching(hash, t);
}

bool Session::IsSearching(lt::info_hash_t hash, lt::info_hash_t& result)
{
    // Check if this torrent is part of a metadata search.
    // Compare either v1 or v2 hash since hybrid torrents
    // can be added with a v1 info hash and then get a v1+v2 hash
    // and vice versa

    lt::info_hash_t v1(hash.v1);
    lt::info_hash_t v2(hash.v2);

    if (m_metadataSearches.count(hash) > 0)
    {
        result = hash;
        return true;
    }

    if (!v1.v1.is_all_zeros() && m_metadataSearches.count(v1) > 0)
    {
        result = v1;
        return true;
    }

    if (!v2.v2.is_all_zeros() && m_metadataSearches.count(v2) > 0)
    {
        result = v2;
        return true;
    }

    return false;
}

void Session::LoadIPFilter(std::string const& path)
{
    // This function might be running in another thread. Be careful
    // not to use any instances etc. Only communicate with the class
    // through wxPostEvent

    BOOST_LOG_TRIVIAL(info) << "Loading IP filter from " << path.c_str();

    wxFileInputStream fileStream(path);
    wxZipInputStream zipStream(fileStream);
    wxZipEntry* entry;

    lt::ip_filter ipf;

    auto begin = std::chrono::high_resolution_clock::now();
    int rules = 0;

    while (entry = zipStream.GetNextEntry(), entry != nullptr)
    {
        wxStringOutputStream out;
        zipStream.Read(out);

        std::string c = out.GetString().ToStdString();

        std::stringstream ss(c);
        std::string line;

        std::regex filter("([\\d|\\.]+)\\s*-\\s*([\\d|\\.]+)\\s*,\\s*([\\d]+).*",
            std::regex_constants::ECMAScript | std::regex_constants::icase);

        while (std::getline(ss, line))
        {
            if (line[line.size() - 1] == '\r') line = line.substr(0, line.size() - 1);

            std::smatch m;

            lt::address start;
            lt::address end;

            if (std::regex_match(line, m, filter)
                && ParseIPv4Address(m[1], start)
                && ParseIPv4Address(m[2], end))
            {
                ipf.add_rule(
                    start,
                    end,
                    stoi(m[3]) <= 127 ? lt::ip_filter::blocked : 0);

                rules++;
            }
        }
    }

    auto end = std::chrono::high_resolution_clock::now();
    auto duration = std::chrono::duration_cast<std::chrono::duration<double>>(end - begin).count();

    BOOST_LOG_TRIVIAL(info) << "Loaded " << rules << " IP filter rule(s) in " << duration << " seconds";

    auto evt = new wxThreadEvent(ptEVT_IPFILTER_UPDATED);
    evt->SetPayload(ipf);
    wxQueueEvent(this, evt);
}

void Session::LoadTorrents()
{
    auto stmt = m_db->CreateStatement("SELECT t.info_hash, tmu.magnet_uri, trd.resume_data, tmu.save_path, IFNULL(t.label_id, -1), lbl.name AS label_name FROM torrent t\n"
        "LEFT JOIN torrent_magnet_uri  tmu ON t.info_hash = tmu.info_hash\n"
        "LEFT JOIN torrent_resume_data trd ON t.info_hash = trd.info_hash\n"
        "LEFT JOIN label lbl ON t.label_id = t.label_id\n"
        "ORDER BY t.queue_position ASC");

    while (stmt->Read())
    {
        std::string info_hash = stmt->GetString(0);
        std::string magnet_uri = stmt->GetString(1);
        std::string save_path = stmt->GetString(3);
        int label_id = stmt->GetInt(4);
        std::string label_name = stmt->GetString(5);

        std::vector<char> resume_data;
        stmt->GetBlob(2, resume_data);

        lt::add_torrent_params params;

        // Always parse magnet uri if it is not empty
        if (!magnet_uri.empty() && !save_path.empty())
        {
            params = lt::parse_magnet_uri(magnet_uri);
            params.save_path = save_path;
        }

        if (resume_data.size() > 0)
        {
            lt::error_code ec;
            lt::bdecode_node node = lt::bdecode(resume_data, ec);

            if (ec)
            {
                BOOST_LOG_TRIVIAL(warning) << "Failed to decode resume data: " << ec;
                continue;
            }

            params = lt::read_resume_data(node, ec);

            if (ec)
            {
                BOOST_LOG_TRIVIAL(warning) << "Failed to read resume data: " << ec;
                continue;
            }
        }

        params.userdata = lt::client_data_t(new AddParams());

        if (label_id > 0)
        {
            params.userdata.get<AddParams>()->labelId = label_id;
            params.userdata.get<AddParams>()->labelName = label_name;
        }

        m_session->async_add_torrent(params);
    }
}

void Session::PauseAfterRecheck(pt::BitTorrent::TorrentHandle* th)
{
    if (m_pauseAfterRecheck.find(th->InfoHash()) != m_pauseAfterRecheck.end())
    {
        BOOST_LOG_TRIVIAL(warning) << "Torrent already rechecking (" << th->InfoHash().v1.data() << ")";
        return;
    }

    m_pauseAfterRecheck.insert({ th->InfoHash(), th });
}

void Session::SaveState()
{
    std::vector<char> stateBuffer = lt::write_session_params_buf(
        m_session->session_state(),
        lt::session::save_dht_state);

    auto stmt = m_db->CreateStatement("INSERT INTO session_state (state_data, timestamp) VALUES (?, strftime('%s'))");
    stmt->Bind(1, stateBuffer);
    stmt->Execute();

    // Keep only the five last states
    m_db->Execute("DELETE FROM session_state WHERE id NOT IN (SELECT id FROM session_state ORDER BY timestamp DESC LIMIT 5)");
}

void Session::SaveTorrents()
{
    m_session->pause();

    // Save each torrents resume data
    int numOutstandingResumeData = 0;
    int numPaused = 0;
    int numFailed = 0;

    // Save all torrents not part of a metadata search
    auto temp = m_session->get_torrent_status(
        [this](const lt::torrent_status& st)
        {
            return !IsSearching(st.info_hashes);
        });

    for (lt::torrent_status& st : temp)
    {
        if (!st.handle.is_valid()
            || !st.has_metadata
            || !st.handle.need_save_resume_data())
        {
            continue;
        }

        st.handle.save_resume_data(
            lt::torrent_handle::flush_disk_cache
            | lt::torrent_handle::save_info_dict);

        ++numOutstandingResumeData;
    }

    // Save all torrents without metadata
    auto missingMeta = m_session->get_torrent_status(
        [this](const lt::torrent_status& st)
        {
            return !st.has_metadata;
        });

    BOOST_LOG_TRIVIAL(info) << "Saving data for " << missingMeta.size() + numOutstandingResumeData << " torrent(s)";

    for (lt::torrent_status& st : missingMeta)
    {
        // Store state
        auto stmt = m_db->CreateStatement("UPDATE torrent SET queue_position = $1 WHERE info_hash = $2");
        stmt->Bind(1, static_cast<int>(st.queue_position));
        stmt->Bind(2, str(st.info_hashes));
        stmt->Execute();

        // Store the magnet uri
        stmt = m_db->CreateStatement("REPLACE INTO torrent_magnet_uri (info_hash, magnet_uri, save_path) VALUES (?, ?, ?);");
        stmt->Bind(1, str(st.info_hashes));
        stmt->Bind(2, pt::BitTorrent::MagnetUri(st.handle));
        stmt->Bind(3, st.handle.status(lt::torrent_handle::query_save_path).save_path);
        stmt->Execute();
    }

    while (numOutstandingResumeData > 0)
    {
        if (!m_session->wait_for_alert(lt::seconds(10))) { continue; }

        std::vector<lt::alert*> alerts;
        m_session->pop_alerts(&alerts);

        for (lt::alert* a : alerts)
        {
            lt::torrent_paused_alert* tp = lt::alert_cast<lt::torrent_paused_alert>(a);

            if (tp)
            {
                ++numPaused;
                continue;
            }

            if (lt::alert_cast<lt::save_resume_data_failed_alert>(a))
            {
                ++numFailed;
                --numOutstandingResumeData;
                continue;
            }

            lt::save_resume_data_alert* rd = lt::alert_cast<lt::save_resume_data_alert>(a);
            if (!rd) { continue; }
            --numOutstandingResumeData;

            std::vector<char> buffer = lt::write_resume_data_buf(rd->params);
            std::string infoHash = str(rd->handle.info_hashes());

            // Store state
            auto stmt = m_db->CreateStatement("UPDATE torrent SET queue_position = $1 WHERE info_hash = $2");
            stmt->Bind(1, static_cast<int>(rd->handle.status().queue_position));
            stmt->Bind(2, infoHash);
            stmt->Execute();

            // Store the data
            stmt = m_db->CreateStatement("REPLACE INTO torrent_resume_data (info_hash, resume_data) VALUES (?, ?);");
            stmt->Bind(1, infoHash);
            stmt->Bind(2, buffer);
            stmt->Execute();
        }
    }
}

void Session::RemoveMetadataHandle(lt::info_hash_t hash)
{
    lt::info_hash_t v1(hash.v1);
    lt::info_hash_t v2(hash.v2);

    for (auto& it : m_metadataSearches)
    {
        if (it.first == hash
            || it.first == v1
            || it.first == v2)
        {
            m_metadataSearches.erase(it.first);
            break;
        }
    }
}

void Session::UpdateMetadataHandle(lt::info_hash_t hash, lt::torrent_handle handle)
{
    lt::info_hash_t v1(hash.v1);
    lt::info_hash_t v2(hash.v2);

    for (auto& it : m_metadataSearches)
    {
        if (it.first == hash
            || it.first == v1
            || it.first == v2)
        {
            it.second = handle;
        }
    }
}

void Session::UpdateTorrentLabel(pt::BitTorrent::TorrentHandle* torrent)
{
    int labelId = torrent->Label();

    if (labelId < 0)
    {
        auto stmt = m_db->CreateStatement("UPDATE torrent SET label_id = NULL WHERE info_hash = ?");
        stmt->Bind(1, str(torrent->InfoHash()));
        stmt->Execute();
    }
    else
    {
        auto stmt = m_db->CreateStatement("UPDATE torrent SET label_id = ? WHERE info_hash = ?");
        stmt->Bind(1, labelId);
        stmt->Bind(2, str(torrent->InfoHash()));
        stmt->Execute();
    }
}
