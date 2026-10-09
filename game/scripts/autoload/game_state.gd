extends Node
## Game state. Like RPG.EXE, most of it lives in one data block whose
## offsets the story scripts use directly (party stats at 0x11D, money at
## 0x11B, story flags at 0x596, inventory at 0x399 ...). We keep a copy of the
## original initialised data segment and read/write it by offset, so script
## opcodes can be ported one to one. Scenes (the MAPZ.ZAQ copy of MAPA.EXE)
## are kept as dictionaries and patched by scripts.

const PARTY_COUNT := 0x27
const PARTY_EXTRA := 0x119
const MONEY := 0x11B
const PARTY := 0x11D
const PARTY_REC := 0x9F
const SPRITES := 0x101
const FLAGS := 0x596
const ITEMS := 0x399

var ds := PackedByteArray()
var scenes := {}
var current_entry := 0
var current_scene := 0
var brightness := 1.0


func _ready() -> void:
	new_game()


func new_game() -> void:
	ds = Assets.rpg_ds.duplicate() if Assets.available() else PackedByteArray()
	if ds.size() < 0x8000:
		ds.resize(0x8000)
	scenes.clear()


func w(off: int) -> int:
	return ds.decode_u16(off)


func setw(off: int, v: int) -> void:
	ds.encode_u16(off, v & 0xFFFF)


func b(off: int) -> int:
	return ds[off]


func setb(off: int, v: int) -> void:
	ds[off] = v & 0xFF


## Story flags: bit 15-(n & 15) of word n >> 4 (RPG.EXE ops 0x04, 0x09).
func flag(n: int) -> bool:
	return (w(FLAGS + (n >> 4) * 2) & (0x8000 >> (n & 15))) != 0


func set_flag(n: int, on: bool) -> void:
	var off := FLAGS + (n >> 4) * 2
	var m := 0x8000 >> (n & 15)
	setw(off, (w(off) | m) if on else (w(off) & ~m))


func money() -> int:
	return w(MONEY)


func add_money(v: int) -> void:
	setw(MONEY, mini(w(MONEY) + v, 0xFFFF))


func party_count() -> int:
	return clampi(w(PARTY_COUNT) + w(PARTY_EXTRA), 1, 4)


func party_sprite(i: int) -> int:
	return w(SPRITES + i * 2)


## Live copy of a scene record, created from MAPA.EXE on first visit.
func scene_state(offset: int) -> Dictionary:
	if not scenes.has(offset):
		var s = Assets.scene(offset)
		scenes[offset] = s.duplicate(true) if s != null else {}
	return scenes[offset]


## Scene record of an entry point (op 0x22 patches other scenes by entry).
func scene_of_entry(ref: int) -> Dictionary:
	var e = Assets.entry(ref)
	if e == null:
		return {}
	return scene_state(int(e["scene"]))


func to_save() -> Dictionary:
	var sc := {}
	for k in scenes:
		sc[str(k)] = {"objects": scenes[k]["objects"]}
	return {
		"version": 1,
		"ds": Marshalls.raw_to_base64(ds),
		"entry": current_entry,
		"scenes": sc,
	}


func from_save(d: Dictionary) -> void:
	ds = Marshalls.base64_to_raw(d["ds"])
	scenes.clear()
	for k in d.get("scenes", {}):
		var s := scene_state(int(k))
		s["objects"] = d["scenes"][k]["objects"]
	current_entry = int(d.get("entry", 0))
