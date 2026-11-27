package app

// The details pane under the list: Overview, Files, Peers and Trackers of the selected torrent.

import "core:fmt"
import "core:strings"

DETAILS_H :: 240
TABS_H :: 28
MAX_ITEMS :: 2000

Tab :: enum {
	Overview,
	Files,
	Peers,
	Trackers,
}

tab_titles := [Tab]string {
	.Overview = "Overview",
	.Files    = "Files",
	.Peers    = "Peers",
	.Trackers = "Trackers",
}

tab: Tab
detail_scroll: f32
detail_id: string // the torrent the cached lists belong to
detail_files: [dynamic]File
detail_peers: [dynamic]Peer
detail_trackers: [dynamic]Tracker

// current_row is the row shown in the pane: the first selected one in list order.
current_row :: proc() -> int {
	for vi in view {
		if selected[rows[vi].id] {return vi}
	}
	return -1
}

// details_refresh reloads the list of the open tab (called with the row refresh).
details_refresh :: proc() {
	ri := current_row()
	if ri < 0 {
		clear(&detail_files)
		clear(&detail_peers)
		clear(&detail_trackers)
		return
	}
	if detail_id != rows[ri].id {
		delete(detail_id)
		detail_id = strings.clone(rows[ri].id)
		detail_scroll = 0
	}
	switch tab {
	case .Overview:
	case .Files:
		resize(&detail_files, MAX_ITEMS)
		resize(&detail_files, int(files(session, i32(ri), raw_data(detail_files), MAX_ITEMS)))
	case .Peers:
		resize(&detail_peers, MAX_ITEMS)
		resize(&detail_peers, int(peers(session, i32(ri), raw_data(detail_peers), MAX_ITEMS)))
	case .Trackers:
		resize(&detail_trackers, 200)
		resize(&detail_trackers, int(trackers(session, i32(ri), raw_data(detail_trackers), 200)))
	}
}

Gcol :: struct {
	title: string,
	w:     f32, // 0 = takes the rest
	right: bool,
}

// draw_grid draws a simple scrolling list; cell gives the text of row i, column c.
draw_grid :: proc(x, y, w, h: f32, cols: []Gcol, n: int, cell: proc(i, c: int) -> string) {
	fixed: f32
	for c in cols {fixed += c.w}
	fill(x, y, w, HEAD_H - 4, th.header)
	line(x, y + HEAD_H - 4.5, x + w, y + HEAD_H - 4.5, th.border)
	body_y, body_h := y + HEAD_H - 4, h - (HEAD_H - 4)
	total := f32(n) * ROW_H
	if hit(x, y, w, h) && !popup.open && dialog == .None {detail_scroll -= ui.scroll * ROW_H * 3}
	detail_scroll = clamp(detail_scroll, 0, max(0, total - body_h))

	cx := x
	for c in cols {
		cw := c.w if c.w > 0 else max(80, w - fixed)
		text_fit(cx + 8, y + 2, cw - 16, c.title, th.text, c.right)
		cx += cw
	}
	clip(x, body_y, w, body_h)
	first := int(detail_scroll / ROW_H)
	for i := first; i < n && f32(i) * ROW_H - detail_scroll < body_h; i += 1 {
		ry := body_y + f32(i) * ROW_H - detail_scroll
		if i % 2 == 1 {fill(x, ry, w, ROW_H, Color{th.hover.r, th.hover.g, th.hover.b, 90})}
		cx = x
		for c, ci in cols {
			cw := c.w if c.w > 0 else max(80, w - fixed)
			text_fit(cx + 8, ry + 2.5, cw - 16, cell(i, ci), th.text, c.right)
			cx += cw
		}
	}
	unclip()
	if total > body_h {
		bh := max(24, body_h * body_h / total)
		by := body_y + (body_h - bh) * (detail_scroll / (total - body_h))
		rrect(x + w - 6, by, 4, bh, 2, Color{th.dim.r, th.dim.g, th.dim.b, 110})
	}
}

file_cell :: proc(i, c: int) -> string {
	f := &detail_files[i]
	switch c {
	case 0: return cstr(f.path[:])
	case 1: return size_text(f.size)
	case 2: return fmt.tprintf("%d%%", int(100 * f64(f.done) / f64(max(f.size, 1))))
	case 3: return "Skip" if f.priority == 0 else ("High" if f.priority > 4 else "Normal")
	}
	return ""
}

peer_cell :: proc(i, c: int) -> string {
	p := &detail_peers[i]
	switch c {
	case 0: return cstr(p.ip[:])
	case 1: return cstr(p.client[:])
	case 2: return fmt.tprintf("%d%%", int(p.progress * 100))
	case 3: return speed_text(p.down_rate)
	case 4: return speed_text(p.up_rate)
	case 5: return "Incoming" if p.incoming != 0 else "Outgoing"
	}
	return ""
}

tracker_cell :: proc(i, c: int) -> string {
	t := &detail_trackers[i]
	switch c {
	case 0: return cstr(t.url[:])
	case 1: return fmt.tprintf("%d", t.tier)
	case 2:
		if t.working != 0 {return "Working"}
		if m := cstr(t.message[:]); m != "" {return m}
		return "Not contacted yet" if t.fails == 0 else fmt.tprintf("Failed (%d)", t.fails)
	}
	return ""
}

file_cols := []Gcol{{"Name", 0, false}, {"Size", 100, true}, {"Progress", 90, true}, {"Priority", 90, false}}
peer_cols := []Gcol{{"Address", 0, false}, {"Client", 160, false}, {"Progress", 80, true}, {"Down", 90, true}, {"Up", 90, true}, {"Direction", 90, false}}
tracker_cols := []Gcol{{"URL", 0, false}, {"Tier", 60, true}, {"Status", 260, false}}

draw_overview :: proc(x, y, w: f32, r: ^Row) {
	st := &r.st
	hv1, hv2 := cstr(st.hash_v1[:]), cstr(st.hash_v2[:])
	pairs := [][2]string {
		{"Name", cstr(st.name[:])},
		{"Save path", cstr(st.save_path[:])},
		{"Status", state_text(st)},
		{"Size", fmt.tprintf("%s of %s (%d%%)", size_text(st.total_done), size_text(st.total_wanted), int(st.progress * 100))},
		{"Downloaded / uploaded", fmt.tprintf("%s / %s   (ratio %.3f)", size_text(st.all_time_download), size_text(st.all_time_upload), ratio(st))},
		{"Seeds / peers", fmt.tprintf("%d (of %d) / %d (of %d)", st.num_seeds, st.list_seeds, st.num_peers, st.list_peers)},
		{"Added / completed", fmt.tprintf("%s / %s", time_text(st.added_time), time_text(st.completed_time))},
		{"Info hash (v1)", hv1 if hv1 != "" else "-"},
		{"Info hash (v2)", hv2 if hv2 != "" else "-"},
	}
	label_w: f32 = 200
	yy := y + 6
	for p in pairs {
		text(x + 12, yy, p[0], th.dim)
		text_fit(x + 12 + label_w, yy, w - label_w - 24, p[1], th.text)
		yy += LINE_H + 2
	}
}

draw_details :: proc(x, y, w, h: f32, live: bool) {
	fill(x, y, w, h, th.bg)
	fill(x, y, w, TABS_H, th.panel)
	line(x, y + 0.5, x + w, y + 0.5, th.border)
	line(x, y + TABS_H - 0.5, x + w, y + TABS_H - 0.5, th.border)
	tx := x + 6
	for t in Tab {
		tw := text_w(tab_titles[t]) + 24
		on := tab == t
		over := live && hit(tx, y, tw, TABS_H)
		if on {fill(tx, y + 2, tw, TABS_H - 2, th.bg)} else if over {fill(tx, y + 2, tw, TABS_H - 4, th.hover)}
		if on {fill(tx, y + 2, tw, 2, th.accent)}
		text(tx + 12, y + 6, tab_titles[t], th.text if on else th.dim)
		if over && ui.press_l && !on {
			tab = t
			detail_scroll = 0
			details_refresh()
		}
		tx += tw
	}

	ri := current_row()
	by := y + TABS_H
	bh := h - TABS_H
	if ri < 0 {
		text(x + 12, by + 10, "Select a torrent to see its details.", th.dim)
		return
	}
	switch tab {
	case .Overview: draw_overview(x, by, w, &rows[ri])
	case .Files: draw_grid(x, by, w, bh, file_cols, len(detail_files), file_cell)
	case .Peers: draw_grid(x, by, w, bh, peer_cols, len(detail_peers), peer_cell)
	case .Trackers: draw_grid(x, by, w, bh, tracker_cols, len(detail_trackers), tracker_cell)
	}
}
