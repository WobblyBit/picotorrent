package app

// Linux side: the file picker (zenity or kdialog on a thread, so the window keeps drawing), the
// config folder, and the small settings file.

import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"

picked: [dynamic]string // files chosen in the dialog, taken by the main loop
picked_mu: sync.Mutex

have :: proc(program: string) -> bool {
	st, _, _, err := os.process_exec({command = {"sh", "-c", strings.concatenate({"command -v ", program}, context.temp_allocator)}}, context.temp_allocator)
	return err == nil && st.exit_code == 0
}

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
