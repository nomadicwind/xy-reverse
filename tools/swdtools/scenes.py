"""MAPA.EXE (scene database) and MAP0.EXE (trigger zones).

MAPA.EXE is copied to SAVE\\MAPZ.ZAQ when a game starts and holds the live
state of every scene. Its body (after the 512-byte header) starts with u16
length and a u16 table of entry points. Map transitions and the new-game code
address an entry point by its table offset (2, 4, ...); RPG.EXE starts a new
game at entry 0x2A.

Entry point (28 bytes):
    +0x00 u16  view: byte offset of the top-left visible cell in the tilemap
    +0x02 u16  0
    +0x04 u16  0
    +0x06 u16  party x on screen, in 4-pixel units
    +0x08 u16  party y on screen, in pixels
    +0x0A u16  facing (0 down, 3 up, 6 left, 9 right)
    +0x0C 14b  Big5 place name ("$$" prefix = not shown)
    +0x1A u16  scene offset

Scene:
    u16 map id (low 11 bits = offset into the MAP0.EXE zone table, flags above:
        0x0800/0x1000 a second tile layer, 0x8000 alternative party sprites)
    u16 unknown
    u16 n, then n objects of 12 u16 (see OBJECT_FIELDS)
    asciiz + u16   tileset descriptor: (LSK file id, palette entry); planes follow
    asciiz + u16   tilemap descriptor: (LSK file id, tilemap entry)
    u16 file id again, u16 music ptr, u16 script ptr, u16 text ptr
    byte path programs for objects, up to FF FF

LSK file ids are word offsets into SWDA.EXE's table: 0 SA, 2 MAP, 4 CD, 6 DO.
"""
import struct

OBJECT_FIELDS = (
    "sprite",   # 0x3E3D high byte SA.LSK entry, low byte base frame
    "frame",    # 0x3FF5 facing frame: 0 down, 3 up, 6 left, 9 right
    "pos",      # 0x40D1 byte offset of the object's cell in the tilemap
    "state",    # 0x4365 0 wander, 1 still, 2/5 animate, 3 hidden, 4/6 still,
                #        6 pick-up, 7 no update, 8 step trigger, 9 key trigger
    "speed",    # 0x41AD low byte delay, high byte alternative SA entry
    "dx",       # 0x47B1 draw offset x (4-pixel units)
    "dy",       # 0x488D draw offset y (pixels)
    "range_x",  # 0x4441 wander range x / animation frame count
    "range_y",  # 0x451D wander range y (low 7 bits), 0x80 = talks on touch
    "event",    # 0x4969 script event (offset into the CHNA event table)
    "anim",     # 0x3F19 animation counter
    "path",     # 0x4B21 path program number (1-based), 0 = none
)


def _body(raw):
    return raw[512:]


def _w(b, o):
    return struct.unpack_from("<H", b, o)[0]


def _table(b):
    table, p, lowest = [], 2, len(b)
    while p < lowest:
        v = _w(b, p)
        table.append(v)
        if v:
            lowest = min(lowest, v)
        p += 2
    return table


def _cstr(b, o):
    q = b.index(b"\0", o)
    return b[o:q], q + 1


def parse_scene(b, off):
    map_id, unk, n = struct.unpack_from("<3H", b, off)
    p = off + 6
    objects = []
    for _ in range(n):
        objects.append(list(struct.unpack_from("<12H", b, p)))
        p += 24
    s1, p = _cstr(b, p)
    tileset = (s1[0] if s1 else 0, _w(b, p))
    p += 2
    s2, p = _cstr(b, p)
    tilemap_file = s2[0] if s2 else 0
    q = p
    tilemap = (tilemap_file, _w(b, q))
    music, _ = _cstr(b, _w(b, q + 2))
    script, _ = _cstr(b, _w(b, q + 4))
    text, _ = _cstr(b, _w(b, q + 6))
    paths = bytearray()
    r = q + 8
    if _w(b, r) != 0:
        while not (b[r] == 0xFF and b[r + 1] == 0xFF):
            paths.append(b[r])
            r += 1
    return {
        "offset": off,
        "map_id": map_id,
        "unknown": unk,
        "objects": objects,
        "tileset": list(tileset),
        "tilemap": list(tilemap),
        "music": music.decode("ascii").replace("\\", "/"),
        "script": script.decode("ascii"),
        "text": text.decode("ascii"),
        "paths": list(paths),
    }


def parse_mapa(raw):
    b = _body(raw)
    table = _table(b)
    entries, scenes = [], {}
    for i, off in enumerate(table):
        ref = 2 + 2 * i
        if off + 28 > len(b) or off < 2 + 2 * len(table):
            entries.append(None)
            continue
        view, _, _, x, y, facing = struct.unpack_from("<6H", b, off)
        name = b[off + 12:off + 26]
        scene_off = _w(b, off + 26)
        try:
            if scene_off not in scenes:
                scenes[scene_off] = parse_scene(b, scene_off)
        except (ValueError, struct.error, IndexError):
            entries.append(None)
            continue
        hidden = name.startswith(b"$$")
        entries.append({
            "ref": ref,
            "view": view,
            "x": x,
            "y": y,
            "facing": facing,
            "name": name.replace(b"$$", b"").decode("big5", "replace").replace("　", "").strip("\0 "),
            "name_hidden": hidden,
            "scene": scene_off,
        })
    return {"entries": entries, "scenes": scenes}


def parse_zones(raw):
    """MAP0.EXE: per map id, 8-byte zones (u16 a, u16 top-left cell offset,
    u16 bottom-right cell offset, u16 action) until 0xF000.

    action & 0x4000: run the event of object (action & 0xFF) / 2
    otherwise: warp to entry (action & 0xFFF); 0x8000/0x1000 keep the view,
    0x2000 also sets a flag byte from a's high byte.
    """
    b = _body(raw)
    table = _table(b)
    zones = {}
    for i, off in enumerate(table):
        ref = 2 + 2 * i
        lst = []
        p = off
        while p + 2 <= len(b) and _w(b, p) != 0xF000:
            if p + 8 > len(b):
                break
            lst.append(list(struct.unpack_from("<4H", b, p)))
            p += 8
        zones[ref] = lst
    return zones
