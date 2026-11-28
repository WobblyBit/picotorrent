package app

// Linux side: the file picker (zenity or kdialog on a thread, so the window keeps drawing), the
// config folder, and the small settings file.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"

picked: [dynamic]string // files chosen in the dialog, taken by the main loop
picked_mu: sync.Mutex

have :: proc(program: string) -> bool {
	st, _, _, err := os.process_exec({command = {"sh", "-c", strings.concatenate({"command -v ", program}, context.temp_allocator)}}, context.temp_allocator)
	return err == nil && st.exit_code == 0
}

picker_missing: bool // atomic: neither zenity nor kdialog is installed

// pick_torrents opens the dialog; the paths arrive in `picked`.
pick_torrents :: proc() {
	thread.create_and_start(proc() {
		cmd: [dynamic]string
		defer delete(cmd)
		if have("zenity") {
			append(&cmd, "zenity", "--file-selection", "--title", "Add torrent", "--multiple", "--separator=\n", "--file-filter=Torrent files | *.torrent", "--file-filter=All files | *")
		} else if have("kdialog") {
			append(&cmd, "kdialog", "--title", "Add torrent", "--getopenfilename", ".", "*.torrent", "--multiple", "--separate-output")
		} else {
			sync.atomic_store(&picker_missing, true)
			wake()
			return
		}
		st, out, _, err := os.process_exec({command = cmd[:]}, context.allocator)
		defer delete(out)
		if err != nil || st.exit_code != 0 {return}
		sync.mutex_lock(&picked_mu)
		for l in strings.split_lines(string(out), context.temp_allocator) {
			if l != "" {append(&picked, strings.clone(l))}
		}
		sync.mutex_unlock(&picked_mu)
		wake()
	}, self_cleanup = true)
}

// pick_save asks for a file name to save to (blocks until the dialog closes); "" if cancelled.
pick_save :: proc(default_name: string) -> string {
	cmd: [dynamic]string
	defer delete(cmd)
	if have("zenity") {
		append(&cmd, "zenity", "--file-selection", "--save", "--confirm-overwrite", strings.concatenate({"--filename=", home(), "/", default_name}, context.temp_allocator))
	} else if have("kdialog") {
		append(&cmd, "kdialog", "--getsavefilename", strings.concatenate({home(), "/", default_name}, context.temp_allocator))
	} else {
		return ""
	}
	st, out, _, err := os.process_exec({command = cmd[:]}, context.temp_allocator)
	if err != nil || st.exit_code != 0 {return ""}
	return strings.trim_space(string(out))
}

// pick_path asks for an existing file or folder (blocks until the dialog closes); "" if cancelled.
pick_path :: proc(folder: bool) -> string {
	cmd: [dynamic]string
	defer delete(cmd)
	if have("zenity") {
		append(&cmd, "zenity", "--file-selection", "--title", "Choose what to share")
		if folder {append(&cmd, "--directory")}
	} else if have("kdialog") {
		append(&cmd, "kdialog", "--getexistingdirectory" if folder else "--getopenfilename", home())
	} else {
		return ""
	}
	st, out, _, err := os.process_exec({command = cmd[:]}, context.temp_allocator)
	if err != nil || st.exit_code != 0 {return ""}
	return strings.trim_space(string(out))
}

// ---- creating a torrent on a worker thread ----

Create_Job :: struct {
	source, out, comment, trackers: cstring,
	version, priv:                  i32,
}

create_state: i32 // 0 idle, 1 working, 2 done, 3 failed (atomic)
create_msg: [512]u8

start_create :: proc(j: Create_Job) {
	sync.atomic_store(&create_state, 1)
	job := new(Create_Job)
	job^ = j
	thread.create_and_start_with_data(job, proc(data: rawptr) {
		jb := cast(^Create_Job)data
		create_msg[0] = 0
		rc := create(jb.source, jb.out, jb.version, jb.priv, jb.comment, jb.trackers, raw_data(create_msg[:]), len(create_msg))
		delete(jb.source); delete(jb.out); delete(jb.comment); delete(jb.trackers)
		free(jb)
		sync.atomic_store(&create_state, 2 if rc == 0 else 3)
		wake()
	}, self_cleanup = true)
}

take_picked :: proc() -> []string {
	sync.mutex_lock(&picked_mu)
	defer sync.mutex_unlock(&picked_mu)
	if len(picked) == 0 {return nil}
	out := make([]string, len(picked), context.temp_allocator)
	copy(out, picked[:])
	clear(&picked)
	return out
}

home :: proc() -> string {
	h := os.get_env("HOME", context.temp_allocator)
	return h if h != "" else "/tmp"
}

config_dir :: proc() -> string {
	x := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	base := x if x != "" else strings.concatenate({home(), "/.config"}, context.temp_allocator)
	return strings.concatenate({base, "/picotorrent"}, context.temp_allocator)
}

download_dir :: proc() -> string {
	if prefs.save != "" {return prefs.save}
	return strings.concatenate({home(), "/Downloads"}, context.temp_allocator)
}

mkdirs :: proc(path: string) {
	_ = os.make_directory_all(path)
}

open_folder :: proc(path: string) {
	_, _, _, _ = os.process_exec({command = {"xdg-open", path}}, context.temp_allocator)
}

// Autostart is an XDG autostart entry; its existence is the setting, so nothing is kept in gui.ini.
autostart_path :: proc() -> string {
	x := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	base := x if x != "" else strings.concatenate({home(), "/.config"}, context.temp_allocator)
	return strings.concatenate({base, "/autostart/picotorrent.desktop"}, context.temp_allocator)
}

autostart_enabled :: proc() -> bool {
	return os.exists(autostart_path())
}

set_autostart :: proc(on: bool) {
	path := autostart_path()
	if !on {
		_ = os.remove(path)
		return
	}
	exe, err := os.read_link("/proc/self/exe", context.temp_allocator)
	if err != nil {return}
	mkdirs(path[:strings.last_index_byte(path, '/')])
	body := fmt.tprintf("[Desktop Entry]\nType=Application\nName=PicoTorrent\nExec=\"%s\"\nTerminal=false\nX-GNOME-Autostart-enabled=true\n", exe)
	_ = os.write_entire_file(path, transmute([]u8)body)
}

// Update check: one HTTPS GET of the latest GitHub release on a worker thread (the shim does the TLS).
APP_VERSION :: "0.26.0" // the Linux port's version; bump with each release tag
UPDATE_HOST :: "api.github.com"
UPDATE_PATH :: "/repos/WobblyBit/picotorrent/releases/latest"

update_state: i32 // 0 idle, 1 working, 2 done (atomic)
update_manual: bool
update_body: [32768]u8
update_err: [256]u8
update_status: i32
update_url: string

start_update_check :: proc(manual: bool) {
	if _, swapped := sync.atomic_compare_exchange_strong(&update_state, 0, 1); !swapped {return}
	update_manual = manual
	thread.create_and_start(proc() {
		update_err[0] = 0
		update_status = https_get(UPDATE_HOST, UPDATE_PATH, raw_data(update_body[:]), len(update_body), raw_data(update_err[:]), len(update_err))
		sync.atomic_store(&update_state, 2)
		wake()
	}, self_cleanup = true)
}

// json_string finds "key": "value" in a flat JSON text (enough for tag_name and html_url).
json_string :: proc(text, key: string) -> string {
	k := strings.concatenate({"\"", key, "\""}, context.temp_allocator)
	i := strings.index(text, k)
	if i < 0 {return ""}
	rest := text[i + len(k):]
	q := strings.index_byte(rest, '"')
	if q < 0 {return ""}
	rest = rest[q + 1:]
	e := strings.index_byte(rest, '"')
	return rest[:e] if e >= 0 else ""
}

// version_parts reads "v1.2.3-rc1" as {1, 2, 3}.
version_parts :: proc(v: string) -> (out: [3]int) {
	s := strings.trim_left(v, "vV")
	if d := strings.index_any(s, "-+ "); d >= 0 {s = s[:d]}
	parts := strings.split(s, ".", context.temp_allocator)
	for p, i in parts {
		if i < 3 {out[i], _ = strconv.parse_int(p)}
	}
	return
}

version_newer :: proc(a, b: [3]int) -> bool {
	for i in 0 ..< 3 {
		if a[i] != b[i] {return a[i] > b[i]}
	}
	return false
}

// update_message returns what to tell the user; "" when an automatic check has nothing to say.
update_message :: proc() -> string {
	manual := update_manual
	if update_status != 200 {
		if !manual {return ""}
		if update_status < 0 {return fmt.tprintf("Cannot check for updates: %s", cstr(update_err[:]))}
		if update_status == 404 {return "No release has been published yet."}
		return fmt.tprintf("Cannot check for updates (HTTP %d).", update_status)
	}
	body := cstr(update_body[:])
	tag := json_string(body, "tag_name")
	if tag == "" {return "Cannot check for updates: unexpected reply." if manual else ""}
	if version_newer(version_parts(tag), version_parts(APP_VERSION)) {
		update_url = strings.clone(json_string(body, "html_url"))
		return fmt.tprintf("PicoTorrent %s is available (you have %s): %s", tag, APP_VERSION, update_url)
	}
	return fmt.tprintf("PicoTorrent %s is up to date.", APP_VERSION) if manual else ""
}
