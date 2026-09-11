# -*- coding: utf-8 -*-
"""生成「固化计数」的地块贴图族（结晶核扩散，Kevin 2026-09-09 选定）。

固化癌组织此前**没有美术**，靠 CWMatch.MARK_SOLID(#0000004d) 压暗一档顶着；
中间计数（0.5 / 1.0 / 1.5）更是完全看不出来。这里一次把整族烘出来。

## 算法：结晶核扩散

每格取 2 个结晶核，石化顺序 = 到最近核的距离 + 柏林噪声扰动。
钙化在现实里就是从几个核往外长的，图案也因此天然「长」而不是「铺」。

对比过的另外三种（预览图见 `--preview`）：
· **柏林噪声** —— Kevin 最初点名的。在 32px 上输了：它平滑且各向同性，
  缩到 576px 的顶面就散成雪花点。**结构能扛住缩小，噪声不能。**
· **Worley F2-F1** —— 裂纹网络，1x 下最好读，但团队要的是「长石头」不是「裂开」。
· **8x8 有序抖动** —— 棋盘格花纹，且 127 格同一张图，平铺感一眼看穿。

## 三个让它在真机尺寸下读得出来的处理

1. **排名阈值，不是数值阈值** —— 同一张场取名次前 f 比例的像素。
   于是高档必然是低档的**超集**：计数涨了图案只会长，不会重新洗牌；
   衰减 −0.5 掉回去就是同一族图倒着放。
2. **覆盖率非线性**（16 / 38 / 66 / 100%）—— 线性 25/50/75/100 会让
   0.5 和 1.0 在 1x 下都只是「有点白」，分不开。
3. **深色轮廓** —— 石块最外一圈压成 STONE_EDGE。像素画里让形状读得出来的就是这一圈；
   没有它，结晶核在 1x 下只是一摊糊。**这三处里最要紧的一处。**

核**往中心收**（BIAS）：贴边的核只能长出「被格子边切掉一半」的石头，形状读不出来。

## 满档 2.0 为什么顶面铺满、侧面留 15%

固化是**离散状态**（【裂解】和癌方【复活】只对它生效），1.5 和 2.0 必须一眼分得开，
所以顶面一点红都不留 ——「顶面还有红 = 还在数，顶面全石 = 已固化」是条硬边界。
侧面留一道红，固化格才仍读得出是**癌**组织而不是中立石头。

## 用法

    python tools/gen_solid_tissue.py                 # 烘资产到 assets/art/solidify/
    python tools/gen_solid_tissue.py --preview p.png # 顺带出一张对照图

生成后要跑一次 `godot --headless --path game --import`，否则 Godot 认不出新资源。
"""
import argparse
import os
import zlib

import numpy as np
from PIL import Image

ART = "game/assets/art"
OUT = os.path.join(ART, "solidify")

# 侧面在**所有**地块上都是这两个绝对色（顶面才按种类不同），所以石色也用同一套明度比
SIDE_M, SIDE_D = (123, 51, 63), (79, 33, 40)
SHADE = {"top": 1.0, "mid": 0.70, "dark": 0.45}

# 2026-09-11（issue #15，团队要的「固化的纹理改为深红色，而不是现在的白垩色」）：
# 石头换成深绯，比癌组织的红（176, 74, 90）更暗更饱和，三档明度关系与白垩版一样 —— 轮廓仍是最暗的那圈
STONE_HI = (168, 48, 58)      # 结晶核心
STONE = (128, 22, 34)         # 石身
STONE_EDGE = (58, 8, 16)      # 轮廓：比石头和红肉都暗，靠明度把形状抠出来

# 计数 -> 覆盖率。前三档**三个面一起排名、一刀切** ——
# 那是「石化锋面卷过棱边」的来源（2026-09-09 改成三维连续之后）。
#
# 满档（20）**不走那一刀**：顶面直接铺满，侧面按侧面内部的名次留一道红。
#
# ⚠ 上一版满档只是把全局排名切在 0.94，注释写着「最后石化的必然是侧面底部
# （核放在顶面那一层，侧面像素在三维里离得最远），所以红缝正好落在老设计想要的位置」——
# **那个推断是错的**。核往中心收（BIAS=0.55），顶面最外那两个尖角（|wx|≈16）
# 在三维里比上半截侧面还远，于是那 6% 的红有一部分留在了**顶面**上：
# 满档的格子边上一圈粉，看着还在数（HXR-I 2026-09-10 报，issue #10）。
# 「顶面还有红 = 还在数，顶面全石 = 已固化」是条硬边界，不能靠推断，得直接铺满。
COVER = {5: 0.16, 10: 0.38, 15: 0.66, 20: 0.94}
TOP_FULL_AT = 20        # 到这一档顶面一点红都不留
SIDE_KEEP = 0.86        # 同一档侧面留下的石化比例：剩下的红让固化格仍读得出是**癌**组织
HI_SHARE = 0.30

SEEDS, WARP, FREQ, BIAS = 2, 0.14, 9.0, 0.55


def seed_of(name, variant):
    """(地块种类, 变体号) -> 稳定种子。

    ⚠ **不要用内置 `hash()`** —— 它对字符串加了每进程随机盐（PYTHONHASHSEED），
    同一份代码每次重跑会出不同的图，仓库里就会不断堆无意义的二进制 diff。
    crc32 跨进程、跨版本、跨平台都一样。"""
    return zlib.crc32(("%s/%d" % (name, variant)).encode("utf-8"))

# 血管不可固化（CWTissue.solidifiable），所以不生成。
# 核心与骨髓散布在棋盘各处、互不相邻，一个变体够用；普通癌组织成片固化，要 4 个换着来。
BASES = {"tissue_cancer": 4, "energy_cancer": 1, "marrow_cancer": 1,
         "marrow_empty_cancer": 1}


def _fade(t):
    return t * t * t * (t * (t * 6 - 15) + 10)


def perlin(shape, freq, rng):
    """柏林梯度噪声（不是插值随机值）。这里只当扰动用，不单独做纹理。"""
    gy = int(np.ceil(shape[0] * freq)) + 1
    gx = int(np.ceil(shape[1] * freq)) + 1
    ang = rng.uniform(0, 2 * np.pi, (gy + 1, gx + 1))
    gvx, gvy = np.cos(ang), np.sin(ang)
    yy, xx = np.meshgrid(np.arange(shape[0]) * freq, np.arange(shape[1]) * freq,
                         indexing="ij")
    y0, x0 = yy.astype(int), xx.astype(int)
    fy, fx = yy - y0, xx - x0

    def dot(iy, ix):
        return gvy[y0 + iy, x0 + ix] * (fy - iy) + gvx[y0 + iy, x0 + ix] * (fx - ix)

    u, v = _fade(fx), _fade(fy)
    a = dot(0, 0) * (1 - u) + dot(0, 1) * u
    b = dot(1, 0) * (1 - u) + dot(1, 1) * u
    return a * (1 - v) + b * v


# 顶面是个**压扁的六边形**：图里横向半径 16px、纵向半径 13px。
# 把纵向除回去，顶面就还原成正六边形 —— 三维里的距离才是各向同性的，
# 不然石头会被拉成椭圆。
SQUASH = 13.0 / 16.0


def face_world(base_img, faces):
    """每个面像素在**三维**里的位置 (wx, wy, wz)，单位 = 顶面像素。

    这是「三个面连成一体」的关键（Kevin 2026-09-09：要保持三个面的连续性）。
    此前顶面和两个侧面各排各的名，等于三张互不相干的图，棱边处对不上。

    · 顶面：wz = 0，(wx, wy) 由图像坐标还原压扁得到
    · 侧面：它挂在顶面某条下边缘的正下方 —— 取**同一列**最上面那个侧面像素，
      它正上方就是顶面的边缘点；侧面继承那个点的 (wx, wy)，往下走多少就是 -wz。
      这样棱边两侧的世界坐标**连续**，石头自然卷过去。
    """
    h, w = base_img.shape[:2]
    cx, cy = (w - 1) / 2.0, 12.5      # 顶面中心（顶面占 y 0..25）
    pos = {}
    for src, _k, kind in faces:
        m = np.all(base_img[:, :, :3] == np.array(src, np.uint8), axis=2)
        ys, xs = np.where(m)
        if ys.size == 0:
            continue
        if kind == "top":
            pos[src] = (m, xs - cx, (ys - cy) / SQUASH, np.zeros_like(xs, float))
            continue
        top_y = {int(x): int(ys[xs == x].min()) for x in np.unique(xs)}
        seam = np.array([top_y[int(x)] - 1 for x in xs], float)   # 正上方那个顶面像素
        pos[src] = (m, xs - cx, (seam - cy) / SQUASH, -(ys - seam))
    return pos


def order3d(pos, rng):
    """石化顺序（值小的先）：到最近结晶核的三维距离 + 柏林扰动。

    核放在顶面那一层（wz≈0）——石化是从表面开始的，不是从块心。
    往中心收（BIAS）的理由同二维版：贴边的核只能长出被切掉一半的石头，形状读不出来。
    """
    r = 16.0
    seeds = []
    for _ in range(SEEDS):
        a = rng.uniform(0, 2 * np.pi)
        d = r * (1.0 - BIAS) * np.sqrt(rng.uniform(0, 1))
        seeds.append((d * np.cos(a), d * np.sin(a), rng.uniform(-1.0, 1.0)))
    warp = perlin((34, 32), 1.0 / FREQ, rng)      # 一张扰动图，按图像坐标取样即可
    out = {}
    for src, (m, wx, wy, wz) in pos.items():
        dist = np.min([np.sqrt((wx - sx) ** 2 + (wy - sy) ** 2 + (wz - sz) ** 2)
                       for sx, sy, sz in seeds], axis=0)
        ys, xs = np.where(m)
        out[src] = dist / 32.0 + WARP * warp[ys, xs]
    return out


def FACES_OF(base_img):
    """这张地块的三个面：(底色, 明度比, 类别)。顶面色按种类不同，自动认。"""
    return ((top_color(base_img), SHADE["top"], "top"),
            (SIDE_M, SHADE["mid"], "side"),
            (SIDE_D, SHADE["dark"], "side"))


def _shade(rgb, k):
    return tuple(int(round(c * k)) for c in rgb)


def top_color(img):
    """顶面色 = 出现最多的不透明色。各种地块顶面色不同（普通/核心/骨髓），
    自动认比在这儿抄一份表安全 —— 美术换色时这里不用跟着改。"""
    px = img.reshape(-1, 4)
    px = px[px[:, 3] > 0]
    vals, cnt = np.unique(px[:, :3], axis=0, return_counts=True)
    return tuple(int(v) for v in vals[cnt.argmax()])


def bake(base_img, order, count):
    """按计数把石头画上去。`order` 是 `order3d()` 出的「每个面像素的石化先后」。

    **只碰三个底色的像素** —— 核心/骨髓的图标（绿色烧瓶、紫色骨头）和它的抗锯齿边
    都不在这三色里，于是自动保住，不必单独抠。"""
    out = base_img.copy()
    faces = FACES_OF(base_img)
    stone = np.zeros(out.shape[:2], bool)

    # **三个面一起排一次名**（Kevin 2026-09-09 要的连续性）。
    # 此前是每个面各排各的 —— 那等于三张互不相干的图，石头在棱边处对不上，
    # 看着就是「一块贴在顶面上的斑」而不是一个石化的立方体。
    all_y, all_x, all_v, all_face = [], [], [], []
    for i, (src, _k, _kind) in enumerate(faces):
        if src not in order:
            continue
        ys, xs = np.where(np.all(base_img[:, :, :3] == np.array(src, np.uint8), axis=2))
        all_y.append(ys); all_x.append(xs); all_v.append(order[src])
        all_face.append(np.full(ys.shape, i))
    ys = np.concatenate(all_y); xs = np.concatenate(all_x)
    vals = np.concatenate(all_v); face_of = np.concatenate(all_face)
    rank = np.argsort(np.argsort(vals))
    take = int(round(len(vals) * COVER[count]))
    sel = rank < take
    hi = rank < int(round(take * HI_SHARE))
    if count == TOP_FULL_AT:
        # 顶面铺满、侧面按**侧面内部**的名次切（全局那一刀会把红留错地方，见 COVER 上面）。
        # 顺序仍是同一份三维排名，所以这一档依旧是上一档的超集：计数只会长，不会重新洗牌。
        is_top = np.isin(face_of, [i for i, (_s, _k, kind) in enumerate(faces)
                                   if kind == "top"])
        side_rank = np.argsort(np.argsort(np.where(is_top, np.inf, vals)))
        keep = int(round((~is_top).sum() * SIDE_KEEP))
        sel = np.where(is_top, True, side_rank < keep)
    for i, (_src, k, _kind) in enumerate(faces):
        f = face_of == i
        s_i, h_i = sel & f, hi & f
        out[ys[s_i], xs[s_i], :3] = _shade(STONE, k)
        out[ys[h_i], xs[h_i], :3] = _shade(STONE_HI, k)
    stone[ys[sel], xs[sel]] = True

    # 轮廓**只在同一个面内**算，否则顶面与侧面的交界会被当成边，整块被描一圈
    for src, k, _ in faces:
        face = np.all(base_img[:, :, :3] == np.array(src, np.uint8), axis=2)
        s = stone & face
        nb = np.zeros_like(s)
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nb |= ~np.roll(s, (dy, dx), (0, 1)) & np.roll(face, (dy, dx), (0, 1))
        out[s & nb, :3] = _shade(STONE_EDGE, k)
    return out


def gen_all():
    os.makedirs(OUT, exist_ok=True)
    made = []
    for name, n_var in BASES.items():
        base = np.array(Image.open(os.path.join(ART, name + ".png")).convert("RGBA"))
        for v in range(n_var):
            # 一个变体一份顺序，四档共用 —— 这就是「高档是低档超集」的来源。
            # 三个面**一起**算、一起排名，石化才是一条卷过棱边的连续锋面。
            rng = np.random.default_rng(seed_of(name, v))
            order = order3d(face_world(base, FACES_OF(base)), rng)
            for c in sorted(COVER):
                p = os.path.join(OUT, "%s_%02d_%d.png" % (name, c, v))
                Image.fromarray(bake(base, order, c), "RGBA").save(p)
                made.append(p)
    return made


def preview(path):
    from PIL import ImageDraw, ImageFont
    ft = {s: ImageFont.truetype(os.path.join(ART, "../fonts/fusion_pixel_10px.ttf"), s)
          for s in (20, 30)}
    counts = [0, 5, 10, 15, 20]
    cv = Image.new("RGB", (1500, 1080), (20, 27, 31))
    d = ImageDraw.Draw(cv)
    d.text((24, 24), "固化计数地块贴图族：结晶核扩散（2 核 / 扰动 .14 / 深色轮廓）",
           font=ft[30], fill=(234, 248, 252))

    d.text((24, 78), "① 四种可固化地块 x 五档（5x）—— 核心与骨髓的图标不被石头盖掉",
           font=ft[20], fill=(255, 176, 58))
    for i, name in enumerate(BASES):
        base = np.array(Image.open(os.path.join(ART, name + ".png")).convert("RGBA"))
        f = order_field(base.shape[0], base.shape[1],
                        np.random.default_rng(seed_of(name, 0)))
        y = 120 + i * 180
        d.text((24, y + 60), name, font=ft[20], fill=(159, 180, 189))
        for j, c in enumerate(counts):
            im = Image.fromarray(base if c == 0 else bake(base, f, c), "RGBA")
            im = im.resize((im.width * 5, im.height * 5), Image.NEAREST)
            cv.paste(im.convert("RGB"), (330 + j * 190, y), im)
            if i == 0:
                d.text((330 + j * 190 + 50, y - 30),
                       "%.1f" % (c / 10.0), font=ft[20], fill=(255, 176, 58))

    d.text((24, 850), "② 真实尺寸（原生像素整体放大 3 倍）：一片正在固化的癌组织",
           font=ft[20], fill=(255, 176, 58))
    grid = [[0, 0, 5, 5, 0, 0, 0], [0, 5, 10, 10, 5, 0, 0], [5, 10, 15, 20, 15, 10, 5],
            [0, 5, 10, 15, 20, 10, 5], [0, 0, 5, 10, 10, 5, 0]]
    base = np.array(Image.open(os.path.join(ART, "tissue_cancer.png")).convert("RGBA"))
    strip = Image.new("RGBA", (7 * 36 + 24, 5 * 20 + 40), (0, 0, 0, 0))
    for r, row in enumerate(grid):
        for c, cnt in enumerate(row):
            f = order_field(base.shape[0], base.shape[1],
                            np.random.default_rng(
                                seed_of("tissue_cancer", (r * 7 + c) % 4)))
            im = Image.fromarray(base if cnt == 0 else bake(base, f, cnt), "RGBA")
            strip.alpha_composite(im, (12 + c * 36 - (18 if r % 2 else 0), r * 20))
    strip = strip.resize((strip.width * 3, strip.height * 3), Image.NEAREST)
    cv.paste(strip.convert("RGB"), (24, 884), strip)
    cv.save(path)
    print("preview ->", path)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview", metavar="PNG")
    a = ap.parse_args()
    files = gen_all()
    print("烘出 %d 张 -> %s" % (len(files), OUT))
    if a.preview:
        preview(a.preview)
