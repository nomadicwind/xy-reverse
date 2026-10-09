extends Node2D
## Map viewer: PageUp/PageDown switches maps, arrow keys move the walker.

@onready var world: Node2D = $World
@onready var player: Node2D = $World/Player
@onready var camera: Camera2D = $World/Player/Camera2D
@onready var label: Label = $UI/Label

var current := 0
var total := 0
var layer: TileMapLayer


func _ready() -> void:
	total = MapLoader.map_count()
	var arg_map := _cli_map()
	if arg_map >= 0:
		current = arg_map
	if total == 0:
		label.text = "No extracted assets.\nRun scripts/extract.sh first."
		return
	show_map(current)
	var shot := _cli_value("--screenshot=")
	if shot != "":
		_screenshot_and_quit(shot)


func _cli_value(prefix: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(prefix):
			return a.substr(prefix.length())
	return ""


func _cli_map() -> int:
	var v := _cli_value("--map=")
	return int(v) if v != "" else -1


func _screenshot_and_quit(path: String) -> void:
	for i in 5:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	get_tree().quit()


func show_map(id: int) -> void:
	current = wrapi(id, 0, total)
	if layer:
		layer.queue_free()
	layer = MapLoader.build_layer(current)
	if layer == null:
		label.text = "Map %d failed to load" % current
		return
	world.add_child(layer)
	world.move_child(layer, 0)
	var size: Vector2i = layer.get_meta("map_size_px")
	player.bounds = Rect2(Vector2.ZERO, Vector2(size))
	player.position = Vector2(size) / 2.0
	camera.limit_right = size.x
	camera.limit_bottom = size.y
	label.text = "MAP %03d  %dx%d" % [current, size.x / 8, size.y / 8]


func _unhandled_input(event: InputEvent) -> void:
	if total == 0:
		return
	if event.is_action_pressed("map_next"):
		show_map(current + 1)
	elif event.is_action_pressed("map_prev"):
		show_map(current - 1)
