class_name Actor
extends Sprite2D
## A map object or a party member drawn from an SA.LSK sprite sheet.
## Field names follow the scene object layout (tools/swdtools/scenes.py).

var index := -1          # object slot, -1 for party members
var sprite := 0          # SA.LSK entry (0 = invisible / party sheet)
var base_frame := 0      # first frame of the current pose set
var frame_dir := 0       # 0 down, 3 up, 6 left, 9 right
var pos := 0             # byte offset of the left cell (objects)
var state := 1
var speed := 0
var dx := 0
var dy := -16
var range_x := 0
var range_y := 0
var event := 0
var anim := 0
var path := 0
var path_pc := 0
var delay := 0
var wander_x := 0
var wander_y := 0
var sheet = null         # {"texture", "frames"}


func setup_from(raw: Array) -> void:
	var fields: Array[int] = []
	for v in raw:
		fields.append(int(v))
	sprite = fields[0] >> 8
	base_frame = fields[0] & 0xFF
	frame_dir = fields[1]
	pos = fields[2]
	state = fields[3]
	speed = fields[4]
	dx = _s16(fields[5])
	dy = _s16(fields[6])
	range_x = fields[7]
	range_y = fields[8]
	event = fields[9]
	anim = fields[10]
	path = fields[11]


static func _s16(v: int) -> int:
	return v - 0x10000 if v >= 0x8000 else v


func set_sheet(s, mat: Material) -> void:
	sheet = s
	material = mat
	centered = false
	region_enabled = true
	if s != null:
		texture = s["texture"]


func hidden_state() -> bool:
	return state == 3 or state == 7 or state == 8 or state == 9


## Frame index inside the sheet: base + facing + walk phase (0, 1, 2, 1).
func frame_index() -> int:
	var phase := 1 if (anim & 1) else anim
	if state == 4 or state == 5 or state == 6:
		return base_frame + phase
	return base_frame + frame_dir + phase


func refresh(world_x: int, world_y: int) -> void:
	if sheet == null:
		visible = false
		return
	var frames: Array = sheet["frames"]
	var i := frame_index()
	if i < 0 or i >= frames.size():
		i = clampi(i, 0, frames.size() - 1)
	var r: Array = frames[i]
	region_rect = Rect2(r[0], r[1], r[2], r[3])
	position = Vector2(world_x, world_y)
