class_name Explorer
extends RefCounted
## Test bot for long play sessions: starts a new game and keeps walking the
## party to NPCs and trigger zones, always picking the target it has visited
## least, talking and bumping on arrival. Text never waits, choices are random
## and battles fight themselves (Overlay.auto_continue). With `god` the party
## cannot lose. Prints every new scene and chapter so a stall shows up as the
## log going quiet.

const STALL_STEPS := 30000

var game: Game
var god := true
var visits := {}            # "entry:kind:index|story" -> times tried
var best_flags := 0
var scenes_seen := {}
var chapters_seen := {}
var steps := 0
var events := 0
var battles := 0
var best_state := {}          # state at the best flag count, for restarts
var best_step := 0
var restarts := 0
var dump_path := ""          # save the game state here with every status line


func _init(g: Game) -> void:
	game = g


## start_entry >= 0 skips the new game and starts at that entry point.
func run(seconds: float, start_entry := -1, resume := "") -> void:
	Overlay.auto_continue = true
	Engine.time_scale = 64.0
	game.bot = true
	game.vm.max_ops = 20000
	var lost := [false]
	game.defeated.connect(func():
		print("[explore] party defeated")
		lost[0] = true)
	if resume != "":
		GameState.new_game()
		var saved = JSON.parse_string(FileAccess.get_file_as_string(resume))
		game.load_saved(saved)
		for r in saved.get("meta", {}).get("seen", []):
			entries_seen[int(r)] = 1
		if start_entry >= 0:
			# jump to another place with the resumed story state
			game.field.load_entry(start_entry)
			game._sync_palette()
	elif start_entry >= 0:
		GameState.new_game()
		game.field.load_entry(start_entry)
		game._sync_palette()
		game.set_brightness(1.0)
	else:
		await game.start_new_game()
	var t_end := Time.get_ticks_msec() + int(seconds * 1000.0)
	_heartbeat(t_end)
	var idle := 0
	var next_dump := 0
	while Time.get_ticks_msec() < t_end and not lost[0]:
		_note_scene()
		if dump_path != "" and Time.get_ticks_msec() >= next_dump:
			next_dump = Time.get_ticks_msec() + 30000
			_dump()
		if god:
			_top_up()
		var acted := await _go_somewhere()
		if not acted:
			idle += 1
			await _wander(8)
			if debug and idle == 1:
				var f := game.field
				var c := f.leader_cell()
				print("[explore] stuck at cell %d (%d,%d) px=%d py=%d view=%d,%d reach=%d" % [c, c % f.map_w, c / f.map_w, f.px[0], f.py[0], f.view_x, f.view_y, _reach().size()])
				for r in range(-2, 3):
					var line := ""
					for k in range(-4, 5):
						line += "%04x " % f.cell(c + r * f.map_w + k)
					print("   ", line)
			if idle % 20 == 0:
				print("[explore] nothing reachable at entry %d (map %d)" % [game.field.entry_ref, game.field.map_id])
		else:
			idle = 0
	print("[explore] done: %d scenes, chapters %s, %d steps, %d events" % [
		scenes_seen.size(), str(chapters_seen.keys()), steps, events])
	print("[explore] entries ", entries_seen)
	print("[explore] money %d, leader level %d" % [GameState.money(), GameState.w(GameState.PARTY + 0x31)])


## Every few seconds, where things stand; shows what a hang is stuck on.
func _heartbeat(t_end: int) -> void:
	var last_steps := -1
	var beat := 0
	while Time.get_ticks_msec() < t_end + 5000:
		await game.get_tree().create_timer(5.0, true, false, true).timeout
		beat += 1
		if beat % 12 == 0:
			print("[explore] status: entry %d map %d, %d steps, %d events, flags %d, last %s" % [
				game.field.entry_ref, game.field.map_id, steps, events, _flag_count(), game.vm.last_event])

		if steps == last_steps:
			var vm := game.vm
			var op = vm.ops[vm.pc - 1] if vm.running and vm.pc > 0 and vm.pc <= vm.ops.size() else null
			print("[explore] stalled: entry %d busy=%s vm=%s %s battle=%s" % [
				game.field.entry_ref, game.busy, vm.script_name if vm.running else "-",
				str(op) if op else "", game.battle_scene != null])
		last_steps = steps


var _last_ref := -1
var entries_seen := {}


## Story state: the flag words DS:596..611 and the events of the scene's
## objects (scripts hand NPCs new events as the story goes on). Targets are tried afresh after
## every change, since talking to the same people often moves the story on.
func _story() -> int:
	var evs := []
	for a in game.field.objects:
		evs.append(a.event)
	return hash([GameState.ds.slice(GameState.FLAGS, 0x612), evs])


func _flag_count() -> int:
	var n := 0
	for off in range(GameState.FLAGS, 0x612):
		var v := GameState.ds[off]
		while v:
			n += v & 1
			v >>= 1
	return n


## Flags seen set at any time in this run. The story clears flags too
## (CHNA7 drops 213 when it sets 217 and 219), so a count can fall while the
## story moves on; a flag set for the first time is progress whatever the count.
var flags_ever := {}


func _new_flags() -> bool:
	var found := false
	for off in range(GameState.FLAGS, 0x612):
		var v := GameState.ds[off]
		if v == 0:
			continue
		for bit in 8:
			if v & (1 << bit) and not flags_ever.has(off * 8 + bit):
				flags_ever[off * 8 + bit] = true
				found = true
	return found


func _note_scene() -> void:
	var fc := _flag_count()
	var fresh := _new_flags() and steps > 0
	if fc > best_flags or fresh:
		best_flags = maxi(fc, best_flags)
		best_step = steps
		best_state = GameState.to_save()
		best_state["meta"] = {"pos": game.field.party_place(), "seen": entries_seen.keys()}
		if dump_path != "":
			var f := FileAccess.open(dump_path.get_basename() + ".best.json", FileAccess.WRITE)
			if f:
				f.store_string(JSON.stringify(best_state))
		print("[explore] flags %d at map %d entry %d after %d steps" % [fc, game.field.map_id, game.field.entry_ref, steps])
	elif steps - best_step > STALL_STEPS and not best_state.is_empty():
		# go back to the best state and try other paths from there
		restarts += 1
		best_step = steps
		visits.clear()
		game.load_saved(best_state.duplicate(true))
		print("[explore] no progress for %d steps, back to flags %d (restart %d)" % [STALL_STEPS, best_flags, restarts])
	var ref := game.field.entry_ref
	if not entries_seen.has(ref):
		# a place never seen counts as progress (mazes such as CHNA5's tomb
		# give no flags until the end); at the best flag count it becomes
		# the state to come back to
		best_step = steps
		if fc == best_flags:
			best_state = GameState.to_save()
			best_state["meta"] = {"pos": game.field.party_place()}
	entries_seen[ref] = entries_seen.get(ref, 0) + 1
	if ref != _last_ref:
		if debug:
			print("[explore] warp %d -> %d (map %d)" % [_last_ref, ref, game.field.map_id])
		_last_ref = ref
	var chapter: String = game.field.scene.get("script", "?")
	if not chapters_seen.has(chapter):
		chapters_seen[chapter] = true
		print("[explore] chapter %s" % chapter)
	var key := "%d" % game.field.map_id
	if not scenes_seen.has(key):
		scenes_seen[key] = ref
		print("[explore] map %d (entry %d, %s) after %d steps" % [game.field.map_id, ref, chapter, steps])


## The game state between two moves, for --resume.
func _dump() -> void:
	var d := GameState.to_save()
	d["meta"] = {"pos": game.field.party_place(), "seen": entries_seen.keys()}
	var f := FileAccess.open(dump_path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(d))


## Items that some story event tests for (op 0x28 with an item id), from
## all CHNA*.EXE scripts; the bot never throws these away.
const NEEDED_ITEMS := [3, 5, 7, 8, 11, 12, 17, 21, 22, 23, 24, 26, 35, 42, 44, 47, 54, 63, 64,
		75, 176, 181, 215, 368, 377, 384, 386, 391, 400, 410, 462, 464, 465, 467, 469, 473,
		483, 493, 500, 542, 567]


func _top_up() -> void:
	# random shopping fills the bag, and a full bag refuses story items:
	# keep one of each item once it gets crowded
	var ids := []
	for k in 50:
		var v := GameState.w(GameState.ITEMS + k * 2)
		if v != 0:
			ids.append(v)
	if ids.size() > 40:
		var keep := []
		for v in ids:
			if not keep.has(v):
				keep.append(v)
		# still crowded: drop items no script ever asks for
		var spare := keep.size() - 36
		for v in keep.duplicate():
			if spare <= 0:
				break
			if not NEEDED_ITEMS.has(v):
				keep.erase(v)
				spare -= 1
		for k in 50:
			GameState.setw(GameState.ITEMS + k * 2, keep[k] if k < keep.size() else 0)
	for i in GameState.party_count():
		var rec := GameState.PARTY + i * GameState.PARTY_REC
		if GameState.w(rec + 0x2F) < 3000:
			GameState.setw(rec + 0x2F, 3000)
			GameState.setw(rec + 0x0C, maxi(GameState.w(rec + 0x0C), 400))
		GameState.setw(rec + 0x2D, GameState.w(rec + 0x2F))
		GameState.setw(rec + 0x08, 0)


# ------------------------------------------------------------------ targets

## Every place worth going in this scene: [key, goal cells, facing or -1].
func _targets() -> Array:
	var f := game.field
	var out := []
	var w := f.map_w
	for a in f.objects:
		# states 7 and 9 are invisible but can still be examined (hidden
		# treasure); only 3 and 8 are switched off (field.gd talk check)
		if a.event == 0 or a.state == 3 or a.state == 8:
			continue
		# no place on the map: reached only through a trigger zone
		if a.pos == 0:
			continue
		var oc := f.pos_to_cell(a.pos)
		var goals := {}
		# below facing up, above facing down, beside facing left/right
		for k in range(1, 3):
			goals[oc + 1 + k * w] = 3
			goals[oc + 1 - k * w] = 0
		goals[oc - 1] = 9
		goals[oc + 3] = 6
		out.append(["%d:o:%d" % [f.entry_ref, a.index], goals])
	for zi in f.zones.size():
		var z: Array = f.zones[zi]
		var a := f.pos_to_cell(int(z[1]))
		var b := f.pos_to_cell(int(z[2]))
		var goals := {}
		var act := int(z[3])
		var key := "%d:z:%d" % [f.entry_ref, zi]
		if not (act & 0x4000) and not entries_seen.has(act & 0xFFF):
			key = "new:%d" % (act & 0xFFF)
		# object zones (0x4000) whose object is in state 9 need the action
		# key while standing inside (game.gd _zone)
		var face := -1
		if act & 0x4000:
			var oi := (act & 0xBFFF) / 2
			if oi < f.objects.size() and f.objects[oi].state == 9:
				face = -2
		for r in range(a / w, b / w + 1):
			for c in range(a % w, b % w + 1):
				# only cells flagged 0x1000 trigger (RPG.EXE 0x1CC5); a zone's
				# rectangle can be larger than its flagged cells
				if f.cell(r * w + c) & 0x1000:
					goals[r * w + c] = face
		out.append([key, goals, act & 0xFFF, "%d:z:%d" % [f.entry_ref, zi]])
	return out


## Breadth-first search over leader cells: cell -> [previous cell, direction].
func _reach(avoid := false) -> Dictionary:
	var f := game.field
	var w := f.map_w
	var start := f.leader_cell()
	var prev := {start: [-1, -1]}
	var queue := [start]
	var head := 0
	while head < queue.size():
		var c: int = queue[head]
		head += 1
		for d in [0, 3, 6, 9]:
			var n := c
			var ok := false
			match d:
				0:
					n = c + w
					ok = f._free3(n)
				3:
					n = c - w
					ok = f._free3(n)
				6:
					n = c - 1
					ok = c % w > 0 and f._free(n)
				9:
					n = c + 1
					ok = c % w < w - 1 and f._free(n)
			if ok and not prev.has(n):
				prev[n] = [c, d]
				# zone cells can be reached but not crossed: walking through
				# a doorway on the way somewhere else warps the party off
				if not (avoid and zone_cells.has(n)):
					queue.append(n)
	return prev


## Doors between entry points, from the zone tables: entry -> [entries].
var _doors := {}


func _doors_of(ref: int) -> Array:
	if _doors.has(ref):
		return _doors[ref]
	var out := []
	var e = Assets.entry(ref)
	if e != null:
		var sc = Assets.scene(int(e["scene"]))
		if sc != null:
			for z in Assets.zones.get(str(int(sc["map_id"]) & 0x7FF), []):
				var act := int(z[3])
				if not (act & 0x4000) and Assets.entry(act & 0xFFF) != null:
					out.append(act & 0xFFF)
	_doors[ref] = out
	return out


## First door on the shortest way (by door count, ignoring walls) from here
## to an entry point never visited, or -1. Map-wide exploration otherwise
## wanders between known places; this pulls the bot to the edge of the map.
func _next_hop() -> int:
	var start := game.field.entry_ref
	var first := {start: -1}
	var queue := [start]
	var head := 0
	while head < queue.size() and head < 2000:
		var r: int = queue[head]
		head += 1
		for n in _doors_of(r):
			if first.has(n):
				continue
			first[n] = n if r == start else first[r]
			if not entries_seen.has(n):
				return first[n]
			queue.append(n)
	return -1


## Every cell of the scene's trigger zones.
func _zone_cells() -> Dictionary:
	var f := game.field
	var w := f.map_w
	var out := {}
	for z in f.zones:
		# object zones run an event and let the party walk on; only doors
		# (warps) are worth walking round
		if int(z[3]) & 0x4000:
			continue
		var a := f.pos_to_cell(int(z[1]))
		var b := f.pos_to_cell(int(z[2]))
		for r in range(a / w, b / w + 1):
			for c in range(a % w, b % w + 1):
				if f.cell(r * w + c) & 0x1000:
					out[r * w + c] = true
	return out


func _path(prev: Dictionary, goal: int) -> Array:
	var dirs := []
	var c := goal
	while prev.has(c) and prev[c][0] >= 0:
		dirs.push_front([prev[c][1], c])
		c = prev[c][0]
	return dirs


var debug := false


var zone_cells := {}
var _avoid := false
var plan: Array = []           # --plan=key,key: targets to try first


func _go_somewhere() -> bool:
	zone_cells = _zone_cells()
	var careful := _reach(true)
	var reach := _reach()
	var best = null
	var best_score := 1 << 30
	var story := _story()
	var hop := _next_hop()
	for t in _targets():
		var key: String = "%s|%d" % [t[0], story]
		var v: int = visits.get(key, 0)
		# Some scenes reset flags on entry, so the story key alone can keep
		# every target fresh; how often a target or a destination was used
		# in any story breaks those loops.
		var worn: int = visits.get(t[0], 0) * 20
		if t.size() > 2:
			worn += int(entries_seen.get(t[2], 0)) / 4
		for g in _goal_order(t[1], careful, reach):
			if reach.has(g):
				var score := v * 1000 + worn + randi() % 50 - (500 if key.begins_with("new:") else 0)
				# objects never examined in any story state come first too
				if ":o:" in t[0] and not visits.has(t[0]):
					score -= 700
				# the next door on the way to a place never visited
				if t.size() > 2 and t[2] == hop:
					score -= 800
				if score < best_score:
					best_score = score
					best = [key, g, t[1][g]]
				break
	# a --plan of target keys goes first, in order, whenever reachable
	if not plan.is_empty():
		for t in _targets():
			# a key starting with ":" matches any entry of the scene
			var raw: String = t[3] if t.size() > 3 else t[0]
			if plan[0] in [t[0], raw] or (plan[0].begins_with(":") and raw.ends_with(plan[0])):
				for g in _goal_order(t[1], careful, reach):
					if reach.has(g):
						best = [t[0] + "|plan", g, t[1][g]]
						print("[explore] plan: %s (careful %s, %d/%d cells)" % [plan[0], careful.has(g), careful.size(), reach.size()])
						plan.pop_front()
						break
				if debug and (best == null or not best[0].ends_with("|plan")):
					var f2 := game.field
					print("[explore] plan %s unreachable: goals %s leader %d" % [plan[0], t[1].keys(), f2.leader_cell()])
				break
	# go round other zones when the goal can be reached that way
	if best != null:
		_avoid = careful.has(best[1])
	if best == null:
		return false
	visits[best[0]] = visits.get(best[0], 0) + 1
	var base_key: String = best[0].get_slice("|", 0)
	visits[base_key] = visits.get(base_key, 0) + 1
	var r := await _walk_to(best[1], best[2])
	if debug:
		var f := game.field
		print("[explore] -> %s goal %d now at %d entry %d result %s runs %d" % [best[0], best[1], f.leader_cell(), f.entry_ref, r, game.vm.runs])
	return r


## Goal cells reachable without crossing other zones first, so a doorway
## the party could walk into safely isn't approached through another door.
func _goal_order(goals: Dictionary, careful: Dictionary, reach: Dictionary) -> Array:
	var safe := []
	var rest := []
	for g in goals:
		if careful.has(g):
			safe.append(g)
		elif reach.has(g):
			rest.append(g)
	return safe + rest


## Walk until the leader stands on cell, re-planning when pushed off the
## path. Stops early when an event or a warp takes over.
func _walk_to(goal: int, face: int) -> bool:
	if face == -2 and game.field.leader_cell() == goal:
		return await _tick(true, -1)
	if face == -1 and game.field.leader_cell() == goal:
		# already standing in the zone: step out so the next try walks in
		await _wander(2)
		return false
	for attempt in 4:
		var prev := _reach(_avoid)
		if not prev.has(goal):
			prev = _reach()
		if not prev.has(goal):
			return false
		for st in _path(prev, goal):
			if debug:
				print("[explore]   step %d to %d from %d" % [st[0], st[1], game.field.leader_cell()])
			if await _tick(false, st[0]):
				return true
			if game.field.leader_cell() != st[1]:
				break
		if game.field.leader_cell() == goal:
			break
	if face >= 0:
		await _tick(false, face)
		await _tick(true, -1)
	elif face == -2 and game.field.leader_cell() == goal:
		await _tick(true, -1)
	return true


func _wander(n: int) -> void:
	var d: int = [0, 3, 6, 9][randi() % 4]
	for i in n:
		await _tick(randi() % 3 == 0, d)


## One field tick; true when an event or warp happened.
func _tick(accept: bool, d: int) -> bool:
	while game.busy:
		await game.get_tree().process_frame
	var ref := game.field.entry_ref
	var vm_runs := game.vm.runs
	await game._field_tick(accept, d)
	while game.busy:
		await game.get_tree().process_frame
	steps += 1
	if steps % 64 == 0:
		await game.get_tree().process_frame
	var ran := game.vm.runs != vm_runs
	if ran:
		events += 1
	return ran or game.field.entry_ref != ref
