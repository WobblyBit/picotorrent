package app

// PicoTorrent for Linux, in Odin: window, menu, torrent list, status bar, themes, persistence.
// libtorrent runs behind linux/shim; this file only drives it and the UI.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

Stored :: struct {
	file: string, // our copy of the .torrent
	save: string, // where its data goes
}

stored: [dynamic]Stored // parallel to the session's torrent list
dht: i32
last_refresh: time.Tick
last_resume: time.Tick

main :: proc() {
	if spec := os.get_env("PT_SELFTEST2", context.temp_allocator); spec != "" {
		resume_selftest(spec)
		return
	}
	table_init()
	load_labels()
	set_language(detect_language())
	load_config()
	args: [dynamic]string
	for a in os.args[1:] {
		append(&args, a)
	}
	if p := os.get_env("PT_SHOT", context.temp_allocator); p != "" {shot_path = strings.clone(p)}
	if os.get_env("PT_THEME", context.temp_allocator) == "light" {th = THEME_LIGHT}
	if os.get_env("PT_COLUMNS", context.temp_allocator) == "all" {
		for c in Col {hidden[c] = false}
	}
	if v := os.get_env("PT_FRAMES", context.temp_allocator); v != "" {shot_at, _ = strconv.parse_int(v)}
	if v := os.get_env("PT_SCROLLX", context.temp_allocator); v != "" {sx, _ := strconv.parse_int(v); scroll_x = f32(sx)}

	if !backend_init() {os.exit(1)}
	defer backend_quit()

	session = session_new()
	if st := os.get_env("PT_SELFTEST", context.temp_allocator); st != "" { 	// source:out -> create v1, v2 and hybrid, read each back
		parts := strings.split(st, ":", context.temp_allocator)
		for ver in ([3]i32{1, 2, 3}) {
			out := fmt.ctprintf("%s.v%d.torrent", parts[1], ver)
			e: [256]u8
			rc := create(strings.clone_to_cstring(parts[0], context.temp_allocator), out, ver, 0, "test", "udp://tracker.example:80/announce", raw_data(e[:]), len(e))
			n := session_n_after(out)
			fmt.printfln("selftest version=%d create=%d err=%s %s", ver, rc, cstr(e[:]), n)
		}
		return
	}
	defer session_free(session)
	resume_dir := fmt.tprintf("%s/resume", config_dir())
	mkdirs(resume_dir)
	set_resume_dir(session, strings.clone_to_cstring(resume_dir, context.temp_allocator))
	apply_prefs()
	load_torrents()
	for a in args {add_torrent_file_from(a)}
	refresh_rows()

	demo := strings.clone(os.get_env("PT_DEMO", context.temp_allocator))
	demo_done := false

	for !should_close() {
		free_all(context.temp_allocator)
		wait_events(0.2)

		if st := sync.atomic_load(&create_state); st >= 2 {
			sync.atomic_store(&create_state, 0)
			modal_text = "The torrent was created." if st == 2 else fmt.tprintf("Cannot create the torrent: %s", cstr(create_msg[:]))
		}
		for p in take_picked() {
			if strings.has_suffix(strings.to_lower(p, context.temp_allocator), ".torrent") {append(&pending_adds, strings.clone(p))}
		}
		if dialog == .None && modal_text == "" && len(pending_adds) > 0 {
			open_add(pending_adds[0])
			delete(pending_adds[0])
			ordered_remove(&pending_adds, 0)
		}
		if time.duration_milliseconds(time.tick_since(last_refresh)) > 500 {
			refresh_rows()
			details_refresh()
			dht = dht_nodes(session)
			if time.duration_seconds(time.tick_since(last_resume)) > 120 {
				request_resume(session)
				last_resume = time.tick_now()
			}
			last_refresh = time.tick_now()
		}

		begin_input()
		w, h := begin_frame()
		if w == 0 {continue}

		live := !popup.open && modal_text == "" && dialog == .None
		dh: f32 = DETAILS_H if h > 560 else 0
		draw_table(0, MENU_H, w, h - MENU_H - STATUS_H - dh, live)
		if dh > 0 {draw_details(0, h - STATUS_H - dh, w, dh, live)}
		draw_menu_bar(w, live || popup.open)
		dl, ul: i64
		for &r in rows {
			dl += i64(r.st.download_rate)
			ul += i64(r.st.upload_rate)
		}
		draw_status_bar(w, h - STATUS_H, len(rows), dl, ul, dht)

		if !demo_done && shot_frames == 3 {
			demo_done = true
			switch demo {
			case "view": popup_bar(1, 6 + text_w("File") + 20)
			case "columns":
				popup_bar(1, 6 + text_w("File") + 20)
				popup.sub_open, popup.sub_y = true, MENU_H + 4
			case "ctx":
				if len(view) > 0 {
					sel_add(rows[view[0]].id)
					popup_torrent(300, 80)
				}
			case "about": modal_text = fmt.tprintf("PicoTorrent for Linux (Odin). libtorrent %s", version())
			case "magnet": open_magnet()
			case "limits":
				if len(view) > 0 {sel_add(rows[view[0]].id)}
				open_limits()
			case "create": open_create()
			case "prefs": open_prefs()
			case "lang": open_lang()
			case "label":
				if len(view) > 0 {sel_add(rows[view[0]].id)}
				labels[strings.clone(rows[view[0]].id)] = "Linux ISOs"
				open_labels(0)
			case "add": open_add(os.get_env("PT_ADD", context.temp_allocator))
			case "files", "peers", "trackers", "overview":
				if len(view) > 0 {sel_add(rows[view[0]].id)}
				tab = Tab(indexof([]string{"overview", "files", "peers", "trackers"}, demo))
				details_refresh()
			}
		}

		act, arg := draw_popup(w, h)
		if act != .None {do_action(act, arg)}
		if dialog == .Label && label_done {dialog = .None}
		if dialog == .Lang && lang_done {dialog = .None}
		if draw_dialog(w, h) {
			switch dialog {
			case .None:
			case .Magnet: for uri in strings.fields(field_text(&magnet_field), context.temp_allocator) {add_magnet_uri(uri)}
			case .Add: accept_add()
			case .Limits: accept_limits()
			case .Create: accept_create()
			case .Prefs: accept_prefs()
			case .Label: accept_label()
			case .Lang:
			}
			if (dialog != .Add || add_done) && (dialog != .Limits || limits_done) && (dialog != .Create || cr_done) && (dialog != .Prefs || pf_done) && (dialog != .Label || label_done) {dialog = .None}
		}
		draw_modal(w, h)
		end_frame()
	}
	save_config()
	request_resume(session)
	_ = flush_resume(session, 8000)
}

// ---- actions ----

selected_indexes :: proc() -> [dynamic]i32 {
	out := make([dynamic]i32, context.temp_allocator)
	for r, i in rows {
		if selected[r.id] {append(&out, i32(i))}
	}
	return out
}

do_action :: proc(a: Action, arg: int) {
	switch a {
	case .None, .Toggle_Column:
	case .Create_Torrent: open_create()
	case .Preferences: open_prefs()
	case .Language: open_lang()
	case .Set_Label: open_labels(0)
	case .Filter_Label: open_labels(1)
	case .Add_Magnet: open_magnet()
	case .Add_Torrent: pick_torrents()
	case .Exit: request_close()
	case .Theme_Light: th = THEME_LIGHT
	case .Theme_Dark: th = THEME_DARK
	case .About: modal_text = fmt.tprintf("PicoTorrent for Linux (Odin). libtorrent %s", version())
	case .Pause: for i in selected_indexes() {pause(session, i)}
	case .Resume: for i in selected_indexes() {resume(session, i)}
	case .Recheck: for i in selected_indexes() {recheck(session, i)}
	case .Copy_Hash:
		b: strings.Builder
		strings.builder_init(&b, context.temp_allocator)
		for &r in rows {
			if !selected[r.id] {continue}
			if v1 := cstr(r.st.hash_v1[:]); v1 != "" {fmt.sbprintln(&b, v1)}
			if v2 := cstr(r.st.hash_v2[:]); v2 != "" {fmt.sbprintln(&b, v2)}
		}
		clipboard_set(strings.trim_space(strings.to_string(b)))
	case .Queue: for i in selected_indexes() {queue_move(session, i, i32(arg))}
	case .Sequential:
		on: i32 = 1
		for &r in rows {
			if selected[r.id] && r.st.sequential != 0 {on = 0}
		}
		for i in selected_indexes() {set_sequential(session, i, on)}
	case .Limits: open_limits()
	case .Announce: for i in selected_indexes() {force_announce(session, i)}
	case .Copy_Magnet:
		b: strings.Builder
		strings.builder_init(&b, context.temp_allocator)
		buf: [2048]u8
		for i in selected_indexes() {
			if magnet(session, i, raw_data(buf[:]), len(buf)) == 0 {fmt.sbprintln(&b, cstr(buf[:]))}
		}
		clipboard_set(strings.trim_space(strings.to_string(b)))
	case .Export:
		if idx := selected_indexes(); len(idx) == 1 {
			name := cstr(rows[idx[0]].st.name[:])
			if p := pick_save(fmt.tprintf("%s.torrent", name)); p != "" {
				if export(session, idx[0], strings.clone_to_cstring(p, context.temp_allocator)) != 0 {modal_text = "Cannot export this torrent (no metadata yet?)."}
			}
		}
	case .Open_Folder:
		for &r in rows {
			if selected[r.id] {open_folder(cstr(r.st.save_path[:]))}
		}
	case .Remove, .Remove_Files:
		idx := selected_indexes()
		for k := len(idx) - 1; k >= 0; k -= 1 {
			i := int(idx[k])
			delete_key(&labels, rows[i].id)
			remove(session, idx[k], 1 if a == .Remove_Files else 0)
			if i < len(stored) {
				if !strings.has_prefix(stored[i].file, "magnet:") {_ = os.remove(stored[i].file)}
				ordered_remove(&stored, i)
			}
		}
		sel_clear()
		save_torrents()
	}
}

// ---- adding and keeping torrents ----

add_torrent_file_from :: proc(path: string) {
	if !strings.has_suffix(strings.to_lower(path, context.temp_allocator), ".torrent") {return}
	add_torrent_with(path, download_dir(), nil)
}

// add_torrent_with adds a .torrent to the session; prio has one entry per file (0 = skip) or is nil.
add_torrent_with :: proc(path, save: string, prio: []i32) {
	mkdirs(save)
	err: [512]u8
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	csave := strings.clone_to_cstring(save, context.temp_allocator)
	if add_torrent_file_ex(session, cpath, csave, raw_data(prio), i32(len(prio)), raw_data(err[:]), len(err)) != 0 {
		modal_text = fmt.tprintf("Cannot add the torrent: %s", cstr(err[:]))
		return
	}
	// keep a copy so the torrent is back at the next start
	dir := fmt.tprintf("%s/torrents", config_dir())
	mkdirs(dir)
	copy_path := fmt.aprintf("%s/%d.torrent", dir, time.now()._nsec)
	if data, rerr := os.read_entire_file(path, context.temp_allocator); rerr == nil {
		_ = os.write_entire_file(copy_path, data)
	}
	append(&stored, Stored{copy_path, strings.clone(save)})
	save_torrents()
}

indexof :: proc(list: []string, s: string) -> int {
	for v, i in list {
		if v == s {return i}
	}
	return 0
}

add_magnet_uri :: proc(uri: string) {
	if !strings.has_prefix(uri, "magnet:") {
		modal_text = "That is not a magnet link."
		return
	}
	save := download_dir()
	mkdirs(save)
	err: [512]u8
	if add_magnet(session, strings.clone_to_cstring(uri, context.temp_allocator), strings.clone_to_cstring(save, context.temp_allocator), raw_data(err[:]), len(err)) != 0 {
		modal_text = fmt.tprintf("Cannot add the magnet link: %s", cstr(err[:]))
		return
	}
	append(&stored, Stored{strings.clone(uri), strings.clone(save)})
	save_torrents()
}

load_torrents :: proc() {
	data, err := os.read_entire_file(fmt.tprintf("%s/torrents.txt", config_dir()), context.temp_allocator)
	if err != nil {return}
	for l in strings.split_lines(string(data), context.temp_allocator) {
		parts := strings.split(l, "\t", context.temp_allocator)
		if len(parts) != 2 {continue}
		e: [512]u8
		c0, c1 := strings.clone_to_cstring(parts[0], context.temp_allocator), strings.clone_to_cstring(parts[1], context.temp_allocator)
		ok := add_magnet(session, c0, c1, raw_data(e[:]), len(e)) if strings.has_prefix(parts[0], "magnet:") else add_torrent_file(session, c0, c1, raw_data(e[:]), len(e))
		if ok == 0 {
			append(&stored, Stored{strings.clone(parts[0]), strings.clone(parts[1])})
		}
	}
}

save_torrents :: proc() {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	for s in stored {fmt.sbprintf(&b, "%s\t%s\n", s.file, s.save)}
	mkdirs(config_dir())
	_ = os.write_entire_file(fmt.tprintf("%s/torrents.txt", config_dir()), transmute([]u8)strings.to_string(b))
}

// ---- settings: theme, hidden columns, sort ----

load_config :: proc() {
	data, err := os.read_entire_file(fmt.tprintf("%s/gui.ini", config_dir()), context.temp_allocator)
	if err != nil {return}
	for l in strings.split_lines(string(data), context.temp_allocator) {
		k, _, v := strings.partition(l, "=")
		switch k {
		case "theme": th = THEME_LIGHT if v == "light" else THEME_DARK
		case "hidden":
			for c in Col {hidden[c] = false}
			for name in strings.split(v, ",", context.temp_allocator) {
				for c in Col {
					if col_key(c) == name {hidden[c] = true}
				}
			}
		case "save": prefs.save = strings.clone(v)
		case "port": prefs.port, _ = strconv.parse_int(v)
		case "down": prefs.down, _ = strconv.parse_int(v)
		case "up": prefs.up, _ = strconv.parse_int(v)
		case "actdl": prefs.act_dl, _ = strconv.parse_int(v)
		case "actseed": prefs.act_seed, _ = strconv.parse_int(v)
		case "dht": prefs.dht = v == "1"
		case "lsd": prefs.lsd = v == "1"
		case "nat": prefs.nat = v == "1"
		case "proxy": prefs.proxy, _ = strconv.parse_int(v)
		case "phost": prefs.phost = strings.clone(v)
		case "pport": prefs.pport, _ = strconv.parse_int(v)
		case "lang": set_language(v)
		case "sort":
			name, _, dir := strings.partition(v, ":")
			for c in Col {
				if col_key(c) == name {sort_col = c}
			}
			sort_asc = dir == "asc"
		}
	}
}

col_key :: proc(c: Col) -> string {
	return fmt.tprintf("%v", c)
}

save_config :: proc() {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	fmt.sbprintfln(&b, "theme=%s", "dark" if th.dark else "light")
	names := make([dynamic]string, context.temp_allocator)
	for c in Col {
		if hidden[c] {append(&names, col_key(c))}
	}
	fmt.sbprintfln(&b, "hidden=%s", strings.join(names[:], ",", context.temp_allocator))
	fmt.sbprintfln(&b, "lang=%s", lang_code)
	fmt.sbprintfln(&b, "save=%s", prefs.save)
	fmt.sbprintfln(&b, "port=%d", prefs.port)
	fmt.sbprintfln(&b, "down=%d", prefs.down)
	fmt.sbprintfln(&b, "up=%d", prefs.up)
	fmt.sbprintfln(&b, "actdl=%d", prefs.act_dl)
	fmt.sbprintfln(&b, "actseed=%d", prefs.act_seed)
	fmt.sbprintfln(&b, "dht=%d", int(prefs.dht))
	fmt.sbprintfln(&b, "lsd=%d", int(prefs.lsd))
	fmt.sbprintfln(&b, "nat=%d", int(prefs.nat))
	fmt.sbprintfln(&b, "proxy=%d", prefs.proxy)
	fmt.sbprintfln(&b, "phost=%s", prefs.phost)
	fmt.sbprintfln(&b, "pport=%d", prefs.pport)
	fmt.sbprintfln(&b, "sort=%s:%s", col_key(sort_col), "asc" if sort_asc else "desc")
	mkdirs(config_dir())
	_ = os.write_entire_file(fmt.tprintf("%s/gui.ini", config_dir()), transmute([]u8)strings.to_string(b))
}

// session_n_after adds the torrent and describes it: the hashes it ends up with.
session_n_after :: proc(path: cstring) -> string {
	e: [256]u8
	if add_torrent_file(session, path, "/tmp", raw_data(e[:]), len(e)) != 0 {return fmt.tprintf("add failed: %s", cstr(e[:]))}
	st: Status
	n := torrent_count(session)
	_ = torrent_status(session, n - 1, &st)
	return fmt.tprintf("v1=%s v2=%s", cstr(st.hash_v1[:]), cstr(st.hash_v2[:]))
}

// resume_selftest: torrent:save. Checks the torrent in one session, saves resume data, and opens it in
// a second session: it must not start by checking the files again.
resume_selftest :: proc(spec: string) {
	parts := strings.split(spec, ":", context.temp_allocator)
	dir := "/tmp/resume_t"
	_ = os.make_directory_all(dir)
	tp, sp := strings.clone_to_cstring(parts[0], context.temp_allocator), strings.clone_to_cstring(parts[1], context.temp_allocator)
	e: [256]u8
	st: Status
	a := session_new()
	set_resume_dir(a, "/tmp/resume_t")
	_ = add_torrent_file(a, tp, sp, raw_data(e[:]), len(e))
	for _ in 0 ..< 75 {
		time.sleep(200 * time.Millisecond)
		_ = dht_nodes(a)
		_ = torrent_status(a, 0, &st)
		if st.state != 1 && st.state != 7 {break}
	}
	fmt.printfln("A: state=%d progress=%.3f", st.state, st.progress)
	request_resume(a)
	fmt.printfln("A: still missing after flush: %d", flush_resume(a, 8000))
	session_free(a)
	b := session_new()
	set_resume_dir(b, "/tmp/resume_t")
	_ = add_torrent_file(b, tp, sp, raw_data(e[:]), len(e))
	time.sleep(300 * time.Millisecond)
	_ = torrent_status(b, 0, &st)
	fmt.printfln("B right after add: state=%d progress=%.3f (1 or 7 would mean it re-checks)", st.state, st.progress)
	session_free(b)
}
