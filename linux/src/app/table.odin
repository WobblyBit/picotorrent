package app

// The torrent list: header (sort, resize, column menu), rows, selection, custom cells (progress
// pill, version badge), scrolling.

import "core:strings"
import "vendor:glfw"
import nvg "vendor:nanovg"

ROW_H :: 22
HEAD_H :: 24

widths: [Col]f32
hidden: [Col]bool
scroll_y: f32
scroll_x: f32
resizing: Col
resizing_on: bool
resize_x0, resize_w0: f32
last_row_clicked: string

table_init :: proc() {
	for c in Col {
		widths[c] = COLS[c].width
		hidden[c] = COLS[c].hidden
	}
}

visible_width :: proc() -> f32 {
	w: f32
	for c in Col {if !hidden[c] {w += widths[c]}}
	return w
}

// draw_table draws the list in the box x,y,w,h. `live` is false while a popup owns the pointer.
draw_table :: proc(x, y, w, h: f32, live: bool) {
	fill(x, y, w, h, th.bg)

	max_sx := max(0, visible_width() - w)
	if live && hit(x, y, w, h) {
		scroll_x -= ui.scroll_x * 40
		if current_mods().shift {scroll_x -= ui.scroll * 40}
	}
	scroll_x = clamp(scroll_x, 0, max_sx)

	// ---- header ----
	fill(x, y, w, HEAD_H, th.header)
	line(x, y + HEAD_H - 0.5, x + w, y + HEAD_H - 0.5, th.border)
	clip(x, y, w, HEAD_H)
	cx := x - scroll_x
	for c in Col {
		if hidden[c] {continue}
		cw := widths[c]
		hot := live && hit(cx, y, cw, HEAD_H)
		if hot && !resizing_on {fill(cx, y, cw - 1, HEAD_H - 1, th.hover)}
		text_fit(cx + 8, y + 4, cw - 16 - (12 if sort_col == c else 0), COLS[c].title, th.text, COLS[c].right)
		if sort_col == c { 	// sort arrow
			ax := cx + cw - 12
			ay := y + HEAD_H / 2
			nvg.BeginPath(vg)
			if sort_asc {
				nvg.MoveTo(vg, ax - 3, ay + 2); nvg.LineTo(vg, ax + 3, ay + 2); nvg.LineTo(vg, ax, ay - 2)
			} else {
				nvg.MoveTo(vg, ax - 3, ay - 2); nvg.LineTo(vg, ax + 3, ay - 2); nvg.LineTo(vg, ax, ay + 2)
			}
			nvg.ClosePath(vg)
			nvg.FillColor(vg, nvg_color(th.dim))
			nvg.Fill(vg)
		}
		line(cx + cw - 0.5, y + 4, cx + cw - 0.5, y + HEAD_H - 4, th.border)

		if live && ui.press_l && hit(cx, y, cw, HEAD_H) {
			if ui.mx > cx + cw - 5 { 	// the column's right edge: start resizing
				resizing, resizing_on, resize_x0, resize_w0 = c, true, ui.mx, widths[c]
			} else {
				if sort_col == c {sort_asc = !sort_asc} else {sort_col, sort_asc = c, true}
				resort()
			}
		}
		if live && ui.press_r && hit(cx, y, cw, HEAD_H) {popup_columns(ui.mx, ui.my)}
		cx += cw
	}
	unclip()
	if resizing_on {
		if ui.down_l {widths[resizing] = max(40, resize_w0 + ui.mx - resize_x0)} else {resizing_on = false}
	}

	// ---- rows ----
	body_y := y + HEAD_H
	body_h := h - HEAD_H
	total := f32(len(view)) * ROW_H
	max_scroll := max(0, total - body_h)
	if live && hit(x, body_y, w, body_h) && !current_mods().shift {scroll_y -= ui.scroll * ROW_H * 3}
	scroll_y = clamp(scroll_y, 0, max_scroll)

	clip(x, body_y, w, body_h)
	first := int(scroll_y / ROW_H)
	for i := first; i < len(view) && f32(i) * ROW_H - scroll_y < body_h; i += 1 {
		r := &rows[view[i]]
		ry := body_y + f32(i) * ROW_H - scroll_y
		is_sel := selected[r.id]
		over := live && hit(x, ry, w, ROW_H) && hit(x, body_y, w, body_h)
		if is_sel {fill(x, ry, w, ROW_H, th.sel)} else if over {fill(x, ry, w, ROW_H, th.hover)}

		cx = x - scroll_x
		for c in Col {
			if hidden[c] {continue}
			cw := widths[c]
			#partial switch c {
			case .Progress: draw_progress(cx + 6, ry, cw - 12, r.st.progress, r.st.paused != 0)
			case .Version: draw_version(cx + 6, ry, version_rank(&r.st))
			case: text_fit(cx + 8, ry + 2.5, cw - 16, cell_text(r, c), th.text, COLS[c].right)
			}
			cx += cw
		}

		if over && ui.press_l {
			m := current_mods()
			if m.ctrl {if is_sel {sel_remove(r.id)} else {sel_add(r.id)}} else {
				sel_clear()
				sel_add(r.id)
			}
		}
		if over && ui.press_r {
			if !is_sel {
				sel_clear()
				sel_add(r.id)
			}
			popup_torrent(ui.mx, ui.my)
		}
	}
	unclip()

	// clicking empty space clears the selection
	if live && ui.press_l && hit(x, body_y, w, body_h) && ui.my > body_y + total - scroll_y {sel_clear()}

	// slim scrollbars
	if max_sx > 0 {
		bw := max(24, w * w / visible_width())
		rrect(x + (w - bw) * (scroll_x / max_sx), y + h - 7, bw, 4, 2, Color{th.dim.r, th.dim.g, th.dim.b, 110})
	}
	if total > body_h {
		bh := max(24, body_h * body_h / total)
		by := body_y + (body_h - bh) * (scroll_y / max_scroll)
		rrect(x + w - 6, by, 4, bh, 2, Color{th.dim.r, th.dim.g, th.dim.b, 110})
	}

	// keys: up/down move the selection, ctrl+A selects all
	if live {
		for k in ui.keys {
			switch k {
			case glfw.KEY_DOWN: move_selection(1)
			case glfw.KEY_UP: move_selection(-1)
			case glfw.KEY_A:
				if current_mods().ctrl {for r in rows {sel_add(r.id)}}
			}
		}
	}
}

move_selection :: proc(d: int) {
	if len(view) == 0 {return}
	cur := -1
	for vi, i in view {
		if selected[rows[vi].id] {cur = i}
	}
	n := clamp(cur + d if cur >= 0 else 0, 0, len(view) - 1)
	sel_clear()
	sel_add(rows[view[n]].id)
	// keep it on screen
	// (the visible height is only known to the caller; a row is small enough to just follow)
	ty := f32(n) * ROW_H
	if ty < scroll_y {scroll_y = ty}
}

// the slim rounded bar of the Windows app: quiet track, accent fill (green when complete) and a
// small percentage.
draw_progress :: proc(x, y, w, progress: f32, paused: bool) {
	pct := int(clamp(progress, 0, 1) * 100)
	label := strings.concatenate({itoa(pct), "%"}, context.temp_allocator)
	tw := text_w("100%")
	bw := w - tw - 8
	bar_h: f32 = 5
	by := y + (ROW_H - bar_h) / 2
	rrect(x, by, bw, bar_h, bar_h / 2, th.track)
	fillw := bw * clamp(progress, 0, 1)
	if fillw > 0 {
		c := th.done if progress >= 1 else th.accent
		if paused {c = th.dim}
		rrect(x, by, max(fillw, bar_h), bar_h, bar_h / 2, c)
	}
	text(x + w - text_w(label), y + 2.5, label, th.dim)
}

// the version pill: grey v1 (legacy), teal v2, and a hybrid with both labels.
draw_version :: proc(x, y: f32, rank: int) {
	if rank == 0 {return}
	grey := Color{138, 148, 158, 255}
	teal := Color{38, 166, 154, 255}
	mid := Color{111, 176, 173, 255}
	nvg.FontSize(vg, font_size * 0.78)
	defer nvg.FontSize(vg, font_size)
	h: f32 = 14
	py := y + (ROW_H - h) / 2
	switch rank {
	case 1, 3:
		label := "v1" if rank == 1 else "v2"
		c := grey if rank == 1 else teal
		w := text_w(label) + 14
		rrect_line(x, py, w, h, h / 2, c)
		text(x + 7, py + 1.5, label, c)
	case 2:
		w1, w2 := text_w("v1"), text_w("v2")
		w := w1 + w2 + 30
		rrect_line(x, py, w, h, h / 2, mid)
		text(x + 7, py + 1.5, "v1", grey)
		line(x + 7 + w1 + 7, py + 4, x + 7 + w1 + 7, py + h - 4, Color{mid.r, mid.g, mid.b, 150})
		text(x + 7 + w1 + 14, py + 1.5, "v2", teal)
	}
}

itoa :: proc(n: int) -> string {
	buf := make([]u8, 24, context.temp_allocator)
	i := len(buf)
	v := n
	if v == 0 {
		i -= 1
		buf[i] = '0'
	}
	for v > 0 {
		i -= 1
		buf[i] = u8('0' + v % 10)
		v /= 10
	}
	return string(buf[i:])
}
