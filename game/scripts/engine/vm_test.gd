class_name VmTest
extends RefCounted
## Smoke test: runs every event of the chapter scripts once, without waiting
## for keys and at high speed, so missing opcodes and script errors show up.


static func run_all(game: Game, which: String) -> void:
	Overlay.auto_continue = true
	Engine.time_scale = 64.0
	var scenes: Dictionary = Assets.mapa["scenes"]
	var by_script := {}
	for k in scenes:
		var sc: Dictionary = scenes[k]
		by_script[sc["script"]] = by_script.get(sc["script"], k)
	var entries: Array = Assets.mapa["entries"]
	var total := 0
	var from := 0                       # "CHNA1:448" starts at that event
	if ":" in which:
		from = int(which.get_slice(":", 1))
		which = which.get_slice(":", 0)
	for name in by_script:
		if which != "all" and name.get_basename() != which:
			continue
		var scene_off := int(by_script[name])
		var ref := -1
		for e in entries:
			if e != null and int(e["scene"]) == scene_off:
				ref = int(e["ref"])
				break
		if ref < 0:
			continue
		var f = Assets.script_file(name)
		if f == null:
			continue
		var keys: Array = f["events"].keys()
		print("[vmtest] %s: %d events" % [name, keys.size()])
		for k in keys:
			if int(k) < from:
				continue
			GameState.new_game()
			game.field.load_entry(ref)
			game.vm.max_ops = 400
			var t0 := Time.get_ticks_msec()
			await game.vm.run(name, int(k), 0)
			print("[vmtest] %s %s %dms" % [name, k, Time.get_ticks_msec() - t0])
			total += 1
	print("[vmtest] done, %d events" % total)


## Runs every battle group with automatic commands and a round limit.
static func run_battles(game: Game) -> void:
	Overlay.auto_continue = true
	Engine.time_scale = 64.0
	var groups: Array = Battle.battle_data().get("groups", [])
	var n := 0
	for g in groups:
		if not (g is Dictionary) or not g.has("script"):
			continue
		GameState.new_game()
		var b := Battle.new(game)
		b.max_rounds = 12
		game.add_child(b)
		game.battle_scene = b
		var t0 := Time.get_ticks_msec()
		var r: int = await b.run(int(g["rpg_value"]))
		game.battle_scene = null
		print("[battletest] %d rounds=%d result=%d %dms" % [int(g["rpg_value"]), b.rounds, r, Time.get_ticks_msec() - t0])
		n += 1
	print("[battletest] done, %d groups" % n)


## docs/CREATURES.md end to end: capture a rat, summon it, fire 金蠶 with
## 防禦, and get the rat back after the battle.
static func run_creatures(game: Game) -> void:
	Overlay.auto_continue = true
	Engine.time_scale = 64.0
	GameState.new_game()
	var rec := GameState.PARTY
	GameState.setw(rec + 0x2D, 999)
	GameState.setw(rec + 0x2F, 999)
	GameState.setw(rec + 0x35, 99)
	GameState.setw(rec + 0x1E, 0xEC)          # 金蠶
	GameState.setb(0x4F8, 0)
	for k in 50:
		GameState.setw(GameState.ITEMS + k * 2, 0)
	var b := Battle.new(game)
	b.force_random = true
	b.max_rounds = 4
	var seen := {}
	b.test_plan = [
		func(m): return {"kind": "capture", "target": b.enemies[0]},
		func(m):
			var k := 0
			while k < 50 and GameState.w(GameState.ITEMS + k * 2) < 314:
				k += 1
			seen["captured"] = GameState.w(GameState.ITEMS + k * 2) if k < 50 else 0
			if k >= 50:
				return {"kind": "defend"}
			return {"kind": "summon", "slot": k, "monster": b._monster(seen["captured"])},
		func(m):
			seen["ally"] = b.allies[0] != null
			seen["sta"] = int(m["sta"])
			return {"kind": "defend"},
	]
	game.add_child(b)
	game.battle_scene = b
	var r: int = await b.run(154)
	game.battle_scene = null
	var back := 0
	for k in 50:
		if GameState.w(GameState.ITEMS + k * 2) >= 314:
			back = GameState.w(GameState.ITEMS + k * 2)
	print("[creaturetest] members=%d enemies=%d group=%s" % [b.members.size(), b.enemies.size(), str(b.group.get("rpg_value"))])
	print("[creaturetest] result=%d rounds=%d captured=%d ally=%s sta=%d silkworm=%d back=%d money=%d" % [
		r, b.rounds, seen.get("captured", 0), seen.get("ally", false), seen.get("sta", -1),
		GameState.w(0x645 + 2 * (0xEC - 0xE6)), back, b.money_total])


## Loads entry points over and over, to catch crashes that build up over a
## long session (the vmtest of a whole chapter used to die near event 450).
static func run_stress(game: Game, n: int) -> void:
	var refs := []
	var es: Array = Assets.mapa["entries"]
	for i in es.size():
		if es[i] != null:
			refs.append(2 * i + 2)
	for k in n:
		game.field.load_entry(refs[k % refs.size()])
		await game.get_tree().process_frame
		if k % 100 == 0:
			print("[stress] %d loads, %d nodes, static %d KB" % [k, game.get_tree().get_node_count(), OS.get_static_memory_usage() / 1024])
	print("[stress] done, %d loads" % n)
