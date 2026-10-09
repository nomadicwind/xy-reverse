"""Disassembler for the CHNA*.EXE story scripts.

A CHNA file is an overlay with a 512-byte header. The body starts with
u16 length, then a u16 table of event offsets (the first entry also marks the
end of the table). Jump targets inside scripts are byte offsets into that
table, so an event is addressed by ``table_offset`` (2, 4, 6, ...).

Each event is a stream of u16 opcodes with u16 arguments, ended by 0x4040
("@@"). Opcode handlers live in RPG.EXE at DS:0x6449 (82 entries). Texts are
Big5, read byte-wise (a 0x20 byte is a half-width space), and end at "$$".
Inside a text "##" is a line break, "%%" waits for a key and "&&" scrolls;
colour codes are written as "{C<index>}" (text) and "{M<index>}" (shadow).
"""
import struct

END = 0x4040

# name, argument spec. Spec letters:
#   w  one u16 word
#   e  a u16 event reference (table offset)
#   T  a text that ends at "$$"
#   L  u16 n followed by n u16 words
#   F  u16 event, u16 n, n flag words
#   M  menu: u16 n, n texts, n events
#   P  object patch list, ends at 0xF800
#   S  op 0x3E: u16 mode, (x, y if mode is 3 or 5), text
OPS = {
    0x00: ("say", "T"),
    0x01: ("obj_reset", ""),
    0x02: ("obj_set_event", "e"),
    0x03: ("map_patch", "ww"),
    0x04: ("if_flag", "we"),
    0x05: ("op05", ""),
    0x06: ("fade_out", ""),
    0x07: ("fade_in", ""),
    0x08: ("wait", "w"),
    0x09: ("set_flag", "ww"),
    0x0A: ("add_stat_capped", "ww"),
    0x0B: ("add_stat", "ww"),
    0x0C: ("heal_party", ""),
    0x0D: ("if_yes", "e"),
    0x0E: ("show_money", ""),
    0x0F: ("if_pay", "we"),
    0x10: ("load_map", "wwwwww"),
    0x11: ("shop_buy_sell", "L"),
    0x12: ("say_keep", "T"),
    0x13: ("shop_buy", "L"),
    0x14: ("say_auto", "T"),
    0x15: ("if_member", "we"),
    0x16: ("redraw", ""),
    0x17: ("obj_up", "w"),
    0x18: ("obj_down", "w"),
    0x19: ("obj_left", "w"),
    0x1A: ("obj_right", "w"),
    0x1B: ("obj_state", "ww"),
    0x1C: ("battle", "w"),
    0x1D: ("load_palette_tiles", "ww"),
    0x1E: ("party_up", "w"),
    0x1F: ("party_down", "w"),
    0x20: ("party_left", "w"),
    0x21: ("party_right", "w"),
    0x22: ("obj_patch", "P"),
    0x23: ("load_tilemap", "ww"),
    0x24: ("play_frames", "w"),
    0x25: ("warp", "w"),
    0x26: ("music", "w"),
    0x27: ("obj_dir", "ww"),
    0x28: ("item", "wew"),
    0x29: ("add_money", "w"),
    0x2A: ("op2a", "w"),
    0x2B: ("op2b", "ww"),
    0x2C: ("op2c", "w"),
    0x2D: ("fade_in", ""),
    0x2E: ("say_top", "T"),
    0x2F: ("party_size", "w"),
    0x30: ("battle_then", "ww"),
    0x31: ("shake", "w"),
    0x32: ("swap_member", "wwww"),
    0x33: ("op33", "w"),
    0x34: ("restart", ""),
    0x35: ("print_at", "wwT"),
    0x36: ("add_item", "ww"),
    0x37: ("op37", ""),
    0x38: ("op38", ""),
    0x39: ("sfx", "w"),
    0x3A: ("boss_battle", "w"),
    0x3B: ("boss_battle_then", "ww"),
    0x3C: ("battle_then2", "ww"),
    0x3D: ("op3d", ""),
    0x3E: ("narrate", "S"),
    0x3F: ("if_all_flags", "F"),
    0x40: ("if_any_flag", "F"),
    0x41: ("menu", "M"),
    0x42: ("op42", ""),
    0x43: ("op43", ""),
    0x44: ("text_at", "wwT"),
    0x45: ("op45", ""),
    0x46: ("picture", "wwww"),
    0x47: ("op47", "ww"),
    0x48: ("op48", "www"),
    0x49: ("op49", "w"),
    0x4A: ("shift_view", "ww"),
    0x4B: ("text_at_auto", "wwT"),
    0x4C: ("op4c", ""),
    0x4D: ("obj_frame", "ww"),
    0x4E: ("remove_item", "ww"),
    0x4F: ("op4f", ""),
    0x50: ("op50", ""),
    0x51: ("op51", "w"),
}


class ScriptError(ValueError):
    pass


def body(raw):
    """Strip the 512-byte overlay header."""
    return raw[512:]


def event_table(b):
    """Event offsets. The table runs from byte 2 up to the lowest offset in it."""
    table, p, lowest = [], 2, len(b)
    while p < lowest:
        v = struct.unpack_from("<H", b, p)[0]
        table.append(v)
        if v:
            lowest = min(lowest, v)
        p += 2
    return table


def _text(b, p):
    """Text up to "$$". Colour codes (a 'C' or 'M' byte and a palette index,
    read like one double-byte character by the game) become "{C16}" / "{M26}"."""
    out = []
    while True:
        if p >= len(b):
            raise ScriptError("text runs off the end")
        c = b[p]
        if c == 0x20:
            out.append(" ")
            p += 1
            continue
        pair = b[p:p + 2]
        p += 2
        if pair == b"$$":
            return "".join(out), p
        if pair[0] in (0x43, 0x4D):
            out.append("{%s%d}" % (chr(pair[0]), pair[1]))
        elif pair[0] < 0x80:
            out.append(pair.decode("latin-1"))
        else:
            out.append(pair.decode("big5", "replace"))


def _w(b, p):
    if p + 2 > len(b):
        raise ScriptError("word runs off the end")
    return struct.unpack_from("<H", b, p)[0], p + 2


def decode_op(b, p):
    """Decode the op at byte offset p. Returns (op dict, next offset)."""
    start = p
    op, p = _w(b, p)
    if op not in OPS:
        raise ScriptError("unknown opcode %#x at %#x" % (op, start))
    name, spec = OPS[op]
    args = []
    for k in spec:
        if k in "we":
            v, p = _w(b, p)
            args.append(v)
        elif k == "T":
            t, p = _text(b, p)
            args.append(t)
        elif k == "L":
            n, p = _w(b, p)
            lst = []
            for _ in range(n):
                v, p = _w(b, p)
                lst.append(v)
            args.append(lst)
        elif k == "F":
            ev, p = _w(b, p)
            n, p = _w(b, p)
            lst = []
            for _ in range(n):
                v, p = _w(b, p)
                lst.append(v)
            args += [ev, lst]
        elif k == "M":
            n, p = _w(b, p)
            texts, evs = [], []
            for _ in range(n):
                t, p = _text(b, p)
                texts.append(t)
            for _ in range(n):
                v, p = _w(b, p)
                evs.append(v)
            args += [texts, evs]
        elif k == "P":
            lst = []
            while True:
                o, p = _w(b, p)
                if o == 0xF800:
                    break
                a, p = _w(b, p)
                c, p = _w(b, p)
                v, p = _w(b, p)
                add = v == 0x4144
                if add:
                    v, p = _w(b, p)
                lst.append([o, a, c, v, add])
            args.append(lst)
        elif k == "S":
            mode, p = _w(b, p)
            args.append(mode)
            if mode in (3, 5):
                x, p = _w(b, p)
                y, p = _w(b, p)
                args += [x, y]
            t, p = _text(b, p)
            args.append(t)
    return {"at": start, "op": op, "name": name, "args": args}, p


def decode_event(b, p, limit=4000):
    """Decode one event starting at byte offset p. Returns a list of ops."""
    ops = []
    for _ in range(limit):
        if _w(b, p)[0] == END:
            return ops
        o, p = decode_op(b, p)
        ops.append(o)
    raise ScriptError("event at %#x has no end" % p)


def decode_file(raw):
    b = body(raw)
    table = event_table(b)
    first = 2 + 2 * len(table)
    strings, p = [], first
    while p < len(b) and len(strings) < 8:
        q = b.find(b"\0", p)
        s = b[p:q]
        if q < 0 or b"." not in s or not all(32 < c < 127 for c in s):
            break
        strings.append(s.decode("ascii"))
        p = q + 1
    code_start = p
    events = {}
    errors = {}
    for i, off in enumerate(table):
        key = 2 + 2 * i
        if off < code_start:
            continue
        try:
            events[key] = {"offset": off, "ops": decode_event(b, off)}
        except ScriptError as e:
            errors[key] = str(e)
    return {"strings": strings, "table": table, "events": events, "errors": errors}
