package app

// The menu bar, popup menus (with one level of submenu), the status bar and a small modal card.

import "core:fmt"
import "vendor:glfw"

MENU_H :: 26
STATUS_H :: 24
ITEM_H :: 24
SEP_H :: 9

// what an item does; handled in main.odin's do_action
Action :: enum {
	None,
	Add_Torrent,
	Add_Magnet,
	Create_Torrent,
	Exit,
	Theme_Light,
	Theme_Dark,
	Toggle_Column,
	About,
	Check_Update,
	Pause,
	Resume,
	Recheck,
	Copy_Hash,
	Remove,
	Remove_Files,
	Open_Folder,
	Queue,
	Sequential,
	Limits,
	Announce,
	Copy_Magnet,
	Export,
	Preferences,
	Set_Label,
	Filter_Label,
	Language,
}

Item :: struct {
	label:    string,
	action:   Action,
	arg:      int,
	checked:  bool,
	disabled: bool,
	sep:      bool,
	sub:      bool, // opens the submenu
}

Popup :: struct {
	open:     bool,
	x, y:     f32,
	items:    [dynamic]Item,
	sub:      [dynamic]Item, // the submenu of the Item with sub = true
	sub_open: bool,
	sub_y:    f32,
	from_bar: int, // which menu-bar title opened it, or -1
}

popup: Popup
bar_titles := [3]string{"File", "View", "Help"}
modal_text: string // when set, a card with an OK button covers the window

// popup_close clears the popup.
popup_close :: proc() {
	popup.open, popup.sub_open = false, false
	clear(&popup.items)
	clear(&popup.sub)
}

add_item :: proc(list: ^[dynamic]Item, label: string, a: Action, arg := 0, checked := false, disabled := false) {
	append(list, Item{label = label, action = a, arg = arg, checked = checked, disabled = disabled})
}
add_sep :: proc(list: ^[dynamic]Item) {append(list, Item{sep = true})}

columns_items :: proc(list: ^[dynamic]Item) {
	for c in Col {add_item(list, COLS[c].title, .Toggle_Column, int(c), !hidden[c])}
}

popup_bar :: proc(i: int, x: f32) {
	popup_close()
	popup.open, popup.x, popup.y, popup.from_bar = true, x, MENU_H, i
	switch i {
	case 0:
		add_item(&popup.items, "Add torrent...", .Add_Torrent)
		add_item(&popup.items, "Add magnet link(s)...", .Add_Magnet)
		add_sep(&popup.items)
		add_item(&popup.items, "Create torrent...", .Create_Torrent)
		add_sep(&popup.items)
		add_item(&popup.items, "Preferences...", .Preferences)
		add_sep(&popup.items)
		add_item(&popup.items, "Exit", .Exit)
	case 1:
		append(&popup.items, Item{label = "Columns", sub = true})
		add_sep(&popup.items)
		add_item(&popup.items, "Language...", .Language)
		add_sep(&popup.items)
		add_item(&popup.items, "Light theme", .Theme_Light, checked = !th.dark)
		add_item(&popup.items, "Dark theme", .Theme_Dark, checked = th.dark)
		add_sep(&popup.items)
		add_item(&popup.items, "Filter by label...", .Filter_Label, checked = label_filter != "")
		columns_items(&popup.sub)
	case 2:
		add_item(&popup.items, "Check for updates...", .Check_Update)
		add_item(&popup.items, "About PicoTorrent", .About)
	}
}

popup_columns :: proc(x, y: f32) {
	popup_close()
	popup.open, popup.x, popup.y, popup.from_bar = true, x, y, -1
	columns_items(&popup.items)
}

popup_torrent :: proc(x, y: f32) {
	popup_close()
	popup.open, popup.x, popup.y, popup.from_bar = true, x, y, -1
	one := len(selected) == 1
	add_item(&popup.items, "Pause", .Pause)
	add_item(&popup.items, "Resume", .Resume)
	add_sep(&popup.items)
	add_item(&popup.items, "Force recheck", .Recheck)
	add_item(&popup.items, "Force reannounce", .Announce)
	append(&popup.items, Item{label = "Queue", sub = true})
	add_item(&popup.sub, "Move up", .Queue, 0)
	add_item(&popup.sub, "Move down", .Queue, 1)
	add_item(&popup.sub, "Move to top", .Queue, 2)
	add_item(&popup.sub, "Move to bottom", .Queue, 3)
	seq := false
	for &r in rows {
		if selected[r.id] && r.st.sequential != 0 {seq = true}
	}
	add_item(&popup.items, "Sequential download", .Sequential, checked = seq)
	add_item(&popup.items, "Speed limits...", .Limits)
	add_item(&popup.items, "Label...", .Set_Label)
	add_sep(&popup.items)
	add_item(&popup.items, "Open folder", .Open_Folder, disabled = !one)
	add_item(&popup.items, "Copy info hash", .Copy_Hash)
	add_item(&popup.items, "Copy magnet link", .Copy_Magnet)
	add_item(&popup.items, "Export .torrent...", .Export, disabled = !one)
	add_sep(&popup.items)
	add_item(&popup.items, "Remove", .Remove)
	add_item(&popup.items, "Remove torrent and files", .Remove_Files)
}

items_height :: proc(items: []Item) -> f32 {
	h: f32 = 8
	for it in items {h += SEP_H if it.sep else ITEM_H}
	return h
}

items_width :: proc(items: []Item) -> f32 {
	w: f32 = 120
	for it in items {w = max(w, text_w(it.label) + 56)}
	return w
}

// draw_items draws one menu list and returns the action picked (when the pointer was pressed on
// an enabled item), the item's index under the pointer, and its top.
draw_items :: proc(items: []Item, x, y: f32) -> (picked: ^Item, hover: int, hover_y: f32) {
	w, h := items_width(items), items_height(items)
	fill(x - 1, y - 1, w + 2, h + 2, th.border)
	fill(x, y, w, h, th.menu_bg)
	hover = -1
	iy := y + 4
	for _, i in items {
		it := &items[i]
		if it.sep {
			line(x + 8, iy + SEP_H / 2, x + w - 8, iy + SEP_H / 2, th.border)
			iy += SEP_H
			continue
		}
		over := hit(x, iy, w, ITEM_H)
		if over {
			hover, hover_y = i, iy
			if !it.disabled {fill(x + 3, iy, w - 6, ITEM_H, th.hover)}
		}
		c := th.dim if it.disabled else th.text
		if it.checked {text(x + 10, iy + 3.5, "✓", th.accent)}
		text(x + 28, iy + 3.5, it.label, c)
		if it.sub {text(x + w - 16, iy + 3.5, "›", c)}
		if over && ui.press_l && !it.disabled && !it.sub {picked = it}
		iy += ITEM_H
	}
	return
}

// draw_popup draws the open popup on top of everything; returns the action to run.
draw_popup :: proc(win_w, win_h: f32) -> (act: Action, arg: int) {
	if !popup.open {return .None, 0}
	w, h := items_width(popup.items[:]), items_height(popup.items[:])
	x := min(popup.x, win_w - w - 4)
	y := min(popup.y, win_h - h - 4)

	pick, hover, hy := draw_items(popup.items[:], x, y)
	if hover >= 0 && popup.items[hover].sub {
		popup.sub_open, popup.sub_y = true, hy
	} else if hover >= 0 {
		popup.sub_open = false
	}
	over_sub := false
	if popup.sub_open && len(popup.sub) > 0 {
		sx := x + w
		sh := items_height(popup.sub[:])
		sy := min(popup.sub_y - 4, win_h - sh - 4)
		over_sub = hit(sx - 1, sy - 1, items_width(popup.sub[:]) + 2, sh + 2)
		sp, _, _ := draw_items(popup.sub[:], sx, sy)
		if sp != nil {pick = sp}
	}
	over_main := hit(x - 1, y - 1, w + 2, h + 2)

	if pick != nil {
		act, arg = pick.action, pick.arg
		// column toggles keep the menu open so several columns can be switched in a row
		if act == .Toggle_Column {
			hidden[Col(arg)] = !hidden[Col(arg)]
			if popup.from_bar == 1 {
				for &it in popup.sub {if it.arg == arg {it.checked = !hidden[Col(arg)]}}
			} else {
				for &it in popup.items {if it.arg == arg {it.checked = !hidden[Col(arg)]}}
			}
			return .None, 0
		}
		popup_close()
	} else if ui.press_l && !over_main && !over_sub {
		// a press on the menu bar is handled by the bar; anywhere else closes
		if !(popup.from_bar >= 0 && ui.my < MENU_H) {popup_close()}
	}
	for k in ui.keys {if k == glfw.KEY_ESCAPE {popup_close()}}
	return
}

// draw_menu_bar draws the bar; clicking a title opens its popup (and hovering another title
// switches while one is open).
draw_menu_bar :: proc(w: f32, live: bool) {
	fill(0, 0, w, MENU_H, th.panel)
	line(0, MENU_H - 0.5, w, MENU_H - 0.5, th.border)
	x: f32 = 6
	for t, i in bar_titles {
		tw := text_w(t) + 20
		open := popup.open && popup.from_bar == i
		over := hit(x, 0, tw, MENU_H)
		if open || (over && live) {fill(x, 2, tw, MENU_H - 4, th.hover)}
		text(x + 10, 4.5, t, th.text)
		if over && ((live && ui.press_l) || (popup.open && popup.from_bar >= 0 && popup.from_bar != i)) {
			if open && ui.press_l {popup_close()} else {popup_bar(i, x)}
		}
		x += tw
	}
}

draw_status_bar :: proc(w, y: f32, nt: int, dl, ul: i64, dht: i32) {
	fill(0, y, w, STATUS_H, th.panel)
	line(0, y + 0.5, w, y + 0.5, th.border)
	text(8, y + 4, fmt.tprintf("%d torrent(s)", nt), th.dim)
	text(w * 0.3, y + 4, fmt.tprintf("DHT: %d nodes", dht), th.dim)
	text(w * 0.55, y + 4, fmt.tprintf("DL: %s/s   UL: %s/s", size_text(dl), size_text(ul)), th.dim)
}

// draw_modal shows modal_text on a card; a click on OK (or Enter/Esc) closes it.
draw_modal :: proc(win_w, win_h: f32) {
	if modal_text == "" {return}
	fill(0, 0, win_w, win_h, Color{0, 0, 0, 120})
	w, h: f32 = 380, 140
	x, y := (win_w - w) / 2, (win_h - h) / 2
	rrect(x - 1, y - 1, w + 2, h + 2, 8, th.border)
	rrect(x, y, w, h, 8, th.menu_bg)
	text_fit(x + 20, y + 24, w - 40, modal_text, th.text)
	bw: f32 = 80
	bx, by := x + w - bw - 16, y + h - 40
	over := hit(bx, by, bw, 26)
	rrect(bx, by, bw, 26, 5, th.accent if over else th.hover)
	text(bx + (bw - text_w("OK")) / 2, by + 4.5, "OK", th.text)
	if ui.press_l && over {modal_text = ""}
	for k in ui.keys {if k == glfw.KEY_ENTER || k == glfw.KEY_ESCAPE {modal_text = ""}}
}
