package app

// A single-line text field and the dialogs built on it (add magnet links).

import "core:fmt"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "vendor:glfw"

Field :: struct {
	buf:   [dynamic]u8,
	caret: int, // byte offset, on a rune boundary
}

field_text :: proc(f: ^Field) -> string {return string(f.buf[:])}

field_set :: proc(f: ^Field, s: string) {
	clear(&f.buf)
	append(&f.buf, s)
	f.caret = len(f.buf)
}

field_insert :: proc(f: ^Field, s: string) {
	inject_at_elems(&f.buf, f.caret, ..transmute([]u8)s)
	f.caret += len(s)
}

prev_rune :: proc(b: []u8, at: int) -> int {
	i := at - 1
	for i > 0 && (b[i] & 0xC0) == 0x80 {i -= 1}
	return max(i, 0)
}

next_rune :: proc(b: []u8, at: int) -> int {
	i := at + 1
	for i < len(b) && (b[i] & 0xC0) == 0x80 {i += 1}
	return min(i, len(b))
}

// draw_field draws a field and, when focused, edits it from this frame's keys and characters.
draw_field :: proc(f: ^Field, x, y, w: f32, focused: bool, hint := "") {
	h: f32 = 28
	rrect(x, y, w, h, 5, th.bg)
	rrect_line(x, y, w, h, 5, th.accent if focused else th.border)
	clip(x + 6, y, w - 12, h)
	defer unclip()
	s := field_text(f)
	if s == "" && !focused {
		text(x + 8, y + 5.5, hint, th.dim)
		return
	}
	// scroll so the caret stays visible
	cw := text_w(s[:f.caret])
	off := max(0, cw - (w - 24))
	text(x + 8 - off, y + 5.5, s, th.text)
	if focused {
		cx := x + 8 - off + cw
		line(cx, y + 6, cx, y + h - 6, th.text)
	}
	if !focused {return}

	for r in ui.chars {
		if r < 32 {continue}
		buf, n := encode_rune(r)
		field_insert(f, string(buf[:n]))
	}
	m := current_mods()
	for k in ui.keys {
		switch k {
		case glfw.KEY_BACKSPACE:
			if f.caret > 0 {
				p := prev_rune(f.buf[:], f.caret)
				remove_range(&f.buf, p, f.caret)
				f.caret = p
			}
		case glfw.KEY_DELETE:
			if f.caret < len(f.buf) {remove_range(&f.buf, f.caret, next_rune(f.buf[:], f.caret))}
		case glfw.KEY_LEFT: f.caret = prev_rune(f.buf[:], f.caret)
		case glfw.KEY_RIGHT: f.caret = next_rune(f.buf[:], f.caret)
		case glfw.KEY_HOME: f.caret = 0
		case glfw.KEY_END: f.caret = len(f.buf)
		case glfw.KEY_V:
			if m.ctrl {
				// one line: pasted line breaks become spaces
				p, _ := strings.replace_all(clipboard_get(), "\n", " ", context.temp_allocator)
				p, _ = strings.replace_all(p, "\r", "", context.temp_allocator)
				field_insert(f, p)
			}
		}
	}
}

encode_rune :: proc(r: rune) -> ([4]u8, int) {
	b: [4]u8
	switch {
	case r < 0x80:
		b[0] = u8(r)
		return b, 1
	case r < 0x800:
		b[0], b[1] = 0xC0 | u8(r >> 6), 0x80 | u8(r & 0x3F)
		return b, 2
	case r < 0x10000:
		b[0], b[1], b[2] = 0xE0 | u8(r >> 12), 0x80 | u8((r >> 6) & 0x3F), 0x80 | u8(r & 0x3F)
		return b, 3
	}
	b[0], b[1], b[2], b[3] = 0xF0 | u8(r >> 18), 0x80 | u8((r >> 12) & 0x3F), 0x80 | u8((r >> 6) & 0x3F), 0x80 | u8(r & 0x3F)
	return b, 4
}

// ---- dialogs ----

Dialog :: enum {
	None,
	Magnet,
	Add,
	Limits,
	Create,
	Prefs,
	Label,
	Lang,
}

cr_src, cr_trackers, cr_comment: Field
cr_focus: int
cr_version: i32 = 2 // 1 = v1, 2 = v2, 3 = hybrid
cr_private: bool
cr_done: bool

open_create :: proc() {
	field_set(&cr_src, "")
	field_set(&cr_trackers, "")
	field_set(&cr_comment, "")
	cr_focus, cr_private, cr_done = 0, false, false
	dialog = .Create
}

accept_create :: proc() {
	src := strings.trim_space(field_text(&cr_src))
	if src == "" {return}
	out := pick_save(fmt.tprintf("%s.torrent", filepath.base(src)))
	if out == "" {return}
	// trackers are typed separated by spaces; the shim wants one per line
	trackers := strings.join(strings.fields(field_text(&cr_trackers), context.temp_allocator), "\n", context.temp_allocator)
	start_create(Create_Job {
		source = strings.clone_to_cstring(src),
		out = strings.clone_to_cstring(out),
		comment = strings.clone_to_cstring(field_text(&cr_comment)),
		trackers = strings.clone_to_cstring(trackers),
		version = cr_version,
		priv = 1 if cr_private else 0,
	})
	modal_text = "Creating the torrent (hashing the files)..."
	cr_done = true
}

limits_down, limits_up: Field
limits_focus: int
limits_done: bool

open_limits :: proc() {
	field_set(&limits_down, "0")
	field_set(&limits_up, "0")
	limits_focus = 0
	limits_done = false
	dialog = .Limits
}

accept_limits :: proc() {
	d, _ := strconv.parse_int(strings.trim_space(field_text(&limits_down)))
	u, _ := strconv.parse_int(strings.trim_space(field_text(&limits_up)))
	for i in selected_indexes() {set_limits(session, i, i32(max(d, 0) * 1024), i32(max(u, 0) * 1024))}
	limits_done = true
}

pending_adds: [dynamic]string // .torrent files waiting for their add dialog
add_path: string
add_name: string
add_files: [dynamic]File
add_on: [dynamic]bool
add_field: Field
add_scroll: f32
add_done: bool

open_add :: proc(path: string) {
	err: [256]u8
	name: [256]u8
	fl := make([]File, MAX_ITEMS, context.temp_allocator)
	n := peek(strings.clone_to_cstring(path, context.temp_allocator), raw_data(name[:]), len(name), raw_data(fl), MAX_ITEMS, raw_data(err[:]), len(err))
	if n < 0 {
		modal_text = fmt.tprintf("Cannot read the torrent: %s", cstr(err[:]))
		return
	}
	delete(add_path)
	delete(add_name)
	add_path, add_name = strings.clone(path), strings.clone(cstr(name[:]))
	clear(&add_files)
	clear(&add_on)
	for f in fl[:n] {
		append(&add_files, f)
		append(&add_on, true)
	}
	field_set(&add_field, download_dir())
	add_scroll = 0
	add_done = false
	dialog = .Add
}

accept_add :: proc() {
	prio := make([]i32, len(add_files), context.temp_allocator)
	any_on := false
	for on, i in add_on {
		prio[i] = 4 if on else 0
		any_on ||= on
	}
	if !any_on {return}
	save := strings.trim_space(field_text(&add_field))
	if save == "" {return}
	add_torrent_with(add_path, save, prio)
	add_done = true
}

dialog: Dialog
magnet_field: Field

open_magnet :: proc() {
	dialog = .Magnet
	field_set(&magnet_field, "")
	// a magnet link on the clipboard is the likely thing to add
	if c := strings.trim_space(clipboard_get()); strings.has_prefix(c, "magnet:") {field_set(&magnet_field, c)}
}

button :: proc(x, y, w: f32, label: string, primary := false) -> bool {
	over := hit(x, y, w, 26)
	rrect(x, y, w, 26, 5, th.accent if primary else (th.sel if over else th.hover))
	text(x + (w - text_w(label)) / 2, y + 4.5, label, th.bg if primary && th.dark else th.text)
	return over && ui.press_l
}

// draw_dialog draws the open dialog over the window and returns true on the frame it was accepted.
draw_dialog :: proc(win_w, win_h: f32) -> (accepted: bool) {
	if dialog == .None {return false}
	fill(0, 0, win_w, win_h, Color{0, 0, 0, 120})
	w, h: f32 = 560, 170
	if dialog == .Add {w, h = 640, min(win_h - 40, 460)}
	if dialog == .Limits {h = 230}
	if dialog == .Create {w, h = 640, 270}
	if dialog == .Prefs {w, h = 700, 650}
	if dialog == .Label {w, h = 560, 260}
	if dialog == .Lang {w, h = 760, 340}
	x, y := (win_w - w) / 2, (win_h - h) / 2
	rrect(x - 1, y - 1, w + 2, h + 2, 8, th.border)
	rrect(x, y, w, h, 8, th.menu_bg)

	switch dialog {
	case .None:
	case .Magnet:
		text(x + 20, y + 16, "Add magnet link(s)", th.text)
		text(x + 20, y + 40, "Paste one or more magnet links, separated by spaces.", th.dim)
		draw_field(&magnet_field, x + 20, y + 66, w - 40, true, "magnet:?xt=urn:btih:...")
		if button(x + w - 20 - 80, y + h - 42, 80, "Add", true) || key_pressed(glfw.KEY_ENTER) {accepted = true}
		if button(x + w - 20 - 80 - 90, y + h - 42, 80, "Cancel") || key_pressed(glfw.KEY_ESCAPE) {dialog = .None}
	case .Prefs: draw_prefs(x, y, w, h, &accepted)
	case .Label: draw_labels(x, y, w, h, &accepted)
	case .Lang: draw_lang(x, y, w, h)
	case .Create:
		text(x + 20, y + 16, "Create torrent", th.text)
		fx := x + 130
		fw := w - 150
		labels := [3]string{"Source", "Trackers", "Comment"}
		fields := [3]^Field{&cr_src, &cr_trackers, &cr_comment}
		for l, i in labels {
			fy := y + 50 + f32(i) * 40
			text(x + 20, fy + 5.5, l, th.dim)
			bw: f32 = 0
			if i == 0 {bw = 150}
			if hit(fx, fy, fw - bw, 28) && ui.press_l {cr_focus = i}
			draw_field(fields[i], fx, fy, fw - bw - (8 if bw > 0 else 0), cr_focus == i, "a file or a folder" if i == 0 else ("space-separated URLs, optional" if i == 1 else "optional"))
			if i == 0 {
				if button(x + w - 20 - 70, fy + 1, 70, "Folder") {if p := pick_path(true); p != "" {field_set(&cr_src, p)}}
				if button(x + w - 20 - 70 - 74, fy + 1, 66, "File") {if p := pick_path(false); p != "" {field_set(&cr_src, p)}}
			}
		}
		if key_pressed(glfw.KEY_TAB) {cr_focus = (cr_focus + 1) % 3}
		text(x + 20, y + 175, "Version", th.dim)
		vx := fx
		for v, i in ([3]string{"v1", "Hybrid", "v2"}) {
			vw: f32 = 72
			vers := [3]i32{1, 3, 2}
			ver := vers[i]
			on := cr_version == ver
			over := hit(vx, y + 170, vw, 26)
			rrect(vx, y + 170, vw, 26, 5, th.accent if on else (th.sel if over else th.hover))
			text(vx + (vw - text_w(v)) / 2, y + 174.5, v, th.bg if on && th.dark else th.text)
			if over && ui.press_l {cr_version = ver}
			vx += vw + 6
		}
		pbx := fx + 3 * 78 + 20
		rrect_line(pbx, y + 175, 16, 16, 3, th.accent if cr_private else th.dim)
		if cr_private {text(pbx + 2.5, y + 173.5, "✓", th.accent)}
		text(pbx + 24, y + 174, "Private", th.text)
		if hit(pbx, y + 170, 100, 26) && ui.press_l {cr_private = !cr_private}
		if button(x + w - 20 - 80, y + h - 42, 80, "Create", true) || key_pressed(glfw.KEY_ENTER) {accepted = true}
		if button(x + w - 20 - 80 - 90, y + h - 42, 80, "Cancel") || key_pressed(glfw.KEY_ESCAPE) {dialog = .None}
	case .Limits:
		text(x + 20, y + 16, "Speed limits for the selected torrent(s)", th.text)
		text(x + 20, y + 44, "In KiB/s; 0 means unlimited.", th.dim)
		text(x + 20, y + 76, "Download", th.text)
		text(x + 20, y + 112, "Upload", th.text)
		if hit(x + 120, y + 66, 140, 28) && ui.press_l {limits_focus = 0}
		if hit(x + 120, y + 102, 140, 28) && ui.press_l {limits_focus = 1}
		if key_pressed(glfw.KEY_TAB) {limits_focus = 1 - limits_focus}
		draw_field(&limits_down, x + 120, y + 66, 140, limits_focus == 0)
		draw_field(&limits_up, x + 120, y + 102, 140, limits_focus == 1)
		if button(x + w - 20 - 80, y + h - 42, 80, "OK", true) || key_pressed(glfw.KEY_ENTER) {accepted = true}
		if button(x + w - 20 - 80 - 90, y + h - 42, 80, "Cancel") || key_pressed(glfw.KEY_ESCAPE) {dialog = .None}
	case .Add:
		aw, ah, ax, ay := w, h, x, y
		text_fit(ax + 20, ay + 16, aw - 40, fmt.tprintf("Add torrent: %s", add_name), th.text)
		text(ax + 20, ay + 44, "Save to", th.dim)
		draw_field(&add_field, ax + 20, ay + 62, aw - 40, true)
		text(ax + 20, ay + 100, "Files", th.dim)
		ly, lh := ay + 120, ah - 120 - 56
		total := f32(len(add_files)) * ROW_H
		if hit(ax, ly, aw, lh) {add_scroll -= ui.scroll * ROW_H * 3}
		add_scroll = clamp(add_scroll, 0, max(0, total - lh))
		rrect_line(ax + 20, ly, aw - 40, lh, 4, th.border)
		clip(ax + 21, ly + 1, aw - 42, lh - 2)
		for i := int(add_scroll / ROW_H); i < len(add_files) && f32(i) * ROW_H - add_scroll < lh; i += 1 {
			ry := ly + f32(i) * ROW_H - add_scroll
			bx := ax + 30
			rrect_line(bx, ry + 4, 14, 14, 3, th.accent if add_on[i] else th.dim)
			if add_on[i] {text(bx + 2, ry + 2.5, "✓", th.accent)}
			text_fit(bx + 24, ry + 2.5, aw - 60 - 120, cstr(add_files[i].path[:]), th.text)
			text_fit(ax + aw - 20 - 100, ry + 2.5, 90, size_text(add_files[i].size), th.dim, true)
			if ui.press_l && hit(ax + 21, ry, aw - 42, ROW_H) && hit(ax, ly, aw, lh) {add_on[i] = !add_on[i]}
		}
		unclip()
		by := ay + ah - 42
		if button(ax + aw - 20 - 80, by, 80, "Add", true) || key_pressed(glfw.KEY_ENTER) {accepted = true}
		if button(ax + aw - 20 - 80 - 90, by, 80, "Cancel") || key_pressed(glfw.KEY_ESCAPE) {dialog = .None}
	}
	return
}

key_pressed :: proc(k: i32) -> bool {
	for p in ui.keys {if p == k {return true}}
	return false
}
