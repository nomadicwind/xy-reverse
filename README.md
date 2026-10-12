# SWDA Remake：轩辕剑外传：枫之舞 重制工程

这个仓库用原版 DOS 数据重建《轩辕剑外传：枫之舞》（大宇，1995），目标是能长期开发、能打包到 macOS、Windows、Linux 和 Android 的工程。

- `tools/`：Python 提取工具 `swdtools`，把原版数据（LSK、RSK、DSK、VOC、RIX）转成 PNG、JSON、WAV 和 UTF-8 文本
- `game/`：Godot 4.3 工程，用 GDScript 编写，读取提取出来的资源
- `docs/`：文件格式（[FORMATS.md](docs/FORMATS.md)）和架构说明（[ARCHITECTURE.md](docs/ARCHITECTURE.md)）
- `scripts/`：提取和打包脚本

原版游戏数据有版权，仓库里不放原版数据，也不放提取结果。每个开发者用自己的游戏拷贝在本地生成。

## 快速开始

```bash
pip install pillow PyOPL      # PyOPL 用来渲染背景音乐，不装就没有音乐
scripts/extract.sh /path/to/swda          # 指向包含 SWDA.EXE 的目录
godot --path game                         # 或者用 Godot 4.3 编辑器打开 game/
```

装了 ffmpeg 的话，音乐会压成 OGG（约 16 MB），否则存成 WAV。

操作：方向键移动，Enter / 空格调查和确认，Esc 打开菜单或返回。

测试用的命令行参数（写在 `--` 之后）：`--newgame`、`--entry=N`、`--battle=N`、`--event=N`、`--autoplay=文件`、`--vmtest=all`，说明见 `game/scripts/main.gd`。

## 测试

```bash
cd tools && pip install -e '.[test]'
pytest                         # 只跑格式单元测试
SWDA_GAME=/path/to/swda pytest # 加上对真实数据的完整校验
```

## 打包

先在 Godot 里安装 4.3 的导出模板，然后运行：

```bash
scripts/export.sh macOS      # 也可以是 Windows / Linux / Android
```

Android 还需要 Android SDK 和签名密钥，在 Godot 的编辑器设置里配置。

### macOS 试玩包

CI 的 `export-macos` 任务会打一个只含引擎、不含游戏数据的包（Actions 页面里的 `SWDA-macos` 附件）。数据用自己的原版游戏提取：

```bash
unzip SWDA-macos.zip -d ~/Games/SWDA          # 得到 SWDA Remake.app
EXTRACT_OUT=~/Games/SWDA/data scripts/extract.sh /path/to/swda
```

游戏会在 .app 旁边的 `data/engine` 找数据。这个包没有经过 Apple 公证，第一次打开要在 Finder 里右键选“打开”，或者运行 `xattr -dr com.apple.quarantine ~/Games/SWDA/SWDA\ Remake.app`。
