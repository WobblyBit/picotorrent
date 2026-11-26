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
	return strings.concatenate({home(), "/Downloads"}, context.temp_allocator)
}

mkdirs :: proc(path: string) {
	_ = os.make_directory_all(path)
}

open_folder :: proc(path: string) {
	_, _, _, _ = os.process_exec({command = {"xdg-open", path}}, context.temp_allocator)
}
