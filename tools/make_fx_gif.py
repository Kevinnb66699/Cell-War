#!/usr/bin/env python3
"""把 preview_tutor_fx.gd 逐帧倾倒出来的 PNG 合成 GIF —— 给 Kevin / hxr 挑表现用的动图。

出帧：
  godot --path game --script res://tests/preview/preview_tutor_fx.gd -- dump=glitch:jitter out=<目录>
合成（12 fps、循环）：
  python tools/make_fx_gif.py <帧目录> <输出.gif>
  python tools/make_fx_gif.py <帧目录的父目录> <输出目录> --batch

**调色板是全片共用的一张**：逐帧各量化各的，像素风会一帧一个色、看着糊。
这里先把所有帧拼起来量化一次拿到 256 色，再拿这张调色板去套每一帧，且 dither 关掉
（抖动点阵会把干净的像素块打成噪点）。

Pillow 会把**连着的一模一样的帧合成一张**（时长累加），所以 GIF 里的帧数会少于倒出来的
PNG 数（收尾定格的半秒就是六张一模一样的）—— 播放效果不变，不是丢帧。
"""
import sys
from pathlib import Path

from PIL import Image

FPS = 12.0


def _frames(d: Path):
    fs = sorted(d.glob("*.png"))
    if not fs:
        raise SystemExit("没有帧：%s" % d)
    return [Image.open(f).convert("RGB") for f in fs]


def make_gif(src: Path, out: Path) -> tuple[int, float]:
    ims = _frames(src)
    w, h = ims[0].size
    # 全片共用调色板：把所有帧竖着拼成一张去量化
    tall = Image.new("RGB", (w, h * len(ims)))
    for i, im in enumerate(ims):
        tall.paste(im, (0, i * h))
    pal = tall.quantize(colors=256, method=Image.MEDIANCUT, dither=Image.Dither.NONE)
    qs = [im.quantize(palette=pal, dither=Image.Dither.NONE) for im in ims]
    out.parent.mkdir(parents=True, exist_ok=True)
    # GIF 的帧间隔只能是 10ms 的整数倍，12 fps（83.3ms）对不上——
    # 按累计时间取整分成 80/80/90 的节奏，整段总时长才不偏
    ms = [int(round((i + 1) * 1000.0 / FPS / 10.0) - round(i * 1000.0 / FPS / 10.0)) * 10
          for i in range(len(qs))]
    qs[0].save(
        out,
        save_all=True,
        append_images=qs[1:],
        duration=ms,
        loop=0,
        disposal=1,
        optimize=False,
    )
    return len(qs), len(qs) / FPS


def main() -> None:
    args = [a for a in sys.argv[1:] if a != "--batch"]
    batch = "--batch" in sys.argv[1:]
    if len(args) != 2:
        raise SystemExit(__doc__)
    src, dst = Path(args[0]), Path(args[1])
    jobs = sorted(p for p in src.iterdir() if p.is_dir()) if batch else [src]
    for j in jobs:
        out = (dst / (j.name + ".gif")) if batch else dst
        n, secs = make_gif(j, out)
        print("%s  %d 帧 / %.2fs / %.1f KB" % (out.name, n, secs, out.stat().st_size / 1024.0))


if __name__ == "__main__":
    main()
