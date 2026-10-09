"""Battle data of 轩辕剑外传：枫之舞 (SWDA), decoded from FIG.EXE, ORC.EXE,
ITEM.EXE and ITEM2.EXE.  See BATTLE.md next to this file for the evidence
(FIG.EXE addresses are code-segment offsets of the image after the 512-byte
MZ header; DS = paragraph 0xE2C, i.e. image offset 0xE2C0).

All functions return plain dicts/lists; Big5 text is decoded to str.
Exported by `swdtools.engine` as engine/battle.json; standalone:

    python3 -m swdtools.battle GAME_DIR OUT.json
"""
import json
import os
import struct
import sys

from .containers import lsk_entries, is_compressed_block
from .lzh import decompress
from .pic import decode_pic

GAME = "."

N_OBJECTS = 586          # object ids 0..585 (items + monsters), one CD.LSK entry each
FIRST_MONSTER = 0x13A    # 314: ids >= this are monsters (FIG 0x1232, 0x1bdd)
N_SKILLS = 127
SKILL_SIZE = 0x28        # FIG 0x76c7 copies 0x14 words
ITEM_SIZE = 36
MONSTER_SIZE = 82
LEVEL_ROWS = 50          # max level 50 (FIG 0x5bf7)
LEVEL_COLS = ("hp_max", "mp_max", "exp_next", "strength", "defense",
              "agility", "luck", "stamina_max", "learn_skill")

# Big5 names of the stats as FIG prints them on level-up (DS 0x2078).
STAT_LABELS = {"level": "等級", "hp": "生命", "stamina": "體力", "mp": "仙術",
               "strength": "力量", "defense": "防禦", "agility": "敏捷", "luck": "運氣"}

# 0x9F-byte party record (RPG DS 0x11D + 0x9F*i).  (offset, size, name, note)
PARTY_RECORD = [
    (0x00, 8, "name", "4 glyph codes drawn with the SAVE\\NAME.DA? font"),
    (0x08, 2, "status", "status bits, see STATUS_BITS"),
    (0x0A, 2, "unknown_0a", ""),
    (0x0C, 2, "attack", "effective attack = strength + weapon (+0xd of items); battle buffs change it"),
    (0x0E, 2, "defense", "effective defense incl. armour (+0xf of items)"),
    (0x10, 22, "equipment", "11 object ids; slots 7/8 (+0x1E,+0x20) hold the 煉妖 creatures used by battle command 5"),
    (0x26, 1, "immune_physical", "max of equipped items' +0x16; 1 = physical attacks miss"),
    (0x27, 4, "element_resist", "elements 1..4, max of items' +0x17..+0x1A; 1 immune, 2 double, 3 absorb"),
    (0x2B, 2, "unknown_2b", ""),
    (0x2D, 2, "hp", "生命 current (0 = KO, status 0x2000)"),
    (0x2F, 2, "hp_max", "生命 max"),
    (0x31, 2, "level", "等級 1..50"),
    (0x33, 2, "luck", "運氣: initiative random range"),
    (0x35, 2, "stamina", "體力 current: paid to summon captured monsters"),
    (0x37, 2, "stamina_max", "體力 max"),
    (0x39, 2, "exp", "experience toward next level"),
    (0x3B, 2, "exp_next", "experience needed (level table column 2)"),
    (0x3D, 2, "strength", "力量 (base attack)"),
    (0x3F, 2, "unknown_3f", ""),
    (0x41, 2, "attack_saved", "battle backup of +0x0C (FIG 0x231/0x256)"),
    (0x43, 2, "defense_saved", "battle backup of +0x0E"),
    (0x45, 2, "wisdom", "智慧 (named by skill 112 增智慧上限); healing spells add caster's 智慧/4 (FIG 0x48aa)"),
    (0x47, 6, "unknown_47", ""),
    (0x4D, 2, "agility_base", "敏捷 shown on level-up"),
    (0x4F, 6, "unknown_4f", ""),
    (0x55, 2, "mp", "仙術 current, paid for 奇術"),
    (0x57, 2, "mp_max", "仙術 max"),
    (0x59, 4, "unknown_59", ""),
    (0x5D, 2, "agility", "effective agility (initiative base) incl. shoes (+0x11 of items)"),
    (0x5F, 2, "agility_saved", "battle backup of +0x5D"),
    (0x61, 4, "unknown_61", ""),
    (0x65, 2, "evasion", "閃躲, out of 12 (+0x13 of items)"),
    (0x67, 2, "evasion_saved", "battle backup of +0x65"),
    (0x69, 4, "unknown_69", ""),
    (0x6D, 50, "skills", "known 奇術 ids (bytes, 0 = empty)"),
]

STATUS_BITS = {
    0x0002: "霧縛 mist-bound (cannot act)",
    0x0004: "定身 held (cannot act)",
    0x0008: "失明 blind (cannot act? in incapacitated mask)",
    0x0010: "凍結 frozen (cannot act)",
    0x0020: "睡眠 asleep (cannot act)",
    0x0040: "unknown, in incapacitated mask",
    0x0080: "封魔 magic sealed (no 奇術, no 符咒 items)",
    0x0100: "蠱毒 gu-poison: damage every turn",
    0x0200: "毒 poison from enemy attacks (cured by 0xFCFF masks)",
    0x0400: "unknown, in incapacitated mask",
    0x0800: "unknown, in incapacitated mask",
    0x1000: "flee helper (removes the 2/10 cap on flee chance)",
    0x2000: "KO / dead",
}
INCAPACITATED_MASK = 0x2C7E   # FIG 0x4a1 / 0xbc8: no command input, cannot dodge

# Battle-script op table (FIG DS 0x2EC7).  Arg codes: w word, j jump (offset
# from script start), T inline text up to "$$", L count + count jumps.
SCRIPT_OPS = {
    0x00: ("say", "T"), 0x01: ("round", ""), 0x02: ("victory", ""),
    0x03: ("defeat", ""), 0x04: ("goto", "j"), 0x05: ("if_var_eq", "wwj"),
    0x06: ("var_inc", "w"), 0x07: ("heal_party", ""), 0x08: ("end", ""),
    0x09: ("sfx", "w"), 0x0A: ("redraw", ""), 0x0B: ("enemy_say", "wwT"),
    0x0C: ("wait", "w"), 0x0D: ("ent_add", "ww"), 0x0E: ("ent_sub", "ww"),
    0x0F: ("ent_set", "ww"), 0x10: ("screen_fx", ""), 0x11: ("check_win_ignoring_0x2000", ""),
    0x12: ("enemy_die_fx", ""), 0x13: ("random_goto", "L"), 0x14: ("var_set", "ww"),
    0x15: ("swap_enemies", "ww"), 0x16: ("if_ent_eq", "wwj"), 0x17: ("end2", ""),
    0x18: ("ask", "j"), 0x19: ("if_pay", "wj"), 0x1A: ("give_drop", ""),
    0x1B: ("show_money", ""), 0x1C: ("if_flag", "wj"), 0x1D: ("bosses_escape", ""),
    0x1E: ("auto_off", ""), 0x1F: ("drop_always", ""), 0x20: ("party_size", "w"),
    0x21: ("set_defeat_flag", "w"), 0x22: ("if_member", "wj"), 0x23: ("party_add", "ww"),
    0x24: ("party_sub", "ww"), 0x25: ("party_set", "ww"), 0x26: ("if_party_eq", "wwj"),
    0x27: ("text_at", "wwT"), 0x28: ("member_pose", "w"), 0x29: ("redraw2", ""),
    0x2A: ("if_item", "wjw"), 0x2B: ("set_flag", "ww"), 0x2C: ("summon", "wj"),
    0x2D: ("damage_first_enemy", "w"), 0x2E: ("redraw3", ""), 0x2F: ("enemy_full_hp", "w"),
}
TERMINATING_OPS = {0x02, 0x03, 0x08, 0x17}

# Per-enemy arrays in FIG DS (10 entries x u16, stride 0x14). Script ops
# 0x0D-0x0F/0x16 address them as 0x23C6 + operand.
ENEMY_ARRAYS = {
    0x23C6: "x (4-pixel columns, from group)", 0x23DA: "y (pixels, monster +0x24)",
    0x23EE: "centre x", 0x2402: "centre y", 0x2416: "type index 0..3",
    0x242A: "level", 0x243E: "poison chance", 0x2452: "flee mode",
    0x2466: "magic frequency", 0x247A: "skill A", 0x248E: "skill B", 0x24A2: "skill C",
    0x24B6: "heal skill", 0x24CA: "special frequency", 0x24DE: "special skill A",
    0x24F2: "special skill B", 0x2506: "mp", 0x251A: "attack", 0x252E: "attack base",
    0x2542: "defense", 0x2556: "defense base", 0x256A: "agility", 0x257E: "luck",
    0x2592: "evasion", 0x25A6: "evasion base", 0x25BA: "hp", 0x25CE: "hp max",
    0x25E2: "exp", 0x25F6: "money", 0x260A: "status/flags", 0x261E: "attack sfx",
    0x2632: "death sfx", 0x2646: "immune physical", 0x265A: "resist element 0 (always 0)",
    0x266E: "resist element 1", 0x2682: "resist element 2", 0x2696: "resist element 3",
    0x26AA: "resist element 4",
}

CHAR_POSES = ("stand", "cast_1", "stand_2", "cast_2", "ready", "attack_1",
              "attack_2", "critical_1", "critical_2")


# ---------------------------------------------------------------- helpers
def _read(game, name):
    with open(os.path.join(game, name), "rb") as f:
        return f.read()


def _w(b, o):
    return struct.unpack_from("<H", b, o)[0]


def _s(b, o):
    return struct.unpack_from("<h", b, o)[0]


def big5(b):
    return bytes(b).decode("big5", "replace").replace("　", " ").rstrip(" \0")


def _overlay_body(raw):
    return raw[512:]


def _overlay_table(b):
    """u16 table from byte 2 up to the lowest nonzero entry."""
    table, p, lowest = [], 2, len(b)
    while p < lowest:
        v = _w(b, p)
        table.append(v)
        if v:
            lowest = min(lowest, v)
        p += 2
    return table


def fig_ds(game=GAME):
    """FIG.EXE data segment (its first instruction is mov ax, DS)."""
    img = _read(game, "FIG.EXE")
    hdr = _w(img, 8) * 16
    body = img[hdr:]
    assert body[0] == 0xB8, "unexpected FIG.EXE entry"
    return body[_w(body, 1) * 16:]


def _dollar_list(ds, start, end):
    return ds[start:end].split(b"$$")


# ---------------------------------------------------------------- FIG tables
def object_names(game=GAME):
    """Names of object ids 0..585 (FIG DS 0xB8B, "$$"-separated, by id)."""
    ds = fig_ds(game)
    parts = _dollar_list(ds, 0xB8B, 0x1DEC)
    return [big5(p) for p in parts[:N_OBJECTS]]


def category_names(game=GAME):
    """Object categories (item/monster word +0): 2-char labels after the names."""
    ds = fig_ds(game)
    start = 0xB8B + sum(len(p) + 2 for p in _dollar_list(ds, 0xB8B, 0x1DEC)[:N_OBJECTS])
    out = []
    while ds[start] >= 0xA1:          # 4-byte Big5 labels, then padding spaces
        out.append(big5(ds[start:start + 4]))
        start += 4
    return out


def battle_messages(game=GAME):
    """Battle strings, keyed by FIG DS offset (hex)."""
    ds = fig_ds(game)
    out, p = {}, 0x1DFB
    while p < 0x2134:
        q = ds.find(b"$$", p)
        if q < 0:
            break
        out["0x%04x" % p] = big5(ds[p:q])
        p = q + 2
    return out


def random_encounters(game=GAME):
    """FIG DS 0x2837: map id -> rectangles -> base group (8 consecutive groups,
    one picked by DOS time 1/100 s mod 8). FIG 0x3a3c."""
    ds = fig_ds(game)
    p, out = 0x2837, []
    while True:
        key = _w(ds, p)
        p += 2
        if key == 0x544D:     # "MT": unknown map -> first entry's rectangles
            break
        rects = []
        while True:
            x0, x1, y0, y1, base, name = struct.unpack_from("<6H", ds, p)
            rects.append({"x0": x0, "x1": x1, "y0": y0, "y1": y1,
                          "group_offset": base,
                          "groups": [base + 2 * k for k in range(8)],
                          "group_indices": [(base - 2) // 2 + k for k in range(8)],
                          "file": "O%c%c.EXE" % (name >> 8, name & 0xFF)})
            p += 12
            if _w(ds, p) == 0xFFFF:
                p += 2
                break
        out.append({"map_id": key, "rects": rects})
    return out


# ---------------------------------------------------------------- ITEM.EXE
def _item_body(game):
    return _overlay_body(_read(game, "ITEM.EXE"))


def _object_offset(b, oid):
    return _w(b, 4 + 2 * oid)          # FIG 0x1d54: es:[id*2+4]


def parse_skill(r, sid, item_body=None):
    """40-byte 奇術/effect record (ITEM.EXE entry 0, by skill id)."""
    w = lambda o: _w(r, o)
    s = {
        "id": sid,
        "name": big5(r[0:10]),
        "next_skill": w(0x0A),          # chained effect (FIG 0x4980)
        "element": r[0x0C] & 7,         # 0 none, 1..4 checked against resists, 5 (thunder) not resisted
        "flags_c": r[0x0C],             # 0x20/0x40/0x80 need media 禁魔雕像/魔心臟腑/幻霧香爐 on field
        "target_flags": r[0x0D],        # 0x08 self, 0x10 one ally, 0x20 one enemy, else all
        "effect": w(0x0E),
        "cost": w(0x10),                # 仙術 for party, enemy mp
        "power": w(0x12),
        "sfx": w(0x14),
        "w16": w(0x16),
        "anim_script": w(0x18),
        "raw_1a": list(struct.unpack_from("<7H", r, 0x1A)),
    }
    s["cost_type"] = {0: "none", 1: "mp", 2: "stamina", 3: "stamina", 4: "mp",
                      5: "herbs"}.get(r[0x0D] & 7, "?")     # FIG 0x42f6, 0x440f
    if r[0x0D] & 7 == 5:   # herb mask in the low byte of cost: 0x10 金 0x08 木 0x04 水 0x02 火 0x01 土
        s["herbs"] = [h for bit, h in ((0x10, "金"), (0x08, "木"), (0x04, "水"), (0x02, "火"), (0x01, "土"))
                      if r[0x10] & bit]
    s["battle_usable"] = not (r[0x0D] & 0x40)                  # FIG 0x42d8
    s["target"] = ("self" if s["target_flags"] & 8 else "ally" if s["target_flags"] & 0x10
                   else "enemy" if s["target_flags"] & 0x20 else "all")
    s["media_required"] = [m for bit, m in ((0x20, 0xAE), (0x40, 0xAF), (0x80, 0xB0)) if r[0x0C] & bit]
    e = s["effect"]
    if e == 1:     # heal / cure (FIG 0x4997, 0x48aa, 0x485a, 0x4ad8)
        pct = lambda v: {"percent": v & 0x7FFF} if v & 0x8000 else {"amount": v}
        s["heal"] = {"char_mask": r[0x1A], "hp": pct(w(0x1C)), "stamina": pct(w(0x1E)),
                     "mp": pct(w(0x20)), "status_and_mask": w(0x22),
                     "stat_offset": w(0x24), "stat_add": _s(r, 0x26)}
    elif e == 3:   # party buff (FIG 0x4de4) / enemy self buff (0x28e4)
        s["buff"] = {"agility": _s(r, 0x1A), "defense": _s(r, 0x1C), "attack": _s(r, 0x1E),
                     "evasion": _s(r, 0x20), "magic_guard_turns": w(0x22), "decoys": w(0x24),
                     "duration": "rand(5)+power"}
    elif e == 8:   # status ailment (FIG 0x472b party->enemy, 0x273d enemy->party)
        s["inflict_status"] = w(0x1A)
    elif e == 4:   # place media items 0xAE..0xB0 on the field (FIG 0x45bc)
        s["media_bits"] = r[0x13]
    if item_body is not None and s["anim_script"]:
        s["anim"] = parse_anim_script(item_body, s["anim_script"])
    return s


ANIM_OPS = {0: ("load_sa_lsk", 1), 1: ("draw", 3), 2: ("restore_bg", 0), 3: ("flip", 0),
            4: ("delay", 1), 5: ("draw_caster", 0), 6: ("flash", 1), 7: ("apply_damage", 1),
            8: ("pal_sub", 3), 9: ("pal_add", 3), 10: ("pal_fade_up", 3), 11: ("pal_fade_down", 3),
            12: ("pal_restore", 0), 13: ("enemy_branch", 1), 14: ("shake_redraw", 0),
            15: ("shake_range", 2), 16: ("sfx", 1)}


def parse_anim_script(b, off, limit=400):
    """Spell animation word list (skill +0x18 -> ITEM.EXE body), FIG 0x4b5b."""
    ops = []
    for _ in range(limit):
        if off + 2 > len(b):
            break
        op = _w(b, off)
        if op == 0xFFFF:
            break
        name, n = ANIM_OPS.get(op, ("op%d" % op, 0))
        args = [_w(b, off + 2 + 2 * k) for k in range(n)]
        ops.append([name] + args)
        off += 2 + 2 * n
        if op not in ANIM_OPS:
            break
    return ops


def skills(game=GAME):
    b = _item_body(game)
    tab = _w(b, 2)                     # FIG 0x76c7: [2] -> skill pointer table
    return [parse_skill(b[_w(b, tab + 2 * i):_w(b, tab + 2 * i) + SKILL_SIZE], i, b)
            for i in range(N_SKILLS)]


def descriptions(game=GAME):
    """ITEM2.EXE: description of object id i at table entry i+1 (entry 0 = "CHAIN.DSK")."""
    b = _overlay_body(_read(game, "ITEM2.EXE"))
    t = _overlay_table(b) + [len(b)]
    out = []
    for i in range(1, len(t) - 1):
        txt = b[t[i]:t[i + 1]]
        txt = txt[:txt.find(b"$$")] if b"$$" in txt else txt
        out.append(big5(txt).replace("##", ""))
    return out


ITEM_SLOT = {1: "necklace", 2: "shoes", 3: "body", 4: "?4", 5: "weapon",
             6: "ring", 7: "head", 9: "?9"}


def parse_item(r, oid, names, cats):
    flags5 = r[5]
    it = {
        "id": oid, "name": names[oid], "category": _w(r, 0),
        "category_name": cats[_w(r, 0)] if _w(r, 0) < len(cats) else None,
        "byte4": r[4], "flags": flags5,
        "battle_usable": bool(flags5 & 0x02),     # FIG 0x1883
        "consumed": bool(flags5 & 0x04),          # FIG 0x12c8
        "kind": r[6], "slot": ITEM_SLOT.get(r[6] & 0x0F) if flags5 & 0x40 else None,
        "skill": r[7],                            # effect skill id (FIG 0x1907, 0x18ec)
        "price": _w(r, 0x0B),                     # RPG 0x5df2
        "attack": _s(r, 0x0D), "defense": _s(r, 0x0F),      # RPG 0x44a8
        "agility": _s(r, 0x11), "evasion": _s(r, 0x13),
        "immune_physical": r[0x16], "element_resist": list(r[0x17:0x1B]),  # RPG 0x457c
        "raw": r.hex(),
    }
    return it


def parse_monster(r, oid, names, cats):
    w, s = (lambda o: _w(r, o)), (lambda o: _s(r, o))
    m = {
        "id": oid, "name": names[oid], "category": w(0),
        "category_name": cats[w(0)] if w(0) < len(cats) else None,
        "sprite": {"file": "CD.LSK", "entry": oid},      # FIG 0x3834: lcall 0xdef:0x3c0, bx=4
        "immune_physical": r[0x16],                      # FIG 0x133e
        "element_resist": list(r[0x17:0x1B]),            # FIG 0x4f66 (0x265a + el*0x14)
        "y": w(0x24), "level": w(0x26), "hp": w(0x28), "mp": w(0x2A),
        "attack": w(0x2C), "evasion": w(0x2E), "luck": w(0x30), "agility": w(0x32),
        "w34": w(0x34), "defense": w(0x36), "exp": w(0x38),
        "skills": [w(0x3A), w(0x3C), w(0x3E)], "money": w(0x40),
        "special_skills": [w(0x42), w(0x44)], "heal_skill": w(0x46),
        "magic_freq": r[0x48], "special_freq": r[0x49],
        "poison": r[0x4A], "flee_mode": r[0x4B],
        "flags": w(0x4C), "attack_sfx": w(0x4E), "death_sfx": w(0x50),
        "header_raw": r[:0x24].hex(),
        "species": r[0x22],        # eaten by 煉妖 creatures whose code matches (FIG 0xcee)
        "byte23": r[0x23],
    }
    return m


def objects(game=GAME):
    b = _item_body(game)
    names = object_names(game)
    cats = category_names(game)
    items, monsters = [], []
    for oid in range(N_OBJECTS):
        off = _object_offset(b, oid)
        if oid < FIRST_MONSTER:
            items.append(parse_item(b[off:off + ITEM_SIZE], oid, names, cats))
        else:
            monsters.append(parse_monster(b[off:off + MONSTER_SIZE], oid, names, cats))
    return items, monsters


# ---------------------------------------------------------------- ORC.EXE
def _orc_body(game):
    return _overlay_body(_read(game, "ORC.EXE"))


def level_tables(game=GAME):
    """Per character (party member id // 12): 50 rows x 9 words.  Row L-1 holds
    the totals at level L; a level-up adds row[L]-row[L-1] (FIG 0x5c24, 0x4a8).
    The table pointer for character c is the u16 at ORC body offset 2*c
    (character 0 uses the overlay's length word)."""
    b = _orc_body(game)
    out = []
    for c in range(6):
        base = _w(b, 2 * c)
        rows = [dict(zip(LEVEL_COLS, struct.unpack_from("<9H", b, base + 18 * k)))
                for k in range(LEVEL_ROWS)]
        out.append({"character": c, "offset": base, "rows": rows})
    return out


def _decode_text(b, p):
    """Text up to "$$" as the FIG printers read it (a 0x20 is one byte,
    anything else two bytes). Returns (str, next offset)."""
    out = bytearray()
    while p < len(b):
        if b[p] == 0x20:
            out += b" "
            p += 1
            continue
        pair = b[p:p + 2]
        p += 2
        if pair == b"$$":
            break
        if pair[0] in (0x43, 0x4D) and pair[1] < 0x40:     # colour codes C/M + index
            out += ("{%c%d}" % (pair[0], pair[1])).encode()
        elif pair == b"##":
            out += b"\\n"
        else:
            out += pair
    return out.decode("big5", "replace"), p


def disasm_script(code, limit=2000):
    ops, p = [], 0
    for _ in range(limit):
        if p + 2 > len(code):
            break
        op = _w(code, p)
        start = p
        p += 2
        if op not in SCRIPT_OPS:
            ops.append({"at": start, "op": op, "name": "?"})
            break
        name, spec = SCRIPT_OPS[op]
        args = []
        for a in spec:
            if a in "wj":
                args.append(_w(code, p))
                p += 2
            elif a == "T":
                t, p = _decode_text(code, p)
                args.append(t)
            elif a == "L":
                n = _w(code, p)
                args.append([_w(code, p + 2 + 2 * k) for k in range(n)])
                p += 2 + 2 * n
        ops.append({"at": start, "op": op, "name": name, "args": args})
    return ops


def parse_group(b, off, names=None):
    """Battle group (FIG 0x36a1)."""
    p = off
    bg = b[p:p + 20].split(b"\0")[0].decode("ascii", "replace").strip()
    p += 20
    types = list(struct.unpack_from("<4H", b, p))
    p += 8
    n = _w(b, p)
    p += 2
    idx = list(struct.unpack_from("<%dH" % n, b, p))
    p += 2 * n
    xs = list(struct.unpack_from("<%dH" % n, b, p))
    p += 2 * n
    drop = None
    if _w(b, p) == 0x2323:                  # "##" + item id; 0x8000 = always
        drop = _w(b, p + 2)
        p += 4
    on_victory, on_defeat, on_flee = struct.unpack_from("<3H", b, p)
    p += 6
    q = p
    while q + 2 <= len(b) and _w(b, q) != 0x2121:   # copied word by word up to "!!"
        q += 2
    code = b[p:q]
    g = {
        "offset": off, "background": bg.replace("C:", "").replace("\\", "/"),
        "monster_types": types, "count": n,
        "enemies": [{"type": i, "monster": types[i] if i < 4 else None, "x": x}
                    for i, x in zip(idx, xs)],
        "drop": None if drop is None else {"item": drop & 0x7FFF, "always": bool(drop & 0x8000)},
        "on_victory": on_victory, "on_defeat": on_defeat, "on_flee": on_flee,
        "script": disasm_script(code),
    }
    if names:
        for e in g["enemies"]:
            if e["monster"] is not None and e["monster"] < len(names):
                e["name"] = names[e["monster"]]
        if g["drop"]:
            g["drop"]["name"] = names[g["drop"]["item"]] if g["drop"]["item"] < len(names) else None
    return g


def groups(game=GAME):
    """ORC.EXE table entry i = group whose RPG [0x594] value is 2+2*i.
    Entries 0..4 point at the level tables, entry 48 is empty."""
    b = _orc_body(game)
    names = object_names(game)
    table = _overlay_table(b)
    level_offsets = {_w(b, 2 * c) for c in range(6)}
    out = []
    for i, off in enumerate(table):
        rec = {"index": i, "rpg_value": 2 + 2 * i}
        if off == 0:
            rec["empty"] = True
        elif off in level_offsets:
            rec["level_table"] = True
        else:
            try:
                rec.update(parse_group(b, off, names))
            except (struct.error, IndexError) as e:
                rec["error"] = str(e)
        out.append(rec)
    return out


# ---------------------------------------------------------------- graphics
def battle_graphics(game=GAME):
    """Where battle pictures live (all verified by reading the loaders)."""
    do = lsk_entries(_read(game, "DO.LSK"))
    chars = []
    for c in range(4):
        poses = []
        for k in range(9):
            e = do[c * 9 + k]
            x = decompress(e) if is_compressed_block(e) else e
            h, w = struct.unpack_from("<HH", x, _w(x, 0))
            poses.append({"pose": CHAR_POSES[k], "do_lsk": c * 9 + k, "w": w, "h": h})
        chars.append({"character": c, "frames": poses})
    return {
        "party": chars,
        "party_note": "DO.LSK entry = (member id // 12) * 9 + pose (FIG 0x13e5, file id 6); "
                      "drawn at x = member*18-12 (4-px columns), y = 83",
        "monsters": "CD.LSK entry = object id, one picture (FIG 0x3825, file id 4); "
                    "drawn at (enemy x, monster +0x24)",
        "items": "CD.LSK entries 0..313 are the item pictures",
        "spell_effects": "SA.LSK entries loaded by anim op 0 (FIG 0x4b80, file id 0)",
        "background": "BA/BAnn.RSK = [picture 320x200, palette (3-byte head + 768 6-bit RGB)]; "
                      "the palette is the battle palette for everything (FIG 0x375e)",
        "ui": "MENU.RSK (LZH, menu/number/icon sheet), CHFIG.DSK font",
    }


def creature_growth(game=GAME):
    """煉妖 creatures (object ids 0xE6..0xFD, worn in equipment slots 7/8):
    growth counter u16 at RPG DS 0x645+2*(id-0xE6); on reaching the threshold
    the slot item becomes 'next' (FIG 0xdce, table FIG DS 0x68E)."""
    ds = fig_ds(game)
    names = object_names(game)
    out = []
    for k in range(24):
        thr, nxt = struct.unpack_from("<HH", ds, 0x68E + 4 * k)
        oid = 0xE6 + k
        out.append({"id": oid, "name": names[oid], "threshold": thr, "next": nxt,
                    "next_name": names[nxt] if 0 < nxt < len(names) else None})
    return out


def music():
    return {"battle": "RX/RI077.RIX", "battle_flagged": "RX/RI076.RIX (group value bit 0x8000 or 0x4000)",
            "victory": "RX/RI079.RIX", "level_up": "RX/RI040.RIX", "defeat": "RX/RI041.RIX",
            "sfx": "VC/SPnnn.VOC (n = sfx number)"}


# ---------------------------------------------------------------- main
def dump(game=GAME):
    items, monsters = objects(game)
    return {
        "categories": category_names(game),
        "messages": battle_messages(game),
        "party_record": [{"offset": o, "size": s, "name": n, "note": t} for o, s, n, t in PARTY_RECORD],
        "status_bits": {"0x%04x" % k: v for k, v in STATUS_BITS.items()},
        "enemy_arrays": {"0x%04x" % k: v for k, v in ENEMY_ARRAYS.items()},
        "level_tables": level_tables(game),
        "skills": skills(game),
        "items": items,
        "monsters": monsters,
        "descriptions": descriptions(game),
        "groups": groups(game),
        "random_encounters": random_encounters(game),
        "graphics": battle_graphics(game),
        "creature_growth": creature_growth(game),
        "music": music(),
    }


if __name__ == "__main__":
    game = sys.argv[1] if len(sys.argv) > 1 else GAME
    out = sys.argv[2] if len(sys.argv) > 2 else "battle_data.json"
    data = dump(game)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    bad = [g["index"] for g in data["groups"] if "error" in g
           or any(op["name"] == "?" for op in g.get("script", []))]
    print("wrote", out, "skills", len(data["skills"]), "items", len(data["items"]),
          "monsters", len(data["monsters"]), "groups", len(data["groups"]), "bad groups", bad)
