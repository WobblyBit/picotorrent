#!/usr/bin/env bash
# Builds the release tarball: linux/package.sh [VERSION]  ->  build/linux/picotorrent-VERSION-linux-x86_64.tar.gz
# Runs build.sh first; the binary needs glibc >= 2.36 and X11 or Wayland (GLFW loads them at run time).
set -euo pipefail
cd "$(dirname "$0")/.."
ver=${1:-$(sed -n 's/^APP_VERSION :: "\(.*\)".*/\1/p' linux/src/app/native.odin)}
name=picotorrent-$ver-linux-x86_64
bash linux/build.sh build >/dev/null
if [[ $(uname -s) != Linux ]]; then   # on Windows the build ran in the VM: fetch the result
	mkdir -p build/linux && scp -q alpine:pt/build/linux/picotorrent build/linux/picotorrent
fi
stage=build/linux/stage/$name
rm -rf build/linux/stage && mkdir -p "$stage"
cp build/linux/picotorrent "$stage/"
cp linux/dist/{picotorrent.desktop,picotorrent.png,install.sh} LICENSE "$stage/"
strip "$stage/picotorrent" 2>/dev/null || true
tar -C build/linux/stage --owner=0 --group=0 -czf "build/linux/$name.tar.gz" "$name"
ls -l "build/linux/$name.tar.gz"
