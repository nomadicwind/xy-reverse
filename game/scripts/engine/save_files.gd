class_name SaveFiles
extends RefCounted
## Save slots as JSON under user://saves.


static func path(slot: int) -> String:
	return "user://saves/slot%d.json" % slot


static func save_slot(slot: int, meta := {}) -> void:
	DirAccess.make_dir_recursive_absolute("user://saves")
	var d := GameState.to_save()
	d["meta"] = meta
	var f := FileAccess.open(path(slot), FileAccess.WRITE)
	f.store_string(JSON.stringify(d))


static func load_slot(slot: int) -> Dictionary:
	if not FileAccess.file_exists(path(slot)):
		return {}
	var d = JSON.parse_string(FileAccess.get_file_as_string(path(slot)))
	return d if d is Dictionary else {}
