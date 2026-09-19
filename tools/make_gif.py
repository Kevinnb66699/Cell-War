#!/usr/bin/env python3
"""把 `tests/preview/preview_*.gd` 连拍出来的 PNG 序列拼成动图（GIF）。

**为什么要有这个**：2026-09-19 的三条表现 issue（#48 能量飘字、#52 固化生成、#53 特效八条）
全是「动起来才看得出对不对」的东西 —— 粒子从哪儿发出、图层压在谁上面、血门是躺着还是立着，
一帧静态图说明不了问题。Kevin 要的就是动图。

仓库里没有 ffmpeg / ImageMagick，Pillow 是现成的，所以拼图这一步走 Python。
**最近邻缩放、不抖动**：像素风一旦被重采样或 dither，看到的就不是引擎画出来的那张图了。

用法：
    python tools/make_gif.py --in <帧前缀> --out <输出.gif> [--fps 20] [--crop x,y,w,h]
例：
    python tools/make_gif.py --in /tmp/frames/energy --out 能量增损.gif --fps 20
"""
import argparse
import glob
import os
import sys

from PIL import Image


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="prefix", required=True, help="帧前缀（会去找 <前缀>_*.png）")
    ap.add_argument("--out", dest="out", required=True)
    ap.add_argument("--fps", type=float, default=20.0)
    ap.add_argument("--crop", default="", help="x,y,w,h —— 只取画面里的一块")
    ap.add_argument("--hold", type=float, default=0.0, help="末帧多停几秒（循环之间喘口气）")
    args = ap.parse_args()

    paths = sorted(glob.glob(args.prefix + "_*.png"))
    if not paths:
        print("找不到帧：%s_*.png" % args.prefix, file=sys.stderr)
        return 1

    box = None
    if args.crop:
        x, y, w, h = (int(v) for v in args.crop.split(","))
        box = (x, y, x + w, y + h)

    frames = []
    for p in paths:
        im = Image.open(p).convert("RGB")
        if box:
            im = im.crop(box)
        # 逐帧各自量化会让调色板每帧跳一次（像素风上很显眼）—— 统一用第一帧的palette
        frames.append(im)
    base = frames[0].quantize(colors=255, method=Image.MEDIANCUT)
    quantized = [f.quantize(palette=base, dither=Image.NONE) for f in frames]

    ms = int(round(1000.0 / args.fps))
    durations = [ms] * len(quantized)
    if args.hold > 0.0:
        durations[-1] = ms + int(args.hold * 1000)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".", exist_ok=True)
    quantized[0].save(args.out, save_all=True, append_images=quantized[1:],
                      duration=durations, loop=0, optimize=True, disposal=2)
    size_kb = os.path.getsize(args.out) / 1024.0
    print("%s：%d 帧 %dms/帧 %.0f KB" % (args.out, len(quantized), ms, size_kb))
    return 0


if __name__ == "__main__":
    sys.exit(main())
