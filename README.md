# SWDA Remake：轩辕剑外传：枫之舞 重制工程

这个仓库用原版 DOS 数据重建《轩辕剑外传：枫之舞》（大宇，1995），目标是能长期开发、能打包到 macOS、Windows、Linux 和 Android 的工程。

- `tools/`：Python 提取工具 `swdtools`，把原版数据（LSK、RSK、DSK、VOC、RIX）转成 PNG、JSON、WAV 和 UTF-8 文本
- `game/`：Godot 4.3 工程，用 GDScript 编写，读取提取出来的资源
- `docs/`：文件格式（[FORMATS.md](docs/FORMATS.md)）和架构说明（[ARCHITECTURE.md](docs/ARCHITECTURE.md)）
- `scripts/`：提取和打包脚本

原版游戏数据有版权，仓库里不放原版数据，也不放提取结果。每个开发者用自己的游戏拷贝在本地生成。

## 快速开始

```bash
pip install pillow            # 提取工具只依赖 Pillow
scripts/extract.sh /path/to/swda          # 指向包含 SWDA.EXE 的目录
godot --path game                         # 或者用 Godot 4.3 编辑器打开 game/
```

运行后用方向键移动，用 PageUp / PageDown 切换地图（共 116 张）。

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
