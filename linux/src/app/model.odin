package app

// The libtorrent shim, the torrent rows built from it, and how each column formats a row.

import "core:fmt"
import "core:slice"
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
	name:              [256]u8,
	hash_v1:           [41]u8,
	hash_v2:           [65]u8,
	save_path:         [512]u8,
	error:             [128]u8,
	state:             i32,
	paused:            i32,
	auto_managed:      i32,
	queue_position:    i32,
	download_rate:     i32,
	upload_rate:       i32,
	num_peers:         i32,
	num_seeds:         i32,
	list_peers:        i32,
	list_seeds:        i32,
	progress:          f32,
	availability:      f32,
	total_wanted:      i64,
	total_done:        i64,
	all_time_download: i64,
	all_time_upload:   i64,
	added_time:        i64,
	completed_time:    i64,
	sequential:        i32,
}

@(default_calling_convention = "c", link_prefix = "pt_")
foreign pt {
	version :: proc() -> cstring ---
	session_new :: proc() -> rawptr ---
	session_free :: proc(s: rawptr) ---
	add_torrent_file :: proc(s: rawptr, path: cstring, save_path: cstring, err: [^]u8, errlen: i32) -> i32 ---
	peek :: proc(path: cstring, name: [^]u8, namelen: i32, out: [^]File, max: i32, err: [^]u8, errlen: i32) -> i32 ---
	add_torrent_file_ex :: proc(s: rawptr, path: cstring, save_path: cstring, prio: [^]i32, nprio: i32, err: [^]u8, errlen: i32) -> i32 ---
	add_magnet :: proc(s: rawptr, uri: cstring, save_path: cstring, err: [^]u8, errlen: i32) -> i32 ---
	torrent_count :: proc(s: rawptr) -> i32 ---
	torrent_status :: proc(s: rawptr, index: i32, out: ^Status) -> i32 ---
	pause :: proc(s: rawptr, index: i32) ---
	resume :: proc(s: rawptr, index: i32) ---
	recheck :: proc(s: rawptr, index: i32) ---
	remove :: proc(s: rawptr, index: i32, delete_files: i32) ---
	dht_nodes :: proc(s: rawptr) -> i32 ---
	queue_move :: proc(s: rawptr, index: i32, to: i32) ---
	set_sequential :: proc(s: rawptr, index: i32, on: i32) ---
	set_limits :: proc(s: rawptr, index: i32, down, up: i32) ---
	force_announce :: proc(s: rawptr, index: i32) ---
	magnet :: proc(s: rawptr, index: i32, out: [^]u8, outlen: i32) -> i32 ---
	export :: proc(s: rawptr, index: i32, path: cstring) -> i32 ---
	files :: proc(s: rawptr, index: i32, out: [^]File, max: i32) -> i32 ---
	peers :: proc(s: rawptr, index: i32, out: [^]Peer, max: i32) -> i32 ---
	trackers :: proc(s: rawptr, index: i32, out: [^]Tracker, max: i32) -> i32 ---
}

File :: struct {
	path:     [512]u8,
	size:     i64,
	done:     i64,
	priority: i32,
}

Peer :: struct {
	ip:        [64]u8,
	client:    [64]u8,
	down_rate: i32,
	up_rate:   i32,
	progress:  f32,
	incoming:  i32,
}

Tracker :: struct {
	url:     [256]u8,
	message: [128]u8,
	tier:    i32,
	fails:   i32,
	working: i32,
}

cstr :: proc(b: []u8) -> string {
	return string(cstring(raw_data(b)))
}

// ---- columns ----

Col :: enum {
	Name,
	Queue,
	Size,
	Size_Remaining,
	Status,
	Progress,
	ETA,
	Down,
	Up,
	Availability,
	Ratio,
	Seeds,
	Peers,
	Added,
	Completed,
	Label,
	Version,
}

Col_Info :: struct {
	title:  string,
	width:  f32,
	right:  bool,
	hidden: bool, // by default
}

COLS := [Col]Col_Info {
	.Name = {"Name", 220, false, false},
	.Queue = {"#", 36, true, false},
	.Size = {"Size", 84, true, false},
	.Size_Remaining = {"Size (remaining)", 110, true, true},
	.Status = {"Status", 130, false, false},
	.Progress = {"Progress", 150, false, false},
	.ETA = {"ETA", 80, true, false},
	.Down = {"Down", 84, true, false},
	.Up = {"Up", 84, true, false},
	.Availability = {"Availability", 90, true, false},
	.Ratio = {"Ratio", 64, true, false},
	.Seeds = {"Seeds", 80, true, false},
	.Peers = {"Peers", 80, true, false},
	.Added = {"Added on", 150, true, false},
	.Completed = {"Completed on", 150, true, false},
	.Label = {"Label", 90, false, true},
	.Version = {"Version", 90, false, true},
}

// ---- rows ----

Row :: struct {
	st: Status,
	id: string, // info hash (v2 if any, else v1): the row's identity across refreshes
}

session: rawptr
rows: [dynamic]Row
view: [dynamic]int // indexes into rows, sorted
sort_col: Col = .Added
sort_asc: bool = false
selected: map[string]bool // by row id

refresh_rows :: proc() {
	n := int(torrent_count(session))
	for r in rows {delete(r.id)}
	clear(&rows)
	for i in 0 ..< n {
		r: Row
		if torrent_status(session, i32(i), &r.st) != 0 {continue}
		hv2 := cstr(r.st.hash_v2[:])
		r.id = strings.clone(hv2 if hv2 != "" else cstr(r.st.hash_v1[:]))
		append(&rows, r)
	}
	resort()
}

row_index_of_session :: proc(id: string) -> int {
	// the session's index of a row is its position in `rows` (refresh keeps the order)
	for r, i in rows {
		if r.id == id {return i}
	}
	return -1
}

version_rank :: proc(st: ^Status) -> int {
	v1, v2 := st.hash_v1[0] != 0, st.hash_v2[0] != 0
	if v1 && v2 {return 2}
	if v2 {return 3}
	if v1 {return 1}
	return 0
}

state_text :: proc(st: ^Status) -> string {
	if e := cstr(st.error[:]); e != "" {return fmt.tprintf("Error: %s", e)}
	switch st.state {
	case 1: return "Checking files"
	case 7: return "Checking resume data"
	case 2: return "Downloading metadata"
	}
	if st.paused != 0 {return "Queued" if st.auto_managed != 0 else "Paused"}
	switch st.state {
	case 3: return "Downloading"
	case 4, 5: return "Seeding"
	}
	return "-"
}

less_row :: proc(a, b: ^Row) -> int {
	cmp_i :: proc(x, y: i64) -> int {return -1 if x < y else (1 if x > y else 0)}
	cmp_f :: proc(x, y: f32) -> int {return -1 if x < y else (1 if x > y else 0)}
	c := 0
	switch sort_col {
	case .Name: c = strings.compare(strings.to_lower(cstr(a.st.name[:]), context.temp_allocator), strings.to_lower(cstr(b.st.name[:]), context.temp_allocator))
	case .Queue: c = cmp_i(i64(a.st.queue_position), i64(b.st.queue_position))
	case .Size: c = cmp_i(a.st.total_wanted, b.st.total_wanted)
	case .Size_Remaining: c = cmp_i(a.st.total_wanted - a.st.total_done, b.st.total_wanted - b.st.total_done)
	case .Status: c = strings.compare(state_text(&a.st), state_text(&b.st))
	case .Progress: c = cmp_f(a.st.progress, b.st.progress)
	case .ETA: c = cmp_i(eta_secs(&a.st), eta_secs(&b.st))
	case .Down: c = cmp_i(i64(a.st.download_rate), i64(b.st.download_rate))
	case .Up: c = cmp_i(i64(a.st.upload_rate), i64(b.st.upload_rate))
	case .Availability: c = cmp_f(a.st.availability, b.st.availability)
	case .Ratio: c = cmp_f(ratio(&a.st), ratio(&b.st))
	case .Seeds: c = cmp_i(i64(a.st.num_seeds), i64(b.st.num_seeds))
	case .Peers: c = cmp_i(i64(a.st.num_peers), i64(b.st.num_peers))
	case .Added: c = cmp_i(a.st.added_time, b.st.added_time)
	case .Completed: c = cmp_i(a.st.completed_time, b.st.completed_time)
	case .Label: c = 0
	case .Version: c = cmp_i(i64(version_rank(&a.st)), i64(version_rank(&b.st)))
	}
	if c == 0 {c = strings.compare(a.id, b.id)}
	return c if sort_asc else -c
}

resort :: proc() {
	clear(&view)
	for _, i in rows {append(&view, i)}
	slice.sort_by(view[:], proc(a, b: int) -> bool {return less_row(&rows[a], &rows[b]) < 0})
}

// ---- formatting ----

size_text :: proc(n: i64) -> string {
	f := f64(n)
	switch {
	case n < 1024: return fmt.tprintf("%d B", n)
	case n < 1024 * 1024: return fmt.tprintf("%.2f KB", f / 1024)
	case n < 1024 * 1024 * 1024: return fmt.tprintf("%.2f MB", f / (1024 * 1024))
	case: return fmt.tprintf("%.2f GB", f / (1024 * 1024 * 1024))
	}
}

speed_text :: proc(n: i32) -> string {
	if n <= 0 {return "-"}
	return fmt.tprintf("%s/s", size_text(i64(n)))
}

ratio :: proc(st: ^Status) -> f32 {
	if st.all_time_download <= 0 {return 0}
	return f32(st.all_time_upload) / f32(st.all_time_download)
}

eta_secs :: proc(st: ^Status) -> i64 {
	if st.paused != 0 || st.state != 3 || st.download_rate <= 0 {return 0}
	return (st.total_wanted - st.total_done) / i64(st.download_rate)
}

eta_text :: proc(st: ^Status) -> string {
	s := eta_secs(st)
	if s <= 0 {return "-"}
	h, m, sec := s / 3600, (s / 60) % 60, s % 60
	if h > 0 {return fmt.tprintf("%dh %dm %ds", h, m, sec)}
	if m > 0 {return fmt.tprintf("%dm %ds", m, sec)}
	return fmt.tprintf("%ds", sec)
}

time_text :: proc(unix: i64) -> string {
	if unix <= 0 {return "-"}
	dt, ok := time.time_to_datetime(time.unix(unix, 0))
	if !ok {return "-"}
	return fmt.tprintf("%04d-%02d-%02d %02d:%02d:%02d", dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second)
}

// cell_text is what a column shows for a row (Progress and Version are drawn, not written).
cell_text :: proc(r: ^Row, c: Col) -> string {
	st := &r.st
	switch c {
	case .Name: return cstr(st.name[:])
	case .Queue: return "-" if st.queue_position < 0 else fmt.tprintf("%d", st.queue_position + 1)
	case .Size: return size_text(st.total_wanted)
	case .Size_Remaining: return size_text(st.total_wanted - st.total_done)
	case .Status: return state_text(st)
	case .Progress: return fmt.tprintf("%d%%", int(st.progress * 100))
	case .ETA: return eta_text(st)
	case .Down: return speed_text(st.download_rate)
	case .Up: return speed_text(st.upload_rate)
	case .Availability: return "-" if st.availability < 0 else fmt.tprintf("%.3f", st.availability)
	case .Ratio: return fmt.tprintf("%.3f", ratio(st))
	case .Seeds: return fmt.tprintf("%d (of %d)", st.num_seeds, st.list_seeds)
	case .Peers: return fmt.tprintf("%d (of %d)", st.num_peers, st.list_peers)
	case .Added: return time_text(st.added_time)
	case .Completed: return time_text(st.completed_time)
	case .Label: return "-"
	case .Version: return ""
	}
	return ""
}

// The selection keys are copies: rows (and their ids) are rebuilt on every refresh.
sel_clear :: proc() {
	for k in selected {delete(k)}
	clear(&selected)
}

sel_add :: proc(id: string) {
	if !selected[id] {selected[strings.clone(id)] = true}
}

sel_remove :: proc(id: string) {
	for k in selected {
		if k == id {
			delete_key(&selected, k)
			delete(k)
			return
		}
	}
}
