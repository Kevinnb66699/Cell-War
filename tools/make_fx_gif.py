#!/usr/bin/env python3
"""把 `tests/preview/preview_*.gd` 逐帧倾倒出来的 PNG 合成 GIF —— 给 Kevin / hxr 挑表现用的动图。

仓库里没有 ffmpeg / ImageMagick，Pillow 是现成的，所以拼图这一步走 Python。

出帧（两种预览各自的倾倒口径）：
  godot --path game --script res://tests/preview/preview_tutor_fx.gd -- dump=glitch:jitter out=<目录>
  godot --path game --script res://tests/preview/preview_fx_0919.gd -- fx53 <帧前缀>
合成：
  python tools/make_fx_gif.py <帧目录> <输出.gif> [--fps 12] [--crop x,y,w,h] [--hold 0.6]
  python tools/make_fx_gif.py <帧目录的父目录> <输出目录> --batch
  python tools/make_fx_gif.py --from-prefix <帧前缀> <输出.gif> [--fps …]

（2026-09-19 并了 `tools/make_gif.py`：两支都是「Pillow 拼 GIF」，只差**按目录**还是**按帧前缀**
找帧，外加 `--fps` / `--crop` / `--hold` 三个旋钮。留这一支，那一支删掉。）

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


def _open(files, box):
    if not files:
        raise SystemExit("没有帧")
    ims = [Image.open(f).convert("RGB") for f in files]
    return [im.crop(box) for im in ims] if box else ims


def _frames(d: Path, box):
    fs = sorted(d.glob("*.png"))
    if not fs:
        raise SystemExit("没有帧：%s" % d)
    return _open(fs, box)


def _frames_of_prefix(prefix: Path, box):
    fs = sorted(prefix.parent.glob(prefix.name + "_*.png"))
    if not fs:
        raise SystemExit("没有帧：%s_*.png" % prefix)
    return _open(fs, box)


def make_gif(ims, out: Path, fps: float, hold: float) -> tuple[int, float]:
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
    ms = [int(round((i + 1) * 1000.0 / fps / 10.0) - round(i * 1000.0 / fps / 10.0)) * 10
          for i in range(len(qs))]
    if hold > 0.0:
        ms[-1] += int(round(hold * 100.0)) * 10   # 末帧多停一会儿，循环之间喘口气
    qs[0].save(
        out,
        save_all=True,
        append_images=qs[1:],
        duration=ms,
        loop=0,
        disposal=1,
        optimize=False,
    )
    return len(qs), sum(ms) / 1000.0


def _flag(args, name, cast, default):
    if name not in args:
        return default, args
    i = args.index(name)
    return cast(args[i + 1]), args[:i] + args[i + 2:]


def main() -> None:
    argv = sys.argv[1:]
    batch = "--batch" in argv
    argv = [a for a in argv if a != "--batch"]
    prefix, argv = _flag(argv, "--from-prefix", str, "")
    fps, argv = _flag(argv, "--fps", float, FPS)
    crop, argv = _flag(argv, "--crop", str, "")
    hold, argv = _flag(argv, "--hold", float, 0.0)
    box = None
    if crop:
        x, y, w, h = (int(v) for v in crop.split(","))
        box = (x, y, x + w, y + h)

    if prefix:
        if len(argv) != 1:
            raise SystemExit(__doc__)
        out = Path(argv[0])
        n, secs = make_gif(_frames_of_prefix(Path(prefix), box), out, fps, hold)
        print("%s  %d 帧 / %.2fs / %.1f KB" % (out.name, n, secs, out.stat().st_size / 1024.0))
        return

    if len(argv) != 2:
        raise SystemExit(__doc__)
    src, dst = Path(argv[0]), Path(argv[1])
    jobs = sorted(p for p in src.iterdir() if p.is_dir()) if batch else [src]
    for j in jobs:
        out = (dst / (j.name + ".gif")) if batch else dst
        n, secs = make_gif(_frames(j, box), out, fps, hold)
        print("%s  %d 帧 / %.2fs / %.1f KB" % (out.name, n, secs, out.stat().st_size / 1024.0))


if __name__ == "__main__":
    main()
