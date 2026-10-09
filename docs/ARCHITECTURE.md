# 架构

## 技术选型：Godot 4 + GDScript，资源用 Python 预处理

| 需求 | 选择的理由 |
|---|---|
| 改写剧情和战斗 | Godot 有场景编辑器和脚本热重载，剧情和战斗都能写成数据（JSON/资源文件）加脚本，不用改引擎 |
| 跨平台打包 | 一份工程直接导出 macOS（通用二进制）、Windows、Linux、Android、iOS 和 Web |
| 长期维护 | MIT 许可，没有授权费，社区大；2D 图块地图（TileMapLayer）、动画、音频都是内置功能 |
| 还原原版 | 原版分辨率 320×200，用整数缩放保持像素风；渲染器选 GL Compatibility，老设备和手机都能跑 |

也考虑过另一个方案：像 SDLPAL 那样用 C++ 和 SDL2 重写引擎。它最忠实于原版、体积也最小，但改剧情和战斗都要写 C++，做 UI 和移动端适配的工作量大得多。如果以后需要一个高度忠实的"原版模式"，可以在 Godot 里用 GDExtension 接入 C++ 模块。

## 数据流

```
原版数据 (SWDA.EXE 所在目录)
   │  tools/swdtools  (Python，离线运行)
   ▼
game/assets/extracted/      ← 被 gitignore，每个人在本地生成
   maps/map_NNN/tileset.png, map.json, objects.bin
   battle/BAxx.png   sprites/DO|CD/*.png   text/*.txt   sfx/*.wav   music/*.rix
   │  Godot 导入
   ▼
game/ (GDScript)
   scripts/map_loader.gd  → TileMapLayer
   data/story, data/battle  → 我们自己写的剧情和战斗数据（进版本库）
```

原版资源和"我们自己的数据"分开存放：`assets/extracted` 只做原版素材的只读镜像，改写的剧情、平衡性和新内容都放在 `game/data/`。以后要替换美术时，只需要换掉提取目录。

## 路线图

1. **资源层**（已完成大部分）：压缩、图片、地图图块和格子、战斗背景、精灵、文本、音效
2. **地图层**：解析地图格子的标志位（通行和遮挡）、物件表（地图第 6 项）、NPC 和出入口
3. **剧情层**：逆向 CHNA*.EXE 的脚本指令集，配合 DSK 文本，转成 `data/story/*.json`，再写一个 GDScript 事件解释器
4. **战斗层**：从 FIG.EXE 逆向数值和公式，转成 `data/battle/*.json`，用 Godot 重写战斗场景
5. **音频**：RIX（AdLib）先离线渲染成 OGG（用 AdPlug），或者以后接入 OPL 模拟器做实时播放
6. **移动端**：触控操作、UI 缩放、存档放到 user://

## 发布时的版权

可以公开分发的只有代码和 `game/data/` 里的原创数据。如果要做给其他玩家用的版本，需要让玩家提供自己的原版数据。可以考虑把提取器移植到 GDScript，在首次运行时导入数据，这样 Android 上也能用。
