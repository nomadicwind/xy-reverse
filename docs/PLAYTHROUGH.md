# Story play-through with the explorer

The explorer bot (`--explore=SECONDS`) plays the story on its own, with full
HP/MP ("god" mode) and random choices. Where it cannot find the way, a run can
resume a saved state and follow a plan of targets:

    godot --headless --path game -- --explore=600 --resume=STATE.json \
        --entry=N --plan=KEY,KEY,... --dump=OUT.json [--debug]

- `--resume` loads a state written by `--dump` (also `OUT.best.json`, the state
  with the most story flags); `--entry=N` then jumps to entry point N.
- Plan keys: `E:z:I` = zone I of the scene entered at entry E, `E:o:I` = object I.
  `~E:z:I` matches any entry of the same scene, `:z:I` any scene. A key is used
  whenever it is reachable, in plan order, and counts as done once the walk got
  there (an event ran or the party went through that door); a key that can't
  be used yet doesn't hold up the others. `!key` waits for the step just before
  it (for going back to someone after a trip).
- States written by `--dump` keep the plan steps still to do; resuming with
  the same `--plan` goes on from there, so a long run can be split into
  segments without losing its place.
- The run ends with `[explore] the end` when the ending returns to the title.

## Route notes (2026-10-10, chapters 10-16)

Every step below was played through in the engine; free exploring fills the gaps.

| Where | What the story needs | Plan used |
|---|---|---|
| 樹海 (CHNA10) | maze exit only by going round other doorways | `782:z:0,762:z:1,768:z:3,774:z:1,780:z:7,new:512` |
| 許昌客棧 | upstairs, talk to 墨子 | `new:572,572:o:3` |
| 天政 (CHNA14) | examine the hidden switch before leaving | `604:o:0,604:z:1,608:o:1` |
| 享天 | pay the 300 toll to the gate soldier | `516:o:0` |
| world map | 鬼神之塔 entrance | `664:z:3` |
| 鬼神之塔 bridge | 雷神 wants a 疾電符: made with the skills menu 製作 button | `678:o:2,678:z:1` |
| 塔頂 | talk to 塔主, then 天外天 for the 香爐 (boss), back to 塔主 | `698:o:1,698:z:1,802:z:1,806:z:1,810:o:16,810:o:16,698:o:1` |
| 鬼神之塔下 | through the opened wall to 太古封神室 | `~730:z:1,732:z:1,702:z:1,706:z:3,710:o:1` |
| 許昌客棧 | bring 壺中仙 to 鬼谷子 → 機關龍 | `566:o:3` |
| 機關龍 | decks to the 煉妖壺 room, final battle, ending | `820:z:1,824:z:3,828:z:5,832:z:7,836:z:1,840:z:1,844:z:1,848:z:3,852:z:3,856:z:1,860:z:1,864:z:3,868:z:3,872:z:5,876:z:5,880:z:1,884:z:7,888:z:3,892:z:9,896:z:5` |

## Whole game from a new game (2026-10-11)

A new game played to the ending in segments that each resume the last saved
state (no `--entry` jumps). Chapters 1-6 need no plan; from the 大梁宮殿 on:

    436:z:1,!372:z:8,374:z:6,494:z:1,496:z:0,500:z:0,358:z:2,172:z:6,170:z:5,
    502:z:1,230:z:10,504:z:1,782:z:0,762:z:1,768:z:3,774:z:1,780:z:7,new:512,
    new:572,572:o:3,516:o:0,792:z:0,624:z:5,628:z:2,524:z:1,588:z:1,592:z:3,
    596:z:5,794:z:1,798:z:1,600:z:7,604:o:0,604:z:1,608:o:1,678:o:2,~664:z:3,
    678:z:1,730:z:0,694:z:1,698:o:1,698:z:1,802:z:1,806:z:1,810:o:16,!810:o:16,
    !698:o:1,~730:z:1,732:z:1,702:o:0,714:z:1,!702:z:1,706:z:3,710:o:1,!566:o:3,
    (then the 機關龍 decks above)

- 大梁宮殿 (436): the story event is the object zone left of the door
  (zone 1); the door on the right leaves the palace.
- After the 香爐 boss in 天外天, go back to 塔主 before anything else.
- 鬼神之塔下: examine the 墓穴 entrance (702 object 0) before the way to the
  太古封神室 opens.

Not yet done: battles at normal strength (the bot plays with full HP/MP).
