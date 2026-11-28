#!/usr/bin/env bash
# Builds the release tarball: linux/package.sh [VERSION]  ->  build/linux/picotorrent-VERSION-linux-x86_64.tar.gz
# Runs build.sh first. From Windows the tarball is made in the Alpine VM (NTFS cannot keep Unix modes) and
# copied back. The binary needs glibc >= 2.36 and X11 or Wayland (GLFW loads them at run time).
set -euo pipefail
cd "$(dirname "$0")/.."
ver=${1:-$(sed -n 's/^APP_VERSION :: "\(.*\)".*/\1/p' linux/src/app/native.odin)}
name=picotorrent-$ver-linux-x86_64
bash linux/build.sh build >/dev/null
if [[ $(uname -s) != Linux ]]; then
	scp -q LICENSE alpine:pt/LICENSE
	ssh alpine "cd ~/pt && bash linux/package.sh $ver"
	mkdir -p build/linux
	scp -q "alpine:pt/build/linux/$name.tar.gz" alpine:pt/build/linux/picotorrent build/linux/
	ls -l "build/linux/$name.tar.gz"
	exit
fi
stage=build/linux/stage/$name
rm -rf build/linux/stage && mkdir -p "$stage"
install -m 755 build/linux/picotorrent "$stage/picotorrent"
install -m 755 linux/dist/install.sh "$stage/install.sh"
install -m 644 linux/dist/picotorrent.desktop linux/dist/picotorrent.png LICENSE "$stage/"
strip "$stage/picotorrent" 2>/dev/null || true
tar -C build/linux/stage --owner=0 --group=0 -czf "build/linux/$name.tar.gz" "$name"
ls -l "build/linux/$name.tar.gz"
