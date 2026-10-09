"""Export everything the Godot engine port reads at runtime.

Images are written as 8-bit grayscale PNGs whose values are palette indices,
so the game can apply the original palettes (and palette fades) in a shader.
Palettes are 256x1 RGBA PNGs.

Output layout (under <out>/engine):
    mapa.json             entry points and scenes (scenes.parse_mapa)
    zones.json            trigger zones by map id (scenes.parse_zones)
    scripts/CHNAn.json    decoded story scripts (script.decode_file)
    lsk/<PACK>/<n>.pal.png    palette entry n
    lsk/<PACK>/<n>.tiles.png  8x8 tile sheet that belongs to palette n (64 columns)
    lsk/<PACK>/<n>.map.json   tilemap entry n: chunks (w, h, raw u16 cells) and
                              the foreground tile list from entry n+1 (MAP.LSK)
    lsk/<PACK>/<n>.png/.json  picture atlas of entry n (frames in file order)
    font.png, font.json   the game's own 16x15 Big5 glyphs, merged from all *.DSK
"""
import json
import struct
from pathlib import Path

from . import battle, scenes, script
from .containers import is_compressed_block, lsk_entries, offsets16, split_offsets16
from .lzh import decompress
from .pic import decode_pic

PACKS = ("SA", "MAP", "CD", "DO")
PACK_IDS = {0: "SA", 2: "MAP", 4: "CD", 6: "DO"}


def _find(game, name):
    for p in Path(game).rglob("*"):
        if p.name.upper() == name.upper():
            return p
    raise FileNotFoundError(name)


def _png_l8(path, w, h, px):
    from PIL import Image
    Image.frombytes("L", (w, h), bytes(px)).save(path, optimize=True)


def _palette_png(path, data):
    from PIL import Image
    rgb = data[2:770]
    im = Image.new("RGBA", (256, 1))
    im.putdata([(rgb[i * 3] * 255 // 63, rgb[i * 3 + 1] * 255 // 63, rgb[i * 3 + 2] * 255 // 63, 255)
                for i in range(256)])
    im.save(path)


def _tilemap(data):
    try:
        parts = split_offsets16(data)
    except struct.error:
        return None
    if not parts:
        return None
    chunks = []
    for p, off in zip(parts, offsets16(data)):
        if len(p) < 4:
            continue
        h, w = struct.unpack_from("<HH", p, 0)
        if w == 0 or h == 0 or len(p) < 4 + w * h * 2:
            return None if not chunks else chunks
        # "base": byte offset of the first cell inside the entry, which is
        # what object, zone and view offsets in the scenes count from
        chunks.append({"w": w, "h": h, "base": off + 4,
                       "cells": list(struct.unpack_from("<%dH" % (w * h), p, 4))})
    return chunks or None


def _looks_like_pic(chunk):
    if len(chunk) < 6:
        return False
    h, w = struct.unpack_from("<HH", chunk, 0)
    if not (0 < w <= 640 and 0 < h <= 480):
        return False
    return chunk[4:6] == b"NT" or len(chunk) - 4 == w * h


def _atlas(frames, max_w=512):
    """Shelf-pack frames (w, h, px) into one image. Returns (W, H, px, rects)."""
    x = y = shelf = 0
    rects = []
    for w, h, _ in frames:
        if x + w > max_w and x > 0:
            x, y, shelf = 0, y + shelf, 0
        rects.append((x, y, w, h))
        x += w
        shelf = max(shelf, h)
    W = max([r[0] + r[2] for r in rects] + [1])
    H = max([r[1] + r[3] for r in rects] + [1])
    out = bytearray([0xFE]) * (W * H)
    for (rx, ry, w, h), (_, _, px) in zip(rects, frames):
        for row in range(h):
            out[(ry + row) * W + rx:(ry + row) * W + rx + w] = px[row * w:(row + 1) * w]
    return W, H, out, rects


def _tiles_png(path, planes):
    n = min(len(p) for p in planes) // 16
    cols = 64
    rows = max(1, (n + cols - 1) // cols)
    W, H = cols * 8, rows * 8
    out = bytearray(W * H)
    for t in range(n):
        ox, oy = (t % cols) * 8, (t // cols) * 8
        for y in range(8):
            for x in range(8):
                out[(oy + y) * W + ox + x] = planes[x % 4][t * 16 + y * 2 + x // 4]
    _png_l8(path, W, H, out)
    return n


def export_pack(game, out, pack):
    d = out / "lsk" / pack
    d.mkdir(parents=True, exist_ok=True)
    entries = lsk_entries(_find(game, pack + ".LSK").read_bytes())
    data = []
    for e in entries:
        if len(e) == 2 and e[0] == 0x41:
            data.append(None)  # "keep the tiles already loaded"
        elif is_compressed_block(e):
            data.append(decompress(e))
        else:
            data.append(bytes(e))
    index = {}
    last_planes = None
    for i, x in enumerate(data):
        if x is None:
            continue
        if len(x) == 1842:
            _palette_png(d / ("%d.pal.png" % i), x)
            kind = {"type": "palette"}
            planes = data[i + 1:i + 5]
            if len(planes) == 4 and all(p is None for p in planes) and last_planes:
                planes = last_planes
            if len(planes) == 4 and all(p is not None and len(p) % 16 == 0 and len(p) > 0 for p in planes) \
                    and len({len(p) for p in planes}) == 1:
                kind["tiles"] = _tiles_png(d / ("%d.tiles.png" % i), planes)
                last_planes = planes
            index[i] = kind
            continue
        chunks = _tilemap(x)
        if chunks:
            m = {"chunks": chunks}
            nxt = data[i + 1] if i + 1 < len(data) else None
            if pack == "MAP" and nxt and len(nxt) % 2 == 0:
                ws = struct.unpack_from("<%dH" % (len(nxt) // 2), nxt)
                if 0xFFFF in ws and ws.index(0xFFFF) % 3 == 0:
                    k = ws.index(0xFFFF)
                    m["fg"] = [list(ws[j:j + 3]) for j in range(0, k, 3)]
            (d / ("%d.map.json" % i)).write_text(json.dumps(m, separators=(",", ":")))
            index[i] = {"type": "tilemap", "chunks": [[c["w"], c["h"]] for c in chunks]}
            continue
        try:
            parts = split_offsets16(x)
        except struct.error:
            parts = []
        frames = []
        for k, c in enumerate(parts):
            if _looks_like_pic(c):
                try:
                    frames.append(decode_pic(c))
                except (struct.error, IndexError):
                    frames.append((1, 1, b"\xfe"))
            else:
                frames.append((1, 1, b"\xfe"))
        if frames and any(f[0] > 1 for f in frames):
            W, H, px, rects = _atlas(frames)
            _png_l8(d / ("%d.png" % i), W, H, px)
            (d / ("%d.json" % i)).write_text(json.dumps({"frames": rects}))
            index[i] = {"type": "pictures", "count": len(frames)}
    (d / "index.json").write_text(json.dumps(index, separators=(",", ":")))
    return len(index)


def export_font(game, out):
    """Merge glyphs from every *.DSK: u16 n, n Big5 codes, n glyphs of 30 bytes
    (15 rows of 16 pixels)."""
    from PIL import Image
    glyphs = {}
    for f in sorted(Path(game).glob("*.DSK")):
        b = f.read_bytes()
        n = struct.unpack_from("<H", b, 0)[0]
        if 2 + n * 32 != len(b):
            continue
        for k in range(n):
            code = b[2 + 2 * k:4 + 2 * k]
            g = b[2 + 2 * n + 30 * k:2 + 2 * n + 30 * (k + 1)]
            try:
                ch = code.decode("big5")
            except UnicodeDecodeError:
                continue
            glyphs.setdefault(ch, g)
    chars = sorted(glyphs)
    cols = 64
    rows = (len(chars) + cols - 1) // cols
    im = Image.new("L", (cols * 16, rows * 16), 0)
    px = im.load()
    for idx, ch in enumerate(chars):
        g = glyphs[ch]
        ox, oy = (idx % cols) * 16, (idx // cols) * 16
        for y in range(15):
            bits = (g[2 * y] << 8) | g[2 * y + 1]
            for x in range(16):
                if bits & (0x8000 >> x):
                    px[ox + x, oy + y] = 255
    # white glyphs with the bitmap as alpha, so the game can tint them
    im = Image.merge("LA", (Image.new("L", im.size, 255), im))
    im.save(out / "font.png", optimize=True)
    (out / "font.json").write_text(json.dumps({"cell": 16, "columns": cols, "chars": "".join(chars)},
                                              ensure_ascii=False))
    export_names(game, out, glyphs)
    return len(chars)


def export_names(game, out, glyphs):
    """SAVE/NAME.DAQ is a 16-glyph font in the DSK layout. Scripts write the
    four player characters' names as the codes ㄅㄆㄇㄈ ㄉㄊㄋㄌ ㄍㄎㄏㄐ ㄑㄒㄔㄕ
    and RPG.EXE draws whatever glyphs the naming screen put there; names are
    right-aligned, blank glyphs pad the left. Match the default glyphs back to
    characters so the remake can keep names as text."""
    f = Path(game) / "SAVE" / "NAME.DAQ"
    if not f.exists():
        return
    b = f.read_bytes()
    n = struct.unpack_from("<H", b, 0)[0]
    by_bits = {g: ch for ch, g in glyphs.items()}
    slots = []
    for k in range(n):
        g = b[2 + 2 * n + 30 * k:2 + 2 * n + 30 * (k + 1)]
        slots.append("" if not any(g) else by_bits.get(g, "?"))
    names = ["".join(slots[i:i + 4]) for i in range(0, len(slots), 4)]
    meta = {"names": names}
    meta.update(_naming_screen(game))
    (out / "names.json").write_text(json.dumps(meta, ensure_ascii=False))


def _naming_screen(game):
    """Texts of the naming screen (RPG.EXE 0x1820) from the data segment:
    the prompt at DS:2598, the slot labels at DS:25C6 and three pages of
    9 x 11 characters at DS:25FE (rows end with ##, pages are 0xD8 bytes)."""
    rpg = _find(game, "RPG.EXE").read_bytes()
    ds = struct.unpack_from("<H", rpg, 8)[0] * 16 + 0xF290

    def text(off):
        end = rpg.index(b"$$", ds + off)
        return rpg[ds + off:end].decode("big5", "replace")

    pages = []
    for p in range(3):
        rows = []
        for r in range(9):
            a = ds + 0x25FE + p * 0xD8 + r * 24
            rows.append(rpg[a:a + 22].decode("big5", "replace"))
        pages.append(rows)
    return {"prompt": text(0x2598), "slots": text(0x25C6), "grid": pages}


def export_rsk(game, out, name):
    """A picture list in an RSK file (MENU.RSK holds the dialogue box frame,
    menu cursors and icons), as an L8 atlas plus frame rects."""
    f = Path(game) / name
    if not f.exists():
        return 0
    frames = []
    d = out / "rsk"
    d.mkdir(parents=True, exist_ok=True)
    for c in split_offsets16(decompress(f.read_bytes())):
        if len(c) == 771:  # a palette part (3-byte header), as in DOR4.RSK
            _palette_png(d / (f.stem + ".pal.png"), b"\0\0" + c[3:771])
        try:
            frames.append(decode_pic(c) if _looks_like_pic(c) else (1, 1, b"\xfe"))
        except (struct.error, IndexError):
            frames.append((1, 1, b"\xfe"))
    W, H, px, rects = _atlas(frames)
    _png_l8(d / (f.stem + ".png"), W, H, px)
    (d / (f.stem + ".json")).write_text(json.dumps({"frames": rects}))
    return len(frames)


def export_battle(game, out):
    """battle.json (FIG/ORC/ITEM tables, see swdtools/battle.py) and the
    battle backgrounds BA/BAnn.RSK = [picture 320x200, palette]."""
    data = battle.dump(str(game))
    (out / "battle.json").write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")))
    d = out / "ba"
    d.mkdir(parents=True, exist_ok=True)
    n = 0
    for f in sorted(Path(game).glob("BA/BA*.RSK")):
        parts = split_offsets16(decompress(f.read_bytes()))
        w, h, px = decode_pic(parts[0])
        _png_l8(d / (f.stem.upper() + ".png"), w, h, px)
        _palette_png(d / (f.stem.upper() + ".pal.png"), b"\0\0" + parts[1][3:771])
        n += 1
    return {"groups": len(data["groups"]), "backgrounds": n}


def export_scripts(game, out):
    d = out / "scripts"
    d.mkdir(parents=True, exist_ok=True)
    n = 0
    for f in sorted(Path(game).glob("CHNA*.EXE")):
        r = script.decode_file(f.read_bytes())
        events = {str(k): v["ops"] for k, v in r["events"].items()}
        (d / (f.stem.upper() + ".json")).write_text(
            json.dumps({"events": events, "errors": {str(k): v for k, v in r["errors"].items()}},
                       ensure_ascii=False, separators=(",", ":")))
        n += 1
    return n


def export_engine(game, out):
    out = Path(out) / "engine"
    out.mkdir(parents=True, exist_ok=True)
    summary = {}
    mapa = scenes.parse_mapa(_find(game, "MAPA.EXE").read_bytes())
    mapa["scenes"] = {str(k): v for k, v in mapa["scenes"].items()}
    (out / "mapa.json").write_text(json.dumps(mapa, ensure_ascii=False, separators=(",", ":")))
    zones = scenes.parse_zones(_find(game, "MAP0.EXE").read_bytes())
    (out / "zones.json").write_text(json.dumps({str(k): v for k, v in zones.items()}, separators=(",", ":")))
    summary["scenes"] = len(mapa["scenes"])
    summary["scripts"] = export_scripts(game, out)
    for pack in PACKS:
        summary[pack] = export_pack(game, out, pack)
    summary["glyphs"] = export_font(game, out)
    summary["menu"] = export_rsk(game, out, "MENU.RSK")
    # the dragon cart cut-scene of op 0x50 (RPG 0x6AB9)
    summary["dor"] = [export_rsk(game, out, "DOR%d.RSK" % n) for n in range(1, 5)]
    summary["battle"] = export_battle(game, out)
    # RPG.EXE's initialised data segment is the new-game state (party, money,
    # flags). DS = 0xF29, so it starts at image offset 0xF290.
    rpg = _find(game, "RPG.EXE").read_bytes()
    hdr = struct.unpack_from("<H", rpg, 8)[0] * 16
    (out / "rpg_ds.bin").write_bytes(rpg[hdr + 0xF290:hdr + 0xF290 + 0x8000])
    summary["places"] = export_places(rpg[hdr + 0xF290:hdr + 0xF290 + 0x8000], out)
    return summary


def export_places(ds, out):
    """乘龍念法 destinations: 16 names of 4 glyphs at DS:3333 (RPG 0x382C).
    Their entry points are the words at DS:3313, read from the state block."""
    names = [ds[0x3333 + 8 * i:0x333B + 8 * i].decode("big5", "replace").strip("\u3000 ") for i in range(16)]
    (out / "places.json").write_text(json.dumps({"places": names}, ensure_ascii=False))
    return len(names)
