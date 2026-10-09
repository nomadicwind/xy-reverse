class_name MapLoader
extends RefCounted
## Builds a TileMapLayer from a map exported by tools/swdtools
## (assets/extracted/maps/map_NNN/{tileset.png,map.json}).

const MAPS_DIR := "res://assets/extracted/maps"


static func map_dir(id: int) -> String:
	return "%s/map_%03d" % [MAPS_DIR, id]


static func map_count() -> int:
	var f := FileAccess.open(MAPS_DIR + "/index.json", FileAccess.READ)
	if f == null:
		return 0
	var idx = JSON.parse_string(f.get_as_text())
	return idx.size() if idx is Array else 0


static func load_meta(id: int) -> Dictionary:
	var f := FileAccess.open(map_dir(id) + "/map.json", FileAccess.READ)
	if f == null:
		return {}
	var meta = JSON.parse_string(f.get_as_text())
	return meta if meta is Dictionary else {}


static func build_layer(id: int) -> TileMapLayer:
	var meta := load_meta(id)
	if meta.is_empty():
		return null
	var texture: Texture2D = load(map_dir(id) + "/tileset.png")
	if texture == null:
		return null
	var ts := int(meta["tile_size"])
	var cols := int(meta["tileset_columns"])
	var count := int(meta["tile_count"])

	var source := TileSetAtlasSource.new()
	source.texture = texture
	source.texture_region_size = Vector2i(ts, ts)
	for t in count:
		source.create_tile(Vector2i(t % cols, t / cols))
	var tileset := TileSet.new()
	tileset.tile_size = Vector2i(ts, ts)
	tileset.add_source(source, 0)

	var layer := TileMapLayer.new()
	layer.tile_set = tileset
	var w := int(meta["width"])
	var cells: Array = meta["cells"]
	for i in cells.size():
		var t := int(cells[i])
		if t < count:
			layer.set_cell(Vector2i(i % w, i / w), 0, Vector2i(t % cols, t / cols))
	layer.set_meta("map_size_px", Vector2i(w * ts, int(meta["height"]) * ts))
	layer.set_meta("flags", meta["flags"])
	return layer
