# -*- coding: utf-8 -*-
"""推出骨髓「进度到头、卡还没结算」那一档的贴图（Kevin 2026-09-11）。

骨髓癌化后产卡周期从 3 缩到 2：攒到 2/3 的格子瞬间变成 2/2，进度环满了、卡却要等下一个 S 阶段才有。
那一档的格子要「进度条和卡牌都变淡」—— 环由 shader 淡（CWBoard.set_store 的 pending），
图标由这两张贴图淡：拿**空仓**那对（marrow_empty_*）把整个图标（框 + 骨头）再淡到 35%。
35% 沿用空仓骨头的那一档（2026-09-08 三档里试出来的）。

图标像素怎么认：顶面（y ≤ 25）里比底色**亮**的像素 —— 框和骨头都是亮色，
深色轮廓和侧面不动。底色 = 顶面出现最多的那个颜色。

用法（仓库根目录）：
    python tools/gen_marrow_pending.py                 # 写 assets/art/marrow_pending_{normal,cancer}.png
    python tools/gen_marrow_pending.py --preview p.png # 顺带出一张三态对照图（6x）

美术要重画直接换那两个文件，代码不用动。
"""
import argparse
import os
from collections import Counter

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ART = os.path.join(HERE, "..", "game", "assets", "art")
KEEP = 0.35          # 图标保留的比例（其余往底色混）
TOP_FACE_H = 26      # 顶面六边形占 y 0..25（同 store_progress.gdshader 的口径）
LUMA_MARGIN = 8      # 比底色亮多少才算图标；顶面上还有两三个近底色的杂点，不该碰


def luma(p):
    return 0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2]


def fade_icon(src):
    im = src.convert("RGBA")
    top = Counter(im.getpixel((x, y)) for y in range(TOP_FACE_H)
                  for x in range(im.width) if im.getpixel((x, y))[3] > 0)
    ground = top.most_common(1)[0][0]
    out = im.copy()
    n = 0
    for y in range(TOP_FACE_H):
        for x in range(im.width):
            p = im.getpixel((x, y))
            if p[3] == 0 or luma(p) <= luma(ground) + LUMA_MARGIN:
                continue
            out.putpixel((x, y), tuple(int(round(g + (c - g) * KEEP)) for c, g in zip(p[:3], ground[:3])) + (255,))
            n += 1
    return out, n


def gen_all():
    made = []
    for kind in ("normal", "cancer"):
        src = Image.open(os.path.join(ART, "marrow_empty_%s.png" % kind))
        out, n = fade_icon(src)
        p = os.path.join(ART, "marrow_pending_%s.png" % kind)
        out.save(p)
        made.append((p, n))
    return made


def preview(path, scale=6):
    from PIL import ImageDraw
    cols = ["marrow_%s", "marrow_empty_%s", "marrow_pending_%s"]
    cv = Image.new("RGB", (60 + 3 * 40 * scale, 40 + 2 * 44 * scale), (20, 27, 31))
    d = ImageDraw.Draw(cv)
    for r, kind in enumerate(("normal", "cancer")):
        for c, name in enumerate(cols):
            im = Image.open(os.path.join(ART, (name % kind) + ".png")).convert("RGBA")
            im = im.resize((im.width * scale, im.height * scale), Image.NEAREST)
            x, y = 30 + c * 40 * scale, 30 + r * 44 * scale
            cv.paste(im.convert("RGB"), (x, y), im)
            d.text((x, y - 14), (name % kind), fill=(200, 210, 220))
    cv.save(path)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview", help="另存一张三态对照图")
    args = ap.parse_args()
    for p, n in gen_all():
        print("wrote %s (%d icon px faded)" % (os.path.relpath(p), n))
    if args.preview:
        preview(args.preview)
        print("preview:", args.preview)
