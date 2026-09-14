# -*- coding: utf-8 -*-
"""把几张 PNG 打成一个 Windows .ico（exe 图标）。

用法（仓库根目录）：
    python tools/make_ico.py game/assets/icon/cellwar.ico game/assets/icon/icon_16.png ...

**为什么自己写而不是装个库**：这条格式一共两种结构体，二十行就完；
而多一个 pip 依赖，就多一件「换台机器就跑不起来」的事（这仓库的发版脚本一律只依赖
git / gh / godot / python 标准库）。

**为什么每一档都要自己给图**：Windows 会从 .ico 里挑**最接近**要用的那一档；
挑不到就拿别的缩 —— 而像素画一遇非整数缩放必糊（同棋盘贴图「一律不缩放」那条约定）。
所以 16 / 32 / 48 / 64 / 128 / 256 六档各给一张，其中 16 是重画的（24→16 会把尖刺削没）。

**PNG 直接塞进 ICO** 是 Vista 起就认的写法（旧写法是 BMP + 一条 AND 掩膜）。
这个游戏的最低目标是 Windows 10，所以六档全用 PNG，省掉掩膜那套。
"""
import struct
import sys


def read_png(path):
    """返回 (宽, 高, 原始字节)。宽高直接读 IHDR —— 不解码像素，PNG 原样塞进 ico。"""
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit("不是 PNG：%s" % path)
    w, h = struct.unpack(">II", data[16:24])
    return w, h, data


def build(out_path, png_paths):
    images = [read_png(p) for p in png_paths]
    images.sort(key=lambda im: im[0])
    header = struct.pack("<HHH", 0, 1, len(images))   # 保留位 / 类型 1 = 图标 / 张数
    # 目录项每条 16 字节，全部排在图像数据之前，所以偏移要先把整个目录量出来
    offset = len(header) + 16 * len(images)
    entries = []
    blobs = []
    for w, h, blob in images:
        # 宽高各占一个字节，**256 写作 0**（一个字节放不下 256，格式就是这么规定的）
        entries.append(struct.pack(
            "<BBBBHHII",
            0 if w >= 256 else w,
            0 if h >= 256 else h,
            0,            # 调色板色数：真彩写 0
            0,            # 保留位
            1,            # 色彩平面
            32,           # 位深（RGBA）
            len(blob),
            offset,
        ))
        blobs.append(blob)
        offset += len(blob)
    with open(out_path, "wb") as f:
        f.write(header)
        for e in entries:
            f.write(e)
        for b in blobs:
            f.write(b)
    return images


def verify(path):
    """把刚写出来的文件按格式读回来 —— 自己写的二进制，不回读一遍不算数。"""
    data = open(path, "rb").read()
    reserved, kind, count = struct.unpack("<HHH", data[:6])
    if reserved != 0 or kind != 1:
        raise SystemExit("✘ 头不对：reserved=%d type=%d" % (reserved, kind))
    sizes = []
    for i in range(count):
        off = 6 + 16 * i
        w, h, _, _, _, bpp, nbytes, at = struct.unpack("<BBBBHHII", data[off:off + 16])
        w = w or 256
        h = h or 256
        chunk = data[at:at + nbytes]
        if chunk[:8] != b"\x89PNG\r\n\x1a\n":
            raise SystemExit("✘ 第 %d 档不是 PNG（偏移 %d）" % (i, at))
        pw, ph = struct.unpack(">II", chunk[16:24])
        if (pw, ph) != (w, h):
            raise SystemExit("✘ 第 %d 档目录写 %dx%d，实际是 %dx%d" % (i, w, h, pw, ph))
        sizes.append("%dx%d(%dB)" % (w, h, nbytes))
    return count, sizes


if __name__ == "__main__":
    if len(sys.argv) < 3:
        raise SystemExit("用法：python tools/make_ico.py <输出.ico> <图1.png> [图2.png ...]")
    out = sys.argv[1]
    build(out, sys.argv[2:])
    n, sizes = verify(out)
    # 这台机器的控制台是 GBK，勾号之类的符号会当场抛 UnicodeEncodeError（第一次跑就撞了）
    print("OK %s: %d sizes - %s" % (out, n, " ".join(sizes)))
