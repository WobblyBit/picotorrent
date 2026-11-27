package app

// PicoTorrent for Linux, in Odin: window, menu, torrent list, status bar, themes, persistence.
// libtorrent runs behind linux/shim; this file only drives it and the UI.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

Stored :: struct {
	file: string, // our copy of the .torrent
	save: string, // where its data goes
}

stored: [dynamic]Stored // parallel to the session's torrent list
dht: i32
last_refresh: time.Tick

main :: proc() {
	table_init()
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
	defer session_free(session)
	load_torrents()
	for a in args {add_torrent_file_from(a)}
	refresh_rows()

	demo := strings.clone(os.get_env("PT_DEMO", context.temp_allocator))
	demo_done := false

	for !should_close() {
		free_all(context.temp_allocator)
		wait_events(0.2)

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
			case "add": open_add(os.get_env("PT_ADD", context.temp_allocator))
			case "files", "peers", "trackers", "overview":
				if len(view) > 0 {sel_add(rows[view[0]].id)}
				tab = Tab(indexof([]string{"overview", "files", "peers", "trackers"}, demo))
				details_refresh()
			}
		}

		act, arg := draw_popup(w, h)
		if act != .None {do_action(act, arg)}
		if draw_dialog(w, h) {
			switch dialog {
			case .None:
			case .Magnet: for uri in strings.fields(field_text(&magnet_field), context.temp_allocator) {add_magnet_uri(uri)}
			case .Add: accept_add()
			}
			if dialog != .Add || add_done {dialog = .None}
		}
		draw_modal(w, h)
		end_frame()
	}
	save_config()
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
	case .None, .Toggle_Column, .Create_Torrent:
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
	case .Open_Folder:
		for &r in rows {
			if selected[r.id] {open_folder(cstr(r.st.save_path[:]))}
		}
	case .Remove, .Remove_Files:
		idx := selected_indexes()
		for k := len(idx) - 1; k >= 0; k -= 1 {
			i := int(idx[k])
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
	fmt.sbprintfln(&b, "sort=%s:%s", col_key(sort_col), "asc" if sort_asc else "desc")
	mkdirs(config_dir())
	_ = os.write_entire_file(fmt.tprintf("%s/gui.ini", config_dir()), transmute([]u8)strings.to_string(b))
}
