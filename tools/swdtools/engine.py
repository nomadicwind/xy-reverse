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

from . import scenes, script
from .containers import is_compressed_block, lsk_entries, split_offsets16
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
    for p in parts:
        if len(p) < 4:
            continue
        h, w = struct.unpack_from("<HH", p, 0)
        if w == 0 or h == 0 or len(p) < 4 + w * h * 2:
            return None if not chunks else chunks
        chunks.append({"w": w, "h": h, "cells": list(struct.unpack_from("<%dH" % (w * h), p, 4))})
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
    return len(chars)


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
    # RPG.EXE's initialised data segment is the new-game state (party, money,
    # flags). DS = 0xF29, so it starts at image offset 0xF290.
    rpg = _find(game, "RPG.EXE").read_bytes()
    hdr = struct.unpack_from("<H", rpg, 8)[0] * 16
    (out / "rpg_ds.bin").write_bytes(rpg[hdr + 0xF290:hdr + 0xF290 + 0x8000])
    return summary
