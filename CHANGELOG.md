# Changelog

This fork starts from upstream PicoTorrent at `24e3e86` (2023-10-17, 86 commits after `v0.25.0`).

## 0.26.1 (2026-11-28)

### Windows

- Fix: the portable zip was missing `coredb.sqlite` (and `crashpad_handler.exe`), so menus showed raw translation keys and the window could fail to appear. The zip now contains both.
- Windows only; the Linux tarball and Flatpak are unchanged from 0.26.0.

## 0.26.0 (2026-11-28)

### Linux port (new, written in Odin on libtorrent 2.1.2)

- Native window (GLFW and NanoVG), no GTK or Qt; light and dark themes.
- Torrent list: sortable, resizable, reorderable and hideable columns, multi-select, slim progress bars, v1 / hybrid / v2 version badges, label column.
- Add torrents from files or magnet links; add dialog with save path and per-file selection.
- Details pane: Overview (v1 and v2 info-hashes), Files (priorities: skip, normal, high), Peers, Trackers.
- Context menu: pause, resume, recheck, force announce, queue order, sequential download, per-torrent speed limits, labels, copy magnet link, export `.torrent`, remove.
- Create torrent: v1, hybrid or v2 (default v2), trackers, comment, private flag; hashing runs on a worker thread.
- Preferences: download folder, listen port, global speed limits, queue limits, DHT, local peer discovery, UPnP and NAT-PMP, SOCKS5 and HTTP proxy, IP filter (eMule `.dat`), connections, unchoke slots, disk threads, anonymous mode, check for updates at start, start at login.
- Labels with a filter view; resume data saved every 2 minutes and at exit, so torrents resume without re-checking.
- Translations: the shared `lang/*.json` files, language picked from the locale, View > Language to change it; Noto fallback fonts for CJK, Georgian, Armenian, Hebrew, Arabic, Devanagari and Sinhala.
- Update check against the latest GitHub release (HTTPS through OpenSSL built into the app).
- Packaging: portable tarball with a per-user `install.sh`, a desktop entry and icon, and a Flatpak (`io.github.WobblyBit.PicoTorrent`, GNOME 50 runtime, zenity bundled for file dialogs).
- Needs glibc 2.36 or newer (Debian 12, Ubuntu 24.04, Fedora 37+, Arch). File pickers need zenity or kdialog.
- Decisions: no tray icon (it would need a D-Bus StatusNotifier client and GNOME shows none); autostart is an XDG autostart entry.

### Windows app (changes since upstream)

- Dependencies updated: libtorrent 2.1 (ABI 4), Boost 1.92, current wxWidgets; vcpkg baseline pinned to the vendored vcpkg commit.
- Torrents are created as v2 by default; new hidden "Torrent version" column with v1, hybrid and v2 badges.
- The details overview shows both the v1 and v2 info-hash; copy info hash gives one hash per line.
- Tracker list reads v2 announce data (v2-only torrents showed nothing).
- Per-torrent speed limits dialog (context menu, multi-select).
- Advanced settings expose disk I/O read and write cache modes and the number of I/O threads.
- Explicit Dark theme option; View > Columns submenu; slim rounded progress bars.
- Update check now reads the GitHub releases API of this fork (default URL changed by migration); the updater was off by default before.
- Robustness: tolerant settings loading, deferred torrent handle deletion, saved column layout kept when columns are added.
- Build and CI: refreshed CI, Cake and WiX tooling, magnet-link unit test, `PICOTORRENT_INSTANCE_ID` for separate test instances.
- Translations for the new strings in 17 languages, Greek strings for the theme choices.

### Known gaps

- Linux: no tray icon; Arabic and Indic text is not shaped; some dynamic strings (status bar, errors) stay English; Flatpak autostart is not supported; the file chooser portal and the IP filter block against a real peer are untested.
- Windows: no country column (the GeoIP code needs a database from the upstream service); this release has no Windows installer.
