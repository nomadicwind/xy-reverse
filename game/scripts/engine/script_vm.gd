class_name ScriptVM
extends RefCounted
## Interpreter for the CHNA*.EXE story scripts (decoded by tools/swdtools/
## script.py). Each op mirrors a handler in RPG.EXE's table at DS:0x6449; the
## comments name the original handler address. Jump targets are event
## references (offsets into the chapter's event table).

const TICK := 1.0 / 18.2

var game                      # Game controller (field, overlay, tree access)
var events := {}
var script_name := ""
var ops: Array = []
var pc := 0
var obj := -1                 # object whose event is running ([0x3C6C] / 2)
var running := false
var ended_by_restart := false
var trace := false
var max_ops := 0              # tests: stop an event after this many ops


func _init(g) -> void:
	game = g


func load_script(name: String) -> void:
	if name == script_name:
		return
	script_name = name
	var f = Assets.script_file(name)
	events = f["events"] if f != null else {}


func goto_event(ref: int) -> void:
	ops = events.get(str(ref), [])
	pc = 0


func run(name: String, ref: int, object_index: int) -> void:
	load_script(name)
	obj = object_index
	goto_event(ref)
	running = true
	var guard := 0
	while pc < ops.size() and running:
		var op: Dictionary = ops[pc]
		pc += 1
		if trace:
			print("[vm] %s %04x %s %s" % [script_name, int(op["at"]), op["name"], op["args"]])
		await _exec(int(op["op"]), op["args"])
		guard += 1
		if max_ops > 0 and guard >= max_ops:
			break
		if guard % 200 == 0:
			await game.get_tree().process_frame
	running = false
	game.overlay.clear()


func stop() -> void:
	running = false


func _wait(ticks: float) -> void:
	await game.get_tree().create_timer(maxf(ticks, 0.0) * TICK).timeout


func _a(args: Array, i: int) -> int:
	return int(args[i])


var field: Field:
	get:
		return game.field


var overlay: Overlay:
	get:
		return game.overlay


func _exec(op: int, args: Array) -> void:
	match op:
		0x00:  # 0x5E2D say: dialogue box, typewriter, wait at the end
			await _say(args[0], false, false)
		0x12:  # 0x5E28 say without waiting at the end (before a choice)
			await _say(args[0], true, false)
		0x14:  # 0x5F84 say, fast
			await _say(args[0], false, true)
		0x2E:  # 0x624E say in a box at the top
			await _say(args[0], false, true, true)
		0x01:  # 0x5A39 hide the current object
			if obj >= 0 and obj < field.objects.size():
				field.set_object_state(obj, 3)
		0x02:  # 0x5A4B set the current object's event
			if obj >= 0 and obj < field.objects.size():
				field.objects[obj].event = _a(args, 0)
		0x03:  # 0x5A55 patch the current object's saved record (MAPZ)
			if obj >= 0:
				var o: Array = field.scene["objects"][obj]
				o[_a(args, 0) / 2] = _a(args, 1)
		0x04:  # 0x5A7A if flag set: goto
			if GameState.flag(_a(args, 0)):
				goto_event(_a(args, 1))
		0x05:  # 0x5A9D fade out
			await game.fade(false)
		0x06:  # 0x5AA3 redraw, fade in
			field.redraw()
			await game.fade(true)
		0x07:  # 0x5AAC redraw, palette on at once
			field.redraw()
			game.set_brightness(1.0)
		0x08:  # 0x5AB5 wait n ticks
			await _wait(_a(args, 0))
		0x09:  # 0x5AB9 set/clear flag
			GameState.set_flag(_a(args, 0), _a(args, 1) != 0)
		0x0A:  # 0x5AE2 add to a party value, capped by the value after it
			var off := GameState.PARTY + _a(args, 0)
			_add_sat(off, _a(args, 1))
			if GameState.w(off + 2) < GameState.w(off):
				GameState.setw(off, GameState.w(off + 2))
		0x0B:  # 0x5AEF add to a party value
			_add_sat(GameState.PARTY + _a(args, 0), _a(args, 1))
		0x0C:  # 0x5B06 restore every member
			game.heal_party()
		0x0D:  # 0x5B2C yes/no; goto on yes
			var yes: bool = await game.choose_yes_no()
			if yes:
				goto_event(_a(args, 0))
		0x0E:  # 0x5C2F show money
			game.show_money()
		0x0F:  # 0x5C35 pay and goto when there is enough money
			if GameState.money() >= _a(args, 0):
				GameState.setw(GameState.MONEY, GameState.money() - _a(args, 0))
				goto_event(_a(args, 1))
		0x10:  # 0x5C49 move the party and view inside the map
			field.reposition(_a(args, 0), _a(args, 1), _a(args, 2), _a(args, 3), _a(args, 4), _a(args, 5))
		0x11:  # 0x5C67 shop with buy and sell
			await game.shop(args[0], true)
		0x13:  # 0x5E30 shop, buy only
			await game.shop(args[0], false)
		0x15:  # 0x5F8C if the character is in the party: goto
			if game.in_party(_a(args, 0)):
				goto_event(_a(args, 1))
		0x16:  # 0x5FC4 redraw
			field.redraw()
		0x17:  # 0x5FDF object steps up
			field.move_object(_a(args, 0) / 2, 3)
		0x18:  # 0x5FF5 object steps down
			field.move_object(_a(args, 0) / 2, 0)
		0x19:  # 0x6006 object steps left
			field.move_object(_a(args, 0) / 2, 6)
		0x1A:  # 0x6014 object steps right
			field.move_object(_a(args, 0) / 2, 9)
		0x1B:  # 0x6050 set object state
			field.set_object_state(_a(args, 0) / 2, _a(args, 1))
		0x1C:  # 0x6064 battle with enemy group n
			await game.battle(_a(args, 0), false)
		0x1D:  # 0x6071 load palette and tiles (cut scenes)
			field.load_tiles(_a(args, 0), _a(args, 1), true)
		0x1E:  # 0x6088 party walks up n steps
			await game.party_walk(3, _a(args, 0))
		0x1F:  # 0x609D party walks down
			await game.party_walk(0, _a(args, 0))
		0x20:  # 0x60B2 party walks left
			await game.party_walk(6, _a(args, 0))
		0x21:  # 0x60C7 party walks right
			await game.party_walk(9, _a(args, 0))
		0x22:  # 0x60DC patch objects of other scenes, by entry point
			for p in args[0]:
				var sc := GameState.scene_of_entry(int(p[0]))
				if sc.is_empty():
					continue
				# RPG.EXE 0x60EA: word at scene + 6 + A + B*12, A signed, so it
				# can reach the previous object or the scene header
				var lin := (Actor._s16(int(p[1])) + int(p[2]) * 12) / 2
				var objs: Array = sc["objects"]
				if lin < 0:
					var hk: String = ["map_id", "unknown", ""][lin + 3] if lin >= -3 else ""
					if hk != "":
						sc[hk] = (int(sc[hk]) + int(p[3])) & 0xFFFF if p[4] else int(p[3])
					continue
				if lin / 12 >= objs.size():
					continue
				var o: Array = objs[lin / 12]
				var k := lin % 12
				if p[4]:
					o[k] = (int(o[k]) + int(p[3])) & 0xFFFF
				else:
					o[k] = int(p[3])
		0x23:  # 0x6117 load a tilemap without foreground (cut scenes)
			field.load_map_entry(_a(args, 0), _a(args, 1), false)
		0x24:  # 0x6133 play n frames of the animated tilemap
			await game.play_frames(_a(args, 0))
		0x25:  # 0x617A go to an entry point
			await game.warp(_a(args, 0))
		0x26:  # 0x6188 play music RI<n>.RIX
			game.play_music(_a(args, 0))
		0x27:  # 0x619A set an object's sprite word
			var o2 := _a(args, 0) / 2
			if o2 < field.objects.size():
				field.set_object_sprite(o2, _a(args, 1))
			field.redraw()
		0x28:  # 0x61BA items: test / replace, or plain goto (0xF7F7)
			_item_op(_a(args, 0), _a(args, 1), _a(args, 2))
		0x29:  # 0x6211 add money
			GameState.add_money(_a(args, 0))
		0x2A:  # 0x6227 byte at 0x4F8
			GameState.setb(0x4F8, _a(args, 0))
		0x2B:  # 0x622C load palette and tiles
			field.load_tiles(_a(args, 0), _a(args, 1), false)
		0x2C:  # 0x6243 field speed (ticks per frame)
			GameState.setw(0x64F9, _a(args, 0))
		0x2D:  # 0x6248 fade in
			await game.fade(true)
		0x2F:  # 0x6257 party size
			GameState.setw(GameState.PARTY_COUNT, _a(args, 0))
			field.refresh_party()
		0x30:  # 0x6060 battle, then run an object's event
			GameState.setw(0x610, _a(args, 0))
			await game.battle(_a(args, 1), false)
		0x31:  # 0x629D shake
			await game.shake(_a(args, 0))
		0x32:  # 0x62B1 swap two party records
			_swap_members(_a(args, 0), _a(args, 1), _a(args, 2), _a(args, 3))
			field.refresh_party()
		0x33:  # 0x62E6 party facing
			field.set_party_facing(_a(args, 0))
		0x34:  # 0x62ED back to the title screen
			ended_by_restart = true
			running = false
			game.restart()
		0x35:  # 0x62F0 print text at x, y (no wait)
			await overlay.write(args[2], _a(args, 0) * 4, _a(args, 1), false)
		0x36:  # 0x6306 put a byte into the first free slot of a list
			var base := GameState.PARTY + _a(args, 0)
			for i in 0x32:
				if GameState.w(base + i) == 0:
					GameState.setb(base + i, _a(args, 1))
					break
		0x37:  # 0x631F stop sound
			game.stop_sfx()
		0x38:  # 0x632C sound stop/reset
			pass
		0x39:  # 0x6332 sound effect SP<n>.VOC
			game.play_sfx(_a(args, 0))
		0x3A:  # 0x6339 boss battle
			await game.battle(_a(args, 0), true)
		0x3B:  # 0x6342 boss battle, then an object's event
			GameState.setw(0x610, _a(args, 0))
			await game.battle(_a(args, 1), true)
		0x3C:  # 0x634B battle, then an object's event
			GameState.setw(0x610, _a(args, 0))
			await game.battle(_a(args, 1), false)
		0x3D:  # 0x6354
			GameState.setb(0x1CC, 0x96)
		0x3E:  # 0x635A journal entry (BOOK.ZAQ), then show the text
			var mode := _a(args, 0)
			var text: String = args[args.size() - 1]
			game.add_journal(text)
			if mode == 3 or mode == 5:
				await _text_at(_a(args, 1), _a(args, 2), text, mode == 5)
			elif mode != 4:
				await _say(text, false, mode == 1)
		0x3F:  # 0x6437 goto when every flag is set
			var all := true
			for f in args[1]:
				if not GameState.flag(int(f)):
					all = false
			if all:
				goto_event(_a(args, 0))
		0x40:  # 0x6475 goto when any flag is set
			for f in args[1]:
				if GameState.flag(int(f)):
					goto_event(_a(args, 0))
					break
		0x41:  # 0x64B3 menu: choose one of n texts, goto its event
			var i: int = await game.menu(args[0])
			var evs: Array = args[1]
			if i >= 0 and i < evs.size():
				goto_event(int(evs[i]))
		0x42:  # 0x65D8 storage (deposit / withdraw)
			await game.storage()
		0x43:  # 0x677E clear screen, palette on
			game.clear_screen()
		0x44:  # 0x6787 text at x, y with typewriter, wait at the end
			await _text_at(_a(args, 0), _a(args, 1), args[2], false)
		0x45:  # 0x6799 save prompt
			await game.save_prompt()
		0x46:  # 0x67E6 picture: SA entry, frame, x, y
			game.show_picture(_a(args, 0), _a(args, 1), _a(args, 2) * 4, _a(args, 3))
		0x47:  # 0x680C set an object's path program
			var o3 := _a(args, 0) / 2
			if o3 < field.objects.size():
				field.objects[o3].path = _a(args, 1)
				field.objects[o3].path_pc = 0
		0x48:  # 0x681B change a member's sprites
			GameState.setw(GameState.SPRITES + _a(args, 0), _a(args, 1))
			GameState.setw(GameState.SPRITES + _a(args, 0) + 8, _a(args, 2))
			field.refresh_party()
		0x49:  # 0x6831 followers that are not fighters
			var n := _a(args, 0)
			if n + GameState.w(GameState.PARTY_COUNT) > 4:
				n = 4 - GameState.w(GameState.PARTY_COUNT)
			GameState.setw(GameState.PARTY_EXTRA, n)
			field.refresh_party()
		0x4A:  # 0x684E pan the view by cells
			field.pan(_a(args, 0), _a(args, 1))
		0x4B:  # 0x689B text at x, y, fast
			await _text_at(_a(args, 0), _a(args, 1), args[2], true)
		0x4C:  # 0x68A3 let objects move one tick
			field.update_objects()
			field.redraw()
			await _wait(GameState.w(0x64F9))
		0x4D:  # 0x68C1 object facing
			var o4 := _a(args, 0) / 2
			if o4 < field.objects.size():
				field.objects[o4].frame_dir = _a(args, 1)
		0x4E:  # 0x68CA remove a byte from a list
			var base2 := GameState.PARTY + _a(args, 0)
			for i in 0x32:
				if GameState.b(base2 + i) == _a(args, 1):
					for j in range(i, 0x31):
						GameState.setb(base2 + j, GameState.b(base2 + j + 1))
					GameState.setb(base2 + 0x31, 0)
					break
		0x4F:  # 0x6911 redraw the current frame
			await game.play_frames(0)
		0x50:  # 0x6941 show DOR1.RSK picture
			pass
		0x51:  # 0x6947 select the animation frame
			field.anim_frame = _a(args, 0)
		_:
			push_warning("script op %x not implemented" % op)


func _add_sat(off: int, v: int) -> void:
	var r := GameState.w(off) + v
	GameState.setw(off, 0xFFFF if r > 0xFFFF else r)


func _say(text: String, keep: bool, fast: bool, top := false) -> void:
	overlay.show_box(top)
	overlay.fast = fast
	var y := (0 if top else 112) + 12
	await overlay.write(text, 40, y, true, 280, 4)
	overlay.fast = false
	if not keep:
		await overlay.wait_key(Vector2(280, y + 48))
		overlay.clear()


func _text_at(x: int, y: int, text: String, fast: bool) -> void:
	overlay.fast = fast
	await overlay.write(text, x * 4, y, true, 300, 0)
	overlay.fast = false
	await overlay.wait_key(Vector2(-1, -1))


func _item_op(id: int, ev: int, repl: int) -> void:
	if id == 0xF7F7:
		goto_event(ev)
		return
	for i in 0x32:
		var off := GameState.ITEMS + i * 2
		if GameState.w(off) == id:
			if repl != 0xF800:
				GameState.setw(off, repl)
			return
	if repl == 0xF800:
		# equipped items count too
		for m in 4:
			for k in 0x0B:
				if GameState.w(GameState.PARTY + m * GameState.PARTY_REC + 0x10 + k * 2) == id:
					return
	goto_event(ev)


func _swap_members(a: int, b: int, c: int, d: int) -> void:
	for i in GameState.PARTY_REC:
		var x := GameState.b(GameState.PARTY + a + i)
		GameState.setb(GameState.PARTY + a + i, GameState.b(GameState.PARTY + b + i))
		GameState.setb(GameState.PARTY + b + i, x)
	var s1 := GameState.w(0x89 + c)
	GameState.setw(0x89 + c, GameState.w(0x89 + d))
	GameState.setw(0x89 + d, s1)
