class_name NameEntry
extends RefCounted
## The naming screen RPG.EXE shows before a new game (0x1820): a grid of
## characters in three pages, the four names on the right. Picking ↑↓ moves
## between names, ←→ between the four places of a name, ▽△ turn the page,
## any other character goes into the current place and moves right; the
## blank cell erases. Esc leaves. The original ☆ opened a glyph painter for
## characters of your own, which the remake leaves out (names are text).
## Names are kept between games in user://names.json, as NAME.DAQ was.

const SAVE_PATH := "user://names.json"
const GRID_X := 28              # [0x2B2A] 7..0x2F, in 4 px units
const GRID_Y := 46              # [0x2B2C] 0x2E..0xAE
const NAME_X := 248             # [0x2B1E] 0x3E..0x4A
const NAME_Y := 18              # [0x2B28] 0x12..0x42
const CURSOR := 0xB3            # MENU.RSK red frame
const INK := "{C0}{M-1}"

var game: Game
var ov: Overlay
var grid: Array = []            # pages of 9 rows of 11 characters
var cells: Array = []           # names as 4 places each, "" = blank
var col := 0
var row := 0
var page := 0
var slot := 0
var place := 0
var _cursors: Array[Sprite2D] = []


func _init(g: Game) -> void:
	game = g
	ov = g.overlay
	var nj = Assets.load_json("names.json")
	if nj is Dictionary:
		grid = nj.get("grid", [])
	for i in 4:
		var nm: String = GameState.names[i] if i < GameState.names.size() else ""
		var c := []
		for k in 4:
			var j := k - (4 - nm.length())
			c.append(nm[j] if j >= 0 else "")
		cells.append(c)


## Saved names, or null when the player never named anyone.
static func load_saved():
	if not FileAccess.file_exists(SAVE_PATH):
		return null
	var d = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH))
	return d if d is Array and d.size() == 4 else null


func run() -> void:
	if grid.is_empty():
		return
	ov.clear()
	ov.add_frame(Vector2(0, 0), 10, 11)
	ov.add_small_frame(Vector2(208, 10), 8, 4)
	var menu = Assets.rsk("MENU")
	for i in 2:
		var s := Sprite2D.new()
		s.centered = false
		if menu:
			var r: Array = menu["frames"][CURSOR]
			s.texture = menu["texture"]
			s.region_enabled = true
			s.region_rect = Rect2(r[0], r[1], r[2], r[3])
		s.material = ov._box_node.material
		ov.add_child(s)
		_cursors.append(s)
	await _redraw()
	Keys.reset()
	while true:
		await game.get_tree().process_frame
		if Keys.just("ui_cancel"):
			break
		if Keys.just("ui_up"):
			row = maxi(0, row - 1)
		elif Keys.just("ui_down"):
			row = mini(8, row + 1)
		elif Keys.just("ui_left"):
			col = maxi(0, col - 1)
		elif Keys.just("ui_right"):
			col = mini(10, col + 1)
		elif Keys.just("ui_page_up"):
			page = maxi(0, page - 1)
		elif Keys.just("ui_page_down"):
			page = mini(grid.size() - 1, page + 1)
		elif Keys.just("ui_accept"):
			_pick(String(grid[page][row])[col])
		else:
			continue
		await _redraw()
	for s in _cursors:
		s.queue_free()
	_save()
	ov.clear()


func _pick(ch: String) -> void:
	match ch:
		"↑": slot = maxi(0, slot - 1)
		"↓": slot = mini(3, slot + 1)
		"←": place = maxi(0, place - 1)
		"→": place = mini(3, place + 1)
		"▽": page = mini(grid.size() - 1, page + 1)
		"△": page = maxi(0, page - 1)
		"☆": place = mini(3, place + 1)
		_:
			cells[slot][place] = "" if ch == "　" else ch
			place = mini(3, place + 1)


func _redraw() -> void:
	ov.clear_text()
	var nj = Assets.load_json("names.json")
	await ov.write(INK + String(nj.get("prompt", "")), 24, 15, false, 320)
	var rows: Array = grid[page]
	for r in rows.size():
		await ov.write(INK + String(rows[r]), GRID_X, GRID_Y + r * 16, false, 320)
	for i in 4:
		await ov.write(INK + ["一：", "二：", "三：", "四："][i], 216, NAME_Y + i * 16, false, 320)
		for k in 4:
			if cells[i][k] != "":
				await ov.write(INK + cells[i][k], NAME_X + k * 16, NAME_Y + i * 16, false, 320)
	_cursors[0].position = Vector2(GRID_X + col * 16 - 4, GRID_Y + row * 16 - 1)
	_cursors[1].position = Vector2(NAME_X + place * 16 - 4, NAME_Y + slot * 16 - 1)


func _save() -> void:
	var names := []
	for c in cells:
		names.append("".join(c))
	GameState.names = names
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(names))
