class_name Overlay
extends Node2D
## Text, dialogue boxes and pictures drawn over the field, using the game's
## own 16x15 glyphs. Text markup from the scripts:
##   ##  new line        %%  wait for a key, then a new page
##   &&  scroll a line   {C16}  text colour (palette index)   {M26}  shadow colour ({M-1} none)

signal key_pressed

const LINE := 16
const SHADER := preload("res://scripts/engine/indexed.gdshader")

var palette_img: Image
var palette_tex: Texture2D
var color_text := 0x0F
var color_shadow := 0x00
var items: Array = []          # {kind, ...}
var box := Rect2()             # current dialogue box, empty = none
var skip := false              # finish the current text at once
var fast := false
var waiting_icon := Vector2(-1, -1)
var _tick := 1.0 / 18.2
static var auto_continue := false   # tests: never wait for keys


func set_palette(img: Image, tex: Texture2D) -> void:
	palette_img = img
	palette_tex = tex
	if _box_node and _box_node.material:
		(_box_node.material as ShaderMaterial).set_shader_parameter("palette", tex)
	queue_redraw()


func pal_color(i: int) -> Color:
	if palette_img == null:
		return Color.WHITE if i != 0 else Color.BLACK
	return palette_img.get_pixel(clampi(i, 0, 255), 0)


func clear() -> void:
	items.clear()
	box = Rect2()
	frames = []
	small_frames = []
	_build_box()
	waiting_icon = Vector2(-1, -1)
	queue_redraw()


func clear_text() -> void:
	items = items.filter(func(it): return it["kind"] == "picture")
	queue_redraw()


func add_picture(tex: Texture2D, region: Rect2, at: Vector2) -> void:
	# a new portrait replaces the one at the same place
	items = items.filter(func(it): return not (it["kind"] == "picture" and it["at"] == at))
	items.append({"kind": "picture", "tex": tex, "region": region, "at": at})
	_sync_pictures()
	queue_redraw()


## The dialogue frame of RPG.EXE 0x8636/0x2C3B: a 9-slice of MENU.RSK
## pictures 0x53..0x5B, 9 columns of 32 px and 4 middle rows of 16 px.
func show_box(top: bool) -> void:
	box = Rect2(16, 0 if top else 112, 288, 88)
	frames = [box]
	clear_text()
	_build_box()


## Adds a frame of `cols` x `rows` (32 x 16 px cells, plus the 12 px top and
## bottom edges), the way menus stack windows. Returns its rectangle.
func add_frame(at: Vector2, cols: int, rows: int) -> Rect2:
	var r := Rect2(at, Vector2(32 * maxi(cols, 2), 24 + 16 * maxi(rows, 1)))
	frames.append(r)
	_build_box()
	return r


## The thin frame of RPG.EXE 0x2B9F (title menu): MENU.RSK 0x50..0x52 on top,
## 0xA8..0xAA for each 16 px row, 0xAB..0xAD at the bottom; `cols` middle
## pieces of 8 px between 24 px ends.
func add_small_frame(at: Vector2, cols: int, rows: int) -> void:
	small_frames.append([at, cols, rows])
	_build_box()


## Removes frames added after the first `keep`, with their text.
func pop_frames(keep: int) -> void:
	while frames.size() > keep:
		var r: Rect2 = frames.pop_back()
		items = items.filter(func(it): return it["kind"] != "glyph" or not r.has_point(it["at"]))
	box = frames[0] if not frames.is_empty() else Rect2()
	_build_box()
	queue_redraw()


var frames: Array = []
var small_frames: Array = []
var _box_node: Node2D


func _build_box() -> void:
	if _box_node == null:
		_box_node = Node2D.new()
		_box_node.show_behind_parent = true
		add_child(_box_node)
		move_child(_box_node, 0)
	for c in _box_node.get_children():
		c.queue_free()
	var menu = Assets.rsk("MENU")
	if (frames.is_empty() and small_frames.is_empty()) or menu == null:
		return
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter("transparent_index", 0xFE)
	mat.set_shader_parameter("palette", palette_tex)
	_box_node.material = mat
	for f in frames:
		# frames of any pixel size: the last column and the bottom edge are
		# pinned to the far side and overlap the middle pieces
		var r: Rect2 = f
		var cols := maxi(2, ceili(r.size.x / 32.0))
		var rows := maxi(1, ceili((r.size.y - 24) / 16.0))
		for col in cols:
			var base := 0x53 if col == 0 else (0x59 if col == cols - 1 else 0x56)
			var x := minf(r.position.x + col * 32, r.end.x - 32)
			var y := r.position.y
			_box_piece(menu, base, Vector2(x, y), mat)
			for k in rows:
				_box_piece(menu, base + 1, Vector2(x, minf(y + 12 + k * 16, r.end.y - 28)), mat)
			_box_piece(menu, base + 2, Vector2(x, r.end.y - 12), mat)


	for f in small_frames:
		var y: float = f[0].y
		for row in [[0x50, 8]] + range(f[2]).map(func(_k): return [0xA8, 16]) + [[0xAB, 0]]:
			var x: float = f[0].x
			_box_piece(menu, row[0], Vector2(x, y), mat)
			x += 24
			for k in f[1]:
				_box_piece(menu, row[0] + 1, Vector2(x, y), mat)
				x += 8
			_box_piece(menu, row[0] + 2, Vector2(x, y), mat)
			y += row[1]


func _box_piece(menu: Dictionary, frame: int, at: Vector2, mat: Material) -> void:
	var r: Array = menu["frames"][frame]
	var s := Sprite2D.new()
	s.centered = false
	s.texture = menu["texture"]
	s.region_enabled = true
	s.region_rect = Rect2(r[0], r[1], r[2], r[3])
	s.position = at
	s.material = mat
	_box_node.add_child(s)


## Splits script text into draw tokens.
static func tokenize(s: String) -> Array:
	var out := []
	var i := 0
	while i < s.length():
		var two := s.substr(i, 2)
		if two == "##" or two == "%%" or two == "&&" or two == "$$":
			out.append({"t": two})
			i += 2
			continue
		var c := s[i]
		if c == "{":
			var j := s.find("}", i)
			if j > i + 2 and (s[i + 1] == "C" or s[i + 1] == "M"):
				out.append({"t": s[i + 1], "v": int(s.substr(i + 2, j - i - 2))})
				i = j + 1
				continue
		out.append({"t": "ch", "v": c})
		i += 1
	return out


## Draws text starting at (x, y) pixels. With `typewriter` it waits one tick
## per glyph unless the player presses a key. `wrap_x` is the right margin.
## Returns when the text is done (does not wait at the end).
func write(text: String, x: int, y: int, typewriter: bool, wrap_x := 280, lines_per_page := 0) -> void:
	var start_x := x
	var cx := x
	var cy := y
	var line_count := lines_per_page
	skip = false
	for tok in tokenize(GameState.expand_names(text)):
		match tok["t"]:
			"C":
				color_text = tok["v"]
			"M":
				color_shadow = tok["v"]
			"##":
				cx = start_x
				cy += LINE
				if lines_per_page > 0:
					line_count -= 1
					if line_count <= 0:
						_scroll_up(box)
						cy -= LINE
						line_count = 1
			"&&":
				_scroll_up(box)
				cx = start_x
			"%%":
				await wait_key(Vector2(cx, cy))
				clear_text()
				cx = start_x
				cy = y
				line_count = lines_per_page
				skip = false
			"$$":
				pass
			"ch":
				var c: String = tok["v"]
				if c == " ":
					cx += 8
					continue
				items.append({"kind": "glyph", "ch": c, "at": Vector2(cx, cy),
						"c": color_text, "m": color_shadow})
				queue_redraw()
				cx += 16
				if cx >= wrap_x:  # RPG.EXE 0x828F: new line at x = 280
					cx = start_x
					cy += LINE
				if typewriter and not skip and not fast:
					await _wait_ticks(1)


func _scroll_up(r: Rect2) -> void:
	for it in items:
		if it["kind"] == "glyph" and (r.size == Vector2.ZERO or r.has_point(it["at"])):
			it["at"].y -= LINE
	items = items.filter(func(it): return it["kind"] != "glyph" or r.size == Vector2.ZERO or it["at"].y >= r.position.y + 4)
	queue_redraw()


func _wait_ticks(n: int) -> void:
	await get_tree().create_timer(_tick * n).timeout


func wait_key(icon_at := Vector2(-1, -1)) -> void:
	waiting_icon = icon_at
	queue_redraw()
	if auto_continue:
		await _wait_ticks(2)
	else:
		await key_pressed
	waiting_icon = Vector2(-1, -1)
	queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_accept") or event.is_action_pressed("ui_cancel"):
		skip = true
		key_pressed.emit()


func _draw() -> void:
	if box.size != Vector2.ZERO and Assets.rsk("MENU") == null:
		draw_rect(box, Color(0, 0, 0, 0.55))
	var font := Assets.font_texture
	for it in items:
		match it["kind"]:
			"picture":
				pass    # child sprites, see _sync_pictures
			"glyph":
				if font == null:
					continue
				var r := Assets.glyph_rect(it["ch"])
				if r.size == Vector2.ZERO:
					draw_string(ThemeDB.fallback_font, it["at"] + Vector2(0, 13), it["ch"], HORIZONTAL_ALIGNMENT_LEFT, -1, 14, pal_color(it["c"]))
					continue
				if it["m"] >= 0:
					draw_texture_rect_region(font, Rect2(it["at"] + Vector2(1, 1), r.size), r, pal_color(it["m"]))
				draw_texture_rect_region(font, Rect2(it["at"], r.size), r, pal_color(it["c"]))
	if waiting_icon.x >= 0:
		var t := Time.get_ticks_msec() / 250 % 2
		draw_circle(waiting_icon + Vector2(8, 8), 3.0 + t, pal_color(color_text))


var _pic_nodes := {}


## Pictures are indexed images: they are Sprite2D children with the palette
## shader (CanvasItem.draw_* calls cannot carry a different material). The
## children are made and freed here, never from _draw, since changing the
## tree while it is being drawn crashes the renderer.
func _sync_pictures() -> void:
	var wanted := {}
	for it in items:
		if it["kind"] == "picture":
			wanted["%s:%s" % [it["at"], it["region"]]] = it
	for k in _pic_nodes.keys():
		if not wanted.has(k):
			_pic_nodes[k].queue_free()
			_pic_nodes.erase(k)
	for k in wanted:
		var it: Dictionary = wanted[k]
		var s: Sprite2D = _pic_nodes.get(k)
		if s == null:
			s = Sprite2D.new()
			s.centered = false
			s.region_enabled = true
			s.show_behind_parent = true
			var m := ShaderMaterial.new()
			m.shader = SHADER
			m.set_shader_parameter("transparent_index", 0xFE)
			s.material = m
			add_child(s)
			_pic_nodes[k] = s
		s.texture = it["tex"]
		s.region_rect = it["region"]
		s.position = it["at"]
		(s.material as ShaderMaterial).set_shader_parameter("palette", palette_tex)


func _process(_d: float) -> void:
	if waiting_icon.x >= 0:
		queue_redraw()
	_sync_pictures()
