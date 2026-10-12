class_name Title
extends Node2D
## The title screen of RPG.EXE 0x0C36: DO.LSK tile sheet 0x3D and tilemap
## 0x42, whose five chunks fade the calligraphy in, song RI078, then after a
## key the menu 開始遊戲 / 繼續遊戲 in a MENU.RSK frame with the arrow 0x93.

const ITEMS := ["　開始遊戲", "　繼續遊戲"]   # DS:2580, with the leading space
const TILES := 0x3D
const MAP := 0x42
const PACK := 6                 # DO.LSK

var sel := 1                    # the original starts on 繼續遊戲
var _bg: Sprite2D
var _overlay: Overlay
var _arrow: Sprite2D
var _music: AudioStreamPlayer
var _chunks: Array = []


func _ready() -> void:
	_bg = Sprite2D.new()
	_bg.centered = false
	add_child(_bg)
	_overlay = Overlay.new()
	add_child(_overlay)
	var pal := Assets.palette(PACK, TILES)
	if pal:
		_overlay.set_palette(pal.get_image(), pal)
	var m = Assets.tilemap(PACK, MAP)
	if m != null:
		_chunks = m["chunks"]
	_music = AudioStreamPlayer.new()
	add_child(_music)
	var song := Assets.root.path_join("music/RI078.ogg")
	if FileAccess.file_exists(song):
		var s := AudioStreamOggVorbis.load_from_buffer(FileAccess.get_file_as_bytes(song))
		if s:
			s.loop = true
			_music.stream = s
			_music.volume_db = -6.0
			_music.play()


## Renders one chunk of the title tilemap into a texture.
func _show_chunk(i: int) -> void:
	if _chunks.is_empty():
		return
	var c: Dictionary = _chunks[clampi(i, 0, _chunks.size() - 1)]
	var tiles_tex := Assets.tiles(PACK, TILES)
	var pal := Assets.palette(PACK, TILES)
	if tiles_tex == null or pal == null:
		return
	var tiles := tiles_tex.get_image()
	var pimg := pal.get_image()
	var w := int(c["w"])
	var h := int(c["h"])
	var out := Image.create(w * 8, h * 8, false, Image.FORMAT_RGB8)
	var cols := tiles.get_width() / 8
	var cells: Array = c["cells"]
	for k in cells.size():
		var t := int(cells[k]) & 0x7FF
		var tx := (t % cols) * 8
		var ty := (t / cols) * 8
		var ox := (k % w) * 8
		var oy := (k / w) * 8
		for y in 8:
			for x in 8:
				var idx := int(tiles.get_pixel(tx + x, ty + y).r8)
				out.set_pixel(ox + x, oy + y, pimg.get_pixel(idx, 0))
	_bg.texture = ImageTexture.create_from_image(out)


func choose() -> int:
	# fade the calligraphy in, two ticks a chunk
	for i in _chunks.size():
		_show_chunk(i)
		await get_tree().create_timer(2.0 / 18.2).timeout
	if _chunks.is_empty():
		_show_chunk(0)
	Keys.reset()
	while not (Keys.just("ui_accept") or Keys.just("ui_cancel")):
		await get_tree().process_frame
	_overlay.add_small_frame(Vector2(100, 150), 8, 2)
	for i in ITEMS.size():
		await _overlay.write("{C0}{M-1}" + ITEMS[i], 108, 159 + i * 16, false, 320)
	var menu = Assets.rsk("MENU")
	if menu:
		var r: Array = menu["frames"][0x93]
		_arrow = Sprite2D.new()
		_arrow.centered = false
		_arrow.texture = menu["texture"]
		_arrow.region_enabled = true
		_arrow.region_rect = Rect2(r[0], r[1], r[2], r[3])
		_arrow.material = _overlay._box_node.material
		add_child(_arrow)
	while true:
		if _arrow:
			_arrow.position = Vector2(188, 161 + sel * 16)
		await get_tree().process_frame
		if Keys.just("ui_down") or Keys.just("ui_up"):
			sel = 1 - sel
		elif Keys.just("ui_accept"):
			_music.stop()
			return sel
		elif Keys.just("ui_cancel"):
			return -1
	return -1
