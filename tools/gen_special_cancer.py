# -*- coding: utf-8 -*-
"""把特殊组织的癌变贴图**重新压到普通癌组织那块红底上**（Kevin 2026-09-14）。

## 为什么

癌变的特殊组织此前每种自带一套底色：代谢核心 #c16271（偏亮的红）、骨髓 #a03984（洋红），
于是同样是「癌组织」，核心那格和旁边的普通癌组织一眼看着不是一回事。Kevin：
「现在代谢核心被癌化后，地块颜色和普通癌组织不一样，请修复！」——
**癌化只换底，不换图标**：底色一律用 tissue_cancer 的那三档，图标（闪电 / 骨头 / 血管菱形）
保持健康版的颜色原样不动。

血管（vessel_cancer）本来就是这么画的，底色已经是 #b04a5a；拿它当**对照**验算法：
这个脚本跑出来的血管癌变版应当和美术那张几乎逐像素相同（见 --check 的输出）。

## 算法：按「含底量」平移

地块只有三个区（顶面 + 两个侧面），每区一个底色；图标只出现在顶面。
把每个像素看成「底色和图标色的混合」：

    out = p + (1 - t) * (新底 - 旧底)        t = 这个像素里图标占多少

t 由 p 在「旧底 → 图标色」这条线上的投影得到。于是：
· 纯底像素（t=0）精确变成新底；
· 纯图标像素（t=1）**一个比特都不动**；
· 边缘抗锯齿那几个混合像素，按原来的混合比重新压到新底上（不这么做会在红底上留一圈绿/紫毛边）。

区的划分直接借 tissue_normal / tissue_cancer：所有地块共用同一个六边形，
同一坐标上 tissue_normal 是哪一区、tissue_cancer 就给出那一区的新底色。

## 顺带重推「积累进度外圈」的暗槽

外圈两张贴图里，**亮圈**（core_lit / marrow_lit）健康版和癌变版本来就同色
（核心都是 #3f9d5f、骨髓都是 #b07fe0）—— 那一半从来没随癌化变过色。
变的是底下那圈**暗槽**，而它满足一条逐字节成立的关系：

    暗槽 = lerp(该地块的顶面底色, 亮圈, 0.30)

四对（核心/骨髓 × 健康/癌变）全部命中，其中三对逐字节相等、一对差 1（作者当时取的整）。
底色一换，暗槽必须跟着换 —— 否则红底上会留一圈上一版底色的褐/洋红。
健康那两张**当对照在脚本里重算一遍**：规则哪天不成立了，这里当场断言失败。

## 顺带重推骨髓的另外两档

marrow_empty_cancer（空仓：骨头淡到 35%）从新的 marrow_cancer 推出来 ——
「哪些像素是骨头」由 marrow_empty_normal 和 marrow_normal 的差集给出，
不猜阈值。跑完还要再跑 gen_marrow_pending.py（第三档）和 gen_solid_tissue.py（固化族）。

## 用法（仓库根目录）

    python tools/gen_special_cancer.py
    python tools/gen_special_cancer.py --check    # 只比对、不落盘
    godot --headless --path game --import         # 换了贴图必须重导一次
"""
import argparse
import os
from collections import Counter

from PIL import Image

ART = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "game", "assets", "art")
KEEP = 0.35          # 空仓那档骨头保留的比例（沿用 2026-09-08 定的值，见 board.gd 文件头）
ANCHOR_MIN = 20      # 出现这么多次才算「图标色」，低于它的是抗锯齿杂点
ANCHOR_FAR = 40      # 离底色这么远才算图标色（曼哈顿距离，够把近底色的杂点挡在外面）
RING_MIX = 0.30      # 暗槽里掺多少亮圈色（从四对现成贴图反推出来的，见文件头）
TOP_FACE_H = 26      # 顶面六边形占 y 0..25（同 store_progress.gdshader 的口径）

## 健康版 -> 癌变版。血管的健康版没有 _normal 后缀（历史原因，见 board.gd）
PAIRS = [("energy_normal", "energy_cancer"),
         ("marrow_normal", "marrow_cancer"),
         ("vessel", "vessel_cancer")]
## 外圈：环名 -> 它画在哪种地块上（用来取底色）。血管没有积累进度，不在表里
RINGS = [("core", "energy_normal"), ("marrow", "marrow_normal")]
STORE = os.path.join(ART, "ui", "store")


def load(name, root=None):
    return Image.open(os.path.join(root or ART, name + ".png")).convert("RGBA")


def top_ground(im):
    """顶面出现最多的那个颜色就是底色"""
    c = Counter(im.getpixel((x, y)) for y in range(TOP_FACE_H) for x in range(im.width)
                if im.getpixel((x, y))[3] > 0)
    return c.most_common(1)[0][0][:3]


def region_map(ref):
    """坐标 -> 区号。区 = tissue_normal 上的颜色，它只有三个（顶面 + 两个侧面）"""
    return {(x, y): ref.getpixel((x, y)) for y in range(ref.height) for x in range(ref.width)}


def reground(src, ref_h, ref_c):
    """把 src（健康版特殊地块）的底色换成 ref_c 的，图标原样保留"""
    reg = region_map(ref_h)
    out = src.copy()
    by_region = {}
    for (x, y), r in reg.items():
        if src.getpixel((x, y))[3] > 0:
            by_region.setdefault(r, []).append((x, y))
    for r, cells in by_region.items():
        count = Counter(src.getpixel(p) for p in cells)
        g_h = count.most_common(1)[0][0]
        g_c = ref_c.getpixel(cells[0])
        ## 这一区的图标色：够多、且离底色够远的那个。顶面有一个，侧面一个也没有
        far = [c for c, n in count.items()
               if n >= ANCHOR_MIN and sum(abs(a - b) for a, b in zip(c[:3], g_h[:3])) >= ANCHOR_FAR]
        assert len(far) <= 1, "区 %s 认出 %d 个图标色，脚本只支持一个" % (g_h, len(far))
        icon = far[0] if far else None
        axis = [i - g for i, g in zip(icon[:3], g_h[:3])] if icon else None
        span = sum(a * a for a in axis) if axis else 0
        shift = [c - h for c, h in zip(g_c[:3], g_h[:3])]
        for p in cells:
            px = src.getpixel(p)
            t = 0.0
            if span:
                t = sum(a * (v - g) for a, v, g in zip(axis, px[:3], g_h[:3])) / float(span)
                t = min(1.0, max(0.0, t))
            out.putpixel(p, tuple(min(255, max(0, int(round(v + (1.0 - t) * s))))
                                  for v, s in zip(px[:3], shift)) + (px[3],))
    return out


def reblend_track(lit, track, ground):
    """按 RING_MIX 把暗槽重新压到 ground 上。**只动环身**（不透明那 156 个像素）——
    四张外圈共用同一圈近透明毛边，那圈是形状的一部分，不该跟着底色走"""
    out = track.copy()
    for y in range(track.height):
        for x in range(track.width):
            t = track.getpixel((x, y))
            if t[3] != 255:
                continue
            l = lit.getpixel((x, y))
            out.putpixel((x, y), tuple(int(round(g + (c - g) * RING_MIX))
                                       for c, g in zip(l[:3], ground)) + (255,))
    return out


def fade_bone(src, bone):
    """空仓：把骨头那些像素朝**本图**的顶面底色混到 KEEP"""
    top = Counter(src.getpixel((x, y)) for y in range(26) for x in range(src.width)
                  if src.getpixel((x, y))[3] > 0)
    ground = top.most_common(1)[0][0]
    out = src.copy()
    for p in bone:
        px = src.getpixel(p)
        out.putpixel(p, tuple(int(round(g + (c - g) * KEEP))
                              for c, g in zip(px[:3], ground[:3])) + (px[3],))
    return out


def build():
    ref_h, ref_c = load("tissue_normal"), load("tissue_cancer")
    made = [(cancer, reground(load(healthy), ref_h, ref_c)) for healthy, cancer in PAIRS]
    ## 骨头的位置：健康版「有卡」和「空仓」差在哪几个像素，那几个就是骨头
    mn, me = load("marrow_normal"), load("marrow_empty_normal")
    bone = [(x, y) for y in range(mn.height) for x in range(mn.width)
            if mn.getpixel((x, y)) != me.getpixel((x, y))]
    new_marrow = dict(made)["marrow_cancer"]
    made.append(("marrow_empty_cancer", fade_bone(new_marrow, bone)))

    ## 外圈暗槽。先拿健康那两张验规则，再按新底色算癌变那两张
    ground_c = top_ground(ref_c)
    rings = []
    for ring, tile in RINGS:
        lit_h, trk_h = load(ring + "_lit_normal", STORE), load(ring + "_track_normal", STORE)
        redo = reblend_track(lit_h, trk_h, top_ground(load(tile)))
        assert redo.tobytes() == trk_h.tobytes(),             "%s_track_normal 复现不出来：暗槽不再是 lerp(底色, 亮圈, %.2f)" % (ring, RING_MIX)
        lit_c, trk_c = load(ring + "_lit_cancer", STORE), load(ring + "_track_cancer", STORE)
        rings.append((ring + "_track_cancer", reblend_track(lit_c, trk_c, ground_c)))
    return made, rings, len(bone)


def diff(a, b):
    return sum(1 for y in range(a.height) for x in range(a.width)
               if a.getpixel((x, y)) != b.getpixel((x, y)))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只比对、不落盘")
    args = ap.parse_args()
    items, rings, n_bone = build()
    ## 这台机器的控制台是 GBK，中文和勾号会当场抛 UnicodeEncodeError（make_ico.py 同一个坑）
    print("bone pixels: %d" % n_bone)
    for root, group in ((ART, items), (STORE, rings)):
        for name, im in group:
            d = diff(load(name, root), im)
            print("%-22s %5d px differ%s" % (name, d, "" if args.check else "  -> written"))
            if not args.check:
                im.save(os.path.join(root, name + ".png"))
