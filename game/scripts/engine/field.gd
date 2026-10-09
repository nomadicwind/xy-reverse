class_name Field
extends Node2D
## The walking map, ported from RPG.EXE's field loop.
##
## Coordinates follow the original: the map is a grid of 8x8 cells stored as
## u16 (low 11 bits tile, high 5 bits flags). The view is the top-left visible
## cell; party positions are screen coordinates (x in 4-pixel units, y in
## pixels) and the leader stays at the screen centre (x 38, y 80) while the
## view can scroll. Cell flags:
##   0x8000 blocked   0x0800 occupied by an object   0x2000 occupied by the party
##   0x1000 trigger zone (MAP0.EXE)   0x4000 unknown, blocks wandering NPCs

signal event_requested(object_index: int)
signal warp_requested(entry_ref: int, mode: int)

const VIEW_W := 40
const VIEW_H := 25
const CENTER_X := 38
const CENTER_Y := 80
const MAX_X := 74
const MAX_Y := 176
const TRAIL := 12

const SHADER := preload("res://scripts/engine/indexed.gdshader")

var entry_ref := 0
var entry: Dictionary
var scene: Dictionary          # live copy of the scene record
var path_bytes := PackedInt32Array()   # scene path bytes as ints
var map_id := 0
var encounters := false

var map_w := 0
var map_h := 0
var cells := PackedInt32Array()
var base := 8                  # byte offset of cell 0 (original 0x4FF)
var view_x := 0
var view_y := 0

var px := PackedInt32Array()   # trail of party screen positions (x, 4px units)
var py := PackedInt32Array()   # (y, pixels)
var pdir := PackedInt32Array() # facing per trail entry
var pmove := PackedInt32Array()# direction history used by the trail
var panim := PackedInt32Array()
var party_cells := PackedInt32Array()
var facing := 0
var party_size := 2

var objects: Array[Actor] = []
var party: Array[Actor] = []
var zones: Array = []

var pal_tex: Texture2D
var mat_tiles: ShaderMaterial
var mat_fg: ShaderMaterial
var mat_sprites: ShaderMaterial
var world: Node2D
var bg_layer: TileMapLayer
var under_layer: TileMapLayer
var fg_layer: TileMapLayer
var over_layer: TileMapLayer
var actors_root: Node2D
var _rand_i := 0
var frozen := false


func _init() -> void:
	world = Node2D.new()
	world.name = "World"
	add_child(world)


# ---------------------------------------------------------------- loading

func load_entry(ref: int, mode := 0) -> bool:
	var e = Assets.entry(ref)
	if e == null:
		push_error("no entry point %d" % ref)
		return false
	var keep_x := px[0] if px.size() > 0 else CENTER_X
	var keep_y := py[0] if py.size() > 0 else CENTER_Y
	entry_ref = ref
	entry = e
	var sc = GameState.scene_state(int(e["scene"]))
	scene = sc
	var pb := PackedInt32Array()
	for v in sc.get("paths", []):
		pb.append(int(v))
	path_bytes = pb
	map_id = int(sc["map_id"])
	encounters = int(sc["unknown"]) != 0
	GameState.current_entry = ref
	GameState.current_scene = int(e["scene"])
	custom_map = false
	_chunks = []
	_build_map()
	view_x = 0
	view_y = 0
	_set_view_from_offset(int(e["view"]))
	if mode == 0:
		_place_party(int(e["x"]), int(e["y"]), int(e["facing"]))
	else:
		_place_party(keep_x, keep_y, facing)
	zones = Assets.zones.get(str(map_id & 0x7FF), [])
	_build_objects()
	_mark_party()
	redraw()
	return true


## Where the party stands, for save files.
func party_place() -> Dictionary:
	return {"view_x": view_x, "view_y": view_y, "x": px[0], "y": py[0], "facing": facing}


func restore_place(p: Dictionary) -> void:
	if p.is_empty():
		return
	view_x = clampi(int(p["view_x"]), 0, maxi(0, map_w - 40))
	view_y = clampi(int(p["view_y"]), 0, maxi(0, map_h - 25))
	_place_party(int(p["x"]), int(p["y"]), int(p["facing"]))
	_mark_party()
	redraw()


func _set_view_from_offset(off: int) -> void:
	var c := (off - base) / 2
	view_x = c % map_w
	view_y = c / map_w


func _build_map() -> void:
	var ts: Array = scene["tileset"]
	var tm: Array = scene["tilemap"]
	pal_tex = Assets.palette(ts[0], ts[1])
	var tiles_tex := Assets.tiles(ts[0], ts[1])
	var m = Assets.tilemap(tm[0], tm[1])
	var chunk: Dictionary = m["chunks"][0]
	map_w = int(chunk["w"])
	map_h = int(chunk["h"])
	# offsets in scenes and zones count from two bytes before the entry's
	# offset table (checked against the zone rectangles, which only land on
	# cells flagged 0x1000 with this base)
	base = 2 * m["chunks"].size() + 6
	cells = PackedInt32Array(chunk["cells"])

	mat_tiles = _material(-1, -1)
	mat_fg = _material(0xFE, -1)
	mat_sprites = _material(0xFE, 1)

	for n in [bg_layer, under_layer, fg_layer, over_layer, actors_root]:
		if n != null:
			n.queue_free()
	var tileset := _tileset(tiles_tex)
	# draw order of RPG.EXE 0x1019: cells, overlay tiles marked 0x2000,
	# sprites by row, cells flagged 0x4000 (opaque), the other overlay tiles
	bg_layer = _layer(tileset, mat_tiles, -3)
	under_layer = _layer(tileset, mat_fg, -2)
	actors_root = Node2D.new()
	actors_root.name = "Actors"
	world.add_child(actors_root)
	fg_layer = _layer(tileset, mat_tiles, 1000)
	over_layer = _layer(tileset, mat_fg, 1001)
	for i in cells.size():
		var t := cells[i] & 0x7FF
		_set_tile(bg_layer, i % map_w, i / map_w, t)
		if cells[i] & 0x4000:
			_set_tile(fg_layer, i % map_w, i / map_w, t)
	for rec in m.get("fg", []):
		var layer := under_layer if (int(rec[2]) & 0x2000) else over_layer
		_set_tile(layer, int(rec[0]), int(rec[1]), int(rec[2]) & 0x7FF)


func _layer(ts: TileSet, mat: Material, z: int) -> TileMapLayer:
	var l := TileMapLayer.new()
	l.tile_set = ts
	l.material = mat
	l.z_index = z
	world.add_child(l)
	return l


func _material(transparent: int, shadow: int) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter("palette", pal_tex)
	mat.set_shader_parameter("transparent_index", transparent)
	mat.set_shader_parameter("shadow_index", shadow)
	mat.set_shader_parameter("brightness", GameState.brightness)
	return mat


func set_brightness(v: float) -> void:
	for m in [mat_tiles, mat_fg, mat_sprites]:
		if m != null:
			m.set_shader_parameter("brightness", v)


var _tile_cols := 64


func _tileset(tex: Texture2D) -> TileSet:
	var ts := TileSet.new()
	ts.tile_size = Vector2i(8, 8)
	var src := TileSetAtlasSource.new()
	src.texture = tex
	src.texture_region_size = Vector2i(8, 8)
	_tile_cols = tex.get_width() / 8
	var rows := tex.get_height() / 8
	for y in rows:
		for x in _tile_cols:
			src.create_tile(Vector2i(x, y))
	ts.add_source(src, 0)
	return ts


func _set_tile(layer: TileMapLayer, x: int, y: int, t: int) -> void:
	layer.set_cell(Vector2i(x, y), 0, Vector2i(t % _tile_cols, t / _tile_cols))


func set_cell_value(i: int, v: int) -> void:
	cells[i] = v
	_set_tile(bg_layer, i % map_w, i / map_w, v & 0x7FF)
	if v & 0x4000:
		_set_tile(fg_layer, i % map_w, i / map_w, v & 0x7FF)
	else:
		fg_layer.erase_cell(Vector2i(i % map_w, i / map_w))


func _build_objects() -> void:
	for a in objects:
		a.queue_free()
	objects.clear()
	var list: Array = scene["objects"]
	for i in list.size():
		var a := Actor.new()
		a.index = i
		a.setup_from(list[i])
		_assign_sheet(a)
		actors_root.add_child(a)
		objects.append(a)
		if not a.hidden_state():
			_occupy(a.pos, true)
	_refresh_party_sheets()


func _assign_sheet(a: Actor) -> void:
	var id := a.sprite
	if (a.speed >> 8) != 0:
		id = a.speed >> 8
	if id == 0:
		var member := a.base_frame / 12
		if a.base_frame <= 0x32 and member < party.size():
			a.set_sheet(party[member].sheet, mat_sprites)
			if member > 0:
				a.base_frame = 0
		else:
			a.set_sheet(null, mat_sprites)
		return
	a.set_sheet(Assets.pictures(0, id), mat_sprites)


func _refresh_party_sheets() -> void:
	for a in party:
		a.queue_free()
	party.clear()
	party_size = GameState.party_count()
	var bank := 4 if (map_id & 0x8000) else 0
	for i in party_size:
		var a := Actor.new()
		a.set_sheet(Assets.pictures(0, GameState.party_sprite(i + bank)), mat_sprites)
		actors_root.add_child(a)
		party.append(a)


func _place_party(x: int, y: int, dir: int) -> void:
	px.resize(TRAIL); py.resize(TRAIL); pdir.resize(TRAIL); pmove.resize(TRAIL); panim.resize(TRAIL)
	party_cells.resize(TRAIL)
	for i in TRAIL:
		px[i] = x; py[i] = y; pdir[i] = dir; pmove[i] = 7; panim[i] = 0; party_cells[i] = -1
	facing = dir


# ---------------------------------------------------------------- cells

func cell_index_at_screen(x: int, y: int) -> int:
	var row := (y + 16) / 8 + view_y
	var col := (x + 2) / 2 + view_x
	return row * map_w + col


func leader_cell() -> int:
	return cell_index_at_screen(px[0], py[0])


func cell(i: int) -> int:
	if i < 0 or i >= cells.size():
		return 0x8000
	return cells[i]


func pos_to_cell(p: int) -> int:
	return (p - base) / 2


func cell_to_pos(c: int) -> int:
	return c * 2 + base


func _occupy(p: int, on: bool) -> void:
	var c := pos_to_cell(p)
	for k in 3:
		if c + k < 0 or c + k >= cells.size():
			continue
		if on:
			cells[c + k] |= 0x8800
		else:
			cells[c + k] &= ~0x8800


func _mark_party() -> void:
	var n := party_size * 3
	for i in TRAIL:
		if party_cells[i] >= 0 and party_cells[i] < cells.size():
			cells[party_cells[i]] &= ~0x2000
		party_cells[i] = -1
	for i in mini(n, TRAIL):
		var c := cell_index_at_screen(px[i], py[i])
		if c >= 0 and c < cells.size():
			cells[c] |= 0x2000
			party_cells[i] = c


# ---------------------------------------------------------------- drawing

func redraw() -> void:
	if custom_map:
		return
	world.position = Vector2(-view_x * 8, -view_y * 8)
	for a in objects:
		if a.hidden_state() or a.sheet == null:
			a.visible = false
			continue
		a.visible = true
		var c := pos_to_cell(a.pos)
		var col := c % map_w
		var row := c / map_w
		a.refresh(col * 8 + a.dx * 4, row * 8 - 16 + a.dy)
		a.z_index = row
	for i in party.size():
		var t := mini(i * 3, TRAIL - 1)
		var a := party[i]
		a.frame_dir = pdir[t]
		a.anim = panim[t]
		a.visible = true
		a.refresh(view_x * 8 + px[t] * 4, view_y * 8 + py[t] - 16)
		a.z_index = view_y + (py[t] + 16) / 8


# ---------------------------------------------------------------- party movement

## One step of the leader. dir: 0 down, 3 up, 6 left, 9 right.
## Returns the object bumped into (for touch events and pick-ups), or -1.
func step(dir: int) -> int:
	facing = dir
	pdir[0] = dir
	var r := _try_move(dir, true)
	_after_move(r == 1)
	if r == 2:
		return facing_object()
	return -1


## 1 moved, 0 blocked, 2 blocked by an object
func _try_move(dir: int, allow_slide: bool) -> int:
	var x := px[0]
	var y := py[0]
	var dvx := 0
	var dvy := 0
	var nx := x
	var ny := y
	match dir:
		9:
			if x == CENTER_X and view_x < map_w - VIEW_W:
				dvx = 1
			elif x != MAX_X:
				nx = x + 2
			else:
				return 0
		6:
			if x == CENTER_X and view_x > 0:
				dvx = -1
			elif x != 0:
				nx = x - 2
			else:
				return 0
		0:
			if y == CENTER_Y and view_y < map_h - VIEW_H:
				dvy = 1
			elif y != MAX_Y:
				ny = y + 8
			else:
				return 0
		3:
			if y == CENTER_Y and view_y > 0:
				dvy = -1
			elif y != 0:
				ny = y - 8
			else:
				return 0
	var row := (ny + 16) / 8 + view_y + dvy
	var col := (nx + 2) / 2 + view_x + dvx
	var t := row * map_w + col
	var span := [0] if (dir == 9 or dir == 6) else [-1, 0, 1]
	var blocked := false
	var by_object := false
	for k in span:
		var c := cell(t + k)
		if c & 0x8000:
			blocked = true
			if c & 0x0800:
				by_object = true
	if blocked:
		if by_object:
			return 2
		if allow_slide:
			var s := _slide_dir(dir, t)
			if s >= 0:
				return _try_move(s, false)
		return 0
	view_x += dvx
	view_y += dvy
	_shift_trail(dvx, dvy, dir)
	px[0] = nx
	py[0] = ny
	return 1


func _free(c: int) -> bool:
	return not (cell(c) & 0x8000)


func _free3(c: int) -> bool:
	return _free(c - 1) and _free(c) and _free(c + 1)


## When a wall is hit head-on, slip around a corner (RPG.EXE 0x1D29, 0x1F25).
## t is the blocked target cell.
func _slide_dir(dir: int, t: int) -> int:
	var w := map_w
	if dir == 9 or dir == 6:
		var back := -1 if dir == 9 else 1
		if _free(t + back + w) and (_free(t + w) or _free(t + 2 * w)):
			return 0
		if _free(t + back - w) and (_free(t - w) or _free(t - 2 * w)):
			return 3
		return -1
	var behind := -w if dir == 0 else w
	if _free3(t + behind + 1) and (_free3(t + 1) or _free3(t + 2)):
		return 9
	if _free3(t + behind - 1) and (_free3(t - 1) or _free3(t - 2)):
		return 6
	return -1


## Followers retrace the leader's steps (RPG.EXE 0x21DA). When the view
## scrolls, everyone's screen position shifts back by the scroll amount.
func _shift_trail(dvx: int, dvy: int, dir: int) -> void:
	pmove[0] = dir
	for k in range(TRAIL - 1, 0, -1):
		px[k] -= 2 * dvx
		py[k] -= 8 * dvy
		var old := pmove[k]
		pmove[k] = pmove[k - 1]
		match old:
			0: py[k] += 8
			9: px[k] += 2
			6: px[k] -= 2
			3: py[k] -= 8
		if old == 0 or old == 3 or old == 6 or old == 9:
			pdir[k] = old


func _after_move(walked: bool) -> void:
	if walked:
		for i in TRAIL:
			panim[i] = (panim[i] + 1) % 4
	_mark_party()


## The object in front of the leader (RPG.EXE 0x5893): look up to four cells
## ahead for an occupied cell, then match an object whose three cells cover it.
func facing_object() -> int:
	var d := leader_cell()
	var stepv := 0
	match facing:
		0: stepv = map_w
		3: stepv = -map_w
		6: stepv = -1
		9: stepv = 1
	var starts := [d]
	if facing == 0 or facing == 3:
		starts += [d - 1, d + 1]
	else:
		starts += [d + map_w, d - map_w]
	for s in starts:
		var c: int = s
		for k in 4:
			c += stepv
			if cell(c) & 0x0800:
				for a in objects:
					if a.state == 3 or a.state == 8:
						continue
					var oc := pos_to_cell(a.pos)
					if oc >= c - 2 and oc <= c:
						return a.index
				return -1
	return -1


## The trigger zone under the leader, or null.
func zone_at_leader():
	var c := leader_cell()
	if not (cell(c) & 0x1000):
		return null
	var row := c / map_w
	var col := c % map_w
	for z in zones:
		var a := pos_to_cell(int(z[1]))
		var b := pos_to_cell(int(z[2]))
		if row >= a / map_w and col >= a % map_w and row <= b / map_w and col <= b % map_w:
			return z
	return null


# ---------------------------------------------------------------- NPCs

const RAND := [0, 4, 7, 0, 5, 0, 6, 0, 4, 0, 0, 6, 0, 7, 5, 4, 0, 0, 6, 0, 0, 5, 4, 0, 7, 0, 0, 5, 6, 0, 4, 7]


func update_objects() -> void:
	for a in objects:
		if a.state == 3 or a.state == 8 or a.state == 9:
			continue
		if a.delay > 0:
			a.delay -= 1
			continue
		_occupy(a.pos, false)
		if a.path != 0:
			_run_path(a)
			a.delay = a.speed & 0xFF
		elif a.state == 2 or a.state == 5:
			a.delay = a.speed & 0xFF
			a.anim += 1
			if a.anim >= (a.range_x & 0xFF):
				a.anim = 0
		elif a.state == 0:
			_wander(a)
		if not a.hidden_state():
			_occupy(a.pos, true)


func _wander(a: Actor) -> void:
	var r: int = RAND[_rand_i % RAND.size()]
	_rand_i += 1 + randi() % 3
	if not (r & 4):
		return
	var d := r & 3
	var stepv := 0
	var ddx := 0
	var ddy := 0
	match d:
		3:
			if a.wander_y == (a.range_y & 0x7F):
				return
			a.frame_dir = 0; stepv = map_w; ddy = 1
		1:
			if a.wander_y == 0:
				return
			a.frame_dir = 3; stepv = -map_w; ddy = -1
		2:
			if a.wander_x == (a.range_x & 0xFF):
				return
			a.frame_dir = 9; stepv = 1; ddx = 1
		0:
			if a.wander_x == 0:
				return
			a.frame_dir = 6; stepv = -1; ddx = -1
	var c := pos_to_cell(a.pos) + stepv
	for k in 3:
		if cell(c + k) & 0xF800:
			return
	a.pos = cell_to_pos(c)
	a.anim = (a.anim + 1) % 4
	a.delay = a.speed & 0xFF
	a.wander_x += ddx
	a.wander_y += ddy


func _run_path(a: Actor) -> void:
	var paths := path_bytes
	if paths.is_empty():
		a.path = 0
		return
	var tbl := (a.path - 1) * 2
	if tbl + 1 >= paths.size():
		a.path = 0
		return
	var start: int = paths[tbl] | (paths[tbl + 1] << 8)
	var pc := start + a.path_pc
	if pc >= paths.size():
		a.path = 0
		return
	var op: int = paths[pc]
	a.path_pc += 1
	match op:
		0:
			a.path_pc = 0
		1:
			a.path = 0
			a.path_pc = 0
		2: _path_move(a, map_w, 0, pc)
		3: _path_move(a, -map_w, 3, pc)
		5: _path_move(a, 1, 9, pc)
		6: _path_move(a, -1, 6, pc)
		7:
			a.base_frame = paths[pc + 1]
			a.path_pc += 1
			a.anim = 0
			a.frame_dir = 0
		9:
			a.state = paths[pc + 1]
			a.path_pc += 1
		10:
			var obj: int = (paths[pc + 1] | (paths[pc + 2] << 8)) / 2
			var ev: int = paths[pc + 3] | (paths[pc + 4] << 8)
			if obj < objects.size():
				objects[obj].event = ev
			a.path_pc += 4
		11:
			var obj2: int = (paths[pc + 1] | (paths[pc + 2] << 8)) / 2
			a.path_pc += 2
			event_requested.emit(obj2)
		_:
			pass


func _path_move(a: Actor, stepv: int, dir: int, pc: int) -> void:
	var c := pos_to_cell(a.pos) + stepv
	for k in 3:
		var v := cell(c + k)
		if v & 0xA800:
			a.path_pc -= 1
			if (a.range_y & 0x80) and (v & 0x2000):
				event_requested.emit(a.index)
			return
	a.frame_dir = dir
	a.base_frame = 0 if a.sprite != 0 else a.base_frame
	a.pos = cell_to_pos(c)
	var paths := path_bytes
	if pc + 1 < paths.size() and paths[pc + 1] == 0xFE:
		a.anim = 0
		a.frame_dir = 0
		a.base_frame = paths[pc + 2]
		a.path_pc += 2
	else:
		a.anim = (a.anim + 1) % 4


# ---------------------------------------------------------------- script support

var anim_frame := 0            # tilemap chunk shown (original 0x501)
var _chunks: Array = []
var custom_map := false        # a cut-scene tilemap replaced the scene's map


func set_object_state(i: int, st: int) -> void:
	if i < 0 or i >= objects.size():
		return
	var a := objects[i]
	_occupy(a.pos, false)
	a.state = st
	if not a.hidden_state():
		_occupy(a.pos, true)


func set_object_sprite(i: int, v: int) -> void:
	var a := objects[i]
	a.sprite = v >> 8
	a.base_frame = v & 0xFF
	_assign_sheet(a)


## Script-driven object step (ops 0x17-0x1A): no collision test.
func move_object(i: int, dir: int) -> void:
	if i < 0 or i >= objects.size():
		return
	var a := objects[i]
	_occupy(a.pos, false)
	match dir:
		3: a.pos -= map_w * 2
		0: a.pos += map_w * 2
		6: a.pos -= 2
		9: a.pos += 2
	a.frame_dir = dir
	if a.state != 4:
		a.anim = (a.anim + 1) % 4
	if not a.hidden_state():
		_occupy(a.pos, true)
	redraw()


## Op 0x10: new view offset (absolute byte offset), view x/y and party place.
func reposition(view_off: int, vx: int, vy: int, x: int, y: int, dir: int) -> void:
	view_x = vx
	view_y = vy
	_place_party(x, y, dir)
	_mark_party()
	redraw()


func set_party_facing(dir: int) -> void:
	for i in TRAIL:
		pdir[i] = dir
	facing = dir
	redraw()


func refresh_party() -> void:
	_refresh_party_sheets()
	_mark_party()
	redraw()


## Op 0x4A: move the view by whole cells, keeping everything in place on the map.
func pan(dxc: int, dyc: int) -> void:
	dxc = Actor._s16(dxc)
	dyc = Actor._s16(dyc)
	view_x += dxc
	view_y += dyc
	for i in TRAIL:
		px[i] -= dxc * 2
		py[i] -= dyc * 8
	redraw()


## Ops 0x1D/0x2B: palette and tile sheet from any pack (cut scenes use DO.LSK).
func load_tiles(file_id: int, entry_no: int, _keep: bool) -> void:
	pal_tex = Assets.palette(file_id, entry_no)
	var tex := Assets.tiles(file_id, entry_no)
	for m in [mat_tiles, mat_fg, mat_sprites]:
		if m != null:
			m.set_shader_parameter("palette", pal_tex)
	if tex != null and bg_layer != null:
		var ts := _tileset(tex)
		for l in [bg_layer, under_layer, fg_layer, over_layer]:
			l.tile_set = ts
	palette_changed.emit()


signal palette_changed


## Op 0x23: a tilemap (often a cut-scene animation, one chunk per frame).
func load_map_entry(file_id: int, entry_no: int, with_fg: bool) -> void:
	var m = Assets.tilemap(file_id, entry_no)
	if m == null:
		return
	custom_map = true
	_chunks = m["chunks"]
	anim_frame = 0
	view_x = 0
	view_y = 0
	for l in [under_layer, fg_layer, over_layer]:
		l.clear()
	if with_fg:
		for rec in m.get("fg", []):
			var layer := under_layer if (int(rec[2]) & 0x2000) else over_layer
			_set_tile(layer, int(rec[0]), int(rec[1]), int(rec[2]) & 0x7FF)
	for a in objects:
		a.visible = false
	for a in party:
		a.visible = false
	show_chunk(0)


func show_chunk(i: int) -> void:
	if _chunks.is_empty():
		return
	i = clampi(i, 0, _chunks.size() - 1)
	var c: Dictionary = _chunks[i]
	var w := int(c["w"])
	var h := int(c["h"])
	var data: Array = c["cells"]
	bg_layer.clear()
	for k in data.size():
		_set_tile(bg_layer, k % w, k / w, int(data[k]) & 0x7FF)
	world.position = Vector2.ZERO
