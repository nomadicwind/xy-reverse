class_name FieldMenu
extends RefCounted
## The menus RPG.EXE opens on the field: the main menu (status, items,
## equipment, skills, system), shops (ops 0x11/0x13), storage (op 0x42), the
## save prompt (op 0x45) and the journal. Texts are RPG.EXE's own strings.
##
## Data lives in the RPG data block (GameState.ds):
##   0x399  inventory, 50 words (item id, high bits are per-member marks)
##   0x3FD  storage, 0x78 words
##   0x4ED  herb counters (藥材金木水火土, items 68..72)
##   party records at 0x11D, equipment words at +0x10

const INV := 0x399
const INV_N := 50
const STORE := 0x3FD
const STORE_N := 0x78
const HERBS := 0x4ED
const HERB_FIRST := 68
const HERB_MAX := 99
const STATUS_NAMES := [[0x2000, "死亡"], [0x0200, "中毒"], [0x0100, "中蠱"], [0x0080, "封魔"],
		[0x0020, "睡眠"], [0x0010, "冰凍"], [0x0008, "失明"], [0x0004, "麻痺"], [0x0002, "束縛"]]
const SLOT_NAMES := ["護頭", "護甲", "武器", "鞋", "戒指", "護駕", "護駕", "法寶", "法寶"]
const MACHINE_SLOTS := ["頭", "驅", "臂", "腿", "心", "護駕", "護駕", "法寶", "法寶"]
## item kind (+06 low nibble) -> equipment slots (RPG 0x43CC)
const KIND_SLOTS := {7: [0], 3: [1], 5: [2], 2: [3], 6: [4], 1: [5, 6], 4: [7, 8]}

var game: Game
var ov: Overlay
var data: Dictionary


func _init(g: Game) -> void:
	game = g
	ov = g.overlay
	data = Battle.battle_data()


# ---------------------------------------------------------------- helpers

static func fw(n: int) -> String:
	return Battle._fw(n)


func _item(id: int) -> Variant:
	var items: Array = data.get("items", [])
	if id >= 0 and id < items.size():
		return items[id]
	var ms: Array = data.get("monsters", [])
	if id >= 314 and id - 314 < ms.size():
		return ms[id - 314]
	return null


func _item_name(id: int) -> String:
	var it = _item(id)
	return String(it["name"]) if it != null else "？"


func _skill(id: int) -> Variant:
	var ss: Array = data.get("skills", [])
	return ss[id] if id >= 0 and id < ss.size() else null


func _rec(m: int) -> int:
	return GameState.PARTY + m * GameState.PARTY_REC


func _member_char(m: int) -> int:
	return GameState.w(0x89 + m * 6) / 12


func _member_name(m: int) -> String:
	var ch := _member_char(m)
	return GameState.names[ch] if ch < GameState.names.size() and GameState.names[ch] != "" else "？"


func _members() -> Array:
	var out := []
	for m in mini(GameState.w(GameState.PARTY_COUNT), 4):
		out.append(m)
	return out


func _inventory() -> Array:
	var out := []
	for k in INV_N:
		var v := GameState.w(INV + k * 2) & 0x0FFF
		if v != 0:
			out.append({"slot": k, "id": v})
	return out


func _compact(base: int, n: int) -> void:
	var ids := []
	for k in n:
		var v := GameState.w(base + k * 2)
		if v != 0:
			ids.append(v)
	for k in n:
		GameState.setw(base + k * 2, ids[k] if k < ids.size() else 0)


func _add_to(base: int, n: int, id: int) -> bool:
	for k in n:
		if GameState.w(base + k * 2) == 0:
			GameState.setw(base + k * 2, id)
			return true
	return false


func add_item(id: int) -> bool:
	if id >= HERB_FIRST and id < HERB_FIRST + 5:
		var off := HERBS + (id - HERB_FIRST) * 2
		if GameState.w(off) >= HERB_MAX:
			return false
		GameState.setw(off, GameState.w(off) + 1)
		return true
	return _add_to(INV, INV_N, id)


func _clear_rect(r: Rect2) -> void:
	ov.items = ov.items.filter(func(it): return it["kind"] != "glyph" or not r.has_point(it["at"]))
	ov.queue_redraw()


func _text(t: String, x: int, y: int, color := 7) -> void:
	await ov.write("{C%d}%s" % [color, t], x, y, false, 320)


## A one-box message at the bottom; waits for a key.
func message(text: String) -> void:
	var keep := ov.frames.size()
	var r := ov.add_frame(Vector2(16, 112), 9, 4)
	await ov.write("{C15}" + text, int(r.position.x) + 24, int(r.position.y) + 12, true, 280, 4)
	await ov.wait_key(Vector2(280, 172))
	ov.pop_frames(keep)


func confirm(text: String) -> bool:
	var keep := ov.frames.size()
	var r := ov.add_frame(Vector2(16, 112), 9, 2)
	await ov.write("{C15}" + text, int(r.position.x) + 24, int(r.position.y) + 12, false, 280)
	var i := await choose(["是", "否"], Vector2(208, 64))
	ov.pop_frames(keep)
	return i == 0


func _text_width(t: String) -> int:
	var w := 0
	for c in t:
		w += 8 if c == " " else 16
	return w


## A framed list at `at`; up/down, accept, cancel = -1. Long lists scroll.
## The frame is removed again before returning.
func choose(labels: Array, at: Vector2, sel := 0, rows := 8, extra := Callable()) -> int:
	if labels.is_empty():
		return -1
	var keep := ov.frames.size()
	var w := 32
	for l in labels:
		w = maxi(w, _text_width(String(l)))
	var cols := clampi((w + 48 + 31) / 32, 2, 10)
	var n := mini(rows, labels.size())
	var r := ov.add_frame(at, cols, n)
	var top := clampi(sel - n + 1, 0, maxi(0, labels.size() - n))
	if Overlay.auto_continue:
		# tests: a random pick, often a cancel so menu loops always end
		ov.pop_frames(keep)
		return -1 if randi() % 3 == 0 else randi() % labels.size()
	while true:
		_clear_rect(r)
		for k in n:
			var i := top + k
			if i >= labels.size():
				break
			await _text(String(labels[i]), int(r.position.x) + 24, int(r.position.y) + 12 + k * 16, 14 if i == sel else 7)
		if top > 0:
			await _text("↑", int(r.end.x) - 24, int(r.position.y) + 12, 7)
		if top + n < labels.size():
			await _text("↓", int(r.end.x) - 24, int(r.position.y) + 12 + (n - 1) * 16, 7)
		if extra.is_valid():
			ov.pop_frames(keep + 1)
			await extra.call(sel)
		Keys.reset()
		var moved := false
		while not moved:
			await game.get_tree().process_frame
			if Keys.just("ui_down"):
				sel = (sel + 1) % labels.size()
				moved = true
			elif Keys.just("ui_up"):
				sel = (sel - 1 + labels.size()) % labels.size()
				moved = true
			elif Keys.just("ui_accept"):
				ov.pop_frames(keep)
				return sel
			elif Keys.just("ui_cancel"):
				ov.pop_frames(keep)
				return -1
		if sel < top:
			top = sel
		elif sel >= top + n:
			top = sel - n + 1
	return -1


func _pick_member(at: Vector2) -> int:
	var ms := _members()
	if ms.size() == 1:
		return ms[0]
	var labels := []
	for m in ms:
		labels.append(_member_name(m))
	var i := await choose(labels, at)
	return ms[i] if i >= 0 else -1


# ---------------------------------------------------------------- main menu

func open() -> void:
	ov.clear()
	var sel := 0
	while true:
		var i := await choose(["狀態", "物品", "裝備", "奇術", "系統"], Vector2(8, 8), sel)
		if i < 0:
			break
		sel = i
		match i:
			0: await _status()
			1: await _items()
			2: await _equip()
			3: await _skills()
			4:
				if await _system():
					break
	ov.clear()


func _status_name(st: int) -> String:
	for p in STATUS_NAMES:
		if st & int(p[0]):
			return p[1]
	return "健康"


func _status() -> void:
	var m := await _pick_member(Vector2(96, 8))
	if m < 0:
		return
	var rec := _rec(m)
	var w := func(o: int) -> int: return GameState.w(rec + o)
	var keep := ov.frames.size()
	var r := ov.add_frame(Vector2(0, 0), 10, 11)
	var x := int(r.position.x) + 24
	var y := int(r.position.y) + 12
	var lines := [
		["{C15}" + _member_name(m), ""],
		["等級　" + fw(w.call(0x31)), "經驗　" + fw(w.call(0x39)) + "／" + fw(w.call(0x3B))],
		["生命　" + fw(w.call(0x2D)) + "／" + fw(w.call(0x2F)), ""],
		["體力　" + fw(w.call(0x35)) + "／" + fw(w.call(0x37)), ""],
		["仙術　" + fw(w.call(0x55)) + "／" + fw(w.call(0x57)), ""],
		["狀態　" + _status_name(w.call(0x08)), "金錢　" + fw(GameState.money())],
		["力量　" + fw(w.call(0x3D)), "智慧　" + fw(w.call(0x45))],
		["敏捷　" + fw(w.call(0x4D)), "運氣　" + fw(w.call(0x33))],
		["戰鬥力" + fw(w.call(0x0C)), "防禦力" + fw(w.call(0x0E))],
		["反應力" + fw(w.call(0x5D)), "閃躲率" + fw(w.call(0x65))],
	]
	for l in lines:
		await _text(l[0], x, y, 7)
		if l[1] != "":
			await _text(l[1], x + 144, y, 7)
		y += 16
	await ov.wait_key()
	# page 2: equipment
	_clear_rect(r)
	y = int(r.position.y) + 12
	await _text("裝備：", x, y, 15)
	y += 16
	var names := MACHINE_SLOTS if _member_char(m) == 1 else SLOT_NAMES
	for k in 9:
		var id: int = w.call(0x10 + k * 2)
		await _text(names[k], x, y, 7)
		await _text(_item_name(id) if id else "－", x + 64, y, 7)
		y += 16
	await ov.wait_key()
	ov.pop_frames(keep)


# ---------------------------------------------------------------- items

func _herb_label(k: int) -> String:
	return "%s　%s" % [_item_name(HERB_FIRST + k), fw(GameState.w(HERBS + k * 2))]


func _items() -> void:
	var sel := 0
	while true:
		var inv := _inventory()
		if inv.is_empty():
			await message("沒有物品")
			return
		var labels := []
		for e in inv:
			var id: int = e["id"]
			if id >= HERB_FIRST and id < HERB_FIRST + 5:
				labels.append(_herb_label(id - HERB_FIRST))
			else:
				labels.append(_item_name(id))
		var i := await choose(labels, Vector2(96, 8), sel, 7, _describe.bind(inv))
		if i < 0:
			return
		sel = i
		var e: Dictionary = inv[i]
		var act := await choose(["使用", "丟棄"], Vector2(224, 8))
		if act == 0:
			await _use_item(e)
		elif act == 1:
			var it = _item(int(e["id"]))
			if it != null and int(it.get("flags", 0)) & 0x08:
				await message("這樣物品不能丟棄！")
			elif await confirm("確定要丟棄？"):
				GameState.setw(INV + int(e["slot"]) * 2, 0)
				_compact(INV, INV_N)


## Shows the ITEM2.EXE description of the highlighted item at the bottom.
func _describe(sel: int, inv: Array) -> void:
	var descs: Array = data.get("descriptions", [])
	var id: int = inv[sel]["id"]
	if id >= descs.size():
		return
	var r := ov.add_frame(Vector2(16, 144), 9, 1)
	var d: String = String(descs[id])
	var close := d.find("』")
	if close >= 0:
		d = d.substr(close + 1)
	d = d.replace("##", "")
	if d.length() > 15:
		d = d.substr(0, 15)
	await _text(d, int(r.position.x) + 24, int(r.position.y) + 12, 7)


func _use_item(e: Dictionary) -> void:
	var it = _item(int(e["id"]))
	if it == null:
		return
	var sk = _skill(int(it.get("skill", 0)))
	if sk == null or int(it.get("skill", 0)) == 0 or int(sk.get("effect", 0)) != 1:
		await message("在此無法使用！")
		return
	var m := await _pick_member(Vector2(224, 40))
	if m < 0:
		return
	if not _heal_member(-1, m, sk):
		await message("此人無法使用！")
		return
	if it.get("consumed", false):
		GameState.setw(INV + int(e["slot"]) * 2, 0)
		_compact(INV, INV_N)


## Heal effect (skill type 1) on a party record, as in FIG 0x4997.
func _heal_member(caster: int, m: int, sk: Dictionary) -> bool:
	var rec := _rec(m)
	var r: Array = sk.get("raw_1a", [0, 0, 0, 0, 0, 0, 0])
	var st := GameState.w(rec + 8)
	var revive := int(r[4]) != 0 and (int(r[4]) & 0x2000) == 0
	if st & 0x2000 and not revive:
		return false
	if int(r[4]):
		GameState.setw(rec + 8, st & int(r[4]))
	var bonus := GameState.w(_rec(caster) + 0x45) / 4 if caster >= 0 else 0
	for p in [[1, 0x2D, 0x2F], [2, 0x35, 0x37], [3, 0x55, 0x57]]:
		var v := int(r[p[0]])
		if v == 0:
			continue
		var mx := GameState.w(rec + p[2])
		if v & 0x8000:
			v = mx * (v & 0x7FFF) / 100
		GameState.setw(rec + p[1], mini(mx, GameState.w(rec + p[1]) + v + bonus))
	if int(r[5]) and int(r[6]):
		GameState.setw(rec + int(r[5]), GameState.w(rec + int(r[5])) + int(r[6]))
	return true


# ---------------------------------------------------------------- equipment

func _equip() -> void:
	var m := await _pick_member(Vector2(96, 8))
	if m < 0:
		return
	var rec := _rec(m)
	var sel := 0
	while true:
		var names := MACHINE_SLOTS if _member_char(m) == 1 else SLOT_NAMES
		var labels := []
		for k in 9:
			var id := GameState.w(rec + 0x10 + k * 2)
			labels.append("%s　%s" % [names[k], _item_name(id) if id else "－"])
		var k := await choose(labels, Vector2(64, 8), sel, 9)
		if k < 0:
			return
		sel = k
		var cands := [{"slot": -1, "id": 0}] if k < 5 else []
		for e in _inventory():
			var it = _item(int(e["id"]))
			if it == null or it.get("slot") == null:
				continue
			var kind := int(it.get("kind", 0)) & 0x0F
			if k in KIND_SLOTS.get(kind, []):
				cands.append(e)
		if cands.is_empty():
			await message("無法裝備在這部位。")
			continue
		var cl := []
		for c in cands:
			cl.append("卸下" if int(c["id"]) == 0 else _item_name(int(c["id"])))
		var j := await choose(cl, Vector2(160, 24), 0, 8)
		if j < 0:
			continue
		var c: Dictionary = cands[j]
		var old := GameState.w(rec + 0x10 + k * 2)
		if int(c["id"]) == 0:
			if _member_char(m) == 1:
				await message("機關人裝備，不能懈下！")
				continue
			if old == 0 or not _add_to(INV, INV_N, old):
				continue
			_apply_equip(rec, old, -1)
			GameState.setw(rec + 0x10 + k * 2, 0)
		else:
			if old == 0x96:
				await message("機關人裝備，不能懈下！")
				continue
			GameState.setw(INV + int(c["slot"]) * 2, old)
			if old:
				_apply_equip(rec, old, -1)
			_apply_equip(rec, int(c["id"]), 1)
			GameState.setw(rec + 0x10 + k * 2, int(c["id"]))
			_compact(INV, INV_N)
		_recalc_resists(rec)


## RPG 0x44A8: item +0D attack, +0F defense, +11 agility, +13 evasion.
func _apply_equip(rec: int, id: int, sign: int) -> void:
	var it = _item(id)
	if it == null:
		return
	var add := func(o: int, v: int) -> void: GameState.setw(rec + o, (GameState.w(rec + o) + sign * v) & 0xFFFF)
	add.call(0x0C, int(it.get("attack", 0)))
	add.call(0x0E, int(it.get("defense", 0)))
	add.call(0x5D, int(it.get("agility", 0)))
	add.call(0x67, int(it.get("evasion", 0)))
	GameState.setw(rec + 0x65, GameState.w(rec + 0x67))


## RPG 0x4524: resistances are the best over the equipped items.
func _recalc_resists(rec: int) -> void:
	var best := [0, 0, 0, 0, 0]
	for k in 11:
		var it = _item(GameState.w(rec + 0x10 + k * 2))
		if it == null or not it.has("immune_physical"):
			continue
		best[0] = maxi(best[0], int(it["immune_physical"]))
		var er: Array = it.get("element_resist", [0, 0, 0, 0])
		for e in 4:
			best[e + 1] = maxi(best[e + 1], int(er[e]))
	for e in 5:
		GameState.setb(rec + 0x26 + e, best[e])


# ---------------------------------------------------------------- skills

func _skills() -> void:
	var m := await _pick_member(Vector2(96, 8))
	if m < 0:
		return
	var rec := _rec(m)
	var ids := []
	var labels := []
	for k in 50:
		var s := GameState.b(rec + 0x6D + k)
		var sk = _skill(s) if s else null
		if sk != null:
			ids.append(sk)
			labels.append("%s　%s" % [String(sk["name"]), fw(int(sk["cost"]))])
	if ids.is_empty():
		await message("沒有奇術")
		return
	var i := await choose(labels, Vector2(64, 8), 0, 9)
	if i < 0:
		return
	var sk: Dictionary = ids[i]
	if int(sk.get("effect", 0)) != 1:
		await message("在此無法使用！")
		return
	var t := m
	if String(sk.get("target", "")) != "self":
		t = await _pick_member(Vector2(224, 40))
		if t < 0:
			return
	if not _pay(rec, sk):
		await message("數值不夠！無法用此奇術！" if String(sk.get("cost_type", "")) != "herbs" else "藥材不夠！無法用此醫術！")
		return
	if String(sk.get("target", "")) == "all":
		for mm in _members():
			_heal_member(m, mm, sk)
	elif not _heal_member(m, t, sk):
		await message("此人無法使用！")


func _pay(rec: int, sk: Dictionary) -> bool:
	var cost := int(sk.get("cost", 0))
	match String(sk.get("cost_type", "")):
		"mp":
			if GameState.w(rec + 0x55) < cost:
				return false
			GameState.setw(rec + 0x55, GameState.w(rec + 0x55) - cost)
		"stamina":
			if GameState.w(rec + 0x35) < cost:
				return false
			GameState.setw(rec + 0x35, GameState.w(rec + 0x35) - cost)
		"herbs":
			for b in 5:
				if cost & (1 << b) and GameState.w(HERBS + b * 2) == 0:
					return false
			for b in 5:
				if cost & (1 << b):
					GameState.setw(HERBS + b * 2, GameState.w(HERBS + b * 2) - 1)
	return true


# ---------------------------------------------------------------- system

## Returns true when the menu should close (after loading).
func _system() -> bool:
	var i := await choose(["讀　　取", "記　　錄", "記　　載", "回到標題"], Vector2(96, 8))
	match i:
		0:
			var s := await pick_slot(false)
			if s > 0:
				var d := SaveFiles.load_slot(s)
				if not d.is_empty():
					ov.clear()
					game.load_saved(d)
					return true
		1:
			var s := await pick_slot(true)
			if s > 0:
				SaveFiles.save_slot(s, _save_meta())
				await message("記錄完成！")
		2:
			await show_journal()
		3:
			if await confirm("確定要回到標題？"):
				ov.clear()
				game.restart()
				return true
	return false


func _save_meta() -> Dictionary:
	var place := String(game.field.entry.get("name", ""))
	return {"place": place, "level": GameState.w(GameState.PARTY + 0x31), "pos": game.field.party_place(),
			"time": Time.get_datetime_string_from_system(false, true)}


## The five save slots (一..五) with place and level. Returns 1..5 or -1.
func pick_slot(saving: bool) -> int:
	var labels := []
	for s in range(1, 6):
		var d := SaveFiles.load_slot(s)
		var meta: Dictionary = d.get("meta", {})
		var nums := ["一", "二", "三", "四", "五"]
		if d.is_empty():
			labels.append(nums[s - 1] + "　－－－－")
		else:
			labels.append("%s　%s　等級%s" % [nums[s - 1], String(meta.get("place", "")), fw(int(meta.get("level", 0)))])
	var i := await choose(labels, Vector2(32, 40))
	if i < 0:
		return -1
	if not saving and SaveFiles.load_slot(i + 1).is_empty():
		return -1
	return i + 1


func show_journal() -> void:
	var pages: Array = GameState.journal
	if pages.is_empty():
		await message("沒有記載")
		return
	var i := pages.size() - 1
	while i >= 0 and i < pages.size():
		ov.clear()
		ov.show_box(false)
		await ov.write("{C15}" + String(pages[i]), 40, 124, false, 280, 4)
		Keys.reset()
		var go := 0
		while go == 0:
			await game.get_tree().process_frame
			if Keys.just("ui_up") or Keys.just("ui_left"):
				go = -1
			elif Keys.just("ui_down") or Keys.just("ui_right"):
				go = 1
			elif Keys.just("ui_accept") or Keys.just("ui_cancel"):
				go = 2
		if go == 2:
			break
		i = clampi(i + go, 0, pages.size() - 1)
	ov.clear()


# ---------------------------------------------------------------- shops

## Ops 0x11 (buy and sell) / 0x13 (buy only). Prices are item +0B.
func shop(ids: Array, can_sell: bool) -> void:
	ov.clear()
	while true:
		var mode := 0
		if can_sell:
			await _money_box()
			mode = await choose(["買", "賣"], Vector2(16, 8))
			if mode < 0:
				break
		if mode == 0:
			await _buy(ids)
			if not can_sell:
				break
		else:
			await _sell()
	ov.clear()


func _money_box() -> void:
	ov.pop_frames(0)
	var r := ov.add_frame(Vector2(192, 0), 4, 1)
	await _text("＄" + fw(GameState.money()), int(r.position.x) + 16, int(r.position.y) + 12, 15)


func _buy(ids: Array) -> void:
	var sel := 0
	while true:
		await _money_box()
		var labels := []
		for id in ids:
			var it = _item(int(id))
			labels.append("%s　%s" % [_item_name(int(id)), fw(int(it.get("price", 0)) if it != null else 0)])
		var i := await choose(labels, Vector2(16, 32), sel, 8)
		if i < 0:
			return
		sel = i
		var id := int(ids[i])
		var it = _item(id)
		var price := int(it.get("price", 0)) if it != null else 0
		if not await confirm("你要買下這物品嗎？"):
			continue
		if GameState.money() < price:
			await message("你的銀兩不夠！")
			continue
		if not add_item(id):
			await message("這樣藥材滿了！" if id >= HERB_FIRST and id < HERB_FIRST + 5 else "物品滿了！無法再攜帶！")
			continue
		GameState.add_money(-price)


func _sell() -> void:
	while true:
		await _money_box()
		var inv := _inventory()
		var labels := []
		for e in inv:
			labels.append(_item_name(int(e["id"])))
		var i := await choose(labels, Vector2(16, 32), 0, 8)
		if i < 0:
			return
		var e: Dictionary = inv[i]
		var it = _item(int(e["id"]))
		var price := int(it.get("price", 0)) / 2 if it != null and it.has("price") else 0
		if price <= 0 or int(e["id"]) >= HERB_FIRST and int(e["id"]) < HERB_FIRST + 5:
			await message("這樣物品我不收購！")
			continue
		if await confirm("這樣物品我出價銀兩" + fw(price)):
			GameState.setw(INV + int(e["slot"]) * 2, 0)
			_compact(INV, INV_N)
			GameState.add_money(price)


# ---------------------------------------------------------------- storage

## Op 0x42: deposit or withdraw (RPG 0x65D8).
func storage() -> void:
	ov.clear()
	await message("把不需要的物品拿給我，我會幫你保存好。")
	while true:
		var i := await choose(["寄放", "取回"], Vector2(16, 8))
		if i < 0:
			break
		if i == 0:
			var inv := _inventory()
			var labels := []
			for e in inv:
				labels.append(_item_name(int(e["id"])))
			var j := await choose(labels, Vector2(16, 40), 0, 8)
			if j < 0:
				continue
			var e: Dictionary = inv[j]
			var it = _item(int(e["id"]))
			if (it != null and int(it.get("flags", 0)) & 0x08) or (int(e["id"]) >= HERB_FIRST and int(e["id"]) < HERB_FIRST + 5):
				await message("這樣物品不能寄放！")
				continue
			if not _add_to(STORE, STORE_N, int(e["id"])):
				await message("物品滿了！無法再寄放！")
				continue
			GameState.setw(INV + int(e["slot"]) * 2, 0)
			_compact(INV, INV_N)
		else:
			var stored := []
			var labels := []
			for k in STORE_N:
				var v := GameState.w(STORE + k * 2)
				if v:
					stored.append({"slot": k, "id": v})
					labels.append(_item_name(v))
			if stored.is_empty():
				await message("沒有寄放的物品")
				continue
			var j := await choose(labels, Vector2(16, 40), 0, 8)
			if j < 0:
				continue
			if not _add_to(INV, INV_N, int(stored[j]["id"])):
				await message("物品滿了！無法再攜帶！")
				continue
			GameState.setw(STORE + int(stored[j]["slot"]) * 2, 0)
			_compact(STORE, STORE_N)
	ov.clear()


## Op 0x45: offer to save.
func save_prompt() -> void:
	ov.clear()
	var s := await pick_slot(true)
	if s > 0:
		SaveFiles.save_slot(s, _save_meta())
		await message("記錄完成！")
	ov.clear()
