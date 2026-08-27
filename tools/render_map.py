"""从 cw_data.gd 读棋盘半径与特殊组织坐标，渲染成 docs/地图布局_127格.svg。

为什么要有这个脚本：示意图是团队评审用的东西，一旦和代码对不上就会误导决策。
所以它不接受手填坐标，一律从 cw_data.gd 解析——图和代码永远同步。

用法（在仓库根目录）：python tools/render_map.py
"""
import math
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "game/scripts/core/cw_data.gd"
DST = ROOT / "docs/地图布局_127格.svg"

FILL = {"none": "#3d6157", "core": "#3f9d6b", "marrow": "#8f66bd", "vessel": "#3897b8"}
EDGE = {"none": "#4d7a6d", "core": "#7fe0a8", "marrow": "#cda6f0", "vessel": "#7fd8f0"}
SYM = {"core": "核", "marrow": "髓", "vessel": "管"}
SIZE, MARGIN, TOP = 26.0, 30, 92


def parse_gd():
    """解析 BOARD_RADIUS 与 CORES / MARROWS / VESSELS 的坐标。"""
    text = SRC.read_text(encoding="utf-8")
    radius = int(re.search(r"BOARD_RADIUS := (\d+)", text).group(1))
    groups = {}
    for name in ("CORES", "MARROWS", "VESSELS"):
        # 常量声明可能跨多行，取到第一个 ']' 为止
        body = re.search(rf"const {name}: Array\[Vector2i\] = \[(.*?)\]", text, re.S).group(1)
        groups[name] = [(int(q), int(r)) for q, r in re.findall(r"Vector2i\((-?\d+), (-?\d+)\)", body)]
    return radius, groups


def main():
    radius, groups = parse_gd()
    kind_of = {}
    for name, key in (("CORES", "core"), ("MARROWS", "marrow"), ("VESSELS", "vessel")):
        for c in groups[name]:
            assert c not in kind_of, f"{c} 被多种特殊组织重复占用"
            kind_of[c] = key

    coords = [(q, r) for q in range(-radius, radius + 1) for r in range(-radius, radius + 1)
              if abs(q) <= radius and abs(r) <= radius and abs(q + r) <= radius]
    for c in kind_of:
        assert c in coords, f"{c} 不在棋盘上"
    assert (0, 0) not in kind_of, "中央格不能是特殊组织（见 规则电子化说明 #34）"

    w, h = math.sqrt(3) * SIZE, 1.5 * SIZE
    tw = int(2 * MARGIN + (2 * radius + 1) * w)
    th = int(TOP + 2 * radius * h + 2 * SIZE + 56)
    cx, cy = MARGIN + radius * w + w / 2, TOP + radius * h + SIZE

    def hexpath(x, y):
        return " ".join("%.1f,%.1f" % (x + SIZE * math.cos(math.radians(60 * i - 90)),
                                       y + SIZE * math.sin(math.radians(60 * i - 90)))
                        for i in range(6))

    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{tw}" height="{th}" '
           f'viewBox="0 0 {tw} {th}" font-family="Microsoft YaHei,Consolas,sans-serif">',
           '<rect width="100%" height="100%" fill="#16202e"/>',
           f'<text x="{MARGIN}" y="34" fill="#eaf6ff" font-size="20" font-weight="bold">'
           f'Cell War 棋盘 · 半径 {radius} / {len(coords)} 格</text>',
           f'<text x="{MARGIN}" y="58" fill="#8fb3a6" font-size="13">'
           f'代谢核心 {len(groups["CORES"])}　骨髓 {len(groups["MARROWS"])}　'
           f'血管 {len(groups["VESSELS"])}　·　数字为轴坐标，中心 (0,0)</text>',
           f'<text x="{MARGIN}" y="76" fill="#6f8f86" font-size="12">'
           f'本图由 tools/render_map.py 从 cw_data.gd 生成，改坐标请改代码后重跑脚本</text>']

    for q, r in sorted(coords, key=lambda c: (c[1], c[0])):
        k = kind_of.get((q, r), "none")
        x, y = cx + w * (q + r / 2.0), cy + h * r
        out.append(f'<polygon points="{hexpath(x, y)}" fill="{FILL[k]}" '
                   f'stroke="{EDGE[k]}" stroke-width="2"/>')
        if k == "none":
            out.append(f'<text x="{x:.1f}" y="{y + 4:.1f}" fill="#7ea395" font-size="9" '
                       f'text-anchor="middle">{q},{r}</text>')
        else:
            out.append(f'<text x="{x:.1f}" y="{y - 1:.1f}" fill="#ffffff" font-size="14" '
                       f'font-weight="bold" text-anchor="middle">{SYM[k]}</text>')
            out.append(f'<text x="{x:.1f}" y="{y + 12:.1f}" fill="#dceaf5" font-size="9.5" '
                       f'text-anchor="middle">{q},{r}</text>')

    ly = th - 26
    for i, (k, label) in enumerate((("core", "代谢核心"), ("marrow", "骨髓"), ("vessel", "血管"))):
        lx = MARGIN + i * 160
        out.append(f'<rect x="{lx}" y="{ly}" width="15" height="15" fill="{FILL[k]}" '
                   f'stroke="{EDGE[k]}" stroke-width="2"/>')
        out.append(f'<text x="{lx + 22}" y="{ly + 13}" fill="#cfe3dc" font-size="13">'
                   f'{label} × {len(groups[{"core": "CORES", "marrow": "MARROWS", "vessel": "VESSELS"}[k]])}</text>')
    out.append('</svg>')
    DST.write_text("\n".join(out), encoding="utf-8")
    print(f"已写出 {DST.relative_to(ROOT)}：{len(coords)} 格，特殊组织 {len(kind_of)} 个")


if __name__ == "__main__":
    main()
