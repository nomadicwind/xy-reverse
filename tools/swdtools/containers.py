"""Offset-table containers used throughout the game data."""
import struct


def lsk_entries(data):
    """*.LSK: u32 offset table, offs[0] is the table size, last offset is EOF."""
    n = struct.unpack_from("<I", data, 0)[0] // 4
    offs = struct.unpack_from("<%dI" % n, data, 0)
    return [data[a:b] for a, b in zip(offs, offs[1:])]


def offsets16(data):
    """The u16 offset table of a split_offsets16 container, in table order."""
    offs = []
    lowest = len(data)
    while 2 * len(offs) < lowest and 2 * len(offs) + 2 <= len(data):
        o = struct.unpack_from("<H", data, 2 * len(offs))[0]
        offs.append(o)
        if o >= 2 * len(offs):
            lowest = min(lowest, o)
    return offs


def split_offsets16(data):
    """Same layout with u16 offsets; used inside decompressed blocks.

    The table is not always sorted (MENU.RSK), so it ends at the smallest
    offset and each entry runs to the next larger offset."""
    offs = offsets16(data)
    ends = sorted(set(o for o in offs if o <= len(data)) | {len(data)})
    out = []
    for a in offs:
        if a > len(data):
            out.append(b"")
            continue
        out.append(data[a:ends[ends.index(a) + 1]] if a < len(data) else b"")
    return out


def is_compressed_block(data):
    """True for a u16 size + method block. Method 0 (stored) must match the size
    exactly, because raw entries (for example the palette DO.LSK #51) can have a
    zero third byte by chance."""
    if len(data) < 4:
        return False
    if data[2] == 1:
        return True
    return data[2] == 0 and len(data) == struct.unpack_from("<H", data, 0)[0] + 3
