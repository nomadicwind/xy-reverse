class_name Battle
extends Node2D
## The battle screen of FIG.EXE. Data comes from engine/battle.json
## (tools/swdtools/battle.py, notes in docs/BATTLE.md); addresses in comments
## are FIG.EXE code offsets.
##
## A battle is driven by its group script (ORC.EXE): "round" runs one round
## of commands and actions, and the script jumps to its victory, defeat or
## flee offsets. Party state is read from and written back to GameState.ds.

const SHADER := preload("res://scripts/engine/indexed.gdshader")
const TICK := 1.0 / 18.2
const INCAPACITATED := 0x2C7E      # FIG 0x4A1: no command, cannot dodge
const KO := 0x2000
const NUM_GREEN := 0x65            # MENU.RSK small numerals 〇..九, 4 colours
const NUM_CYAN := 0x6F
const NUM_YELLOW := 0x79
const NUM_RED := 0x83

enum Result { WIN, LOSE, FLEE }

var game: Game
var overlay: Overlay
var data: Dictionary
var group: Dictionary
var group_value := 0
var random_encounter := false
var members: Array = []            # party side, dicts (see _load_member)
var enemies: Array = []            # enemy side, dicts (see _add_enemy)
var vars := {}                     # group script variables (DS:2F2D)
var result := Result.WIN
var fled := false
var exp_total := 0
var money_total := 0
var crit_counter := 21             # RPG DS:592
var flee_tries := 0
var max_rounds := 0                # tests: stop after this many rounds
var allies: Array = [null, null]   # summoned monsters, DS:2384 (docs/CREATURES.md)
var rounds := 0
var test_plan: Array = []          # tests: Callables (member) -> command, used first
var force_random := false          # tests: treat a scripted group as a random encounter

var _pal_img: Image
var _pal_tex: Texture2D
var _mat: ShaderMaterial
var _bg: Sprite2D
var _hud: Node2D
var _menu_rsk


func _init(g: Game) -> void:
	game = g
	overlay = g.overlay


# ---------------------------------------------------------------- set-up

static func battle_data() -> Dictionary:
	var d = Assets.load_json("battle.json")
	return d if d is Dictionary else {}


## Starts the battle for an RPG group value ([0x594]); 0 = random encounter
## at the party's place. Returns a Result.
func run(value: int) -> int:
	data = battle_data()
	if data.is_empty():
		return Result.WIN
	_menu_rsk = Assets.rsk("MENU")
	crit_counter = GameState.w(0x592) if GameState.w(0x592) > 0 else 21
	var v := value & 0x3FFF
	random_encounter = v == 0 or force_random
	if v == 0:
		v = _encounter_group()
		if v == 0:
			return Result.WIN
	group_value = v
	var idx := (v - 2) / 2
	var groups: Array = data["groups"]
	if idx < 0 or idx >= groups.size() or not (groups[idx] is Dictionary) or not groups[idx].has("script"):
		push_warning("battle group %d not found" % v)
		return Result.WIN
	group = groups[idx]
	_setup_graphics()
	_load_party()
	for e in group["enemies"]:
		_add_enemy(int(e["monster"]), int(e["x"]))
	game.play_music_path("RX/RI076.RIX" if value & 0xC000 else "RX/RI077.RIX")
	_redraw()
	await game.fade(true)
	await _run_script(0)
	_return_allies()
	_write_back()
	await game.fade(false)
	_teardown()
	return result


## FIG 0x3A3C: the map's rectangles over the view position give 8 groups,
## one picked at random.
func _encounter_group() -> int:
	var map_id := game.field.map_id & 0xFFF
	var vx := game.field.view_x
	var vy := game.field.view_y
	var tables: Array = data.get("random_encounters", [])
	if tables.is_empty():
		return 0
	var t = tables[0]
	for m in tables:
		if int(m["map_id"]) == map_id:
			t = m
			break
	for r in t["rects"]:
		if vx >= int(r["x0"]) and vx <= int(r["x1"]) and vy >= int(r["y0"]) and vy <= int(r["y1"]):
			var gs: Array = r["groups"]
			return int(gs[randi() % gs.size()])
	return 0


func _setup_graphics() -> void:
	var bgname: String = String(group.get("background", "BA/BA01.RSK")).get_file().get_basename().to_upper()
	_pal_img = Assets.load_image("ba/%s.pal.png" % bgname)
	_pal_tex = Assets.load_texture("ba/%s.pal.png" % bgname)
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER
	_mat.set_shader_parameter("palette", _pal_tex)
	_mat.set_shader_parameter("transparent_index", 0xFE)
	_bg = Sprite2D.new()
	_bg.centered = false
	_bg.texture = Assets.load_texture("ba/%s.png" % bgname)
	_bg.material = _mat
	add_child(_bg)
	_hud = Node2D.new()
	_hud.z_index = 5
	add_child(_hud)
	overlay.set_palette(_pal_img, _pal_tex)
	game.field.visible = false


func _teardown() -> void:
	game.field.visible = true
	overlay.clear()
	queue_free()


func set_brightness(v: float) -> void:
	if _mat:
		_mat.set_shader_parameter("brightness", v)


func _sprite(tex: Texture2D, r: Array, at: Vector2) -> Sprite2D:
	var s := Sprite2D.new()
	s.centered = false
	s.texture = tex
	s.region_enabled = true
	s.region_rect = Rect2(r[0], r[1], r[2], r[3])
	s.position = at
	s.material = _mat
	return s


# ---------------------------------------------------------------- party

func _load_party() -> void:
	members.clear()
	var n := GameState.w(GameState.PARTY_COUNT)
	for i in mini(n, 4):
		members.append(_load_member(i))
	for m in members:
		_place_member(m)


func _load_member(i: int) -> Dictionary:
	var rec := GameState.PARTY + i * GameState.PARTY_REC
	var id := GameState.w(0x89 + i * 6)
	var w := func(o: int) -> int: return GameState.w(rec + o)
	var m := {
		"side": 0, "slot": i, "rec": rec, "char": id / 12,
		"name": _member_name(id / 12),
		"status": w.call(0x08), "atk": w.call(0x0C), "def": w.call(0x0E),
		"immune": GameState.b(rec + 0x26),
		"res": [0, GameState.b(rec + 0x27), GameState.b(rec + 0x28), GameState.b(rec + 0x29), GameState.b(rec + 0x2A)],
		"hp": w.call(0x2D), "hpm": w.call(0x2F), "lvl": w.call(0x31), "luck": w.call(0x33),
		"sta": w.call(0x35), "stam": w.call(0x37), "int": w.call(0x45),
		"mp": w.call(0x55), "mpm": w.call(0x57), "agi": w.call(0x5D), "eva": w.call(0x65),
		"skills": [], "timers": {}, "decoys": 0, "guard": 0, "pose": 0, "node": null,
	}
	m["base"] = {"atk": m["atk"], "def": m["def"], "agi": m["agi"], "eva": m["eva"]}
	for k in 50:
		var s := GameState.b(rec + 0x6D + k)
		if s != 0:
			m["skills"].append(s)
	return m


func _member_name(ch: int) -> String:
	var nm: String = GameState.names[ch] if ch < GameState.names.size() else ""
	return nm if nm != "" else "？"


func _place_member(m: Dictionary) -> void:
	if m["node"]:
		m["node"].queue_free()
	var entry: int = int(m["char"]) * 9 + int(m["pose"])
	var p = Assets.pictures(6, entry)   # DO.LSK
	if p == null:
		return
	var s := _sprite(p["texture"], p["frames"][0], Vector2((int(m["slot"]) + 1) * 72 - 48, 83))
	s.z_index = 2
	add_child(s)
	m["node"] = s
	s.modulate = Color(0.5, 0.5, 0.5) if int(m["status"]) & KO else Color.WHITE


func _set_pose(m: Dictionary, pose: int) -> void:
	m["pose"] = pose
	_place_member(m)


func _write_back() -> void:
	for m in members:
		var rec: int = m["rec"]
		GameState.setw(rec + 0x2D, m["hp"])
		GameState.setw(rec + 0x35, m["sta"])
		GameState.setw(rec + 0x55, m["mp"])
		# FIG 0x256: battle effects end, lasting conditions stay
		GameState.setw(rec + 0x08, int(m["status"]) & 0xF200)
	GameState.setw(0x592, crit_counter)
	if result == Result.LOSE:
		GameState.setb(0x58F, 1)


# ---------------------------------------------------------------- enemies

func _monster(id: int) -> Variant:
	var ms: Array = data["monsters"]
	var i := id - 314
	return ms[i] if i >= 0 and i < ms.size() else null


func _add_enemy(id: int, x: int) -> Dictionary:
	var mo = _monster(id)
	if mo == null:
		return {}
	var e := {
		"side": 1, "slot": enemies.size(), "id": id, "name": mo["name"], "mon": mo,
		"x": x * 4, "y": int(mo["y"]), "lvl": int(mo["level"]),
		"hp": int(mo["hp"]), "hpm": int(mo["hp"]), "mp": int(mo["mp"]),
		"atk": int(mo["attack"]), "def": int(mo["defense"]), "agi": int(mo["agility"]),
		"luck": int(mo["luck"]), "eva": int(mo["evasion"]),
		"immune": int(mo["immune_physical"]), "res": [0] + Array(mo["element_resist"]),
		"status": int(mo["flags"]), "timers": {}, "decoys": 0, "gone": false, "node": null,
		"exp": int(mo.get("exp", 0)), "money": int(mo.get("money", 0)),
	}
	e["base"] = {"atk": e["atk"], "def": e["def"], "agi": e["agi"], "eva": e["eva"]}
	var p = Assets.pictures(4, id)   # CD.LSK
	if p != null:
		var s := _sprite(p["texture"], p["frames"][0], Vector2(e["x"], e["y"]))
		s.z_index = 1
		add_child(s)
		e["node"] = s
	enemies.append(e)
	return e


func _alive(u: Dictionary) -> bool:
	if u["side"] == 1:
		return not u["gone"] and int(u["hp"]) > 0
	return not (int(u["status"]) & KO)


func _can_act(u: Dictionary) -> bool:
	return _alive(u) and not (int(u["status"]) & INCAPACITATED)


func _living(side: Array) -> Array:
	return side.filter(func(u): return _alive(u))


func _center(u: Dictionary) -> Vector2:
	var n: Sprite2D = u["node"]
	if n == null:
		return Vector2(160, 60)
	return n.position + n.region_rect.size * Vector2(0.5, 0.4)


# ---------------------------------------------------------------- HUD

func _redraw() -> void:
	for c in _hud.get_children():
		c.queue_free()
	for m in members:
		var x := 4 + int(m["slot"]) * 79
		var y := 176
		_numbers(int(m["hp"]), Vector2(x, y), NUM_YELLOW if _alive(m) else NUM_RED)
		_numbers(int(m["mp"]), Vector2(x, y + 9), NUM_CYAN)
		_numbers(int(m["sta"]), Vector2(x + 40, y + 9), NUM_GREEN)
	# FIG 0x34FA: summoned monsters show only as a name at the top
	for a in allies:
		if a != null:
			var lbl := Node2D.new()
			var nm := String(a["name"])
			var at := Vector2(8 + int(a["slot"]) * 80, 4)
			lbl.draw.connect(func():
				for k in nm.length():
					var r := Assets.glyph_rect(nm[k])
					if r.size != Vector2.ZERO and Assets.font_texture:
						lbl.draw_texture_rect_region(Assets.font_texture, Rect2(at + Vector2(k * 16, 0), r.size), r, overlay.pal_color(0x0F)))
			_hud.add_child(lbl)
	for e in enemies:
		if e["node"]:
			e["node"].visible = _alive(e) or (int(e["status"]) & 0x8000 and not e["gone"])


## Draws a number with the small MENU.RSK numerals.
func _numbers(v: int, at: Vector2, base: int, parent: Node = null) -> float:
	if _menu_rsk == null:
		return 0.0
	var s := str(maxi(v, 0))
	var x := at.x
	for ch in s:
		var r: Array = _menu_rsk["frames"][base + int(ch)]
		var sp := _sprite(_menu_rsk["texture"], r, Vector2(x, at.y))
		(parent if parent else _hud).add_child(sp)
		x += r[2]
	return x - at.x


## A number that floats over a unit for a moment.
func _pop(u: Dictionary, v: int, base: int) -> void:
	var n := Node2D.new()
	n.z_index = 6
	add_child(n)
	var w := _numbers(v, Vector2.ZERO, base, n)
	n.position = _center(u) - Vector2(w / 2, 0)
	var t := create_tween()
	t.tween_property(n, "position:y", n.position.y - 12, 0.4)
	t.tween_interval(0.3)
	t.tween_callback(n.queue_free)


## A short message at the top (攻 擊, skill names, 逃走失敗 ...).
func _message(text: String, secs := 0.6) -> void:
	overlay.clear_text()
	var w := 0
	for c in text:
		w += 8 if c == " " else 16
	await overlay.write("{C15}" + text, 160 - w / 2, 8, false, 320)
	await _wait(secs)
	overlay.clear_text()


## The game font only has full-width digits.
static func _fw(n: int) -> String:
	var out := ""
	for c in str(n):
		out += char(0xFF10 + int(c)) if c >= "0" and c <= "9" else c
	return out


func _wait(secs: float) -> void:
	if Overlay.auto_continue:
		secs = minf(secs, 0.05)
	await get_tree().create_timer(secs).timeout


func _msg(key: String, fallback: String) -> String:
	var ms: Dictionary = data.get("messages", {})
	return String(ms.get(key, fallback))


# ---------------------------------------------------------------- group script

func _ops() -> Array:
	return group["script"]


func _op_index(at: int) -> int:
	var ops := _ops()
	for i in ops.size():
		if int(ops[i]["at"]) == at:
			return i
	return ops.size()


func _var(n: int) -> int:
	return int(vars.get(n, 0))


## Runs the group script from byte offset `at` (FIG 0x2B2 dispatch).
func _run_script(at: int) -> void:
	var ops := _ops()
	var pc := _op_index(at)
	var guard := 0
	while pc < ops.size():
		guard += 1
		if guard > 5000:
			push_warning("battle script loop")
			return
		var op: Dictionary = ops[pc]
		var a: Array = op.get("args", [])
		pc += 1
		match int(op["op"]):
			0x00:
				await _say(a[0])
			0x01:
				rounds += 1
				if max_rounds > 0 and rounds > max_rounds:
					return
				var r := await _round()
				if r >= 0:
					pc = _op_index(r)
			0x02:
				await _victory()
				result = Result.WIN
				return
			0x03:
				await _defeat()
				return
			0x04:
				pc = _op_index(int(a[0]))
			0x05:
				if _var(int(a[0])) == int(a[1]):
					pc = _op_index(int(a[2]))
			0x06:
				vars[int(a[0])] = _var(int(a[0])) + 1
			0x07:
				for m in members:
					m["hp"] = m["hpm"]; m["mp"] = m["mpm"]; m["sta"] = m["stam"]
					m["status"] = 0
					_place_member(m)
				_redraw()
			0x08, 0x17:
				if fled:
					result = Result.FLEE
				return
			0x09:
				game.play_sfx(int(a[0]))
			0x0A, 0x29, 0x2E:
				_redraw()
			0x0B:
				await _say(a[2])
			0x0C:
				await _wait(int(a[0]) * TICK)
			0x0D, 0x0E, 0x0F:
				_enemy_array_op(int(op["op"]), int(a[0]), int(a[1]))
			0x10:
				pass
			0x11:
				pass
			0x12:
				_redraw()
			0x13:
				var l: Array = a[0]
				if not l.is_empty():
					pc = _op_index(int(l[randi() % l.size()]))
			0x14:
				vars[int(a[0])] = int(a[1])
			0x15:
				pass
			0x16:
				if _enemy_array_get(int(a[0])) == int(a[1]):
					pc = _op_index(int(a[2]))
			0x18:
				if not await game.choose_yes_no():
					pc = _op_index(int(a[0]))
			0x19:
				if GameState.money() >= int(a[0]):
					GameState.add_money(-int(a[0]))
				else:
					pc = _op_index(int(a[1]))
			0x1A:
				_give_drop(false)
			0x1B:
				pass
			0x1C:
				if not GameState.flag(int(a[0])):
					pc = _op_index(int(a[1]))
			0x1D:
				for e in enemies:
					if int(e["status"]) & 0x8000 and int(e["hp"]) <= 0:
						e["gone"] = true
						await _message(_msg("0x1ec7", "逃  走"))
				_redraw()
			0x1E, 0x1F, 0x20, 0x21, 0x28:
				pass
			0x22:
				if not game.in_party(int(a[0])):
					pc = _op_index(int(a[1]))
			0x23, 0x24, 0x25:
				_party_word_op(int(op["op"]), int(a[0]), int(a[1]))
			0x26:
				if _party_word(int(a[0])) != int(a[1]):
					pc = _op_index(int(a[2]))
			0x27:
				await overlay.write(a[2], int(a[0]) * 4, int(a[1]), true)
				await overlay.wait_key()
				overlay.clear_text()
			0x2A:
				if not _has_item(int(a[0])):
					pc = _op_index(int(a[1]))
			0x2B:
				GameState.set_flag(int(a[0]), int(a[1]) != 0)
			0x2C:
				var e := _add_enemy(int(a[0]), 30 + enemies.size() * 10)
				if e.is_empty():
					pc = _op_index(int(a[1]))
				_redraw()
			0x2D:
				if not enemies.is_empty():
					enemies[0]["hp"] = maxi(0, int(enemies[0]["hp"]) - int(a[0]))
			0x2F:
				for e in enemies:
					e["hp"] = e["hpm"]
			_:
				push_warning("battle op %x not implemented" % int(op["op"]))


func _say(text: String) -> void:
	overlay.show_box(true)
	await overlay.write(text, 40, 12, true, 280, 4)
	await overlay.wait_key(Vector2(280, 60))
	overlay.clear()


## Enemy arrays at DS:23C6, 20 bytes each: ofs / 20 picks the field,
## (ofs % 20) / 2 the enemy (FIG ops 0D-0F, 16).
const ENEMY_FIELDS := {
	0x00: "x", 0x14: "y", 0x8C: "lvl", 0x154: "mp", 0x168: "atk", 0x17C: "atk",
	0x190: "def", 0x1A4: "def", 0x1B8: "agi", 0x1CC: "luck", 0x1E0: "eva", 0x1F4: "eva",
	0x208: "hp", 0x21C: "hpm", 0x244: "status",
}


func _enemy_field(ofs: int) -> Array:
	var f: int = (ofs / 20) * 20
	var i: int = (ofs % 20) / 2
	return [ENEMY_FIELDS.get(f, ""), i]


func _enemy_array_get(ofs: int) -> int:
	var fi := _enemy_field(ofs)
	if fi[0] == "" or fi[1] >= enemies.size():
		return 0
	var e: Dictionary = enemies[fi[1]]
	if fi[0] == "x":
		return int(e["x"]) / 4
	return int(e[fi[0]])


func _enemy_array_op(op: int, ofs: int, v: int) -> void:
	var fi := _enemy_field(ofs)
	if fi[0] == "" or fi[1] >= enemies.size():
		return
	var e: Dictionary = enemies[fi[1]]
	var cur := _enemy_array_get(ofs)
	var nv := cur + v if op == 0x0D else (cur - v if op == 0x0E else v)
	if fi[0] == "x":
		e["x"] = nv * 4
		if e["node"]:
			e["node"].position.x = nv * 4
	elif fi[0] == "y":
		e["y"] = nv
		if e["node"]:
			e["node"].position.y = nv
	else:
		e[fi[0]] = nv
	_redraw()


func _party_word(ofs: int) -> int:
	return GameState.w(GameState.PARTY + ofs)


func _party_word_op(op: int, ofs: int, v: int) -> void:
	var cur := _party_word(ofs)
	var nv := cur + v if op == 0x23 else (cur - v if op == 0x24 else v)
	GameState.setw(GameState.PARTY + ofs, nv & 0xFFFF)
	# keep the live copies in step for the common fields
	var i := ofs / GameState.PARTY_REC
	var o := ofs % GameState.PARTY_REC
	if i < members.size():
		var key = {0x2D: "hp", 0x2F: "hpm", 0x35: "sta", 0x55: "mp", 0x08: "status"}.get(o)
		if key:
			members[i][key] = nv
	_redraw()


func _has_item(id: int) -> bool:
	for k in 50:
		if GameState.w(GameState.ITEMS + k * 2) & 0x0FFF == id:
			return true
	return false


# ---------------------------------------------------------------- a round

## FIG 0x1571 / 0x607 / 0x6AD. Returns the script offset to jump to after
## the round (victory / defeat / flee), or -1 to carry on.
func _round() -> int:
	if game.bot and rounds > 40:
		for e in enemies:           # test bot: a fight it cannot win ends
			e["hp"] = 0
		return int(group["on_victory"])
	if game.bot:
		for m in members:
			m["status"] = 0
			m["hp"] = m["hpm"]
			_place_member(m)
	for a in allies:
		if a != null:
			a["ready"] = true
	var cmds := {}
	for m in members:
		if not _can_act(m):
			continue
		var c = await _command(m)
		if c is Dictionary and c.get("kind") == "flee":
			if await _try_flee(m):
				fled = true
				return int(group["on_flee"])
			continue
		cmds[m["slot"]] = c
	# initiative: rand(luck) + agility, highest first (FIG 0x607)
	var order := []
	for m in members:
		if _can_act(m) and cmds.has(m["slot"]):
			order.append([randi_range(0, maxi(0, int(m["luck"]) - 1)) + int(m["agi"]), 0, m])
	for e in enemies.slice(0, 6):
		if _alive(e):
			order.append([randi_range(0, maxi(0, int(e["luck"]) - 1)) + int(e["agi"]), 1, e])
	for a in allies:
		if a != null and a["ready"]:
			order.append([randi_range(0, maxi(0, int(a["luck"]) - 1)) + int(a["agi"]), 2, a])
	order.sort_custom(func(a, b): return a[0] > b[0])
	for o in order:
		var u: Dictionary = o[2]
		if u["side"] == 2:
			if allies.has(u):
				await _ally_act(u)
				_redraw()
				if _won():
					return int(group["on_victory"])
			continue
		if not _can_act(u):
			continue
		if u["side"] == 0:
			await _member_act(u, cmds[u["slot"]])
		else:
			await _enemy_act(u)
		_end_of_turn(u)
		_redraw()
		if _living(members).is_empty():
			return int(group["on_defeat"])
		if _won():
			return int(group["on_victory"])
	if _living(members).is_empty():
		return int(group["on_defeat"])
	if _won():
		return int(group["on_victory"])
	return -1


func _won() -> bool:
	for e in enemies:
		if _alive(e):
			return false
	return true


# ---------------------------------------------------------------- commands

## Command input for one member: attack, skills, items, flee / capture.
func _command(m: Dictionary):
	if Overlay.auto_continue:
		if not test_plan.is_empty():
			return test_plan.pop_front().call(m) if int(m["slot"]) == 0 else {"kind": "defend"}
		return {"kind": "attack", "target": _first_alive(enemies)}
	_set_pose(m, 4)
	# FIG 0x20B2: 煉妖術 only for member 0, once RPG DS:4F8 bit 0 is clear
	var can_capture: bool = int(m["slot"]) == 0 and not (GameState.b(0x4F8) & 1)
	while true:
		var labels := ["攻擊", "奇術", "物品", "防禦", "逃走"]
		if can_capture:
			labels.append("煉妖術")
		var i: int = await _choose(labels, m)
		if i == 3:
			_set_pose(m, 0)
			return {"kind": "defend"}
		if i == 5:
			var tc = await _pick_target(enemies)
			if tc != null:
				_set_pose(m, 0)
				return {"kind": "capture", "target": tc}
			continue
		if i == 4:
			i = 3
		match i:
			0:
				var t = await _pick_target(enemies)
				if t != null:
					_set_pose(m, 0)
					return {"kind": "attack", "target": t}
			1:
				var sk = await _pick_skill(m)
				if sk != null:
					var t = await _pick_skill_target(sk)
					if t != null or _skill_target_kind(sk) == "all":
						_set_pose(m, 0)
						return {"kind": "skill", "skill": sk, "target": t}
			2:
				var it = await _pick_item(m)
				if it != null and it.has("monster"):
					_set_pose(m, 0)
					return {"kind": "summon", "slot": it["slot"], "monster": it["monster"]}
				if it != null:
					var sk = _skill(int(it["item"]["skill"]))
					var t = null
					if sk != null:
						t = await _pick_skill_target(sk)
					_set_pose(m, 0)
					return {"kind": "item", "slot": it["slot"], "item": it["item"], "skill": sk, "target": t}
			3:
				_set_pose(m, 0)
				return {"kind": "flee"}
	return null


func _first_alive(side: Array) -> Variant:
	for u in side:
		if _alive(u):
			return u
	return null


## A small menu box at the member's place. Returns the index, -1 = back.
func _choose(labels: Array, m: Dictionary, per_page := 0) -> int:
	var sel := 0
	var x := clampi((int(m["slot"]) + 1) * 72 - 40, 8, 240)
	while true:
		overlay.clear_text()
		var y := 92
		for k in labels.size():
			var l: String = labels[k]
			await overlay.write(("{C14}" if k == sel else "{C7}") + l, x, y, false, 320)
			y += 16
		while true:
			await get_tree().process_frame
			if Keys.just("ui_down"):
				sel = (sel + 1) % labels.size()
				break
			if Keys.just("ui_up"):
				sel = (sel - 1 + labels.size()) % labels.size()
				break
			if Keys.just("ui_accept"):
				overlay.clear_text()
				return sel
			if Keys.just("ui_cancel"):
				overlay.clear_text()
				return -1
	return -1


## Left/right picks a unit; the arrow sits over it.
func _pick_target(side: Array):
	var live := _living(side)
	if live.is_empty():
		return null
	var sel := 0
	while true:
		overlay.clear_text()
		var u: Dictionary = live[sel]
		var c := _center(u)
		await overlay.write("{C14}↓", int(c.x) - 8, maxi(0, int(c.y) - 40), false, 320)
		await overlay.write("{C15}" + String(u["name"]), 8, 8, false, 320)
		while true:
			await get_tree().process_frame
			if Keys.just("ui_right") or Keys.just("ui_down"):
				sel = (sel + 1) % live.size()
				break
			if Keys.just("ui_left") or Keys.just("ui_up"):
				sel = (sel - 1 + live.size()) % live.size()
				break
			if Keys.just("ui_accept"):
				overlay.clear_text()
				return live[sel]
			if Keys.just("ui_cancel"):
				overlay.clear_text()
				return null
	return null


func _skill(id: int) -> Variant:
	var ss: Array = data["skills"]
	return ss[id] if id >= 0 and id < ss.size() else null


func _skill_target_kind(sk: Dictionary) -> String:
	return String(sk.get("target", "all"))


func _pick_skill(m: Dictionary):
	var usable := []
	var labels := []
	for id in m["skills"]:
		var sk = _skill(int(id))
		if sk == null or not sk.get("battle_usable", true):
			continue
		usable.append(sk)
		labels.append("%s %s" % [String(sk["name"]), _fw(int(sk["cost"]))])
	if usable.is_empty():
		await _message("沒有奇術")
		return null
	var i := await _choose_scroll(labels, m)
	return usable[i] if i >= 0 else null


func _pick_skill_target(sk: Dictionary):
	match _skill_target_kind(sk):
		"enemy":
			return await _pick_target(enemies)
		"ally":
			return await _pick_target(members)
		"self":
			return {}
	return {}


func _pick_item(m := {}):
	var list := []
	var labels := []
	var items: Array = data["items"]
	for k in 50:
		var v := GameState.w(GameState.ITEMS + k * 2)
		var id := v & 0x0FFF
		if id >= 314 and _monster(id) != null:
			list.append({"slot": k, "monster": _monster(id)})
			labels.append(String(_monster(id)["name"]))
			continue
		if id == 0 or id >= items.size():
			continue
		var it: Dictionary = items[id]
		if not it.get("battle_usable", false):
			continue
		list.append({"slot": k, "item": it})
		labels.append(String(it["name"]))
	if list.is_empty():
		await _message("沒有可用的物品")
		return null
	while true:
		var i := await _choose_scroll(labels, {"slot": 1})
		if i < 0:
			return null
		var mo = list[i].get("monster")
		if mo == null:
			return list[i]
		# FIG 0x182C: monster +05 bit 2, and 體力 >= 2 x level
		if not (_monster_byte5(mo) & 0x02):
			await _message("現在無法使用！")
		elif m.is_empty() or int(m["sta"]) < 2 * int(mo["level"]):
			await _message("體力不夠，無法招喚！")
		else:
			return list[i]
	return null


static func _monster_byte5(mo: Dictionary) -> int:
	var h := String(mo.get("header_raw", ""))
	return h.substr(10, 2).hex_to_int() if h.length() >= 12 else 0


## Like _choose but pages through long lists, 6 lines at a time.
func _choose_scroll(labels: Array, m: Dictionary) -> int:
	var top := 0
	var sel := 0
	var x := 96
	while true:
		overlay.show_box(true)
		var y := 12
		for k in range(top, mini(top + 4, labels.size())):
			await overlay.write(("{C14}" if k == sel else "{C7}") + String(labels[k]), x - 56, y, false, 320)
			y += 16
		while true:
			await get_tree().process_frame
			if Keys.just("ui_down"):
				sel = mini(sel + 1, labels.size() - 1)
				break
			if Keys.just("ui_up"):
				sel = maxi(sel - 1, 0)
				break
			if Keys.just("ui_accept"):
				overlay.clear()
				return sel
			if Keys.just("ui_cancel"):
				overlay.clear()
				return -1
		if sel < top:
			top = sel
		elif sel >= top + 4:
			top = sel - 3
	return -1


# ---------------------------------------------------------------- actions

func _member_act(m: Dictionary, c) -> void:
	if not (c is Dictionary):
		return
	match c.get("kind"):
		"attack":
			var t = c.get("target")
			if t == null or not _alive(t):
				t = _first_alive(enemies)
			if t != null:
				await _attack_enemy(m, t)
		"skill":
			await _cast(m, c["skill"], c.get("target"))
		"item":
			await _use_item(m, c)
		"defend":
			await _defend(m)
		"capture":
			await _capture(m, c.get("target"))
		"summon":
			await _summon(m, int(c["slot"]), c["monster"])


## FIG 0x12DC.
func _attack_enemy(m: Dictionary, e: Dictionary) -> void:
	crit_counter = maxi(1, crit_counter - 1)
	var crit := randi() % crit_counter == 0
	if crit:
		crit_counter = 21
	_set_pose(m, 7 if crit else 5)
	await _message(_msg("0x1dfb", "攻 擊"), 0.2)
	_set_pose(m, 8 if crit else 6)
	var atk := randi_range(0, int(m["lvl"]) / 2 + 1) + int(m["atk"])
	if int(e["immune"]) == 1 or atk <= int(e["def"]):
		await _message("沒有效果", 0.4)
	elif _can_act(e) and randi() % 12 < int(e["eva"]):
		await _message(_msg("0x1e0d", "閃 躲"), 0.4)
	else:
		var dmg := atk - int(e["def"])
		if crit:
			dmg *= 2
		await _hurt(e, dmg)
	_set_pose(m, 0)


## Damage to a unit, with the flash, number and KO handling.
func _hurt(u: Dictionary, dmg: int) -> void:
	dmg = maxi(dmg, 0)
	u["hp"] = maxi(0, int(u["hp"]) - dmg)
	if game.bot and u["side"] == 0:
		u["hp"] = maxi(1, int(u["hp"]))      # test bot: the party cannot fall
	_pop(u, dmg, NUM_RED)
	var n: Sprite2D = u["node"]
	if n:
		for k in 3:
			n.visible = false
			await _wait(0.05)
			n.visible = true
			await _wait(0.05)
	if int(u["hp"]) <= 0:
		if u["side"] == 0:
			u["status"] = KO
			crit_counter = 1    # FIG: the next party attack is a sure crit
			_place_member(u)
		else:
			game.play_sfx(int(u["mon"].get("death_sfx", 26)))
			if not (int(u["status"]) & 0x8000) and n:
				var t := create_tween()
				t.tween_property(n, "modulate:a", 0.0, 0.3)
	_redraw()


func _heal(u: Dictionary, field: String, v: int) -> void:
	var mx: String = {"hp": "hpm", "mp": "mpm", "sta": "stam"}[field]
	u[field] = mini(int(u[mx]), int(u[field]) + v)
	_pop(u, v, NUM_GREEN)
	_redraw()


func _pay(m: Dictionary, sk: Dictionary) -> bool:
	var cost := int(sk["cost"])
	match String(sk.get("cost_type", "")):
		"mp":
			if int(m["mp"]) < cost:
				return false
			m["mp"] = int(m["mp"]) - cost
		"stamina":
			if int(m["sta"]) < cost:
				return false
			m["sta"] = int(m["sta"]) - cost
		"herbs":
			# DS:4ED counters, one per herb bit
			for b in 5:
				if cost & (1 << b) and GameState.w(0x4ED + b * 2) == 0:
					return false
			for b in 5:
				if cost & (1 << b):
					GameState.setw(0x4ED + b * 2, GameState.w(0x4ED + b * 2) - 1)
	return true


## Skills, party side (FIG 0x42F6 cost, 0x1DBD effect).
func _cast(m: Dictionary, sk: Dictionary, target, free := false) -> void:
	if int(m["status"]) & 0x80:
		await _message(_msg("0x1e2f", "現在無法使用！"))
		return
	if not free and not _pay(m, sk):
		await _message(_msg("0x1e15", "數值不夠！無法用此奇術！"))
		return
	_set_pose(m, 1)
	await _message(String(sk["name"]), 0.3)
	_set_pose(m, 3)
	if int(sk.get("sfx", 0)):
		game.play_sfx(int(sk["sfx"]))
	var targets := _skill_targets(sk, m, target, 0)
	await _play_anim(sk, m, func(): await _apply_skill(m, sk, targets, false))
	_set_pose(m, 0)
	# chained effects (+0A)
	var nxt := int(sk.get("next_skill", 0))
	if nxt > 0 and nxt != int(sk["id"]):
		var s2 = _skill(nxt)
		if s2 != null:
			await _apply_skill(m, s2, _skill_targets(s2, m, target, 0), false)


func _skill_targets(sk: Dictionary, caster: Dictionary, target, caster_side: int) -> Array:
	var kind := _skill_target_kind(sk)
	var effect := int(sk.get("effect", 0))
	var hostile := effect == 2 or effect == 8 or effect == 9
	var foes := enemies if caster_side == 0 else members
	var friends := members if caster_side == 0 else enemies
	match kind:
		"self":
			return [caster]
		"ally", "enemy":
			if target is Dictionary and not target.is_empty():
				return [target]
			return [_first_alive(foes if hostile else friends)] if _first_alive(foes if hostile else friends) != null else []
	return _living(foes if hostile else friends)


## Applies one skill record to its targets. `enemy_caster` uses the enemy-side
## meaning of the effect types (FIG 0x2703).
func _apply_skill(caster: Dictionary, sk: Dictionary, targets: Array, enemy_caster: bool) -> void:
	var r: Array = sk.get("raw_1a", [0, 0, 0, 0, 0, 0, 0])
	var lvl := int(caster["lvl"])
	match int(sk.get("effect", 0)):
		1:  # heal / cure (FIG 0x4997)
			for t in targets:
				var revive := (int(r[4]) & 0x2000) == 0 and int(r[4]) != 0
				if not _alive(t) and not revive:
					continue
				if int(r[4]):
					t["status"] = int(t["status"]) & int(r[4])
					if t["side"] == 0:
						_place_member(t)
				for pair in [[1, "hp"], [2, "sta"], [3, "mp"]]:
					var v := int(r[pair[0]])
					if v == 0:
						continue
					var mx: String = {"hp": "hpm", "mp": "mpm", "sta": "stam"}[pair[1]]
					if v & 0x8000:
						v = int(t[mx]) * (v & 0x7FFF) / 100
					v += int(caster.get("int", 0)) / 4
					_heal(t, pair[1], v)
				if int(r[5]) and int(r[6]) and t["side"] == 0:
					GameState.setw(int(t["rec"]) + int(r[5]), GameState.w(int(t["rec"]) + int(r[5])) + int(r[6]))
		2:  # damage (FIG 0x4EF3; enemy 0x237A)
			for t in targets:
				if not _alive(t):
					continue
				if int(t["timers"].get("guard", 0)) > 0:
					await _message(_msg("0x1ed9", "護 魔"), 0.3)
					continue
				if int(t.get("decoys", 0)) > 0:
					t["decoys"] = int(t["decoys"]) - 1
					await _message(_msg("0x1ee1", "替 身"), 0.3)
					continue
				var dmg := randi_range(0, lvl / 2 + 1) + int(sk.get("power", 0))
				var el := int(sk.get("element", 0))
				if enemy_caster and el == 1:
					_grow_passive(t, 0xF5, 0xF9, dmg)
				elif enemy_caster and el == 2:
					_grow_passive(t, 0xFA, 0xFD, dmg)
				var res := int(t["res"][el]) if el >= 1 and el <= 4 else 0
				match res:
					1:
						await _message("失效", 0.3)
						continue
					2:
						dmg *= 2
					3:
						_heal(t, "hp", dmg)
						continue
				await _hurt(t, dmg)
		3:  # buffs (FIG 0x4DE4)
			for t in targets:
				var turns := randi_range(0, 4) + int(sk.get("power", 0))
				var base: Dictionary = t["base"]
				if int(r[0]):
					t["agi"] = int(base["agi"]) + randi_range(0, lvl / 2 + 1) + int(r[0])
					t["timers"]["agi"] = turns
				if int(r[1]):
					t["def"] = int(base["def"]) + randi_range(0, lvl / 2 + 1) + int(r[1])
					t["timers"]["def"] = turns
				if int(r[2]):
					t["atk"] = int(base["atk"]) + randi_range(0, lvl / 2 + 1) + int(r[2])
					t["timers"]["atk"] = turns
				if int(r[3]):
					t["eva"] = int(r[3])
					t["timers"]["eva"] = turns
				if int(r[4]):
					t["timers"]["guard"] = int(r[4])
				if int(r[5]):
					t["decoys"] = int(r[5])
		7:  # escape
			if random_encounter:
				fled = true
		8:  # status (FIG 0x5037 / 0x27AC)
			for t in targets:
				if not _alive(t):
					continue
				var el := int(sk.get("element", 0))
				if el >= 1 and el <= 4 and int(t["res"][el]) == 1:
					await _message("失效", 0.3)
					continue
				if t["side"] == 1 and int(t["status"]) & 0x8000:
					await _message("失效", 0.3)
					continue
				var bits := int(r[0])
				t["status"] = int(t["status"]) | bits
				var turns := randi_range(0, 4) + (int(sk.get("power", 0)) if t["side"] == 1 else 2)
				for b in 16:
					if bits & (1 << b):
						t["timers"]["s%d" % b] = turns
				if t["side"] == 0:
					_place_member(t)
		9:  # dispel buffs
			for t in targets:
				for k in ["agi", "def", "atk", "eva"]:
					t[k] = t["base"][k]
					t["timers"].erase(k)
				t["timers"].erase("guard")
				t["decoys"] = 0
	_redraw()


## Spell animation scripts (FIG 0x4B5B, op table DS:1DD1): frames from an
## SA.LSK sheet drawn over the battle, palette ramps, shakes, and the point
## where the effect lands (op 7). `apply` runs there, or at the end.
func _play_anim(sk: Dictionary, caster: Dictionary, apply: Callable) -> void:
	var ops: Array = sk.get("anim", [])
	var applied := false
	var sheet = null
	var layer := Node2D.new()
	layer.z_index = 3
	add_child(layer)
	var pending: Array = []
	var cnode: Sprite2D = caster.get("node")
	var old_z := cnode.z_index if cnode else 0
	if Overlay.auto_continue:
		ops = []
	for o in ops:
		var a: Array = o
		match String(a[0]):
			"enemy_branch":
				if caster["side"] == 1:
					break
			"load_sa_lsk":
				sheet = Assets.pictures(0, int(a[1]))
			"draw":
				if sheet != null and int(a[1]) < sheet["frames"].size():
					var sp := _sprite(sheet["texture"], sheet["frames"][int(a[1])], Vector2(int(a[2]) * 4, int(a[3])))
					sp.visible = false
					layer.add_child(sp)
					pending.append(sp)
			"restore_bg":
				for c in layer.get_children():
					if not pending.has(c):
						c.queue_free()
			"draw_caster":
				if cnode:
					cnode.z_index = 4
			"flip":
				for sp in pending:
					sp.visible = true
				pending.clear()
				await _wait(TICK)
			"delay":
				await _wait(TICK * maxi(1, int(a[1])))
			"flash":
				for k in maxi(1, int(a[1])):
					set_brightness(1.8)
					await _wait(TICK)
					set_brightness(1.0)
					await _wait(TICK)
			"apply_damage":
				if not applied:
					applied = true
					await apply.call()
			"pal_sub", "pal_fade_down":
				set_brightness(0.55)
			"pal_add", "pal_fade_up":
				set_brightness(1.35)
			"pal_restore":
				set_brightness(1.0)
			"shake_redraw", "shake_range":
				for k in 4:
					position.y = 3 if k % 2 == 0 else -3
					await _wait(TICK * 0.5)
				position.y = 0
			"sfx":
				game.play_sfx(int(a[1]))
	set_brightness(1.0)
	layer.queue_free()
	if cnode:
		cnode.z_index = old_z
	if not applied:
		if ops.is_empty() and not Overlay.auto_continue:
			await _flash_screen()
		await apply.call()


func _flash_screen() -> void:
	for k in 2:
		set_brightness(1.6)
		await _wait(0.05)
		set_brightness(1.0)
		await _wait(0.05)


func _use_item(m: Dictionary, c: Dictionary) -> void:
	var it: Dictionary = c["item"]
	var id := int(it["id"])
	if id >= 314:
		await _message("無法使用")
		return
	await _message(String(it["name"]), 0.3)
	var sk = c.get("skill")
	if sk != null:
		# 符咒 (category 0x10) cast their skill and cost 仙術; others are free
		var talisman := int(it.get("category", 0)) == 0x10
		if talisman:
			await _cast(m, sk, c.get("target"))
		else:
			await _apply_skill(m, sk, _skill_targets(sk, m, c.get("target"), 0), false)
	if it.get("consumed", false):
		var off := GameState.ITEMS + int(c["slot"]) * 2
		if GameState.w(off) & 0x0FFF == id:
			GameState.setw(off, 0)
			_compact_items()


func _compact_items() -> void:
	var ids := []
	for k in 50:
		var v := GameState.w(GameState.ITEMS + k * 2)
		if v != 0:
			ids.append(v)
	for k in 50:
		GameState.setw(GameState.ITEMS + k * 2, ids[k] if k < ids.size() else 0)


## FIG 0x750: only in random encounters.
func _try_flee(m: Dictionary) -> bool:
	if not random_encounter:
		await _message("無法逃走")
		return false
	if flee_tries == 0:
		flee_tries = members.size() * 2
	var e0 = _first_alive(enemies)
	var ok := e0 == null or int(m["lvl"]) >= int(e0["lvl"]) + 4 or randi() % 10 < 2
	flee_tries -= 1
	if flee_tries <= 0:
		ok = true
	if not ok:
		await _message(_msg("0x1e03", "逃走失敗"))
	return ok


# ---------------------------------------------------------------- enemy turn

## FIG 0x2132.
func _enemy_act(e: Dictionary) -> void:
	var mo: Dictionary = e["mon"]
	var leader = members[0] if not members.is_empty() else null
	if random_encounter and not (int(e["status"]) & 0xE000):
		if int(mo.get("flee_mode", 0)) == 2:
			await _enemy_leaves(e)
			return
		if leader and int(leader["lvl"]) >= int(e["lvl"]) + 9:
			var r := randi() % 3
			if r == 2:
				await _enemy_leaves(e)
				return
			if r == 1:
				return
	if int(e["hp"]) <= int(e["hpm"]) / 4:
		var heal = _skill(int(mo.get("heal_skill", 0)))
		if heal != null and int(mo.get("heal_skill", 0)) and int(e["mp"]) >= int(heal["cost"]):
			e["mp"] = int(e["mp"]) - int(heal["cost"])
			await _message(String(heal["name"]), 0.4)
			var v := int(heal["raw_1a"][1])
			_heal(e, "hp", v)
			return
		if random_encounter and int(mo.get("flee_mode", 0)) == 1:
			var r2 := randi() % 3
			if r2 == 0:
				await _enemy_leaves(e)
				return
			if r2 == 2:
				return
	var live := _living(members)
	if live.is_empty():
		return
	var target: Dictionary = live[randi() % live.size()]
	if not (int(e["status"]) & 0x80) and randi() % 10 <= int(mo.get("magic_freq", 0)) and int(mo.get("magic_freq", 0)) > 0:
		var sid := 0
		var sp: Array = mo.get("special_skills", [0, 0])
		if randi() % 10 <= int(mo.get("special_freq", 0)) and (int(sp[0]) or int(sp[1])):
			sid = int(sp[randi() % 2])
		else:
			var ss: Array = mo.get("skills", [0, 0, 0])
			sid = int(ss[2 - randi() % 3])
		var sk = _skill(sid)
		if sid and sk != null and int(e["mp"]) >= int(sk["cost"]):
			e["mp"] = int(e["mp"]) - int(sk["cost"])
			await _message(String(sk["name"]), 0.4)
			if int(sk.get("sfx", 0)):
				game.play_sfx(int(sk["sfx"]))
			var tg := _skill_targets(sk, e, target, 1)
			await _play_anim(sk, e, func(): await _apply_skill(e, sk, tg, true))
			return
	await _attack_member(e, target)


func _enemy_leaves(e: Dictionary) -> void:
	e["gone"] = true
	e["exp_lost"] = true
	await _message(String(e["name"]) + _msg("0x1ec7", "逃  走").strip_edges(), 0.5)
	_redraw()


## FIG 0x2B03.
func _attack_member(e: Dictionary, m: Dictionary) -> void:
	var mo: Dictionary = e["mon"]
	game.play_sfx(int(mo.get("attack_sfx", 40)))
	var n: Sprite2D = e["node"]
	if n:
		var t := create_tween()
		t.tween_property(n, "position:y", n.position.y + 8, 0.08)
		t.tween_property(n, "position:y", n.position.y, 0.08)
		await t.finished
	var lv := int(e["lvl"])
	if int(m["immune"]) == 1:
		await _message("沒有效果", 0.3)
		return
	var atk := randi_range(0, lv / 2 + 1) + int(e["atk"])
	var dmg := 0
	if atk <= int(m["def"]):
		var roll := randi_range(0, lv / 2 + 1)
		if roll == 0:
			await _message(_msg("0x1e0d", "閃 躲"), 0.3)
			return
		dmg = roll
	else:
		if _can_act(m) and randi() % 12 < int(m["eva"]):
			await _message(_msg("0x1e0d", "閃 躲"), 0.3)
			return
		dmg = atk - int(m["def"])
	if int(m.get("decoys", 0)) > 0:
		m["decoys"] = int(m["decoys"]) - 1
		await _message(_msg("0x1ee1", "替 身"), 0.3)
		return
	_grow_passive(m, 0xF2, 0xF4, dmg)
	await _hurt(m, dmg)
	var pz := int(mo.get("poison", 1))
	if pz != 1 and _alive(m) and randi() % 10 <= pz:
		m["status"] = int(m["status"]) | 0x200


# ---------------------------------------------------------------- timers

## FIG 0x883 / 0xA4F: buffs run out, status counters tick, 蠱毒 hurts.
func _end_of_turn(u: Dictionary) -> void:
	var t: Dictionary = u["timers"]
	for k in t.keys():
		t[k] = int(t[k]) - 1
		if t[k] > 0:
			continue
		t.erase(k)
		if k in ["agi", "def", "atk", "eva"]:
			u[k] = u["base"][k]
		elif k.begins_with("s"):
			u["status"] = int(u["status"]) & ~(1 << int(k.substr(1)))
	if int(u["status"]) & 0x100 and _alive(u):
		var l := int(enemies[0]["lvl"]) if u["side"] == 0 and not enemies.is_empty() else int(members[0]["lvl"])
		u["hp"] = maxi(0, int(u["hp"]) - (randi_range(0, 2 * l - 1) + l))
		if int(u["hp"]) <= 0 and u["side"] == 0:
			u["status"] = KO
			_place_member(u)


# ---------------------------------------------------------------- results

## FIG 0x5A89.
func _victory() -> void:
	exp_total = 0
	money_total = 0
	for e in enemies:
		if e.get("exp_lost", false):
			continue
		exp_total += int(e["exp"])
		money_total += int(e["money"])
	game.play_music_path("RX/RI079.RIX")
	GameState.setw(GameState.MONEY, mini(0xFFFF, GameState.money() + money_total))
	var live := _living(members)
	var share := exp_total / maxi(1, live.size())
	_write_back()
	var lines := "得到經驗值 %s##得到金錢 %s" % [_fw(exp_total), _fw(money_total)]
	var drop := _give_drop(true)
	if drop != "":
		lines += "##得到 " + drop
	await _say_text(lines)
	for m in live:
		var rec: int = m["rec"]
		GameState.setw(rec + 0x39, mini(0xFFFF, GameState.w(rec + 0x39) + share))
		var ups := _level_up(m)
		if ups > 0:
			game.play_music_path("RX/RI040.RIX")
			await _say_text("%s 等級提升到 %s！" % [m["name"], _fw(GameState.w(rec + 0x31))])
			# reload stats so the write-back below keeps the refills
			var fresh := _load_member(int(m["slot"]))
			for k in ["hp", "hpm", "mp", "mpm", "sta", "stam", "status"]:
				m[k] = fresh[k]


func _say_text(text: String) -> void:
	overlay.show_box(false)
	await overlay.write(text, 40, 124, true, 280, 4)
	await overlay.wait_key(Vector2(280, 172))
	overlay.clear()


## Group drop item ("##"): always with bit 0x8000, else 1 in 3.
func _give_drop(roll: bool) -> String:
	var d = group.get("drop")
	if not (d is Dictionary):
		return ""
	if roll and not d.get("always", false) and randi() % 3 != 0:
		return ""
	var id := int(d["item"])
	for k in 50:
		var off := GameState.ITEMS + k * 2
		if GameState.w(off) == 0:
			GameState.setw(off, id)
			return String(data["items"][id]["name"]) if id < data["items"].size() else ""
	return ""


## FIG 0x5BF7: per-character tables of 50 rows, a level-up adds the
## difference of two rows.
func _level_up(m: Dictionary) -> int:
	var rec: int = m["rec"]
	var table = null
	for t in data.get("level_tables", []):
		if int(t["character"]) == int(m["char"]):
			table = t
	if table == null:
		return 0
	var rows: Array = table["rows"]
	var n := 0
	while true:
		var lvl := GameState.w(rec + 0x31)
		if lvl >= 50 or lvl >= rows.size():
			break
		var need := GameState.w(rec + 0x3B)
		var ex := GameState.w(rec + 0x39)
		if ex < need:
			break
		GameState.setw(rec + 0x39, ex - need)
		var a: Dictionary = rows[lvl - 1]
		var b: Dictionary = rows[lvl]
		var d := func(k: String) -> int: return int(b[k]) - int(a[k])
		var add := func(o: int, v: int) -> void: GameState.setw(rec + o, GameState.w(rec + o) + v)
		add.call(0x2F, d.call("hp_max")); GameState.setw(rec + 0x2D, GameState.w(rec + 0x2F))
		add.call(0x57, d.call("mp_max")); GameState.setw(rec + 0x55, GameState.w(rec + 0x57))
		add.call(0x3D, d.call("strength")); add.call(0x0C, d.call("strength"))
		add.call(0x0E, d.call("defense"))
		add.call(0x4D, d.call("agility")); add.call(0x5D, d.call("agility"))
		add.call(0x33, d.call("luck"))
		add.call(0x37, d.call("stamina_max")); GameState.setw(rec + 0x35, GameState.w(rec + 0x37))
		GameState.setw(rec + 0x3B, int(b["exp_next"]))
		var learn := int(b["learn_skill"])
		if learn:
			for k in 50:
				if GameState.b(rec + 0x6D + k) == 0:
					GameState.setb(rec + 0x6D + k, learn)
					break
		GameState.setw(rec + 0x08, 0)
		GameState.setw(rec + 0x31, lvl + 1)
		n += 1
	return n


func _defeat() -> void:
	result = Result.LOSE
	game.play_music_path("RX/RI041.RIX")
	await _say_text("　全體陣亡！")


# ---------------------------------------------------------------- creatures
# docs/CREATURES.md: 煉妖術 capture, 防禦 with 法寶 creatures, summoned allies.

func _free_item_slot() -> int:
	for k in 50:
		if GameState.w(GameState.ITEMS + k * 2) == 0:
			return k
	return -1


## FIG 0xEA2: no roll and no cost; the conditions decide.
func _capture(m: Dictionary, e) -> void:
	if e == null or not _alive(e):
		e = _first_alive(enemies)
	if e == null:
		return
	_set_pose(m, 2)
	game.play_sfx(0x10)
	await _wait(3 * TICK)
	_set_pose(m, 3)
	await _message("煉妖術", 0.5)
	var lv := int(members[0]["lvl"])
	var el := int(e["lvl"])
	var ok := random_encounter and _free_item_slot() >= 0 \
		and not (int(e["mon"].get("flags", 0)) & 0xA000) and el <= lv + 7 \
		and (lv < 5 or el <= lv - 5 or int(e["hp"]) <= int(e["hpm"]) >> 2)
	if ok:
		e["hp"] = 0
		GameState.setw(GameState.ITEMS + _free_item_slot() * 2, int(e["id"]))
		game.play_sfx(0x0F)
		_redraw()
		await _wait(9 * TICK)
	else:
		await _message(_msg("0x1df3", "失　敗"), 0.4)
	_set_pose(m, 0)


## FIG 0xBD0: 防禦 has no effect of its own; it fires the creatures in the
## two 法寶 slots (+1E, +20).
func _defend(m: Dictionary) -> void:
	_set_pose(m, 4)
	await _wait(4 * TICK)
	for off in [0x1E, 0x20]:
		var id := GameState.w(int(m["rec"]) + off)
		if id >= 0xE6 and id <= 0xEB:
			var kinds := [0x0E, 0x10, 0x12] if id <= 0xE8 else [0x1A, 0x1E, 0x14]
			var n := 0
			for e in enemies:
				if not _alive(e) or not random_encounter or int(e["status"]) & 0xE000:
					continue
				if not int(e["mon"].get("species", 0)) in kinds:
					continue
				game.play_sfx(int(e["mon"].get("death_sfx", 26)))
				e["hp"] = 0
				e["status"] = 0
				e["exp"] = 0
				n += 1
				_redraw()
				await _message("血芝麻" if id <= 0xE8 else "青魚牙", 0.3)
			if n:
				_grow(m, off, id, n)
		elif id >= 0xEC and id <= 0xEE:
			var sum := 0
			for e in enemies:
				sum += int(e["money"])
				e["money"] = 0
			if sum > 0:
				game.play_sfx(0x0D)
				await _message("金　蠶", 0.3)
				_grow(m, off, id, sum)
	_redraw()
	await _wait(8 * TICK)
	_set_pose(m, 0)


## FIG 0xDCE: counters per creature id at RPG DS:645, clamped at the
## threshold, where the slot item turns into the next one.
func _grow(m: Dictionary, off: int, id: int, n: int) -> void:
	var ctr := 0x645 + 2 * (id - 0xE6)
	var v := GameState.w(ctr) + n
	var g = null
	for row in data.get("creature_growth", []):
		if int(row["id"]) == id:
			g = row
	if g == null:
		return
	var thr := int(g["threshold"])
	if v >= thr:
		v = thr
		GameState.setw(int(m["rec"]) + off, int(g["next"]))
	GameState.setw(ctr, mini(v, 0xFFFF))


## Passive growth for both 法寶 slots of a party member hit by something.
func _grow_passive(m: Dictionary, lo: int, hi: int, n: int) -> void:
	if m.get("side", 0) != 0 or not m.has("rec") or n <= 0:
		return
	for off in [0x1E, 0x20]:
		var id := GameState.w(int(m["rec"]) + off)
		if id >= lo and id <= hi:
			_grow(m, off, id, n)


## FIG 0x1232 / 0x53E1: the monster leaves the inventory and fights on the
## party side from the next round; it has no HP and is never drawn.
func _summon(m: Dictionary, slot: int, mo: Dictionary) -> void:
	var off := GameState.ITEMS + slot * 2
	var id := int(mo["id"])
	if GameState.w(off) & 0x0FFF != id:
		return
	var s := allies.find(null)
	if s < 0:
		await _message("要替換那一隻？", 0.3)
		s = 0 if Overlay.auto_continue else await _pick_ally()
		if s < 0:
			return
		GameState.setw(off, int(allies[s]["id"]))
	else:
		GameState.setw(off, 0)
	game.play_sfx(0x0E)
	m["sta"] = maxi(0, int(m["sta"]) - 2 * int(mo["level"]))
	allies[s] = {
		"side": 2, "slot": s, "id": id, "name": mo["name"], "mon": mo, "node": null,
		"lvl": int(mo["level"]), "mp": int(mo["mp"]), "atk": int(mo["attack"]),
		"agi": int(mo["agility"]), "luck": int(mo["luck"]), "ready": false,
	}
	_redraw()


func _pick_ally() -> int:
	var sel := 0
	while true:
		overlay.clear_text()
		await overlay.write("{C14}" + String(allies[sel]["name"]), 8 + sel * 80, 9, false, 320)
		while true:
			await get_tree().process_frame
			if Keys.just("ui_left") or Keys.just("ui_right"):
				sel = 1 - sel
				break
			if Keys.just("ui_accept"):
				overlay.clear_text()
				return sel
			if Keys.just("ui_cancel"):
				overlay.clear_text()
				return -1
	return -1


## FIG 0xF8E: enemy-like choice of skill, cast with member 0 as the caster;
## anything that cannot be cast becomes a plain attack (no roll, no crit).
func _ally_act(a: Dictionary) -> void:
	var live := _living(enemies)
	if live.is_empty():
		return
	var target: Dictionary = live[randi() % live.size()]
	var mo: Dictionary = a["mon"]
	if randi() % 10 <= int(mo.get("magic_freq", 0)):
		var sid := 0
		var sp: Array = mo.get("special_skills", [0, 0])
		if randi() % 10 <= int(mo.get("special_freq", 0)):
			sid = int(sp[randi() % 2])
		else:
			var ss: Array = mo.get("skills", [0, 0, 0])
			sid = int(ss[2 - randi() % 3])
		var sk = _skill(sid)
		if sid and sk != null and int(a["mp"]) >= int(sk["cost"]) \
				and not (_skill_target_kind(sk) in ["self", "ally"]):
			a["mp"] = int(a["mp"]) - int(sk["cost"])
			if Array(sk.get("media_required", [])).is_empty():
				await _message(_msg("0x200c", "奇 術"), 0.3)
				var caster: Dictionary = members[0]
				var tg := _skill_targets(sk, caster, target if _skill_target_kind(sk) == "enemy" else null, 0)
				await _play_anim(sk, caster, func(): await _apply_skill(caster, sk, tg, false))
				return
	await _message(_msg("0x1dfb", "攻 擊"), 0.2)
	game.play_sfx(int(mo.get("attack_sfx", 40)))
	if _can_act(target) and randi() % 12 < int(target["eva"]):
		await _message(_msg("0x1e0d", "閃 躲"), 0.3)
		return
	var dmg := int(a["atk"]) - int(target["def"])
	if int(target["immune"]) == 1 or dmg <= 0:
		await _message("沒有效果", 0.3)
		return
	await _hurt(target, dmg)


## Battle end (FIG 0x256): summoned monsters go back to the inventory, or
## are lost when it is full.
func _return_allies() -> void:
	_compact_items()
	for s in 2:
		if allies[s] == null:
			continue
		var k := _free_item_slot()
		if k >= 0:
			GameState.setw(GameState.ITEMS + k * 2, int(allies[s]["id"]))
		allies[s] = null
