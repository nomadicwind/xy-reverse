class_name CartScene
extends Node2D
## Script op 0x50 (RPG.EXE 0x6AB9): the dragon cart rolls past the sunset.
## DOR4.RSK is the sky and holds the palette for all four files; the cart
## (DOR1 parts 0-1, DOR2 part 0) and the fortress (DOR3 part 0) slide left
## 8 px a frame for 0x8F frames, DOR3 part 1 rises across the screen, and
## from frame 0x7D four figures (DOR3 parts 2..21) walk in and turn left.
## Positions are the original's, in 4-pixel units (DS:3AF0..3B1B).

const SHADER := preload("res://scripts/engine/indexed.gdshader")
const FRAMES := 0x8F
const WALK_FROM := 0x7D

var _mat: ShaderMaterial
var _rsk := {}
var _layer: Node2D


func _ready() -> void:
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER
	_mat.set_shader_parameter("palette", Assets.load_texture("rsk/DOR4.pal.png"))
	_mat.set_shader_parameter("transparent_index", 0xFE)
	_mat.set_shader_parameter("brightness", 0.0)
	for n in range(1, 5):
		_rsk[n] = Assets.rsk("DOR%d" % n)
	var bg := _piece(4, 0, Vector2.ZERO)
	if bg:
		add_child(bg)
	_layer = Node2D.new()
	add_child(_layer)


func _piece(file: int, part: int, at: Vector2) -> Sprite2D:
	var r = _rsk.get(file)
	if r == null or part >= r["frames"].size():
		return null
	var f: Array = r["frames"][part]
	var s := Sprite2D.new()
	s.centered = false
	s.texture = r["texture"]
	s.region_enabled = true
	s.region_rect = Rect2(f[0], f[1], f[2], f[3])
	s.position = at
	s.material = _mat
	return s


func _draw_at(file: int, part: int, x: int, y: int) -> void:
	var s := _piece(file, part, Vector2(x * 4, y))
	if s:
		_layer.add_child(s)


func play() -> void:
	var cart := [80, 138, 218, 298]          # DOR1.0, DOR1.1, DOR2.0, DOR3.0
	var riser := Vector2i(-100, 320)
	var wx := [36, 40, 44, 48]
	var wy := [-52, -44, -36, -28]
	var wf := [17, 12, 7, 2]
	var ws := [0, 0, 0, 0]
	var tick := 2.0 / 18.2
	for frame in FRAMES:
		for c in _layer.get_children():
			c.queue_free()
		_draw_at(1, 0, cart[0], 3)
		_draw_at(1, 1, cart[1], 3)
		_draw_at(2, 0, cart[2], 3)
		_draw_at(3, 0, cart[3], 3)
		for k in 4:
			cart[k] -= 2
		_draw_at(3, 1, riser.x, riser.y)
		riser += Vector2i(1, -3)
		if frame >= WALK_FROM:
			for k in 4:
				if ws[k] != 0:
					wx[k] -= 2
					ws[k] += 1
					if ws[k] == 3:
						wf[k] += 1
				elif wy[k] == 0x2C:
					wf[k] += 1
					ws[k] = 1
					wx[k] -= 2
				else:
					wy[k] += 8
			for k in 4:
				_draw_at(3, wf[k], wx[k], wy[k])
		if frame < 16:
			_mat.set_shader_parameter("brightness", (frame + 1) / 16.0)
		await get_tree().create_timer(tick).timeout
	for i in 17:
		_mat.set_shader_parameter("brightness", 1.0 - i / 16.0)
		await get_tree().create_timer(tick * 0.5).timeout
