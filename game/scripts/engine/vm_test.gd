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
