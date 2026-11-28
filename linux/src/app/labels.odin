package app

// Labels: a free-text tag per torrent, kept in labels.txt by info hash, and a filter on them.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "vendor:glfw"

labels: map[string]string // row id -> label
label_filter: string // "" = show all
label_field: Field
label_mode: int // 0 = set on the selection, 1 = pick a filter
label_done: bool

label_of :: proc(id: string) -> string {
	return labels[id] or_else ""
}

all_labels :: proc() -> []string {
	seen := make(map[string]bool, context.temp_allocator)
	out := make([dynamic]string, context.temp_allocator)
	for _, v in labels {
		if v != "" && !seen[v] {
			seen[v] = true
			append(&out, v)
		}
	}
	slice.sort(out[:])
	return out[:]
}

load_labels :: proc() {
	data, err := os.read_entire_file(fmt.tprintf("%s/labels.txt", config_dir()), context.temp_allocator)
	if err != nil {return}
	for l in strings.split_lines(string(data), context.temp_allocator) {
		k, _, v := strings.partition(l, "\t")
		if k != "" && v != "" {labels[strings.clone(k)] = strings.clone(v)}
	}
}

save_labels :: proc() {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	for k, v in labels {fmt.sbprintf(&b, "%s\t%s\n", k, v)}
	mkdirs(config_dir())
	_ = os.write_entire_file(fmt.tprintf("%s/labels.txt", config_dir()), transmute([]u8)strings.to_string(b))
}

open_labels :: proc(mode: int) {
	label_mode, label_done = mode, false
	field_set(&label_field, "")
	if mode == 0 {
		for &r in rows {
			if selected[r.id] {
				field_set(&label_field, label_of(r.id))
				break
			}
		}
	}
	dialog = .Label
}

accept_label :: proc() {
	if label_mode == 0 {
		v := strings.trim_space(field_text(&label_field))
		for &r in rows {
			if !selected[r.id] {continue}
			if v == "" {delete_key(&labels, r.id)} else {labels[strings.clone(r.id)] = strings.clone(v)}
		}
		save_labels()
		resort()
	}
	label_done = true
}

draw_labels :: proc(x, y, w, h: f32, accepted: ^bool) {
	text(x + 20, y + 16, "Label" if label_mode == 0 else "Show only torrents with a label", th.text)
	cy := y + 50
	if label_mode == 0 {
		text(x + 20, cy, "Type a label (empty removes it), or pick one:", th.dim)
		draw_field(&label_field, x + 20, cy + 22, w - 40, true)
		cy += 64
	}
	cx := x + 20
	chips := make([dynamic]string, context.temp_allocator)
	if label_mode == 1 {append(&chips, "")}
	append(&chips, ..all_labels())
	for c in chips {
		name := c if c != "" else "All"
		cw := text_w(name) + 24
		if cx + cw > x + w - 20 {
			cx = x + 20
			cy += 34
		}
		on := (label_mode == 1 && label_filter == c) || (label_mode == 0 && field_text(&label_field) == c)
		over := hit(cx, cy, cw, 26)
		rrect(cx, cy, cw, 26, 13, th.accent if on else (th.sel if over else th.hover))
		text(cx + 12, cy + 4.5, name, th.bg if on && th.dark else th.text)
		if over && ui.press_l {
			if label_mode == 0 {field_set(&label_field, c)} else {
				label_filter = strings.clone(c)
				resort()
				label_done = true
			}
		}
		cx += cw + 8
	}
	if label_mode == 1 && len(chips) == 1 {text(x + 20, cy + 40, "No labels yet. Give a torrent one from its context menu.", th.dim)}
	if label_mode == 0 {
		if button(x + w - 20 - 80, y + h - 42, 80, "OK", true) || key_pressed(glfw.KEY_ENTER) {accepted^ = true}
		if button(x + w - 20 - 80 - 90, y + h - 42, 80, "Cancel") || key_pressed(glfw.KEY_ESCAPE) {dialog = .None}
	} else {
		if button(x + w - 20 - 80, y + h - 42, 80, "Close") || key_pressed(glfw.KEY_ESCAPE) {dialog = .None}
	}
}
