#!/bin/sh
# Installs PicoTorrent for the current user (no root): ~/.local/bin, the menu entry and the icon.
# Usage: ./install.sh [uninstall]
set -e
here=$(cd "$(dirname "$0")" && pwd)
bin=${XDG_BIN_HOME:-$HOME/.local/bin}
data=${XDG_DATA_HOME:-$HOME/.local/share}
if [ "${1:-}" = uninstall ]; then
	rm -f "$bin/picotorrent" "$data/applications/picotorrent.desktop" "$data/icons/hicolor/256x256/apps/picotorrent.png"
	echo "PicoTorrent removed (settings in ~/.config/picotorrent are kept)."
	exit 0
fi
mkdir -p "$bin" "$data/applications" "$data/icons/hicolor/256x256/apps"
install -m 755 "$here/picotorrent" "$bin/picotorrent"
install -m 644 "$here/picotorrent.png" "$data/icons/hicolor/256x256/apps/picotorrent.png"
sed "s|^Exec=picotorrent|Exec=$bin/picotorrent|" "$here/picotorrent.desktop" > "$data/applications/picotorrent.desktop"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$data/applications" || true
echo "PicoTorrent installed in $bin."
