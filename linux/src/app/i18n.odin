package app

// Translations. The shared lang/*.json files of the Windows app are embedded in the binary. Our
// English texts are the en-US values, so every string that is drawn is looked up by its English
// text and replaced by the chosen language's version; anything without a match (numbers, names,
// strings built at run time) is drawn as it is.

import "base:runtime"
import "core:encoding/json"
import "core:os"
import "core:slice"
import "core:strings"
import "vendor:glfw"

lang_files := #load_directory("../../../lang")

lang_code: string // "" or "en-US" = English
lang_map: map[string]string // key -> text, for lang_code
english_key: map[string]string // English text (no &) -> key

strip_amp :: proc(s: string) -> string {
	if !strings.contains(s, "&") {return s}
	r, _ := strings.replace_all(s, "&", "", context.temp_allocator)
	return strings.clone(r)
}

load_lang_file :: proc(code: string) -> (out: map[string]string, ok: bool) {
	for f in lang_files {
		if f.name != strings.concatenate({code, ".json"}, context.temp_allocator) {continue}
		v, err := json.parse(f.data)
		if err != nil {return}
		obj, is_obj := v.(json.Object)
		if !is_obj {return}
		for k, val in obj {
			if s, is_s := val.(json.String); is_s {out[strings.clone(k)] = strip_amp(strings.clone(string(s)))}
		}
		return out, true
	}
	return
}

lang_codes :: proc() -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for f in lang_files {append(&out, strings.trim_suffix(f.name, ".json"))}
	slice.sort(out[:])
	return out[:]
}

set_language :: proc(code: string) {
	if english_key == nil {
		if en, ok := load_lang_file("en-US"); ok {
			for k, v in en {
				if v not_in english_key {english_key[v] = k}
			}
		}
	}
	lang_code = strings.clone(code)
	lang_map = nil
	if code == "" || code == "en-US" {return}
	if m, ok := load_lang_file(code); ok {lang_map = m}
}

// detect_language picks the language from the locale variables: "el_GR.UTF-8" -> "el-GR", or any
// file for the same language.
detect_language :: proc() -> string {
	for name in ([]string{"LC_ALL", "LC_MESSAGES", "LANG"}) {
		v := os.get_env(name, context.temp_allocator)
		if v == "" || v == "C" || v == "POSIX" {continue}
		base, _, _ := strings.partition(v, ".")
		code, _ := strings.replace_all(base, "_", "-", context.temp_allocator)
		lang, _, _ := strings.partition(code, "-")
		for c in lang_codes() {
			if c == code {return strings.clone(c)}
		}
		for c in lang_codes() {
			if strings.has_prefix(c, strings.concatenate({lang, "-"}, context.temp_allocator)) {return strings.clone(c)}
		}
	}
	return ""
}

// tr translates an English text; unknown texts come back unchanged.
tr :: proc(s: string) -> string {
	if lang_map == nil || len(s) == 0 {return s}
	if k, ok := english_key[s]; ok {
		if t, ok2 := lang_map[k]; ok2 && t != "" {return t}
		return s
	}
	if strings.has_suffix(s, "...") {
		if k, ok := english_key[s[:len(s) - 3]]; ok {
			if t, ok2 := lang_map[k]; ok2 && t != "" {return strings.concatenate({t, "..."}, context.temp_allocator)}
		}
	}
	return s
}

// ---- the language picker ----

lang_done: bool

open_lang :: proc() {
	lang_done = false
	dialog = .Lang
}

draw_lang :: proc(x, y, w, h: f32) {
	text(x + 20, y + 16, "Language", th.text)
	cx, cy: f32 = x + 20, y + 50
	chips := make([dynamic]string, context.temp_allocator)
	append(&chips, "en-US")
	for c in lang_codes() {
		if c != "en-US" {append(&chips, c)}
	}
	for c in chips {
		cw := text_w(c) + 20
		if cx + cw > x + w - 20 {
			cx = x + 20
			cy += 32
		}
		on := (lang_code == c) || (lang_code == "" && c == "en-US")
		over := hit(cx, cy, cw, 26)
		rrect(cx, cy, cw, 26, 13, th.accent if on else (th.sel if over else th.hover))
		text(cx + 10, cy + 4.5, c, th.bg if on && th.dark else th.text)
		if over && ui.press_l {
			set_language(c)
			save_config()
			lang_done = true
		}
		cx += cw + 6
	}
	if button(x + w - 20 - 80, y + h - 42, 80, "Close") || key_pressed(glfw.KEY_ESCAPE) {dialog = .None}
}

_ :: runtime
