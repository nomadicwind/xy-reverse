# SWDA (轩辕剑外传：枫之舞) battle system — FIG.EXE notes

> Corrections and the 煉妖術 / 防禦 / summoning rules are in [CREATURES.md](CREATURES.md) (section 0 lists where this file is wrong).

Notation. `FIG xxxx` = offset in FIG.EXE's code segment 0 (image after the
512-byte MZ header, disassemble it to follow along). `DS:xxxx` = FIG data segment
(paragraph 0xE2C, image offset 0xE2C0; the first 0x681 bytes mirror RPG.EXE's
DS). `RPG xxxx` = rpg.asm. Overlay offsets are relative to the body (after
the 512-byte header).
**[V]** = read in the code and/or checked against the data. **[I]** = inferred
(names, intent, or partly read code). Parser: `tools/swdtools/battle.py`; full dump:
`engine/battle.json` (extracted).

## 0. Files and loading

| what | where | evidence |
|---|---|---|
| battle groups + level tables | ORC.EXE (table entry i = group whose RPG `[0x594]` value is `2+2*i`) | FIG 3a24, 36a1 [V] |
| skills (奇術 and item effects) | ITEM.EXE entry 0: 127 pointers at body 0x498, 0x28-byte records | FIG 76c7 [V] |
| items (ids 0..313) / monsters (314..585) | ITEM.EXE: object id `n` at table offset `4+2n` (entry n+1); 36 / 82-byte records | FIG 1d54 [V] |
| object names | DS:0B8B, `$$`-separated, indexed by object id; 42 two-char category names follow | FIG 1bd1 path, checked by data [V] |
| descriptions | ITEM2.EXE entry n+1 (`『name』text$$`, `##` = newline) | data [V] (not used by FIG) |
| monster pictures | CD.LSK entry = object id, one picture per entry (entries 0..313 are item pictures) | FIG 3825 (lcall 0DEF:03C0, bx=4 → CD.LSK) [V] |
| party battle sprites | DO.LSK entry = `(member_id/12)*9 + pose`, 4 characters × 9 poses = entries 0..35 | FIG 13e5 (bx=6 → DO.LSK) [V] |
| spell effects | SA.LSK entries, loaded by animation op 0 | FIG 4b80 (bx=0 → SA.LSK) [V] |
| background + palette | `BA\BAnn.RSK` named in the group: `[pic 320x200, palette]` | FIG 374f, 375e [V] |
| UI | MENU.RSK, CHFIG.DSK (font), SAVE\NAME.DAQ (glyphs for player-named characters) | FIG 37d4..3819 [V] |
| music | battle `RX\RI077.RIX` (RI076 if `[0x594]` bit 0x8000/0x4000), victory RI079, level-up RI040, defeat RI041 | FIG 367e, 5aec, 5c84, 05bb [V] |
| sound effects | `VC\SPnnn.VOC`, n = sfx number | FIG 5097 [V] |

Note for `swdtools/script.py`: CHNA op **0x30** (named `music2`) is the battle
start: `[0x610]=arg0, [0x594]=arg1` (RPG 6060). Op 0x0D (`battle`) is a menu/choice op.
Group values seen: e.g. CHNA2 `[*,178]`, CHNA6 `[*,18..36]`.

## 1. RPG ↔ FIG hand-over [V]

* FIG start: if segment 0x6000 begins with `IF`, copy 0x6000:2.. → DS:0..0x680 (FIG 365a). `[0x594]` bits 0x8000/0x4000 pick the music and are then masked off.
* `[0x594]==0` → random encounter: look up map id `[0x12]&0xFFF` in DS:2837 (`random_encounters` in JSON). Each map has rectangles over the player position `[0x50F],[0x511]`. Each rectangle gives a base group, and the battle uses `base + 2*(DOS 1/100 s mod 8)`, so 8 consecutive groups (FIG 3a3c). The table ends with `MT`. An unknown map falls back to the first map's rectangles.
* End: write `CO` to 0x6000:0 and save DS:0..0x680 (all of the RPG state: party records, money, inventory, flags, `[0x58F]` defeat flag, `[0x3FB]` captured/dropped item) to `SAVE\SAVE.ZAQ` (FIG 00b2..00e3, 80d6).
* `[0x58F]` = 1 after a defeat (op 3, or all KO). Battle buffs are undone at the end (FIG 256: +0x0C/+0x0E/+0x5D/+0x65 restored from the backups, status `&= 0xF200`).

## 2. Battle group (ORC.EXE) [V] (FIG 36a1)

```
char  bg[20]        "C:BA\BAnn.RSK" space/NUL padded
u16   type[4]       monster object ids (0 = unused)
u16   n             enemies (≤6 in the data; arrays hold 10; turn order only sees 6)
u16   idx[n]        type index 0..3 per enemy
u16   x[n]          x in 4-pixel columns (y comes from monster +0x24)
[u16 0x2323, u16 drop]   optional "##": drop item; bit 0x8000 = always, else 1/3 chance
u16   on_victory, on_defeat, on_flee    script offsets
u16[] script        word ops up to the word "!!" (0x2121)
```
Entries 0..4 of the table point at the level tables. Entry 48 is 0. 363 real groups.
The group **script** drives the whole battle. A plain battle is
`screen_fx; L: round; goto L` followed by `victory / defeat / end` at the three
offsets. Op table DS:2EC7 (`SCRIPT_OPS` in battle.py). Highlights:

| op | args | meaning |
|---|---|---|
| 00 | text | dialogue box, text up to `$$` (0x20 is 1 byte, other characters 2; `##` newline; `C`/`M`+byte colour codes) |
| 01 | – | **one round**: command input, initiative, actions. Afterwards: all KO → on_defeat; fled → on_flee; all enemies HP 0 → sum exp/money → on_victory (FIG 2b2, 3fd..49d) |
| 02 | – | victory rewards and level-ups, then the script ends (FIG 5a89) |
| 03 | – | defeat: `[0x58F]=1`, "全體陣亡！", ends (FIG 5c7f) |
| 04/05/06/13/14 | | goto / if var==v goto / var++ / random goto among n / var=v (vars DS:2F2D) |
| 0D/0E/0F/16 | ofs,v | add/sub/set/compare an enemy-array word at DS:23C6+ofs. ofs<0x14 moves x and centre x together |
| 0B / 27 | e,h,text / x,y,text | enemy speech bubble / text at x,y |
| 1C / 2B | bit,(jmp/val) | test / set RPG story flag bits at DS:596 |
| 22, 23-26 | | party member test; add/sub/set/compare a party-record word (DS:11D+ofs) |
| 2A | item,jmp,new | inventory test/replace (0xF800 = also search equipment) |
| 2C | monster,jmp | add a helper enemy in the 2 summon slots |
| 1D | – | enemies with flag 0x8000 and HP 0 "逃走" (bosses that leave) |
| 07 | – | full heal, clear status |

## 3. Monster record (ITEM.EXE, 82 bytes) — FIG 38d1 copies it into per-enemy arrays

| off | field | evidence |
|---|---|---|
| 00 | u16 category (index into the category list: 2 妖魔, 38 神族, 39 機關 …) | data [V] |
| 02 | u16 object id (= name index = CD.LSK entry) | FIG 3837 [V] |
| 04..15 | item-style header (flags, stat modifiers?) | not read by FIG [I] |
| 16 | u8 physical immunity (1 → physical attacks miss) | FIG 133e [V] |
| 17..1A | u8 resistance to elements 1..4: 1 immune, 2 double damage, 3 absorb (heals) | FIG 4f66 [V] |
| 22 | u8 species code, eaten by the matching 煉妖 creature (command 5) | FIG 0cee [V] |
| 24 | y position (pixels) | FIG 38d8, 3439 [V] |
| 26 | level (flee checks, capture, damage randomness) | FIG 0777, 2b23 [V] |
| 28 | HP (current and max) | [V] |
| 2A | MP (pays skill cost +0x10) | FIG 2392 [V] |
| 2C | attack (current and base) | FIG 2b2f [V] |
| 2E | evasion (dodge if rand(12) < value) (current and base) | FIG 136a [V] |
| 30 | luck = initiative random range | FIG 065e [V] |
| 32 | agility = initiative base | FIG 0665 [V] |
| 34 | unknown, not loaded by FIG | |
| 36 | defense (current and base) | FIG 1345 [V] |
| 38 | exp reward | FIG 0480 [V] |
| 3A,3C,3E | normal skills A/B/C | FIG 22c9 [V] |
| 40 | money reward | FIG 0484 [V] |
| 42,44 | special skills | FIG 22a9 [V] |
| 46 | heal skill used at HP ≤ max/4 | FIG 21fe [V] |
| 48 / 49 | u8 magic frequency / special frequency (out of 10) | FIG 2287 [V] |
| 4A | u8 poison chance: if ≠1 and rand(10) ≤ v, a hit adds status 0x200 | FIG 2c09 [V] |
| 4B | u8 flee mode: 2 always flees; 1 may flee at HP ≤ 1/4 (random encounters) | FIG 2158, 2237 [V] |
| 4C | flags → enemy status word (0x8000 = story enemy: drawn at HP 0, cannot be captured, leaves via op 1D; 0x2000 = ignored by op 11) | FIG 3422, 579c [V]/[I] |
| 4E / 50 | attack sfx / death sfx | FIG 2b07, 1507 [V] |

Enemy AI per turn (FIG 2132) [V]:
1. Random encounters only, if the enemy is not flagged 0xE000: flee mode 2 → leaves (no reward). If party leader level ≥ enemy level+9: rand(3) = 2 → leaves, 1 → hesitates (turn lost).
2. HP ≤ max/4: cast the heal skill if MP allows (HP += skill +0x1C). Flee mode 1: rand(3) = 0 → leaves, 2 → hesitates.
3. Target = random living member. If not sealed (封魔): when rand(10) ≤ magic_freq, first try a special skill if rand(10) ≤ special_freq (A or B at random), otherwise one of A/B/C at random (C, B, A for r = 0, 1, 2). Casting needs MP ≥ cost. Otherwise physical attack.

## 4. Party record (0x9F bytes at RPG DS:11D)

See `PARTY_RECORD` in tools/swdtools/battle.py. Verified fields: +08 status, +0C attack (effective), +0E defense, +10 11 equipment ids,
+26 physical immunity, +27..2A element resistances (RPG 4524 takes the maximum over equipped items' +16..+1A),
+2D/+2F 生命 HP cur/max, +31 level, +33 運氣 luck, +35/+37 體力 cur/max, +39 exp, +3B exp to next level,
+3D 力量 strength, +41/+43/+5F/+67 battle backups, +45 智慧, +4D 敏捷 base, +55/+57 仙術 cur/max,
+5D effective agility, +65 閃躲 evasion, +6D 50 learnt skill ids. Equipping adds item +0D→+0C, +0F→+0E, +11→+5D, +13→+65/+67 (RPG 44a8) [V].
Member ids at DS:89 (stride 6) are `character*12`. The character index selects the sprites and the level table [V].

### Level-up [V] (FIG 5bf7, 4a8)
ORC body word `[2*c]` points at character c's table (c = id/12; c=0 uses the length word, which equals 0xCE88): 50 rows × 9 u16:
`hp_max, mp_max, exp_next, strength, defense, agility, luck, stamina_max, learn_skill`.
Row L-1 holds the totals at level L. While `level<50 and exp ≥ exp_next`: `exp -= exp_next`, then add `row[L]-row[L-1]`
to: +2F (and refill +2D), +57 (refill +55), +3D and +0C, +0E, +4D and +5D, +33, +37 (refill +35). Set `exp_next = row[L].exp_next`, add `learn_skill` to the skill list if nonzero, clear status, level+1.

## 5. Items (36 bytes) [V unless noted]
+00 category, +02 id, +04 u8 ? [I], +05 flags (0x02 usable in battle FIG 1883, 0x04 consumed on use FIG 12c8, 0x40 equipment [I]),
+06 low nibble slot (5 weapon, 3 body, 7 head, 2 shoes, 1 necklace, 6 ring … [I]; RPG 449f), +07 skill id = use effect (FIG 1907),
+0B price (RPG 5df2), +0D attack, +0F defense, +11 agility, +13 evasion (RPG 44a8), +16 physical immunity, +17..1A element resistances (RPG 457c).
Category 0x10 (符咒) items cast their skill and cost 仙術; blocked by 封魔 (FIG 18cd). Ids ≥ 314 in the inventory are **captured monsters**: using one costs 體力 = 2×level and summons it as an ally (FIG 189a, 1232) [V]. Ally AI: FIG f8e [I].
Herb items 0x44..0x48 (藥材金/木/水/火/土) are counters at RPG DS:4ED (FIG 1bf0).

## 6. Skills (40 bytes) [V unless noted]
| off | field |
|---|---|
| 00 | name[10] Big5 |
| 0A | next skill id: the effect chains (FIG 4980) |
| 0C | bits 0-2 element (0 none; 1..4 resistable; 5 thunder, never resisted), 0x20/0x40/0x80 need media 禁魔雕像/魔心臟腑/幻霧香爐 on the field (FIG 4902, 4a1c) |
| 0D | bits 0-2 cost type (1,4 仙術 +55; 2,3 體力 +35; 5 herbs; 0 free) (FIG 42f6, 440f); 0x08 self, 0x10 one ally, 0x20 one enemy, none of these = all; 0x40 not usable in battle |
| 0E | effect type, party side DS:1DBD: 1 heal/cure/raise stats, 2 damage (dealt by anim op 7), 3 buff, 4 place media, 7 escape, 8 inflict status, 9 dispel enemy buffs. Enemy side FIG 2703: 2 damage, 3 self-buff, 4 destroy media, 8 status, 9 dispel party buffs |
| 10 | cost (herb bit mask when the cost type is 5) |
| 12 | power: damage base / buff duration base |
| 14 | sfx; 18 → animation script (ITEM body); 1A.. effect data (below) |

* Heal (type 1, FIG 4997): +1C 生命, +1E 體力, +20 仙術. A value with bit 0x8000 means percent of max. Final amount = value (or max×pct/100) + caster 智慧/4, capped at max. +22 status AND-mask (0xD001/0xD9FF also clear 0x2000 = revive). +24 record offset, +26 permanent add (e.g. skill 112 +45 智慧).
* Buff (type 3, FIG 4de4): +1A agility, +1C defense, +1E attack (each `rand(level/2+2)+value` on top of the saved base), +20 evasion (set), +22 護魔 turns, +24 代形 decoys. Duration = rand(5)+power turns.
* Status (type 8): +1A status bits ORed onto the target. Each bit's counter = rand(5)+power (enemy target, FIG 5037) or rand(5)+2 (party target, FIG 27ac). Element resistance 1 = "失效".
* Animation script (FIG 4b5b, table DS:1DD1): word ops `0 load SA.LSK n, 1 draw f x y, 2 restore, 3 flip, 4 delay n, 5 draw caster, 6 flash n, 7 apply damage, 8-11 palette ramps (start,count,step|n<<8), 12 restore palette, 13 enemy branch (FFFF: an enemy caster stops here), 14 shake, 15 shake range, 16 sfx`, ending with FFFF.

## 7. Round flow [V]
1. **Command input** (FIG 1571) for each member not KO and not incapacitated (status & 0x2C7E). Top menu (`[0x280C]`): 0 奇術 (blocked by 封魔), 1 items, 2 attack (sub-option 1 = auto-attack every round, `[0x20ED]`), 3 sub-menu: flee / 煉妖術 capture (cmd 3) / use creatures (cmd 5). The menu labels are graphics; the order is from code [I].
2. **Initiative** (FIG 607): party `rand(luck)+agility(+5D)`, enemies `rand(+30)+(+32)`. 10 slots (4 party + 6 enemies), sorted by descending pick (ties → lower slot).
3. **Actions** in that order (FIG 6ad), skipping KO members and dead enemies. After each actor, end-of-turn timers run (FIG 883 party / a4f enemy): buffs expire ("…恢復"), status counters tick down (sleep 0x20, 霧縛 0x02, 定身 0x04, 封魔 0x80, frozen 0x10, blind 0x08). 蠱毒 0x100 deals `rand(2L)+L` (L = level of enemy 0, or of the party leader for enemies). Bug: frozen/blind enemy flags are cleared while the counter is still nonzero (FIG b8f/b9f use the inverted jump).
4. All members KO → `[0x58F]=1`.

### Physical attack, party → enemy (FIG 12dc)
`atk = rand(level/2+2) + attack(+0C)`. Critical if `rand(C)==0`, where C = RPG DS:592: it drops by 1 per attack, resets to 21 on a crit, and is set to 1 when a party member is KO'd. Miss if the enemy is physically immune or `atk ≤ def`. If the enemy can act, it dodges when `rand(12) < evasion`. `dmg = atk - def`, doubled on a crit.

### Physical attack, enemy → member (FIG 2b03)
`atk = rand(L/2+2) + enemy attack` (L = enemy level). Miss if the member has +26 = 1. If `atk ≤ def(+0E)`: `rand(L/2+2)==0` → miss, else damage = that roll. Dodge if the member can act and `rand(12) < +65`. `dmg = atk - def`. 代形 decoys and 護魔 are checked in 27cc / 0dfc. Poison: see monster +4A. KO sets 0x2000.

### Spells
Damage = `rand(L/2+2) + power`, no defense (party FIG 4ef3/4f66, enemy 237a/2586). Resistance by element: 1 immune ("失效"), 2 ×2, 3 heals.
護魔 (enemy counter 0x270E, party 0x22F3) blocks it ("護　魔"). A decoy (0x22FB) absorbs one spell ("替　身").

### Flee (FIG 750) and capture (FIG ea2)
Flee works only in random encounters (`[0x594]==0` and `[0x20FB]==0`). Success if member level ≥ enemy0 level + 4. Otherwise success if `rand(N) < 2`, with N = 10, or N = position+2 when status 0x1000 is set. Every failure decrements a counter that starts at 2×party size; reaching 0 succeeds.
煉妖術 needs a random encounter and an empty `[0x3FB]`. The enemy must not be flagged 0x8000/0x2000, and must have level ≤ leader+7 and (level ≤ leader−5 or HP ≤ max/4). On success the enemy is removed and `[0x3FB]` = monster id, which becomes an inventory item.
Creatures (command 5, slots +1E/+20, ids 0xE6..0xFD in 3 stages): 血芝麻/青魚牙 instantly remove enemies whose species code (monster +22) matches (random encounters, no exp). The creatures grow: counters at RPG DS:645, thresholds and next stage at DS:68E (`creature_growth` in JSON). 岩蟻 grows when the member takes physical hits, 龍鱗/幻蟲/吐牛 grow on fire, 冰針 on ice (FIG dfc, e32, e6a).

### Rewards (FIG 5a89) [V]
exp = Σ monster exp, money = Σ money (both totalled at FIG 46b while the last check sees all enemies dead). Money goes to `[0x11B]` (capped at 0xFFFF). Exp is split evenly among members without the 0x2000 flag. Drop: see group `##` (only if `[0x3FB]` is free). Then the level-ups.

## 8. Graphics [V]
* Party sprites: back view, h=137, 9 poses `stand, cast1, stand2, cast2, ready(cmd 5), attack1, attack2, crit1, crit2` (pose = 5+2×(crit−1), then +1; FIG 144a). Drawn at x = slot×18−12 (4-pixel columns), y = 83.
* Enemies: one CD.LSK picture each (h, w in the picture header). x from the group, y from monster +24. Flashed while being hit (`[0x22AB]`). Status icons are drawn from sprites 0xB1/0x9B+i.
* All pictures use `swdtools.pic.decode_pic` (offset table → `u16 h,u16 w,"NT"+RLE`). The palette is the BA*.RSK palette. Index 0xFE is transparent.

## 9. Unknown / not done
* Monster +04..+15, +34, +4C semantics beyond the bits above. Item +04, +08..+0A, +1B..+23.
* Party record +0A, +2B, +3F, +47..+4C, +4F..+54, +59..+5C, +61..+64, +69..+6C.
* Exact menu labels and layout (MENU.RSK graphics not decoded). Battle number font.
* Summoned-ally AI (FIG f8e…) and anim op 5 details were only skimmed. Script ops 0x11/0x12/0x18/0x28 only partly read.
* Element names are inferred from skill names: 1 fire, 2 ice, 3 rock/蠱, 4 mind (sleep, seal), 5 thunder.
* Skill 118 (神秘果) has effect 21581: it is a field-only record that overlaps other data.
* RNG: FIG uses words of its own code segment (CS:2B2 + `[0x590]`) as random numbers (FIG 2cc6). A remake can use any RNG.
