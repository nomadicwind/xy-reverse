extends Node
## Reads the data exported by `python3 -m swdtools engine` at runtime.
##
## The data never goes through Godot's importer (the folder carries a
## .gdignore), so the same code works in the editor and in exported builds,
## where players point the game at their own extracted copy.
## Search order: --data=<dir>, res://assets/extracted/engine,
## <executable dir>/data/engine, user://engine.

const PACK_BY_ID := {0: "SA", 2: "MAP", 4: "CD", 6: "DO"}

var root := ""
var _json := {}
var _textures := {}
var _images := {}

var mapa: Dictionary
var zones: Dictionary
var font_chars := {}
var font_texture: Texture2D
var rpg_ds: PackedByteArray


func _ready() -> void:
	root = _find_root()
	if root == "":
		push_warning("No extracted data found. Run scripts/extract.sh first.")
		return
	mapa = load_json("mapa.json")
	zones = load_json("zones.json")
	rpg_ds = FileAccess.get_file_as_bytes(root + "/rpg_ds.bin")
	_load_font()


func available() -> bool:
	return root != ""


func _find_root() -> String:
	var cands: Array[String] = []
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--data="):
			cands.append(a.substr(7))
	cands.append("res://assets/extracted/engine")
	cands.append(OS.get_executable_path().get_base_dir().path_join("data/engine"))
	cands.append("user://engine")
	for c in cands:
		if FileAccess.file_exists(c.path_join("mapa.json")):
			return c
	return ""


func load_json(rel: String):
	if _json.has(rel):
		return _json[rel]
	var path := root.path_join(rel)
	if not FileAccess.file_exists(path):
		return null
	var v = JSON.parse_string(FileAccess.get_file_as_string(path))
	_json[rel] = v
	return v


func load_image(rel: String) -> Image:
	if _images.has(rel):
		return _images[rel]
	var path := root.path_join(rel)
	if not FileAccess.file_exists(path):
		return null
	var img := Image.new()
	if img.load_png_from_buffer(FileAccess.get_file_as_bytes(path)) != OK:
		return null
	_images[rel] = img
	return img


func load_texture(rel: String) -> Texture2D:
	if _textures.has(rel):
		return _textures[rel]
	var img := load_image(rel)
	if img == null:
		return null
	if img.get_format() == Image.FORMAT_RGB8 and not rel.ends_with(".pal.png"):
		img.convert(Image.FORMAT_L8)
	var tex := ImageTexture.create_from_image(img)
	_textures[rel] = tex
	return tex


func pack_name(file_id: int) -> String:
	return PACK_BY_ID.get(file_id, "MAP")


func palette(file_id: int, entry: int) -> Texture2D:
	return load_texture("lsk/%s/%d.pal.png" % [pack_name(file_id), entry])


func tiles(file_id: int, entry: int) -> Texture2D:
	return load_texture("lsk/%s/%d.tiles.png" % [pack_name(file_id), entry])


func tilemap(file_id: int, entry: int):
	return load_json("lsk/%s/%d.map.json" % [pack_name(file_id), entry])


## Picture atlas of an LSK entry: {"texture": Texture2D, "frames": [[x,y,w,h], ...]}
func pictures(file_id: int, entry: int):
	var key := "pics:%d:%d" % [file_id, entry]
	if _json.has(key):
		return _json[key]
	var meta = load_json("lsk/%s/%d.json" % [pack_name(file_id), entry])
	var tex := load_texture("lsk/%s/%d.png" % [pack_name(file_id), entry])
	var r = null
	if meta != null and tex != null:
		r = {"texture": tex, "frames": meta["frames"]}
	_json[key] = r
	return r


## A picture list exported from an RSK file (rsk/<name>.png/.json).
func rsk(name: String):
	var key := "rsk:" + name
	if _json.has(key):
		return _json[key]
	var meta = load_json("rsk/%s.json" % name)
	var tex := load_texture("rsk/%s.png" % name)
	var r = null
	if meta != null and tex != null:
		r = {"texture": tex, "frames": meta["frames"]}
	_json[key] = r
	return r


func script_file(name: String):
	return load_json("scripts/%s.json" % name.get_basename().to_upper())


func entry(ref: int):
	var i := (ref - 2) / 2
	var es: Array = mapa.get("entries", [])
	if i < 0 or i >= es.size():
		return null
	return es[i]


func scene(offset: int):
	return mapa.get("scenes", {}).get(str(offset))


func _load_font() -> void:
	var meta = load_json("font.json")
	var img := load_image("font.png")
	if meta == null or img == null:
		return
	var chars: String = meta["chars"]
	for i in chars.length():
		font_chars[chars[i]] = i
	font_texture = ImageTexture.create_from_image(img)


## Region of a glyph in font_texture, or an empty rect when the game has no glyph.
func glyph_rect(ch: String) -> Rect2:
	if not font_chars.has(ch):
		return Rect2()
	var i: int = font_chars[ch]
	return Rect2((i % 64) * 16, (i / 64) * 16, 16, 15)
