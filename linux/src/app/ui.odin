package app

// Theme, drawing helpers and the per-frame input state. Immediate mode: widgets read `ui` while
// they draw.

import "core:strings"
import nvg "vendor:nanovg"

Color :: struct {
	r, g, b, a: u8,
}

Theme :: struct {
	dark:     bool,
	bg:       Color, // window and list background
	panel:    Color, // menu bar, status bar
	header:   Color, // column header
	text:     Color,
	dim:      Color, // secondary text
	border:   Color,
	sel:      Color, // selected row
	hover:    Color, // hovered row / item
	accent:   Color, // progress fill, focus
	done:     Color, // completed progress
	track:    Color, // progress track
	menu_bg:  Color,
}

THEME_DARK :: Theme {
	dark = true,
	bg = {32, 32, 32, 255},
	panel = {43, 43, 43, 255},
	header = {40, 40, 40, 255},
	text = {232, 232, 232, 255},
	dim = {150, 150, 150, 255},
	border = {70, 70, 70, 255},
	sel = {32, 66, 100, 255},
	hover = {50, 50, 50, 255},
	accent = {53, 177, 225, 255},
	done = {61, 186, 120, 255},
	track = {58, 58, 58, 255},
	menu_bg = {48, 48, 48, 255},
}

THEME_LIGHT :: Theme {
	dark = false,
	bg = {255, 255, 255, 255},
	panel = {240, 240, 240, 255},
	header = {245, 245, 245, 255},
	text = {20, 20, 20, 255},
	dim = {110, 110, 110, 255},
	border = {200, 200, 200, 255},
	sel = {205, 232, 255, 255},
	hover = {232, 240, 250, 255},
	accent = {53, 177, 225, 255},
	done = {61, 186, 120, 255},
	track = {224, 224, 224, 255},
	menu_bg = {252, 252, 252, 255},
}

th: Theme = THEME_DARK

// What the input handler collected for the frame being drawn.
UI :: struct {
	mx, my:    f32, // pointer, logical units
	scale:     f32,
	press_l:   bool, // went down this frame
	press_r:   bool,
	release_l: bool,
	down_l:    bool, // held
	scroll:    f32, // wheel, positive = up
	scroll_x:  f32, // horizontal wheel or touchpad
	keys:      [dynamic]i32,
	chars:     [dynamic]rune,
}

ui: UI

hit :: proc(x, y, w, h: f32) -> bool {
	return ui.mx >= x && ui.mx < x + w && ui.my >= y && ui.my < y + h
}

// ---- drawing ----

fill :: proc(x, y, w, h: f32, c: Color) {
	nvg.BeginPath(vg)
	nvg.Rect(vg, x, y, w, h)
	nvg.FillColor(vg, nvg_color(c))
	nvg.Fill(vg)
}

rrect :: proc(x, y, w, h, r: f32, c: Color) {
	nvg.BeginPath(vg)
	nvg.RoundedRect(vg, x, y, w, h, r)
	nvg.FillColor(vg, nvg_color(c))
	nvg.Fill(vg)
}

rrect_line :: proc(x, y, w, h, r: f32, c: Color, width: f32 = 1) {
	nvg.BeginPath(vg)
	nvg.RoundedRect(vg, x + 0.5, y + 0.5, w - 1, h - 1, r)
	nvg.StrokeColor(vg, nvg_color(c))
	nvg.StrokeWidth(vg, width)
	nvg.Stroke(vg)
}

line :: proc(x1, y1, x2, y2: f32, c: Color, width: f32 = 1) {
	nvg.BeginPath(vg)
	nvg.MoveTo(vg, x1, y1)
	nvg.LineTo(vg, x2, y2)
	nvg.StrokeColor(vg, nvg_color(c))
	nvg.StrokeWidth(vg, width)
	nvg.Stroke(vg)
}

text_w :: proc(s: string) -> f32 {
	return nvg.TextBounds(vg, 0, 0, s)
}

// text draws s with its top-left at (x, y).
text :: proc(x, y: f32, s: string, c: Color) {
	nvg.FillColor(vg, nvg_color(c))
	nvg.Text(vg, x, y, s)
}

LINE_H :: 17 // the height of one text line, logical units (14 px em)

// text_fit draws s in the width w, cut with an ellipsis when it does not fit. right aligns it.
text_fit :: proc(x, y, w: f32, s: string, c: Color, right := false) {
	if w <= 4 {return}
	str := s
	tw := text_w(str)
	if tw > w {
		// drop runes from the end until "…" fits
		end := len(str)
		for end > 0 {
			end -= 1
			for end > 0 && (str[end] & 0xC0) == 0x80 {end -= 1}
			cut := strings.concatenate({str[:end], "…"}, context.temp_allocator)
			if text_w(cut) <= w {
				str = cut
				tw = text_w(cut)
				break
			}
		}
		if end == 0 {return}
	}
	tx := x + (w - tw if right else 0)
	text(tx, y, str, c)
}

// ---- frame input ----

// begin_input turns the queued events into the frame's flags; the key and char lists are kept
// for the widgets that need them.
begin_input :: proc() {
	ui.press_l, ui.press_r, ui.release_l, ui.scroll, ui.scroll_x = false, false, false, 0, 0
	clear(&ui.keys)
	clear(&ui.chars)
	for e in events {
		switch v in e {
		case Ev_Move: ui.mx, ui.my = v.x * to_ui, v.y * to_ui
		case Ev_Press:
			if v.button == 0 {ui.press_l = true; ui.down_l = true} else {ui.press_r = true}
		case Ev_Release:
			if v.button == 0 {ui.release_l = true; ui.down_l = false}
		case Ev_Scroll:
			ui.scroll += v.dy
			ui.scroll_x += v.dx
		case Ev_Key: append(&ui.keys, v.key)
		case Ev_Char: append(&ui.chars, v.r)
		}
	}
	clear(&events)
}
