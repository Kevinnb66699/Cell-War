#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给 fusion_pixel_10px.ttf 补一个 U+221E（∞）字形。

起因：教程 S4 的台词要写「能量 ∞」，字形覆盖闸 t_font_coverage 当场拦下——
缝合像素 10px 原版 25070 个字形里没有 ∞，也没有 ≈ / ∝ 可以顶替
（2026-09-19 Kevin：「补字形，如果没有相似字形，就用 INF」）。

字形是手画的点阵，规矩照抄同一份字库里的数字与 →（U+2192）：
  * 1000 units/em，一个点阵像素 = 100 units；
  * 每个点亮的像素写成一条顺时针方形轮廓（和数字 0 的写法同向，非零环绕规则下相邻方块自然并成一块）；
  * 全角符号：advance 1000、字面 9 像素宽（x 0..900），和 → / ○ 一档；
  * 纵向 5 像素高、落在 y 100..600 —— 与数字（y 0..700）同基线、视觉居中，和 → 占的是同一条带。

这个脚本改的是二进制资源，**跑一次就够了**，重复跑会在已经有 ∞ 的字体上报错退出。
跑：python tools/add_infinity_glyph.py game/assets/fonts/fusion_pixel_10px.ttf
"""
import sys

from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTFont

CODEPOINT = 0x221E
GLYPH_NAME = "u221E"
PX = 100          # 一个点阵像素占的 units
X0 = 0            # 字面左边缘
Y_TOP = 600       # 最上面一行像素的上边缘

# 9x5 的点阵：两个环在正中交叉（单纯把两个方环拼起来会在中间连成一根竖杠，不像 ∞）
PIXELS = [
    ".##...##.",
    "#..#.#..#",
    "#...#...#",
    "#..#.#..#",
    ".##...##.",
]


def build_glyph():
    pen = TTGlyphPen(None)
    for row, line in enumerate(PIXELS):
        for col, ch in enumerate(line):
            if ch != "#":
                continue
            x, y = X0 + col * PX, Y_TOP - row * PX
            # 顺时针：左上 → 右上 → 右下 → 左下（和 u0030 的方块同向）
            pen.moveTo((x, y))
            pen.lineTo((x + PX, y))
            pen.lineTo((x + PX, y - PX))
            pen.lineTo((x, y - PX))
            pen.closePath()
    return pen.glyph()


def main(path):
    font = TTFont(path)
    if CODEPOINT in font.getBestCmap():
        sys.exit("U+%04X 已经在字库里了，不用再补" % CODEPOINT)

    # 先把这几张表读出来：它们按旧的 numGlyphs 解包，改完字形数再读就会报「数据不够」
    hmtx, vmtx, glyf, post = font["hmtx"], font["vmtx"], font["glyf"], font["post"]

    glyph = build_glyph()
    glyph.recalcBounds(glyf)

    order = font.getGlyphOrder() + [GLYPH_NAME]
    font.setGlyphOrder(order)
    glyf.glyphs[GLYPH_NAME] = glyph
    glyf.glyphOrder = order
    post.glyphOrder = order
    font["maxp"].numGlyphs = len(order)
    hmtx[GLYPH_NAME] = (1000, glyph.xMin)
    # vmtx 的 tsb 在这份字库里恒等于 800 - yMax（数字 100、→ 200、○ 0，都对得上）
    vmtx[GLYPH_NAME] = (1000, 800 - glyph.yMax)
    for sub in font["cmap"].tables:
        sub.cmap[CODEPOINT] = GLYPH_NAME

    font.save(path)
    print("已写入 %s：%s advance=%d bbox=(%d,%d,%d,%d)"
          % (path, GLYPH_NAME, 1000, glyph.xMin, glyph.yMin, glyph.xMax, glyph.yMax))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "game/assets/fonts/fusion_pixel_10px.ttf")
