"""MAP.LSK: a stream of records, decoded in order.

palette  decompresses to 1842 bytes: u16, 768 bytes 6-bit RGB, 1072 bytes not yet decoded
planes   four entries, plane k of a Mode X tile sheet, 16 bytes per 8x8 tile
         (8 rows x 2 bytes). A 2-byte entry b"A" + n means "reuse the current sheet".
tilemap  u16 container; chunk 0 = u16 h, u16 w, h*w u16 cells (low 11 bits tile
         index, high 5 bits flags, meaning not confirmed yet). Extra chunks are
         kept raw (probably extra layers or overlays).
objects  the entry right after a tilemap (u16 records, not decoded yet)

Usually palette, 4 planes, tilemap, objects (7 entries), but a sheet can be
shared by several tilemap/objects pairs.
"""
import struct
from .containers import is_compressed_block, split_offsets16
from .lzh import decompress
from .pic import vga_palette

TILE = 8


def _tilemap(data):
    try:
        parts = split_offsets16(data)
    except struct.error:
        return None
    if not parts or len(parts[0]) < 4:
        return None
    h, w = struct.unpack_from("<HH", parts[0], 0)
    if w == 0 or h == 0 or len(parts[0]) != 4 + w * h * 2:
        return None
    return h, w, parts


def _tiles_from_planes(planes):
    n = len(planes[0]) // 16
    return [bytes(planes[x % 4][t * 16 + y * 2 + x // 4] for y in range(TILE) for x in range(TILE))
            for t in range(n)]


def parse_maps(entries):
    """Return a list of map dicts in file order."""
    out = []
    palette = pal_extra = tiles = None
    planes = []
    pending = None
    for idx, e in enumerate(entries):
        if len(e) == 2 and e[0] == 0x41:
            continue  # reuse current tile sheet
        data = decompress(e) if is_compressed_block(e) else bytes(e)
        if pending is not None:
            pending["objects_raw"] = data
            out.append(pending)
            pending = None
            continue
        if len(data) == 1842:
            palette, pal_extra = vga_palette(data[2:770]), data[770:]
            planes = []
            continue
        tm = _tilemap(data)
        if tm is not None and palette is not None:
            if len(planes) == 4:
                tiles = _tiles_from_planes(planes)
                planes = []
            h, w, parts = tm
            cells = struct.unpack_from("<%dH" % (h * w), parts[0], 4)
            pending = {
                "entry": idx,
                "palette": palette,
                "palette_extra": pal_extra,
                "tiles": tiles,
                "width": w,
                "height": h,
                "cells": [c & 0x7FF for c in cells],
                "flags": [c >> 11 for c in cells],
                "extra_layers": parts[1:],
            }
            continue
        planes.append(data)
    if pending is not None:
        pending["objects_raw"] = b""
        out.append(pending)
    return out


def tileset_image(m, columns=64):
    from PIL import Image
    n = len(m["tiles"])
    rows = (n + columns - 1) // columns
    pal = [c for rgb in m["palette"] for c in rgb]
    im = Image.new("P", (columns * TILE, rows * TILE))
    im.putpalette(pal)
    for t, px in enumerate(m["tiles"]):
        im.paste(Image.frombytes("P", (TILE, TILE), px), ((t % columns) * TILE, (t // columns) * TILE))
    return im.convert("RGB")


def render_map(m):
    from PIL import Image
    pal = [c for rgb in m["palette"] for c in rgb]
    im = Image.new("P", (m["width"] * TILE, m["height"] * TILE))
    im.putpalette(pal)
    tiles = [Image.frombytes("P", (TILE, TILE), px) for px in m["tiles"]]
    for i, t in enumerate(m["cells"]):
        if t < len(tiles):
            im.paste(tiles[t], ((i % m["width"]) * TILE, (i // m["width"]) * TILE))
    return im.convert("RGB")
