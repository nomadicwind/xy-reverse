import os
import struct
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from swdtools.containers import is_compressed_block, lsk_entries, split_offsets16  # noqa: E402
from swdtools.lzh import decompress  # noqa: E402
from swdtools.pic import decode_pic  # noqa: E402

GAME = os.environ.get("SWDA_GAME")


def test_stored_block():
    assert decompress(struct.pack("<HB", 3, 0) + b"abc") == b"abc"


def test_lsk_entries():
    data = struct.pack("<3I", 12, 14, 17) + b"ab" + b"cde"
    assert lsk_entries(data) == [b"ab", b"cde"]


def test_split_offsets16():
    data = struct.pack("<2H", 4, 6) + b"xy" + b"z"
    assert split_offsets16(data) == [b"xy", b"z"]


def test_pic_raw():
    w, h, px = decode_pic(struct.pack("<HH", 2, 4) + bytes(range(8)))
    assert (w, h, px) == (4, 2, bytes(range(8)))


def test_pic_rle_planar():
    # 4x1 image: each plane row holds one pixel; plane p gets colour 10+p.
    body = b"".join(bytes([1, 10 + p, 0xFF]) for p in range(4))
    w, h, px = decode_pic(struct.pack("<HH", 1, 4) + b"NT" + body)
    assert (w, h, px) == (4, 1, bytes([10, 11, 12, 13]))


@pytest.mark.skipif(not GAME, reason="set SWDA_GAME to the folder holding SWDA.EXE")
def test_every_block_decompresses_to_declared_size():
    for pack in ("MAP", "SA", "DO", "CD"):
        for e in lsk_entries((Path(GAME) / (pack + ".LSK")).read_bytes()):
            if is_compressed_block(e):
                assert len(decompress(e)) == struct.unpack_from("<H", e, 0)[0]


@pytest.mark.skipif(not GAME, reason="set SWDA_GAME to the folder holding SWDA.EXE")
def test_map_count():
    from swdtools.maps import parse_maps
    maps = parse_maps(lsk_entries((Path(GAME) / "MAP.LSK").read_bytes()))
    assert len(maps) == 116
    assert (maps[0]["width"], maps[0]["height"]) == (120, 120)
