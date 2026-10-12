# SWDA battle: 煉妖術 capture, 防禦 + creatures (法寶), summoned monsters

This file uses the notation of BATTLE.md. `FIG xxxx` is a FIG.EXE code offset, `DS:xxxx` is the FIG
data segment (DS:0..0x680 is the RPG state block, GameState.ds), and `RPG xxxx` is rpg.asm.
**[V]** means read in the code or checked against the data. **[I]** means inferred.

Enemy arrays (stride 2, index = enemy slot) are the ones in `ENEMY_ARRAYS` (battle.py). The ones used
here are 23C6 x, 23EE centre x, 2416 type index, 242A level, 25BA HP, 25CE HP max, 25E2 exp,
25F6 money and 260A status/flags. `[0x2394+2*type]` holds the group's monster object ids.
`[0x23C4]` is the live enemy count. `[0x23C2]` is the group's original count (FIG 36c7).

## 0. Corrections to BATTLE.md

| BATTLE.md says | actually | evidence |
|---|---|---|
| top-menu entry 3 opens "flee / capture / creatures" | it opens 防禦 (cmd 5) on the left, 逃 (flee) on the right, and 煉妖術 (cmd 3) at the top | FIG 1687..1704, 204e [V] |
| cmd 5 "use creatures" | cmd 5 is **防禦 (defend)**. It has no defensive effect. It only triggers the two equipped 法寶 creatures. Item texts: 「裝備後使用防禦指令，會自動吞食…」 | ITEM2 descriptions; `[0x20FC]` is read only by the dispatcher FIG 80e [V] |
| creature ids "in 3 stages" | The three ids that share a name are **variants**, not stages. Each id turns straight into an ordinary **item** when its counter is full (遊雲 vanishes) | DS:68E table, FIG dce [V] |
| script op 2C "add a helper enemy" | op 2C adds a **party-side summoned monster** (the same 2 slots as item summons). No group uses it | FIG 5984 [V]; no 0x2C in the group scripts [V] |
| `[0x3FB]` "captured/dropped item" | `[0x3FB]` is the **50th inventory slot** (inventory = 50 words at DS:399..3FC). "[0x3FB]==0" means "the inventory is not full". Compaction (FIG 1ae2 = RPG 3fc8) moves it into the first free slot | FIG 1ae2, RPG 3fc8, RPG msg DS:2E67 「物品滿了！無法再增加！」 [V] |

## 1. Menu placement [V]

Command input: FIG 1571. The cross-shaped top menu is `[0x280C]`, picked with the arrow keys
(FIG 1d6f: left→0, right→1, up→2, down→3). A key is ignored when its bit in `[0x235B]` is set
(8/4/2/1 = entries 0/1/2/3).

| entry | position (DS:217F x / 2187 y) | label frames (MENU.RSK) | meaning |
|---|---|---|---|
| 0 left | 07,2C | 3A 3E 「奇術」 | skills (blocked by 封魔) |
| 1 right | 1B,2C | 38 39 「物品」 | items, **including captured monsters** |
| 2 up (default) | 11,0C | 3F 40 | attack (sub-menu: normal / auto `[0x20ED]`) |
| 3 down | 11,4C | 21 22 (glyphs not identified) | sub-menu below |

Sub-menu for entry 3 (FIG 204e draws it; it starts with `[0x2810]=0`; positions DS:2197 x / DS:219D y):

| `[0x2810]` | key | position | label frames | action |
|---|---|---|---|---|
| 0 | left | 0B,58 | 2A 2B 「防禦」 | cmd 5 (no target), FIG 16f8 |
| 1 | right | 1F,58 | 2F 30 「逃…」 | flee: `[0x20F6]=1, [0x20ED]=1`, FIG 16c9 |
| 2 | up | 15,3A | 47 48 49 「煉妖術」 | cmd 3, then pick a target enemy (FIG 1768; a single living enemy is picked automatically). Cancel returns to this sub-menu |

The 煉妖術 entry is drawn and enabled (`[0x235B]=1` instead of 3) **only if** the acting member is
member 0 (`[0x27FE]==0`) **and** `(RPG DS:4F8 & 1) == 0` (FIG 20b2..210e). DS:4F8 starts at 1 (locked)
in RPG.EXE's DS image. CHNA op **0x2A** sets it (RPG 6227, `[0x4F8]=arg`). CHNA6 runs `op2a 0` once,
which unlocks 煉妖術 in battle and the 煉化 entry of the field item menu (RPG 3176, 31e3) [V].

## 2. 煉妖術 capture (cmd 3, FIG ea2) [V]

Flow:
1. Target = `[0x2104+2*member]`. FIG 51b2 retargets to the first living enemy if that one is dead, and aborts if none is left.
2. Animation: pose 2, sfx 0x10, wait 3, pose 3, then the action banner `DS:1FE1 " 煉妖術"` (FIG a09: box at member x+15, y 0xA9, wait 10).
3. Conditions, checked in order. Any failure goes to step 5. L = member 0's level `[0x14E]` (= DS:11D+0x31). E = enemy.

| # | condition for continuing | addr |
|---|---|---|
| a | `[0x594]==0` (random encounter) | FIG edd |
| b | `[0x3FB]==0` (inventory not full) | FIG ee4 |
| c | `E.flags & 0x8000 == 0` and `E.flags & 0x2000 == 0` (monster +4C) | FIG eeb |
| d | `E.level <= L+7` (otherwise fail) | FIG efb |
| e | success if `E.level <= L-5` (16-bit unsigned: when L<5 the subtraction wraps, so every enemy that passes (d) succeeds), **or** `E.hp <= E.hp_max >> 2` | FIG f09..f1d |

   There is no random roll and no cost (nothing is deducted).
4. **Success** (FIG f61): `E.hp = 0`; `[0x3FB] = [0x2394 + 2*E.type]`, which is the **monster object id itself (314..585)**: item id == monster id, and ITEM.EXE resolves both through `4+2n`. Then sfx 0x0F, a redraw (the enemy disappears; there is no death animation and no message), and wait 9.
   * E's exp and money are **not** cleared, so they are still paid at victory (FIG 46b sums every enemy slot).
   * If this was the last enemy, the round ends in victory as usual.
5. **Failure** (FIG f1f): a 4-wide box at (banner x+4, 0xA9−0xF) with `DS:1DF3 "失　敗"` (Big5 a5a2 a140 b1d1), then wait 5. The same message is used for every reason.

After the action phase every round, FIG 43a calls the compaction routine 1ae2. The monster moves from slot 49 (`[0x3FB]`) into the first free inventory slot and **can be summoned from the next round on**.
The end-of-battle routine (FIG 256 → 283) compacts again. Since `[0x3FB]` is free again, the victory drop (FIG 5b61) still works.
If the inventory is full, `[0x3FB]` stays occupied, so capture always fails and no drop is given.

On the field, RPG shows monster entries with "level×2" as their number (RPG 408c), and FIG does the same (FIG 1bdd).

## 3. 防禦 + 法寶 creatures (cmd 5, FIG bd0) [V]

The creatures are ordinary items 0xE6..0xFD (category 28 法寶, +06 = 0xC4, kind nibble 4 → equipment
slots 7/8 = party record **+1E / +20**, RPG 43CC). They come from story scripts. For example CHNA1
op 0x28 `item [0,ev,230]` gives 血芝麻 and `[35,ev,233]` gives 青魚牙. Others are in CHNA4/5/6/10/11/14/15/16 [I: op 0x28 with a=0 = put the item in an empty slot].
They are not made by 煉化: no recipe or species table entry yields 0xE6..0xFD [V].

Action: pose 4 ("ready") and wait 4. Then process slot +1E, then slot +20 (FIG c15 each), redraw, and wait 8. There is no other effect: no damage reduction, no turn skip.

| ids | name (msg DS) | on 防禦 | growth += | addr |
|---|---|---|---|---|
| E6/E7/E8 | 血芝麻 (`2044` "Ck 血芝麻C") | each enemy with HP≠0, `[0x594]==0`, `flags&0xE000==0` and **monster +22 == 0x0E/0x10/0x12** is removed: death sfx (+50), HP=0, flags=0, **exp=0 (money kept)**, then redraw and banner, wait 3 | 1 per enemy | FIG c67..d42 |
| E9/EA/EB | 青魚牙 (`2051` "CE 青魚牙C") | the same with species 0x1A/0x1E/0x14 | 1 per enemy | FIG c8e..cb3 |
| EC/ED/EE | 金蠶 (`205E` "C2 金 蠶C") | sums the money of **all** enemy slots and sets each to 0 (the battle pays no money). If the sum is >0: sfx 0x0D and banner. Works in any battle | total money | FIG d4f |
| EF/F0/F1 | 遊雲 (`206B` "C\x85 游 雲C") | clears every placed medium (4 slots: `DS:2374+2k < 0x50` → set to 0x50 = empty). If any was cleared: sfx 0x0E, banner, redraw, wait 4 | number cleared | FIG d7d |
| F2/F3/F4 | 岩蟻 | passive: every enemy physical hit that lands on the wearer (after the miss and dodge checks) | the damage `atk−def` (before the HP cap) | FIG 2bd3 → dfc |
| F5..F9 | 龍鱗 ×3, 幻蟲 F8, 吐牛 F9 | passive: an enemy **fire** spell (skill +0C&7 == 1) reaches the wearer (after the 護魔 and 替身 checks, before resistance) | `[0x23BC]` = rand(Lₑ/2+2)+power | FIG 25d8 → e32 |
| FA..FD | 冰針 ×3, 幻蟲 FD | the same for **ice** (element 2) | same | FIG 25e4 → e6a |

Colour codes in those strings: `C`+byte sets the text colour, and `C\0` resets it.

Growth (FIG dce): `ctr = RPG DS:645 + 2*(id-0xE6)` (u16, saved with the game). `ctr += n`.
If `ctr >= thr` (thr = FIG DS:68E + 4*(id-0xE6), a FIG constant that is not in the save):
`ctr = thr` (clamped, never reset) and the slot word (+1E or +20) becomes `next`
(DS:690+4k). That is an ordinary item id; 0 for 遊雲, which then disappears. There is no message.
Notes:
* Counters are **per creature id, not per member**. Two wearers, or the same id in both slots, add up. Each slot calls dce separately, so wearing the same id twice doubles the growth.
* Because the counter stays at `thr`, the same id obtained again transforms on its next growth event.

| id | name | thr | → item | | id | name | thr | → item |
|---|---|---|---|---|---|---|---|---|
| E6 | 血芝麻 | 40 | 29 蜃珠 | | F2 | 岩蟻 | 3000 | 268 風介捲軸 |
| E7 | 血芝麻 | 110 | 82 元神劍 | | F3 | 岩蟻 | 3000 | 269 火介捲軸 |
| E8 | 血芝麻 | 40 | 260 仙果丹 | | F4 | 岩蟻 | 3000 | 270 雲介捲軸 |
| E9 | 青魚牙 | 40 | 29 蜃珠 | | F5 | 龍鱗 | 2000 | 271 火之捲軸 |
| EA | 青魚牙 | 40 | 260 仙果丹 | | F6 | 龍鱗 | 3000 | 272 火之戒指 |
| EB | 青魚牙 | 40 | 51 仙魄香 | | F7 | 龍鱗 | 4000 | 83 精火劍 |
| EC-EE | 金蠶 | 1000 | 2 金塊 | | F8 | 幻蟲 (fire) | 8000 | 103 鳳凰羽衣 |
| EF | 遊雲 | 20 | 0 (gone) | | F9 | 吐牛 (fire) | 8000 | 67 無形劍 |
| F0 | 遊雲 | 30 | 0 | | FA/FB/FC | 冰針 | 2100/3000/4000 | 276 冰之捲軸 / 277 冰之戒指 / 84 冰珀劍 |
| F1 | 遊雲 | 40 | 0 | | FD | 幻蟲 (ice) | 8000 | 102 玄雪絲衣 |

(`creature_growth` in battle.json.)

## 4. Summoning a captured monster (item id ≥ 314) [V unless noted]

**Selection** (item menu, FIG 182c):
* The item must be free this round (`id & 0xF000 == 0`). Other members' reservations are high bits.
* The monster record must have byte **+05 bit 0x02**. 253 of the 272 monsters have it. Most bosses (504..523) do not, and they show 「現在無法使用！」 (DS:1E2F).
* The member needs **體力 (+35) ≥ 2 × monster level (+26)**. Otherwise 「體力不夠，無法招喚！」 (DS:1FEA) is shown and the menu stays open (FIG 189a).
* Targeting comes from the skill in record byte +07 (normally 0, no target) [I].
* The command is stored as cmd 1, and the inventory slot is marked with `0x8000>>member`.

**Execution** (cmd 1 → FIG 11e3 → 1232): redraw the member. Then:
* Slot 0 (`[0x2384]`) free → summon into slot 0 at x = 2. Else slot 1 (`[0x2386]`) free → slot 1, x = 0x16 (FIG 1243..125b).
* Both full: the box 「要替換那一隻？」 (DS:2014) appears, then FIG 52f2 runs: left/right picks slot 0/1, confirm or cancel. On confirm the old monster's id is written into the used item's inventory slot (a **swap**), then the new one is summoned into that slot. On cancel nothing happens and the turn is lost.
* Summon (FIG 53e1): `[0x2384+2s] = id`. Animation FIG 3552: sfx 0x0E, 10 frames of 5e1f. The array index is `[0x23C4]+[0x2388]` (the replace path uses `[0x23C2]+s`). FIG 38d1 copies the monster record into that enemy slot. Then: `type = id` (≥314, which marks it as an ally), **HP = 0, money = 0, exp = 0**, `x = 2 / 0x16`, `centre x = 2s` [V; the value looks like a bug]. `[0x2388]++`.
* **體力 −= 2 × level** (FIG 542f). The amount is deducted here, not re-checked [I: the word can wrap if 體力 dropped since selection].
* In the normal path the inventory slot is cleared (FIG 12d2). The item leaves the inventory for the battle.
* At the next round start `[0x23C4] += [0x2388]` (FIG 3fd), so the ally joins initiative from the **next round**: `rand(+30 luck)+(+32 agility)`, like an enemy.

**Display**: an ally is never drawn as a sprite. The enemy drawer skips HP-0 slots without flag 0x8000 (FIG 3422).
On every redraw FIG 34fa draws a 4-wide name box at (x=0 or 0x14, y=0) with the monster name at (x+2, 9), for slot 0 and slot 1.
Its action banner appears at (ally x, 0x0F).

**Ally turn** (FIG 85a: `type > 9` → FIG f8e). Allies skip the end-of-turn timers (FIG a4f is not called):
1. Caster context = party member 0 (`[0x23AC]=0x11D`, `[0x22D1]=0`, no party pose). Target = a random enemy slot with HP≠0 (retry `rand([0x23C4])`).
2. If `rand(10) <= magic_freq (+48)`: if `rand(10) <= special_freq (+49)`, try special A/B (rand(2)). Otherwise try `rand(3)` = 0 → skill C, 1 → B, 2 → A. A skill id of 0 or too little MP (FIG 237a: `MP(+2A) >= cost`, deducted, power = `rand(ownLevel/2+2)+skill.power`) falls through to the physical attack.
3. A skill that targets self or one ally (+0D & 0x18) → physical attack instead. Otherwise banner 「奇 術」 (DS:200C), then FIG 1106:
   * The skill needs a medium (+0C 0x80/0x40/0x20) that is not on the field (`DS:2378/2376/2374 >= 0x50`): the ally **places that medium** this turn (sprite B0/AF/AE moves to x 3E/44/4A, FIG 50c0). The MP is already spent and no spell is cast. Enemies refund the MP and cast afterwards (FIG 249a); allies do not [V].
   * Otherwise the skill runs through the **party-side** executor FIG 48d0. One-enemy skills (+0D&0x20) hit the target; others hit every living enemy. Damage in anim op 7 is `rand(L0/2+2)+power` with **L0 = member 0's level** (FIG 4ef3, because `[0x23AC]` is member 0). Then wait 5. Effect types are read from the party table (DS:1DBD) [I for non-damage types].
4. Physical attack (FIG 105d): banner 「攻 擊」 (DS:1DFB), attack sfx (+4E). If the target can act and `rand(12) < evasion` → 閃躲. Else `dmg = ally attack (+2C) − target defense`, 0 if the target is physically immune or `atk <= def`. There is **no random term and no critical hit**. If HP ≤ dmg the target dies (FIG 1501).
5. Allies never use the heal skill, never flee or hesitate, and skip status and buff handling.

**Duration and end**: an ally cannot be targeted (enemy AI targets party members; party targeting skips HP 0) and never dies. It stays until the battle ends or it is replaced. The victory check ignores it (HP 0).
At every battle end (victory FIG 5bca, defeat 444, flee 45b → FIG 256) the inventory is compacted. Then for slot 0 and then slot 1: `if [0x3FB]==0: [0x3FB]=id; compact`.
So **the monster comes back to the inventory** (it is not consumed) unless the inventory is full, in which case it is lost [V].
Script op 2C (args `monster, jump_if_both_full`) puts a monster into a free slot without animation or cost. It is returned the same way.

## 5. Field side (RPG), for reference

* Item menu → 煉妖術 (4th entry, hidden while `[0x4F8]&1`), RPG 3e33 → 45bc. 「請再選一樣物品。」 (RPG DS:2E55) asks for a second item. An item with +06&0xC0==0xC0 gives 「這物品無法煉化！」 (DS:2E43).
* The result comes from the recipe table RPG DS:2012 (69 triples `a,b,result` in any order, ends at 0xFFFF). Otherwise a species matrix is used: DS:1CF1 holds the row width, DS:1CF2 the list pointers, indexed by the +22 bytes of both items. The average of their +23 bytes selects the entry from a `(limit,result)` list. RPG 4663..46e7 [V for the structure, the details were not followed].
* A monster result needs its level ≤ leader level + 4, otherwise 「等級不足！無法煉成！」 (DS:2E7F). After the stats are shown and the player confirms, both inputs are consumed and the result takes the second item's slot (RPG 4806) [I for the slot detail].

## 6. Unresolved

* Main-menu bottom label (frames 21/22) and the second flee glyph (frame 30) were not identified from the low-contrast glyphs. 防禦 is identified from the glyph shapes plus the item texts.
* Ally `centre x = 2s` (FIG 541d) seems to be a bug. Its only visible use is the animation anchor `[0x23B2]`.
* Non-damage enemy skills cast by an ally through the party executor (buff, status, media) were not traced.
* Why monsters 522 (+05=0xC0) and 523 (0x80) differ from the other bosses is unknown. Neither is summonable.
