# 轩辕剑外传：枫之舞 (SWDA) — 文件格式笔记

来源：用户上传的 xuanyuan.7z（DOSBox 打包版）。游戏本体已复制到 `game/`。

## 运行方式
- `SWDA.EXE` 是启动器（检查 XMS），依次调用 `RPG.EXE`、`FIG.EXE`、`MEO.EXE` 等模块。
- DOSBox 配置在 `game/dosbox-config.conf`：`machine=svga_s3`，`memsize=64`，`mount c .\swda`。

## 可执行文件
| 文件 | 类型 |
|---|---|
| SWDA.EXE | 16 位实模式 MZ，启动器，打开 MAP/SA/CD/DO/VC.LSK |
| RPG.EXE (95 KB) | 16 位实模式 MZ，有 51 个重定位项，主程序（地图和剧情） |
| FIG.EXE (80 KB) | 16 位实模式 MZ，战斗系统（推断） |
| CHNA1..16.EXE | MZ 头大小 512，0 个重定位，CS:IP=0:0。看起来是各章节的脚本/覆盖模块，包含 "CHNAn.DSK"、"MAP1.EXE" 字符串 |
| MAPA/MAP0/ITEM/ITEM2/ORC/MEO/DATE2.EXE | 同样的覆盖模块形式 |
| JS3.EXE | 用 LZEXE 0.91 压缩（摇杆设置工具） |
| INSTALL.EXE, JGAME.EXE | Borland/Turbo C 编译 |

没有 DOS4GW 或其他保护模式扩展器，所以 Ghidra 应该用 `x86:LE:16:Real Mode` 分析。

## 数据文件
### *.LSK：资源包（已确认）
- 文件开头是一张 uint32 小端偏移表。`offs[0]` 等于表的字节长度，所以条目数是 `offs[0]/4 - 1`。最后一个偏移等于文件大小。
- 条目 i 的数据 = `data[offs[i]:offs[i+1]]`。
- MAP.LSK 833 项，DO.LSK 664 项，SA.LSK 450 项，CD.LSK 587 项。
- 条目本身是压缩的，见下面的 "压缩块"。（SA.LSK 里有极少数 2 字节的条目没有压缩头）
- 工具：`tools/lsk.py`

### 压缩块（LSK 条目和 *.RSK 共用，已破解）
- 头部：`u16 解压后大小, u8 方法`。方法为 0 表示未压缩，非 0 表示 LZH，比特流从第 4 个字节开始。
- 算法来自 RPG.EXE 的远过程 0AF8:38AC，是 LHA -lh5- 风格的静态 Huffman 加 LZ77。参数：NT=19/TBIT=5，NC=510/CBIT=9，NP=17/PBIT=5，每个块前面有 16 位块大小，直接从输出缓冲区回拷（不用环形缓冲），距离等于 p+1。
- 实现在 `tools/swdlzh.py` 的 `decompress()`。4 个 LSK 包的 2534 个条目和 45 个 RSK 全部解压成功，大小都和头部声明一致。

### u16 偏移表容器（解压后常见）
- 和 LSK 一样，只是偏移是 u16：`offs[0]` 等于表的字节长度。实现在 `split_offsets16()`。

### 图片块（战斗背景 BA/*.RSK、DO.LSK、CD.LSK 等）
- 结构是 `u16 h, u16 w`，后面要么是原始 w*h 字节，要么是 `"NT"` 加 RLE。
- RLE 按 Mode X 平面逐行编码：`FF` 结束一行（w/4 像素），`80|n` 后面跟 n 个字面字节，`n<80` 表示把下一个字节重复 n 次。所有行按平面优先排列（先存平面 0 的全部行，再存平面 1，依此类推）。
- `FE` 是精灵的透明色。实现在 `decode_pic()`。
- BA*.RSK 是 `[图片, 调色板]`，调色板是 3 字节头加 768 字节，每个分量 6 位（0-63）。

### MAP.LSK：地图（已破解，可以拼出整张地图）
每张地图占 7 个条目（833 = 7 × 119）：
0. 调色板：u16，后面是 768 字节 6 位 RGB，再后面是 1072 字节未知数据（可能是图块属性）
1-4. 图块的 4 个 Mode X 平面。第 k 个条目是平面 k，每个 8x8 图块占 16 字节（8 行 × 2 字节）。像素 (x,y) = `plane[x%4][t*16 + y*2 + x//4]`
5. 地图格子：u16 偏移表，chunk0 是 `u16 h, u16 w` 加上 h*w 个 u16。低 11 位是图块号，高位是标志（通行和遮挡，待确认）
6. 物件和事件列表（u16 三元组，还没解析）
- 示例输出：`out/map00_world.png`（野外 120×120 格），`out/map01_town.png`（城镇 220×120 格）。工具：`tools/extract_demo.py`

### *.DSK：剧情文本（已确认）
- 直接是 Big5 编码的繁体中文文本，开头是脚本用的人名和词表（"指令檔巨集定義" "公輸般" "西門豹" ...），后面是对白。
- 和同名 CHNAn.EXE 配对使用。

### *.RIX：音乐（已确认）
- 头 `AA 55`，是 Softstar 的 RIX OPL2/AdLib 音乐格式，AdPlug 能直接播放（libadplug 有 RIX 播放器）。

### *.VOC：音效（已确认）
- 标准 Creative Voice File，8 位 PCM，可以直接转 WAV。

### MENU.PIC
- 开头像 RGB 调色板（每个分量 0-255），后面是图像数据，可能是 RLE，待确认。

### SAVE/*.ZA?
- SAVE.ZAn 1665 字节，`$$` + Big5 名字 + `$$`，后面是 u16 字段。MAPZ.ZAn 65514 字节。

## 注意
- RPG.EXE 引用了 MAN1.RSK、BMAN1-6.RSK、NAME.DSK，但这个包里没有这些文件。可能放在 LSK 里，也可能这个包不完整。
