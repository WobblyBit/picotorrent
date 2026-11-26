#!/usr/bin/env bash
# PicoTorrent for Linux (Odin). Usage: linux/build.sh spike [FILE.torrent SAVE_PATH]
# From Windows it syncs the repo to the Alpine VM and runs there; in the VM it builds in a Debian
# bookworm container (glibc 2.36, the same recipe as xz-plus's gui-portable).
set -euo pipefail

LT_VER=2.1.2
LT_SHA512=682109ebee80a3a64ba362809be50a9985de40088d6811a286ae8a3b1062b070805491e636a02cde185366eea2245ae2c0cbb3c95e28b058c6f667e09676bcea
TS_REF=105cce59972f925a33aa6b1c3109e4cd3caf583d
TS_SHA512=4a0090755831e0e4a1930817345fa5934144421d9a9d710fe8ed3712233fa2fa037fc0e0d4f88b7cc8fb1bc05fe2d55372af1ff47d6fbf5208e03f45f2a424e4
IMAGE=pt-linux-build

inside() {
	local odin=/cache/odin out=/work/build/linux
	mkdir -p "$out"
	if [[ ! -f /cache2/lt/lib/libtorrent-rasterbar.a ]]; then
		echo "linux: building libtorrent $LT_VER (static), once"
		cd /cache2 && rm -rf lt-src lt-build lt
		curl -fsSL -o lt.tar.gz "https://github.com/arvidn/libtorrent/archive/v$LT_VER.tar.gz"
		echo "$LT_SHA512  lt.tar.gz" | sha512sum -c - >/dev/null || { echo "libtorrent checksum mismatch" >&2; exit 1; }
		curl -fsSL -o ts.tar.gz "https://github.com/arvidn/try_signal/archive/$TS_REF.tar.gz"
		echo "$TS_SHA512  ts.tar.gz" | sha512sum -c - >/dev/null || { echo "try_signal checksum mismatch" >&2; exit 1; }
		mkdir lt-src && tar xzf lt.tar.gz -C lt-src --strip-components=1
		mkdir -p lt-src/deps/try_signal && tar xzf ts.tar.gz -C lt-src/deps/try_signal --strip-components=1
		cmake -S lt-src -B lt-build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_CXX_STANDARD=17 \
			-DCMAKE_POSITION_INDEPENDENT_CODE=ON -Dbuild_tests=OFF -Dbuild_examples=OFF -Dbuild_tools=OFF \
			-Dpython-bindings=OFF -Dwebtorrent=OFF -Ddeprecated-functions=OFF -Dstatic_runtime=OFF -DCMAKE_INSTALL_PREFIX=/cache2/lt >/dev/null
		cmake --build lt-build -j"$(nproc)" 2>&1 | tail -3
		cmake --install lt-build >/dev/null
	fi
	cd /work
	echo "linux: shim"
	g++ -std=c++17 -O2 -fPIC -Wall -Wextra -c linux/shim/pt_lt.cpp $(PKG_CONFIG_PATH=/cache2/lt/lib/pkgconfig pkg-config --cflags libtorrent-rasterbar) -o "$out/pt_lt.o"
	ar rcs "$out/libptlt.a" "$out/pt_lt.o"
	cp /cache2/lt/lib/libtorrent-rasterbar.a /usr/lib/x86_64-linux-gnu/libssl.a /usr/lib/x86_64-linux-gnu/libcrypto.a "$out/"
	cp "$(g++ -print-file-name=libstdc++.a)" "$out/"
	cd /work
	"$odin/odin" build linux/src/spike -out:"$out/spike" -o:speed -vet -strict-style -extra-linker-flags:"-static-libgcc"
	echo "needed libraries:"; ldd "$out/spike" | sed 's/(0x.*//; s/^/  /'
	echo "glibc needed: $(objdump -T "$out/spike" | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1)"
	if [[ $# -ge 2 ]]; then echo "--- run"; "$out/spike" "$1" "$2"; fi
	chown -R "$HOST_UID:$HOST_GID" "$out"
}

if [[ ${1:-} == --inside ]]; then shift; inside "$@"; exit; fi

cd "$(dirname "$0")/.."
if [[ $(uname -s) != Linux ]]; then   # Windows: sync to the VM and run there
	tar cf - linux .local/linuxtest 2>/dev/null | ssh alpine 'mkdir -p ~/pt && tar xf - -C ~/pt'
	exec ssh alpine "cd ~/pt && bash linux/build.sh $*"
fi

cmd=${1:-spike}; shift || true
if ! docker image inspect $IMAGE >/dev/null 2>&1; then
	echo "linux: making the build image"
	docker build -q -t $IMAGE - >/dev/null <<'DOCKER'
FROM xzp-gui-build
RUN DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y -qq --no-install-recommends libboost-dev libssl-dev && rm -rf /var/lib/apt/lists/*
DOCKER
fi
docker run --rm -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" -v "$PWD:/work" -v xzp-gui-cache:/cache -v pt-linux-cache:/cache2 \
	$IMAGE bash /work/linux/build.sh --inside "$@"
