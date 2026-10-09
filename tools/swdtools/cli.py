"""Command-line extractor.

    python3 -m swdtools extract --game <dir with SWDA.EXE> --out <dir>
"""
import argparse
import json
import os
import shutil
import struct
import sys
from pathlib import Path

from . import audio, maps
from .containers import is_compressed_block, lsk_entries, split_offsets16
from .lzh import decompress
from .pic import decode_pic, to_rgba, vga_palette


def _find(game, name):
    for p in Path(game).rglob("*"):
        if p.name.upper() == name.upper():
            return p
    raise FileNotFoundError(name)


def _looks_like_pic(chunk):
    if len(chunk) < 6:
        return False
    h, w = struct.unpack_from("<HH", chunk, 0)
    if not (0 < w <= 640 and 0 < h <= 480):
        return False
    return chunk[4:6] == b"NT" or len(chunk) - 4 == w * h


def extract_maps(game, out, only=None, previews=False):
    entries = lsk_entries(_find(game, "MAP.LSK").read_bytes())
    index = []
    for i, m in enumerate(maps.parse_maps(entries)):
        if only is not None and i not in only:
            continue
        d = out / "maps" / ("map_%03d" % i)
        d.mkdir(parents=True, exist_ok=True)
        cols = 64
        maps.tileset_image(m, cols).save(d / "tileset.png")
        meta = {
            "id": i,
            "source_entry": m["entry"],
            "width": m["width"],
            "height": m["height"],
            "tile_size": maps.TILE,
            "tileset_columns": cols,
            "tile_count": len(m["tiles"]),
            "cells": m["cells"],
            "flags": m["flags"],
        }
        (d / "map.json").write_text(json.dumps(meta, separators=(",", ":")))
        (d / "objects.bin").write_bytes(m["objects_raw"])
        for k, layer in enumerate(m["extra_layers"]):
            (d / ("layer%d.bin" % (k + 1))).write_bytes(layer)
        if previews:
            maps.render_map(m).save(d / "preview.png")
        index.append({"id": i, "width": m["width"], "height": m["height"]})
        print("map %03d  %dx%d  %d tiles" % (i, m["width"], m["height"], len(m["tiles"])))
    (out / "maps" / "index.json").write_text(json.dumps(index, indent=1))
    return len(index)


def battle_palette(game, name="BA01.RSK"):
    parts = split_offsets16(decompress(_find(game, name).read_bytes()))
    return vga_palette(parts[1][3:])


def extract_battle(game, out):
    d = out / "battle"
    d.mkdir(parents=True, exist_ok=True)
    n = 0
    for f in sorted(Path(game).rglob("BA*.RSK")):
        parts = split_offsets16(decompress(f.read_bytes()))
        pal = vga_palette(parts[1][3:])
        w, h, px = decode_pic(parts[0])
        to_rgba(w, h, px, pal, transparent=None).save(d / (f.stem + ".png"))
        n += 1
    return n


def extract_sprites(game, out, packs=("DO", "CD")):
    # Character sprites share the battle palette range; BA01 is used until the
    # per-scene palette selection is reversed.
    pal = battle_palette(game)
    total = 0
    for pack in packs:
        d = out / "sprites" / pack
        d.mkdir(parents=True, exist_ok=True)
        for i, e in enumerate(lsk_entries(_find(game, pack + ".LSK").read_bytes())):
            if not is_compressed_block(e):
                continue
            data = decompress(e)
            try:
                parts = split_offsets16(data)
            except struct.error:
                continue
            for k, chunk in enumerate(parts):
                if _looks_like_pic(chunk):
                    w, h, px = decode_pic(chunk)
                    to_rgba(w, h, px, pal).save(d / ("%04d_%02d.png" % (i, k)))
                    total += 1
    return total


def extract_text(game, out):
    d = out / "text"
    d.mkdir(parents=True, exist_ok=True)
    n = 0
    for f in sorted(Path(game).glob("*.DSK")):
        (d / (f.stem + ".txt")).write_text(f.read_bytes().decode("big5", errors="replace"), encoding="utf-8")
        n += 1
    return n


def extract_audio(game, out):
    sfx = out / "sfx"
    music = out / "music"
    sfx.mkdir(parents=True, exist_ok=True)
    music.mkdir(parents=True, exist_ok=True)
    n = 0
    for f in sorted(Path(game).rglob("*.VOC")):
        audio.voc_to_wav(f.read_bytes(), sfx / (f.stem + ".wav"))
        n += 1
    for f in sorted(Path(game).rglob("*.RIX")):
        shutil.copyfile(f, music / f.name)
    return n


def main(argv=None):
    ap = argparse.ArgumentParser(prog="swdtools")
    sub = ap.add_subparsers(dest="cmd", required=True)
    ex = sub.add_parser("extract", help="convert original data into open formats")
    ex.add_argument("--game", required=True, help="directory containing SWDA.EXE")
    ex.add_argument("--out", required=True)
    ex.add_argument("--maps", help="comma separated map ids (default: all)")
    ex.add_argument("--only", help="comma separated: maps,battle,sprites,text,audio")
    ex.add_argument("--previews", action="store_true", help="also render full map PNGs")
    a = ap.parse_args(argv)

    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    what = set((a.only or "maps,battle,sprites,text,audio").split(","))
    only = {int(x) for x in a.maps.split(",")} if a.maps else None
    summary = {}
    if "maps" in what:
        summary["maps"] = extract_maps(a.game, out, only, a.previews)
    if "battle" in what:
        summary["battle"] = extract_battle(a.game, out)
    if "sprites" in what:
        summary["sprites"] = extract_sprites(a.game, out)
    if "text" in what:
        summary["text"] = extract_text(a.game, out)
    if "audio" in what:
        summary["sfx"] = extract_audio(a.game, out)
    (out / "manifest.json").write_text(json.dumps(summary, indent=1))
    print(json.dumps(summary))


if __name__ == "__main__":
    sys.exit(main())
