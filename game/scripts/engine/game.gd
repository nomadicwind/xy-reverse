class_name Game
extends Node2D
## Runs the field loop of RPG.EXE (0x0107): read input, move the party,
## update objects, check trigger zones, draw. Script events pause the loop.

signal finished
signal defeated

const TICK := 1.0 / 18.2

var field: Field
var overlay: Overlay
var vm: ScriptVM
var ui_layer: CanvasLayer
var busy := false
var _acc := 0.0
var _held_dir := -1
var music: AudioStreamPlayer
var sfx: AudioStreamPlayer
var auto_events := true
var bot := false          # tests: an Explorer drives the field instead of the keys


func _ready() -> void:
	field = Field.new()
	field.name = "Field"
	add_child(field)
	ui_layer = CanvasLayer.new()
	ui_layer.layer = 10
	add_child(ui_layer)
	overlay = Overlay.new()
	overlay.name = "Overlay"
	ui_layer.add_child(overlay)
	vm = ScriptVM.new(self)
	field.event_requested.connect(_on_event_requested)
	field.palette_changed.connect(_sync_palette)
	music = AudioStreamPlayer.new()
	add_child(music)
	sfx = AudioStreamPlayer.new()
	add_child(sfx)


func _sync_palette() -> void:
	var img: Image = field.pal_tex.get_image() if field.pal_tex else null
	overlay.set_palette(img, field.pal_tex)


func start_new_game() -> void:
	GameState.new_game()
	busy = true
	field.load_entry(0x2A)
	_sync_palette()
	play_scene_music()
	set_brightness(0.0)
	# RPG.EXE 0x0D73: the naming screen comes first
	if not Overlay.auto_continue:
		await NameEntry.new(self).run()
	# RPG.EXE 0x0D83: the new game runs object 1's event at entry 0x2A
	await run_object_event(1)
	busy = false


func load_saved(d: Dictionary) -> void:
	GameState.from_save(d)
	field.load_entry(GameState.current_entry)
	field.restore_place(d.get("meta", {}).get("pos", {}))
	_sync_palette()
	set_brightness(1.0)
	play_scene_music()


func run_object_event(i: int) -> void:
	if i < 0 or i >= field.objects.size():
		return
	var ev := field.objects[i].event
	if ev == 0:
		return
	busy = true
	await vm.run(field.scene.get("script", "CHNA1.EXE"), ev, i)
	if field.custom_map:
		pass
	field.redraw()
	busy = false


func _on_event_requested(i: int) -> void:
	if not busy:
		run_object_event(i)


var _accept := false
var _accept_was_down := false
var _cancel := false
var _cancel_was_down := false


func _process(delta: float) -> void:
	# latch the action key: the field only ticks every few frames
	var down := Input.is_action_pressed("ui_accept")
	if down and not _accept_was_down:
		_accept = true
	_accept_was_down = down
	var cdown := Input.is_action_pressed("ui_cancel")
	if cdown and not _cancel_was_down:
		_cancel = true
	_cancel_was_down = cdown
	if bot or busy or not Assets.available() or field.cells.is_empty():
		_accept = false
		_cancel = false
		return
	_acc += delta
	var frame := maxf(1.0, float(GameState.w(0x64F9))) * TICK
	if _acc < frame:
		return
	_acc = 0.0
	var acc := _accept
	_accept = false
	_field_tick(acc)


func _input_dir() -> int:
	if Input.is_action_pressed("ui_right"):
		return 9
	if Input.is_action_pressed("ui_left"):
		return 6
	if Input.is_action_pressed("ui_down"):
		return 0
	if Input.is_action_pressed("ui_up"):
		return 3
	return -1


## One field tick. d: direction to walk, or -2 to read the keys.
func _field_tick(accept: bool, d := -2) -> void:
	# pending event after a battle (0x610)
	var pend := GameState.w(0x610)
	if pend != 0:
		GameState.setw(0x610, 0)
		await run_object_event((pend - 2) / 2)
		return
	var z = field.zone_at_leader()
	if z != null:
		if await _zone(z, accept):
			return
	if d == -2:
		d = _input_dir()
	if d >= 0:
		var hit := field.step(d)
		if hit >= 0:
			if await _touch(hit):
				return
		if field.encounters:
			await _maybe_encounter()
	if _cancel:
		_cancel = false
		await open_menu()
		return
	if accept:
		var o := field.facing_object()
		if o >= 0:
			field.objects[o].frame_dir = _face_towards(field.facing)
			await run_object_event(o)
			return
	field.update_objects()
	field.redraw()


func _face_towards(dir: int) -> int:
	match dir:
		0: return 3
		3: return 0
		6: return 9
		9: return 6
	return 0


## Walking into an object: pick-ups (state 6) and objects that talk on touch.
func _touch(i: int) -> bool:
	var a := field.objects[i]
	if a.state == 6:
		field.set_object_state(i, 3)
		return false
	if a.range_y & 0x80:
		await run_object_event(i)
		return true
	return false


## Trigger zones (RPG.EXE 0x1132).
func _zone(z: Array, accept: bool) -> bool:
	var action := int(z[3])
	if action & 0x4000:
		var i := (action & 0xBFFF) / 2
		if i < 0x100 and i < field.objects.size():
			# RPG.EXE 0x11EF: state 8 = switched off, 9 = needs the action key
			var st := field.objects[i].state
			if st != 8 and (st != 9 or accept):
				var ref := field.entry_ref
				await run_object_event(i)
				# a script warp moved the party: don't walk on with the key
				# that was meant for the old place
				if field.entry_ref != ref:
					return true
		# RPG.EXE 0x1CD2: the tick goes on to the keys after an object zone,
		# so the party can walk out of a zone whose event does nothing
		return false
	if action & 0x2000:
		var flag_byte := int(z[0]) >> 8
		GameState.setw(0x14, flag_byte)
		GameState.setb(0x612 + flag_byte, 1)
	await warp(action)
	return true


## Go to an entry point. Bits 0x8000/0x1000 keep the party's screen place.
func warp(action: int) -> void:
	var mode := 0
	if action & 0x8000:
		mode = 1
	if action & 0x1000:
		mode = 3 if (action & 0x8000) else 2
	var ref := action & 0xFFF
	field.load_entry(ref, mode)
	_sync_palette()
	set_brightness(1.0)
	play_scene_music()
	var z = field.zone_at_leader()
	if z != null and not (int(z[3]) & 0x4000):
		await warp(int(z[3]))


# ---------------------------------------------------------------- script services

func set_brightness(v: float) -> void:
	GameState.brightness = v
	field.set_brightness(v)
	if battle_scene:
		battle_scene.set_brightness(v)


func fade(to_on: bool) -> void:
	var steps := 16
	for i in steps + 1:
		var t := float(i) / steps
		set_brightness(t if to_on else 1.0 - t)
		await get_tree().create_timer(TICK * 0.5).timeout


func clear_screen() -> void:
	overlay.clear()
	set_brightness(1.0)


func play_frames(n: int) -> void:
	if n == 0xFF:
		n = 1
		field.anim_frame -= 1
	if n == 0:
		field.show_chunk(field.anim_frame)
		return
	for i in n:
		overlay.clear()
		field.show_chunk(field.anim_frame)
		field.anim_frame += 1
		await get_tree().create_timer(maxf(1.0, GameState.w(0x64F9)) * TICK).timeout


func show_picture(entry: int, frame: int, x: int, y: int) -> void:
	var p = Assets.pictures(0, entry)
	if p == null:
		return
	var frames: Array = p["frames"]
	if frame >= frames.size():
		return
	var r: Array = frames[frame]
	overlay.add_picture(p["texture"], Rect2(r[0], r[1], r[2], r[3]), Vector2(x, y))


func party_walk(dir: int, n: int) -> void:
	for i in n:
		field.step(dir)
		field.update_objects()
		field.redraw()
		await get_tree().create_timer(maxf(1.0, GameState.w(0x64F9)) * TICK).timeout


func shake(v: int) -> void:
	var off := Actor._s16(v)
	field.position.y = off / 80.0
	field.redraw()
	await get_tree().process_frame
	field.position.y = 0


func heal_party() -> void:
	for m in GameState.w(GameState.PARTY_COUNT):
		var rec := GameState.PARTY + m * GameState.PARTY_REC
		GameState.setw(rec + 8, 0)
		GameState.setw(rec + 0x2D, GameState.w(rec + 0x2F))
		GameState.setw(rec + 0x35, GameState.w(rec + 0x37))
		GameState.setw(rec + 0x55, GameState.w(rec + 0x57))


func in_party(id: int) -> bool:
	var n := GameState.w(GameState.PARTY_COUNT)
	for i in n:
		if GameState.w(0x89 + i * 6) == id:
			return true
	return false


func show_money() -> void:
	overlay.items.append({"kind": "glyph", "ch": "$", "at": Vector2(224, 68), "c": 0x0F, "m": 0})
	var s := str(GameState.money())
	await overlay.write(s, 240, 68, false)


func choose_yes_no() -> bool:
	var i: int = await menu(["是", "否"])
	return i == 0


## A vertical list of choices; returns the index or -1 when cancelled.
func menu(texts: Array) -> int:
	var sel := 0
	if Overlay.auto_continue:
		return randi() % texts.size()
	while true:
		overlay.clear_text()
		var y := 20
		for i in texts.size():
			var t: String = texts[i]
			await overlay.write(("{C15}" if i == sel else "{C7}") + t.replace("##", " "), 48, y, false, 300)
			y += 16 * (1 + t.count("##"))
		await get_tree().process_frame
		while true:
			await get_tree().process_frame
			if Keys.just("ui_down"):
				sel = (sel + 1) % texts.size()
				break
			if Keys.just("ui_up"):
				sel = (sel - 1 + texts.size()) % texts.size()
				break
			if Keys.just("ui_accept"):
				overlay.clear_text()
				return sel
			if Keys.just("ui_cancel"):
				overlay.clear_text()
				return -1
	return -1


func shop(items: Array, sell: bool) -> void:
	await FieldMenu.new(self).shop(items, sell)


func storage() -> void:
	await FieldMenu.new(self).storage()


func save_prompt() -> void:
	await FieldMenu.new(self).save_prompt()


## The main menu (Esc on the field).
func open_menu() -> void:
	busy = true
	await FieldMenu.new(self).open()
	field.redraw()
	busy = false


var battle_scene: Battle
var _steps := 0          # RPG DS:2D33 / 3311 / 3312, not saved
var _enc_count := 0
var _enc_hits := 0


## Op 0x1C and friends (RPG 0x2412): FIG.EXE takes over until the battle ends.
## A lost battle shows the defeat message and goes back to the title.
## Returns false when the party lost.
func battle(group: int, _boss: bool) -> bool:
	busy = true
	var old_music: String = _music_path
	await fade(false)
	battle_scene = Battle.new(self)
	add_child(battle_scene)
	var r: int = await battle_scene.run(group)
	battle_scene = null
	_sync_palette()
	field.redraw()
	_play_music_file(old_music)
	if r == Battle.Result.LOSE:
		defeated.emit()
		return false
	await fade(true)
	return true


## The scene as RPG.EXE reloads it after a battle: objects from their saved
## records, the party where it stood.
func reload_scene() -> void:
	var place := field.party_place()
	field.load_entry(field.entry_ref, 1)
	field.restore_place(place)


## RPG 0x2367, once per step on maps with encounters.
func _maybe_encounter() -> void:
	_steps += 1
	if _steps >= 10:
		_steps = 0
		_poison_tick()
	_enc_count += 1
	if _enc_count < 0x28:
		return
	var r := randi() & 0xFFFF
	if not (r & 4):
		return
	_enc_count = r & 31
	_enc_hits += 1
	if _enc_hits < 4:
		return
	_enc_count = 0
	_enc_hits = 0
	GameState.setw(0x594, 0)
	await battle(0, false)
	busy = false


## Status 0x200 (poison from enemy attacks) costs 1 HP every 10 steps.
func _poison_tick() -> void:
	for m in GameState.w(GameState.PARTY_COUNT):
		var rec := GameState.PARTY + m * GameState.PARTY_REC
		var st := GameState.w(rec + 8)
		if st & 0x2000 or not (st & 0x200):
			continue
		var hp := maxi(0, GameState.w(rec + 0x2D) - 1)
		GameState.setw(rec + 0x2D, hp)
		if hp == 0:
			GameState.setw(rec + 8, 0x2000)


func add_journal(text: String) -> void:
	if GameState.journal.is_empty() or GameState.journal[-1] != text:
		GameState.journal.append(text)


func restart() -> void:
	finished.emit()


func play_music(n: int) -> void:
	_play_music_file("RX/RI%03d.RIX" % n)


var _music_path := ""


func play_music_path(path: String) -> void:
	_play_music_file(path)


## Songs are rendered from RX/*.RIX by the extractor (music/<NAME>.ogg or
## .wav) and loop like the original.
func _play_music_file(path: String) -> void:
	if path == _music_path and music.playing:
		return
	_music_path = path
	music.stop()
	if path == "":
		return
	var stem := path.get_file().get_basename().to_upper()
	var base := Assets.root.path_join("music/" + stem)
	var st: AudioStream = null
	if FileAccess.file_exists(base + ".ogg"):
		var ogg := AudioStreamOggVorbis.load_from_buffer(FileAccess.get_file_as_bytes(base + ".ogg"))
		if ogg:
			ogg.loop = true
			st = ogg
	elif FileAccess.file_exists(base + ".wav"):
		var bytes := FileAccess.get_file_as_bytes(base + ".wav")
		if bytes.size() > 44:
			var wav := AudioStreamWAV.new()
			wav.format = AudioStreamWAV.FORMAT_16_BITS
			wav.mix_rate = bytes.decode_u32(24)
			wav.data = bytes.slice(44)
			wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
			wav.loop_end = (bytes.size() - 44) / 2
			st = wav
	if st:
		music.stream = st
		music.volume_db = -6.0
		music.play()


func play_scene_music() -> void:
	_play_music_file(field.scene.get("music", ""))


func play_sfx(n: int) -> void:
	var path := Assets.root.path_join("sfx/SP%03d.wav" % n)
	if not FileAccess.file_exists(path):
		return
	var st := AudioStreamWAV.new()
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() < 44:
		return
	st.format = AudioStreamWAV.FORMAT_8_BITS
	st.mix_rate = bytes.decode_u32(24)
	var data := bytes.slice(44)
	for i in data.size():
		data[i] = (data[i] + 128) & 0xFF
	st.data = data
	sfx.stream = st
	sfx.play()


func stop_sfx() -> void:
	sfx.stop()
