# Story play-through with the explorer

The explorer bot (`--explore=SECONDS`) plays the story on its own, with full
HP/MP ("god" mode) and random choices. Where it cannot find the way, a run can
resume a saved state and follow a plan of targets:

    godot --headless --path game -- --explore=600 --resume=STATE.json \
        --entry=N --plan=KEY,KEY,... --dump=OUT.json [--debug]

- `--resume` loads a state written by `--dump` (also `OUT.best.json`, the state
  with the most story flags); `--entry=N` then jumps to entry point N.
- Plan keys: `E:z:I` = zone I of the scene entered at entry E, `E:o:I` = object I.
  `~E:z:I` matches any entry of the same scene, `:z:I` any scene. Each key waits
  until it is reachable, then is used once.
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

Not yet done: one unbroken run from a new game (the bot still loses time in
the CHNA3 tomb maze and the CHNA6 木人巷), and battles at normal strength.
