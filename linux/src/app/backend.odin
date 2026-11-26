package app

// The window, input and drawing backend: GLFW (window and events), OpenGL 3.3 core and NanoVG
// (shapes and text). Based on xz-plus's backend. Everything above this file works in logical
// units; the monitor's content scale is applied when a frame starts.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import gl "vendor:OpenGL"
import "vendor:glfw"
import nvg "vendor:nanovg"
import nvg_gl "vendor:nanovg/gl"

Event :: union {
	Ev_Key,
	Ev_Char,
	Ev_Press,
	Ev_Release,
	Ev_Move,
	Ev_Scroll,
}

Ev_Key :: struct {
	key: i32,
}
Ev_Char :: struct {
	r: rune,
}
Ev_Press :: struct {
	button: i32, // 0 left, 1 right
}
Ev_Release :: struct {
	button: i32,
}
Ev_Move :: struct {
	x, y: f32, // window units
}
Ev_Scroll :: struct {
	dx, dy: f32,
}

Mods :: struct {
	ctrl, shift: bool,
}

WIN_W :: 1280
WIN_H :: 720
MIN_W :: 800
MIN_H :: 480
FONT_PX :: 14

win: glfw.WindowHandle
vg: ^nvg.Context
events: [dynamic]Event
to_ui: f32 = 1 // window units -> logical units
font_id: int
font_size: f32
shot_path: string // developer aid: save a frame here and quit
shot_frames: int // frames drawn so far
last_click: struct {
	at:   time.Tick,
	x, y: f32,
	n:    u8,
}

backend_init :: proc() -> bool {
	glfw.SetErrorCallback(proc "c" (code: i32, desc: cstring) {
		context = runtime.default_context()
		fmt.eprintln("picotorrent: glfw:", desc)
	})
	if !glfw.Init() {
		fmt.eprintln("picotorrent: cannot start GLFW")
		return false
	}
	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 3)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 3)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
	glfw.WindowHint(glfw.OPENGL_FORWARD_COMPAT, 1)
	glfw.WindowHint(glfw.STENCIL_BITS, 8)
	win = glfw.CreateWindow(WIN_W, WIN_H, "PicoTorrent", nil, nil)
	if win == nil {
		fmt.eprintln("picotorrent: cannot open a window (OpenGL 3.3 is needed)")
		return false
	}
	glfw.MakeContextCurrent(win)
	glfw.SwapInterval(1)
	gl.load_up_to(3, 3, glfw.gl_set_proc_address)
	vg = nvg_gl.Create({.ANTI_ALIAS, .STENCIL_STROKES})
	if vg == nil {
		fmt.eprintln("picotorrent: cannot start the renderer")
		return false
	}
	if !load_font() {
		fmt.eprintln("picotorrent: no usable font found")
		return false
	}

	u := content_scale()
	pxr := pixel_ratio()
	glfw.SetWindowSize(win, i32(f32(WIN_W) * u / pxr), i32(f32(WIN_H) * u / pxr))
	glfw.SetWindowSizeLimits(win, i32(f32(MIN_W) * u / pxr), i32(f32(MIN_H) * u / pxr), glfw.DONT_CARE, glfw.DONT_CARE)

	glfw.SetKeyCallback(win, proc "c" (_: glfw.WindowHandle, key, _, action, _: i32) {
		if action == glfw.RELEASE {return}
		context = runtime.default_context()
		k := key
		if k == glfw.KEY_KP_ENTER {k = glfw.KEY_ENTER}
		append(&events, Ev_Key{k})
	})
	glfw.SetCharCallback(win, proc "c" (_: glfw.WindowHandle, r: rune) {
		context = runtime.default_context()
		append(&events, Ev_Char{r})
	})
	glfw.SetMouseButtonCallback(win, proc "c" (_: glfw.WindowHandle, button, action, _: i32) {
		if button != glfw.MOUSE_BUTTON_LEFT && button != glfw.MOUSE_BUTTON_RIGHT {return}
		context = runtime.default_context()
		b: i32 = 0 if button == glfw.MOUSE_BUTTON_LEFT else 1
		if action == glfw.PRESS {append(&events, Ev_Press{b})} else {append(&events, Ev_Release{b})}
	})
	glfw.SetCursorPosCallback(win, proc "c" (_: glfw.WindowHandle, x, y: f64) {
		context = runtime.default_context()
		append(&events, Ev_Move{f32(x), f32(y)})
	})
	glfw.SetScrollCallback(win, proc "c" (_: glfw.WindowHandle, dx, dy: f64) {
		context = runtime.default_context()
		append(&events, Ev_Scroll{f32(dx), f32(dy)})
	})
	return true
}

backend_quit :: proc() {
	if vg != nil {nvg_gl.Destroy(vg)}
	if win != nil {glfw.DestroyWindow(win)}
	glfw.Terminate()
}

wait_events :: proc(timeout: f64) {glfw.WaitEventsTimeout(timeout)}
wake :: proc() {glfw.PostEmptyEvent()}
should_close :: proc() -> bool {return bool(glfw.WindowShouldClose(win))}
request_close :: proc() {glfw.SetWindowShouldClose(win, true)}

current_mods :: proc() -> Mods {
	down :: proc(k: i32) -> bool {return glfw.GetKey(win, k) == glfw.PRESS}
	return {
		ctrl = down(glfw.KEY_LEFT_CONTROL) || down(glfw.KEY_RIGHT_CONTROL),
		shift = down(glfw.KEY_LEFT_SHIFT) || down(glfw.KEY_RIGHT_SHIFT),
	}
}

// click_count is 1 for a click, 2 for a quick second click in the same place.
click_count :: proc() -> u8 {
	now := time.tick_now()
	dt := time.duration_milliseconds(time.tick_diff(last_click.at, now))
	dx, dy := ui.mx - last_click.x, ui.my - last_click.y
	if last_click.n == 1 && dt < 450 && dx * dx + dy * dy < 36 {
		last_click.n = 2
	} else {
		last_click.n = 1
	}
	last_click.at, last_click.x, last_click.y = now, ui.mx, ui.my
	return last_click.n
}

clipboard_set :: proc(s: string) {
	glfw.SetClipboardString(win, strings.clone_to_cstring(s, context.temp_allocator))
}

content_scale :: proc() -> f32 {
	sx, _ := glfw.GetWindowContentScale(win)
	return max(sx, 1)
}

pixel_ratio :: proc() -> f32 {
	ww, _ := glfw.GetWindowSize(win)
	fw, _ := glfw.GetFramebufferSize(win)
	if ww <= 0 {return 1}
	return f32(fw) / f32(ww)
}

// begin_frame starts a frame and returns the window's size in logical units (0 while minimised).
begin_frame :: proc() -> (w, h: f32) {
	fw, fh := glfw.GetFramebufferSize(win)
	if fw <= 0 || fh <= 0 {return 0, 0}
	u := content_scale()
	ui.scale = u
	to_ui = pixel_ratio() / u
	gl.Viewport(0, 0, fw, fh)
	gl.ClearColor(f32(th.bg.r) / 255, f32(th.bg.g) / 255, f32(th.bg.b) / 255, 1)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.STENCIL_BUFFER_BIT)
	nvg.BeginFrame(vg, f32(fw) / u, f32(fh) / u, u)
	nvg.FontFaceId(vg, font_id)
	nvg.FontSize(vg, font_size)
	nvg.TextAlign(vg, .LEFT, .TOP)
	return f32(fw) / u, f32(fh) / u
}

end_frame :: proc() {
	nvg.EndFrame(vg)
	shot_frames += 1
	if shot_path != "" && shot_frames == shot_at { 	// let the window settle first
		save_screenshot(shot_path)
		request_close()
	}
	glfw.SwapBuffers(win)
}

shot_at := 12

// save_screenshot writes the frame just drawn as a 24-bit BMP.
save_screenshot :: proc(path: string) {
	fw, fh := glfw.GetFramebufferSize(win)
	px := make([]u8, int(fw) * int(fh) * 4, context.temp_allocator)
	gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
	gl.ReadPixels(0, 0, fw, fh, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(px))
	row := (int(fw) * 3 + 3) & ~int(3)
	out := make([]u8, 54 + row * int(fh), context.temp_allocator)
	put32 :: proc(b: []u8, o: int, v: u32) {for i in 0 ..< 4 {b[o + i] = u8(v >> u32(8 * i))}}
	out[0], out[1] = 'B', 'M'
	put32(out, 2, u32(len(out)))
	put32(out, 10, 54)
	put32(out, 14, 40)
	put32(out, 18, u32(fw))
	put32(out, 22, u32(fh))
	out[26], out[28] = 1, 24
	put32(out, 34, u32(row * int(fh)))
	for y in 0 ..< int(fh) {
		for x in 0 ..< int(fw) {
			s := (y * int(fw) + x) * 4
			d := 54 + y * row + x * 3
			out[d], out[d + 1], out[d + 2] = px[s + 2], px[s + 1], px[s]
		}
	}
	_ = os.write_entire_file(path, out)
}

// ---- drawing ----

nvg_color :: proc(c: Color) -> nvg.Color {return nvg.RGBA(c.r, c.g, c.b, c.a)}
clip :: proc(x, y, w, h: f32) {nvg.Scissor(vg, x, y, w, h)}
unclip :: proc() {nvg.ResetScissor(vg)}

// ---- the font ----

FONT_NAMES :: []string{"DejaVuSans.ttf", "LiberationSans-Regular.ttf", "NotoSans-Regular.ttf", "Roboto-Regular.ttf", "Ubuntu-R.ttf", "FreeSans.ttf"}
FONT_DIRS :: []string{"/usr/share/fonts", "/usr/local/share/fonts", "/usr/X11R6/lib/X11/fonts", "/run/current-system/sw/share/X11/fonts"}

find_font :: proc(dir, name: string, depth := 0) -> string {
	files, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {return ""}
	for f in files {
		if f.type != .Directory && strings.equal_fold(f.name, name) {return strings.clone(f.fullpath, context.temp_allocator)}
	}
	if depth >= 5 {return ""}
	for f in files {
		if f.type == .Directory {
			if p := find_font(f.fullpath, name, depth + 1); p != "" {return p}
		}
	}
	return ""
}

load_font :: proc() -> bool {
	for name in FONT_NAMES {
		for dir in FONT_DIRS {
			p := find_font(dir, name)
			if p == "" {continue}
			data, err := os.read_entire_file(p, context.allocator)
			if err != nil {continue}
			id := nvg.CreateFontMem(vg, "ui", data, false)
			if id < 0 {
				delete(data)
				continue
			}
			font_id = id
			font_size = FONT_PX * em_factor(data)
			return true
		}
	}
	return false
}

// em_factor is the ratio of a font's line height to its em square: NanoVG's size is the line
// height, and we want the em to be FONT_PX.
em_factor :: proc(d: []u8) -> f32 {
	be16 :: proc(d: []u8, o: int) -> int {
		if o < 0 || o + 2 > len(d) {return 0}
		return int(d[o]) << 8 | int(d[o + 1])
	}
	s16 :: proc(d: []u8, o: int) -> int {
		v := be16(d, o)
		return v - 0x10000 if v >= 0x8000 else v
	}
	head, hhea := -1, -1
	for i in 0 ..< be16(d, 4) {
		rec := 12 + 16 * i
		if rec + 16 > len(d) {break}
		off := be16(d, rec + 8) << 16 | be16(d, rec + 10)
		switch string(d[rec:rec + 4]) {
		case "head": head = off
		case "hhea": hhea = off
		}
	}
	if head < 0 || hhea < 0 {return 1.2}
	upem := be16(d, head + 18)
	if upem == 0 {return 1.2}
	return f32(s16(d, hhea + 4) - s16(d, hhea + 6)) / f32(upem)
}
