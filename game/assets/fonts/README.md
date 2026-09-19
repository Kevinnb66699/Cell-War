# 字体

两款都是 SIL Open Font License 1.1，可商用、可随游戏分发。许可证原文见同目录的 `*_OFL.txt`。

| 文件 | 用途 | 点阵网格 | **合法字号** |
|---|---|---|---|
| `fusion_pixel_10px.ttf` | 全部中文与正文（缝合像素 Fusion Pixel 10px，proportional / zh_hans） | 10×10 | 10 / 20 / 30 / 40 |
| `silkscreen_bold.ttf` | 仅 Logo「CELL WAR」等拉丁标题 | 8×8（字面高 5 格） | 8 的整数倍，当前用 64 |

**字号只能取网格的整数倍**，否则点阵被重采样成非整数像素，边缘会糊。
导入设置里抗锯齿 / hinting / 次像素定位全部关掉，理由同上——它们都会给点阵磨出灰边。

选缝合像素而不是 GNU Unifont：Unifont 是 16 网格，只有 16 / 32 两档能用，
会把「菜单项 / 副标题 / 版本号」压成同一号；10 网格有四档，够铺开层级。

## 2026-09-19 · 补了一个 ∞（U+221E）字形

缝合像素 10px 的原版 25070 个码位里**没有 ∞**，也没有 ≈ / ∝ 能顶替 ——
教程 S4 的台词「能量 ∞」被字形闸 `t_font_coverage` 当场拦下
（Kevin 2026-09-19：「补字形，如果没有相似字形，就用 INF」，字形补上了，用不着 INF）。

`tools/add_infinity_glyph.py`（fontTools）手画了一个点阵 ∞ 写进 `fusion_pixel_10px.ttf`：
9×5 像素（900×500 units，一像素 100 units）、advance 1000 —— 全角，和 → / ○ 一档；
纵向落在 y 100..600，与数字（y 0..700）同基线、视觉齐腰。每个点亮的像素是一条顺时针方形轮廓，
写法与数字 0 的方块同向（非零环绕规则下相邻方块自然并成一块）。
`cmap`（三张子表）/ `glyf` / `loca` / `hmtx` / `vmtx` / `maxp` / `post` 一并更新，
字形数 24803 → 24804、码位 25070 → 25071。`.import` 没动，Godot 按路径重导。
真渲染对照图：`tests/preview/preview_infinity.gd`。

**许可证处置**：OFL 1.1 明文允许修改与再分发。这份字体的版权行是
`Copyright (c) 2022, TakWolf (https://takwolf.com).` —— **没有声明 Reserved Font Name**
（OFL 只在声明了保留名时才禁止改完继续沿用原名），所以 `name` 表里的家族名
`Fusion Pixel 10px Prop zh_hans` 原样保留、没有改名。
许可证原文与版权声明随字体一起分发，见同目录 `fusion_pixel_10px_OFL.txt`。
