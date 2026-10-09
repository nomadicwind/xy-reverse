class_name Overlay
extends Node2D
## Text, dialogue boxes and pictures drawn over the field, using the game's
## own 16x15 glyphs. Text markup from the scripts:
##   ##  new line        %%  wait for a key, then a new page
##   &&  scroll a line   {C16}  text colour (palette index)   {M26}  shadow colour

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
	queue_redraw()


func pal_color(i: int) -> Color:
	if palette_img == null:
		return Color.WHITE if i != 0 else Color.BLACK
	return palette_img.get_pixel(clampi(i, 0, 255), 0)


func clear() -> void:
	items.clear()
	box = Rect2()
	waiting_icon = Vector2(-1, -1)
	queue_redraw()


func clear_text() -> void:
	items = items.filter(func(it): return it["kind"] == "picture")
	queue_redraw()


func add_picture(tex: Texture2D, region: Rect2, at: Vector2) -> void:
	# a new portrait replaces the one at the same place
	items = items.filter(func(it): return not (it["kind"] == "picture" and it["at"] == at))
	items.append({"kind": "picture", "tex": tex, "region": region, "at": at})
	queue_redraw()


func show_box(top: bool) -> void:
	box = Rect2(16, 0 if top else 112, 288, 80)
	clear_text()


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
	for tok in tokenize(text):
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
				if cx >= wrap_x + 16:
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
	if box.size != Vector2.ZERO:
		draw_rect(box, Color(0, 0, 0, 0.55))
		draw_rect(box, pal_color(color_text).darkened(0.3), false, 1.0)
	var font := Assets.font_texture
	for it in items:
		match it["kind"]:
			"picture":
				var mat := _picture_material()
				# draw_texture_rect_region ignores materials, so use a child sprite cache
				_draw_indexed(it["tex"], it["region"], it["at"])
			"glyph":
				if font == null:
					continue
				var r := Assets.glyph_rect(it["ch"])
				if r.size == Vector2.ZERO:
					draw_string(ThemeDB.fallback_font, it["at"] + Vector2(0, 13), it["ch"], HORIZONTAL_ALIGNMENT_LEFT, -1, 14, pal_color(it["c"]))
					continue
				draw_texture_rect_region(font, Rect2(it["at"] + Vector2(1, 1), r.size), r, pal_color(it["m"]))
				draw_texture_rect_region(font, Rect2(it["at"], r.size), r, pal_color(it["c"]))
	if waiting_icon.x >= 0:
		var t := Time.get_ticks_msec() / 250 % 2
		draw_circle(waiting_icon + Vector2(8, 8), 3.0 + t, pal_color(color_text))


var _pic_nodes := {}


func _picture_material() -> ShaderMaterial:
	return null


## Pictures are indexed images: draw them through Sprite2D children with the
## palette shader (CanvasItem.draw_* calls cannot carry a different material).
func _draw_indexed(tex: Texture2D, region: Rect2, at: Vector2) -> void:
	var key := "%s:%s" % [at, region]
	var s: Sprite2D = _pic_nodes.get(key)
	if s == null:
		s = Sprite2D.new()
		s.centered = false
		s.region_enabled = true
		var m := ShaderMaterial.new()
		m.shader = SHADER
		m.set_shader_parameter("transparent_index", 0xFE)
		s.material = m
		add_child(s)
		_pic_nodes[key] = s
	s.texture = tex
	s.region_rect = region
	s.position = at
	(s.material as ShaderMaterial).set_shader_parameter("palette", palette_tex)
	s.show_behind_parent = true
	s.visible = true
	s.set_meta("used", true)


func _process(_d: float) -> void:
	if waiting_icon.x >= 0:
		queue_redraw()
	# hide picture sprites whose item is gone
	var wanted := {}
	for it in items:
		if it["kind"] == "picture":
			wanted["%s:%s" % [it["at"], it["region"]]] = true
	for k in _pic_nodes.keys():
		if not wanted.has(k):
			_pic_nodes[k].queue_free()
			_pic_nodes.erase(k)
