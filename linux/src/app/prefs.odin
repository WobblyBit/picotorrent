package app

// Preferences: where downloads go, the connection, queue limits and the proxy. Kept in gui.ini and
// pushed to libtorrent with apply_prefs.

import "core:strconv"
import "core:strings"
import "vendor:glfw"

Prefs :: struct {
	save:             string, // "" = ~/Downloads
	port, down, up:   int, // down and up in KiB/s, 0 = unlimited
	act_dl, act_seed: int, // 0 = unlimited
	dht, lsd, nat:    bool,
	proxy:            int, // 0 none, 1 SOCKS5, 2 HTTP
	phost:            string,
	pport:            int,
}

prefs := Prefs {
	port     = 6881,
	act_dl   = 3,
	act_seed = 5,
	dht      = true,
	lsd      = true,
	nat      = true,
	pport    = 1080,
}

PF_SAVE :: 0
PF_PORT :: 1
PF_DOWN :: 2
PF_UP :: 3
PF_ACTDL :: 4
PF_ACTSEED :: 5
PF_HOST :: 6
PF_PPORT :: 7

pf: [8]Field
pf_focus: int
pf_done: bool
pf_dht, pf_lsd, pf_nat: bool
pf_proxy: int

apply_prefs :: proc() {
	s := Settings {
		listen_port      = i32(prefs.port),
		down_limit       = i32(prefs.down * 1024),
		up_limit         = i32(prefs.up * 1024),
		dht              = i32(prefs.dht),
		lsd              = i32(prefs.lsd),
		nat              = i32(prefs.nat),
		proxy_type       = i32(prefs.proxy),
		proxy_port       = i32(prefs.pport),
		active_downloads = i32(prefs.act_dl),
		active_seeds     = i32(prefs.act_seed),
	}
	n := min(len(prefs.phost), len(s.proxy_host) - 1)
	copy(s.proxy_host[:n], prefs.phost[:n])
	apply_settings(session, &s)
}

open_prefs :: proc() {
	field_set(&pf[PF_SAVE], prefs.save if prefs.save != "" else download_dir())
	field_set(&pf[PF_PORT], itoa(prefs.port))
	field_set(&pf[PF_DOWN], itoa(prefs.down))
	field_set(&pf[PF_UP], itoa(prefs.up))
	field_set(&pf[PF_ACTDL], itoa(prefs.act_dl))
	field_set(&pf[PF_ACTSEED], itoa(prefs.act_seed))
	field_set(&pf[PF_HOST], prefs.phost)
	field_set(&pf[PF_PPORT], itoa(prefs.pport))
	pf_dht, pf_lsd, pf_nat, pf_proxy = prefs.dht, prefs.lsd, prefs.nat, prefs.proxy
	pf_focus, pf_done = 0, false
	dialog = .Prefs
}

parse_num :: proc(f: ^Field, lo, hi, fallback: int) -> int {
	v, ok := strconv.parse_int(strings.trim_space(field_text(f)))
	if !ok {return fallback}
	return clamp(v, lo, hi)
}

accept_prefs :: proc() {
	save := strings.trim_space(field_text(&pf[PF_SAVE]))
	prefs.save = strings.clone(save) if save != download_dir_default() else ""
	prefs.port = parse_num(&pf[PF_PORT], 1, 65535, 6881)
	prefs.down = parse_num(&pf[PF_DOWN], 0, 10_000_000, 0)
	prefs.up = parse_num(&pf[PF_UP], 0, 10_000_000, 0)
	prefs.act_dl = parse_num(&pf[PF_ACTDL], 0, 1000, 3)
	prefs.act_seed = parse_num(&pf[PF_ACTSEED], 0, 1000, 5)
	prefs.dht, prefs.lsd, prefs.nat, prefs.proxy = pf_dht, pf_lsd, pf_nat, pf_proxy
	prefs.phost = strings.clone(strings.trim_space(field_text(&pf[PF_HOST])))
	prefs.pport = parse_num(&pf[PF_PPORT], 1, 65535, 1080)
	apply_prefs()
	save_config()
	pf_done = true
}

download_dir_default :: proc() -> string {
	return strings.concatenate({home(), "/Downloads"}, context.temp_allocator)
}

check :: proc(x, y: f32, label: string, on: ^bool) {
	rrect_line(x, y, 16, 16, 3, th.accent if on^ else th.dim)
	if on^ {text(x + 2.5, y - 1.5, "✓", th.accent)}
	text(x + 24, y - 0.5, label, th.text)
	if hit(x, y - 4, 200, 24) && ui.press_l {on^ = !on^}
}

draw_prefs :: proc(x, y, w, h: f32, accepted: ^bool) {
	text(x + 20, y + 16, "Preferences", th.text)
	text(x + 20, y + 52, "Download folder", th.dim)
	rows := [?]struct {
		label: string,
		id:    int,
	}{{"Listen port", PF_PORT}, {"Download limit (KiB/s)", PF_DOWN}, {"Upload limit (KiB/s)", PF_UP}, {"Active downloads", PF_ACTDL}, {"Active seeds", PF_ACTSEED}}
	if hit(x + 20, y + 70, w - 40, 28) && ui.press_l {pf_focus = PF_SAVE}
	draw_field(&pf[PF_SAVE], x + 20, y + 70, w - 40, pf_focus == PF_SAVE)
	for r, i in rows {
		fy := y + 120 + f32(i) * 40
		text(x + 20, fy + 5.5, r.label, th.text)
		if hit(x + 200, fy, 110, 28) && ui.press_l {pf_focus = r.id}
		draw_field(&pf[r.id], x + 200, fy, 110, pf_focus == r.id)
	}
	text(x + 20, y + 322, "0 = unlimited. Limits and the port apply at once.", th.dim)

	rx := x + 370
	text(rx, y + 126, "Network", th.dim)
	check(rx, y + 152, "DHT", &pf_dht)
	check(rx, y + 182, "Local peer discovery", &pf_lsd)
	check(rx, y + 212, "UPnP and NAT-PMP", &pf_nat)
	text(rx, y + 248, "Proxy", th.dim)
	for t, i in ([3]string{"None", "SOCKS5", "HTTP"}) {
		bx := rx + f32(i) * 82
		on := pf_proxy == i
		over := hit(bx, y + 270, 76, 26)
		rrect(bx, y + 270, 76, 26, 5, th.accent if on else (th.sel if over else th.hover))
		text(bx + (76 - text_w(t)) / 2, y + 274.5, t, th.bg if on && th.dark else th.text)
		if over && ui.press_l {pf_proxy = i}
	}
	if pf_proxy != 0 {
		if hit(rx, y + 304, 190, 28) && ui.press_l {pf_focus = PF_HOST}
		if hit(rx + 198, y + 304, 90, 28) && ui.press_l {pf_focus = PF_PPORT}
		draw_field(&pf[PF_HOST], rx, y + 304, 190, pf_focus == PF_HOST, "host")
		draw_field(&pf[PF_PPORT], rx + 198, y + 304, 90, pf_focus == PF_PPORT)
	}
	if key_pressed(glfw.KEY_TAB) {pf_focus = (pf_focus + 1) % len(pf)}

	if button(x + w - 20 - 80, y + h - 42, 80, "OK", true) || key_pressed(glfw.KEY_ENTER) {accepted^ = true}
	if button(x + w - 20 - 80 - 90, y + h - 42, 80, "Cancel") || key_pressed(glfw.KEY_ESCAPE) {dialog = .None}
}
