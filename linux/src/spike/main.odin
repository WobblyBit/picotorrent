// Spike: Odin calls libtorrent (through linux/shim) and prints a torrent's status.
package spike

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

when ODIN_OS == .Linux {
	foreign import pt {
		"../../../build/linux/libptlt.a",
		"../../../build/linux/libtorrent-rasterbar.a",
		"../../../build/linux/libssl.a",
		"../../../build/linux/libcrypto.a",
		"../../../build/linux/libstdc++.a",
		"system:m",
		"system:pthread",
		"system:dl",
	}
}

Status :: struct {
	name:         [256]u8,
	hash_v1:      [41]u8,
	hash_v2:      [65]u8,
	state:        i32,
	paused:       i32,
	progress:     f32,
	total_wanted: i64,
	total_done:   i64,
	num_peers:    i32,
	num_seeds:    i32,
}

@(default_calling_convention = "c", link_prefix = "pt_")
foreign pt {
	version :: proc() -> cstring ---
	session_new :: proc() -> rawptr ---
	session_free :: proc(s: rawptr) ---
	add_torrent_file :: proc(s: rawptr, path: cstring, save_path: cstring, err: [^]u8, errlen: i32) -> i32 ---
	torrent_count :: proc(s: rawptr) -> i32 ---
	torrent_status :: proc(s: rawptr, index: i32, out: ^Status) -> i32 ---
}

cstr :: proc(b: []u8) -> string {
	return string(cstring(raw_data(b)))
}

main :: proc() {
	if len(os.args) < 3 {
		fmt.eprintln("usage: spike FILE.torrent SAVE_PATH")
		os.exit(2)
	}
	fmt.println("libtorrent", version())

	s := session_new()
	defer session_free(s)

	err: [512]u8
	path := strings.clone_to_cstring(os.args[1], context.temp_allocator)
	save := strings.clone_to_cstring(os.args[2], context.temp_allocator)
	if add_torrent_file(s, path, save, raw_data(err[:]), len(err)) != 0 {
		fmt.eprintln("add failed:", cstr(err[:]))
		os.exit(1)
	}

	// Let libtorrent check the files, then print what it found.
	for _ in 0 ..< 20 {
		time.sleep(250 * time.Millisecond)
		st: Status
		torrent_status(s, 0, &st)
		fmt.printf("%s  state=%d  %.0f%%  %d/%d bytes  v1=%q v2=%q\n",
			cstr(st.name[:]), st.state, st.progress * 100, st.total_done, st.total_wanted,
			cstr(st.hash_v1[:]), cstr(st.hash_v2[:]))
		if st.state == 4 || st.state == 5 { break } // finished / seeding
	}
}
