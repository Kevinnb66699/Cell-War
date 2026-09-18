#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 game/tests/l0/*.json 从 cwxworld/1 迁到 cwxcase/2 + cwxworld/2（口径二 · 测试迁移规格 §0.6.5 第 3 条）。

**四件事，一件都不许自己编数据**：

  1. 删 tile 上的 `cell` 键        —— 占位一律由 `cells[].at` 反推（§0.6.1 第 3 条：tile 12 键不收 `cell`）
  2. 癌席补 `cancer_type`          —— 从该席细胞的 `type` 推；唯一没落子的那席查 MANUAL_CANCER_TYPE 登记表
                                      （§0.6.1 第 2 条：不设 "none" 哨兵、不许兜底）
  3. 每条用例补 `"schema": "cwxcase/2"` —— 写在该条对象的**第一行**（在 `id` 之前，§0.6.2 第 1 条）
  4. 三格补 `"type": "normal"`      —— §0.6.1 第 3 条把「省略 type」的含义从「普通格」改成
                                      「棋盘本来的特殊组织」；这三格坐落在 CWData.MARROWS 上、
                                      今天被装成普通格，补上字面量才保住今天的世界

**不做**的三件（裁决明写）：不改写 `expect`（裸整数留着，§0.6.2 第 2 条）；不补 `marked`
三键（写了 `marked` 就必须三个都写，是**用例作者**的事，loader 与本脚本都不替人填，§0.6.1 第 4 条）；
不改名 `probe`（45 条的 P 族一律留 `probe`，§0.6.2 第 1 条）。

**为什么是文本手术而不是 json.dump 重排**：这批用例的缩进是手写的、同样内容有的摊开有的挤成一行
（`derived_a.json` 与 `anaerobic.json` 里一模一样的 players 数组，一个单行一个多行），
没有任何序列化器能逐字复现。整份重排会把 737 行全变成 diff，真正的四处改动就埋没了。
所以这里只动要改的那几个字节，改完再**独立算一遍目标树**跟结果对，对不上就一个字都不落盘。

行尾：`derived_a.json` / `move_cost.json` 是 CRLF，其余四份是 LF —— 一律以 `newline=""` 读写，
插进去的那一行跟着本文件的行尾走（`sed -i` 会把 CRLF 压成 LF，所以这件事只能走 python）。

幂等：跑第二遍不产生任何改动（脚本自己在同一次运行里验一遍）。

用法：
    python tools/migrate_l0_cases.py              # 就地改写 game/tests/l0/*.json
    python tools/migrate_l0_cases.py --dry-run    # 只打印会改什么，不写文件
    python tools/migrate_l0_cases.py --dir some/other/dir
"""

from __future__ import annotations

import argparse
import copy
import glob
import json
import os
import re
import sys

SCHEMA = "cwxcase/2"

# CWData.CORES / MARROWS / VESSELS（game/scripts/core/cw_data.gd）。
# 只用来**报错**：坐落在特殊组织上、又省略了 `type` 的格子，含义在 §0.6.1 第 3 条改过一次，
# 逐格登记而不是批量补，是为了让「今天恰好只有三格」这件事下次再变时当场炸出来。
CORES = {(0, -3), (3, 0), (-3, 3)}
MARROWS = {(3, -3), (0, 3), (-3, 0), (6, -3), (-3, 6), (-3, -3)}
VESSELS = {(6, 0), (-6, 0)}
SPECIAL = CORES | MARROWS | VESSELS

# 没落子的癌席：癌种推不出来，**按用例语境逐条登记在这里**，loader 与本脚本都不许兜底。
# 键 = (用例 id, 席位)，值 = CellType 名（与 cells[].type 同一套字面量）。
MANUAL_CANCER_TYPE = {
    # 这条只验「一个相邻癌组织 → 30‰」，癌种不参与算式。写 Osteosarcoma 是为了与
    # 步 7 之前 C# `?? CellType.Osteosarcoma` 兜底装出来的世界逐字相同 —— 期望值因此不变（§0.6.1 第 2 条）。
    ("proliferate_chance/healthy_one_adjacent_cancer/stage_I", 1): "Osteosarcoma",
}

# 坐落在特殊组织上、却要当普通格用的格子。键 = (用例 id, "q,r")，值 = tile 的 `type` 字面量。
MANUAL_TILE_TYPE = {
    # 三格都在 CWData.MARROWS 上（3,-3 / -3,0 / 0,3），今天两侧 loader 都把「省略 type」读成普通格。
    # §0.6.1 第 3 条把默认值改成 `special_of(at)` 之后，不补这三个字面量就等于把用例的盘面换掉了。
    ("aerobic_share/basic_level_I/four_seats_full_healthy", "3,-3"): "normal",
    ("aerobic_share/basic_level_I/four_seats_full_healthy", "-3,0"): "normal",
    ("aerobic_share/basic_level_I/four_seats_full_healthy", "0,3"): "normal",
}

CANCER_TYPES = ("Melanoma", "SignetRing", "Osteosarcoma", "SmallCellLung")

# 一条用例对象的开头：`  {` 换行 `    "schema"` 或 `    "id"`。
# 认 schema 是为了**跑第二遍时锚点数不变**（幂等自证要拿它数条数）。
_CASE_HEAD = re.compile(r'^  \{(\r?\n)    "(schema|id)":', re.M)
# 单层字典（players / tiles 的条目都不含嵌套对象）
_OBJ = re.compile(r"\{[^{}]*\}")
# tile 上的 `cell`（整数值）；`args` 里的 `"cell": "0"` 是字符串，匹配不到
_TILE_CELL = re.compile(r',\s*"cell"\s*:\s*-?\d+(?=\s*[,}])')
_AT = re.compile(r'"at"\s*:\s*"([^"]*)"')


def die(msg: str) -> "SystemExit":
    return SystemExit("migrate_l0_cases: %s" % msg)


def parse_at(text: str) -> tuple:
    q, r = text.split(",")
    return (int(q.strip()), int(r.strip()))


# ---- 独立复算：文本手术的结果要跟它逐字相同 ----

def cancer_type_of(case: dict, seat: int) -> str:
    """该席细胞的癌种；没落子就查登记表。查不到 = 整份中止，不给兜底。"""
    found = sorted({c.get("type") for c in case["world"].get("cells", [])
                    if int(c.get("seat", -1)) == seat and c.get("type") in CANCER_TYPES})
    if len(found) == 1:
        return found[0]
    if len(found) > 1:
        raise die("用例 %s 的癌席 %d 落了多种癌细胞（%s），癌种推不出来"
                  % (case["id"], seat, " / ".join(found)))
    key = (case["id"], seat)
    if key in MANUAL_CANCER_TYPE:
        return MANUAL_CANCER_TYPE[key]
    raise die(
        "用例 %s 的癌席 %d 没有细胞，癌种推不出来。\n"
        "  请在 tools/migrate_l0_cases.py 的 MANUAL_CANCER_TYPE 里按用例语境登记一条，"
        "或给这条用例补一只细胞 —— 脚本不替你选（规格 §0.5 纪律 3：不许「推不出来就给默认值」）。"
        % (case["id"], seat))


def tile_type_of(case: dict, tile: dict) -> str:
    """省略了 `type` 又坐落在特殊组织上的格子：查登记表，查不到 = 整份中止。"""
    key = (case["id"], tile["at"])
    if key in MANUAL_TILE_TYPE:
        return MANUAL_TILE_TYPE[key]
    raise die(
        "用例 %s 点名了格 %s：它在 CORES / MARROWS / VESSELS 上，却没写 `type`。\n"
        "  §0.6.1 第 3 条把「省略 type」的含义改成了「棋盘本来的特殊组织」，"
        "所以这格到底要当普通格还是特殊组织，得由人登记进 MANUAL_TILE_TYPE。"
        % (case["id"], tile["at"]))


def expected_tree(cases: list) -> list:
    """从原树独立算一遍迁移后的目标树。"""
    out = copy.deepcopy(cases)
    for old, new in zip(cases, out):
        if "schema" not in new:
            new["schema"] = SCHEMA
        world = new["world"]
        for t in world.get("tiles", []):
            t.pop("cell", None)
            if "type" not in t and parse_at(t["at"]) in SPECIAL:
                t["type"] = tile_type_of(old, t)
        for p in world.get("players", []):
            if p.get("faction") == "cancer" and "cancer_type" not in p:
                p["cancer_type"] = cancer_type_of(old, int(p["seat"]))
    return out


# ---- 文本手术 ----

def array_span(text: str, key: str, where: str) -> tuple:
    """`"key": [` … 配对的 `]`，返回内容的 [start, end)。跳字符串字面量，不怕值里有括号。"""
    m = re.search(r'"%s"\s*:\s*\[' % re.escape(key), text)
    if m is None:
        return None
    i = m.end() - 1
    depth, j, in_str, esc = 0, m.end() - 1, False, False
    while j < len(text):
        ch = text[j]
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
        elif ch == '"':
            in_str = True
        elif ch == "[":
            depth += 1
        elif ch == "]":
            depth -= 1
            if depth == 0:
                return (i + 1, j)
        j += 1
    raise die("%s：\"%s\" 数组没有收口" % (where, key))


def append_key(obj_text: str, addition: str) -> str:
    """往字典的最后一个键后面塞一段（保住 `{ … }` 里那对空格的写法）。"""
    return "%s%s %s" % (obj_text[:-1].rstrip(), addition, obj_text[-1])


def patch_span(chunk: str, key: str, where: str, repl) -> tuple:
    """只在 `"key": [...]` 这一段里做 `_OBJ` 替换，别碰 args / cells。"""
    span = array_span(chunk, key, where)
    if span is None:
        return chunk, []
    notes: list = []
    body = _OBJ.sub(lambda m: repl(m.group(0), notes), chunk[span[0]:span[1]])
    return chunk[:span[0]] + body + chunk[span[1]:], notes


def migrate_case(chunk: str, case: dict, eol: str, has_schema: bool) -> tuple:
    where = "用例 %s" % case["id"]
    notes: list = []

    if not has_schema:
        head = chunk.index("{") + 1
        head += len(eol)
        chunk = chunk[:head] + '    "schema": "%s",%s' % (SCHEMA, eol) + chunk[head:]
        notes.append("补 schema")

    # players：癌席补 cancer_type（按文档序与解析序配对）
    wanted = [p for p in case["world"].get("players", [])]
    idx = [0]

    def on_player(body: str, out: list) -> str:
        if idx[0] >= len(wanted):
            raise die("%s：players 文本里的条目比解析出来的多" % where)
        p = wanted[idx[0]]
        idx[0] += 1
        if p.get("faction") != "cancer" or "cancer_type" in p:
            return body
        ctype = cancer_type_of(case, int(p["seat"]))
        out.append("席位 %d 补 cancer_type=%s" % (int(p["seat"]), ctype))
        return append_key(body, ', "cancer_type": "%s"' % ctype)

    chunk, more = patch_span(chunk, "players", where, on_player)
    notes += more
    if idx[0] != len(wanted):
        raise die("%s：players 文本里的条目（%d）比解析出来的（%d）少" % (where, idx[0], len(wanted)))

    # tiles：删 cell、给登记表里的格子补 type
    tiles = case["world"].get("tiles", [])
    jdx = [0]

    def on_tile(body: str, out: list) -> str:
        if jdx[0] >= len(tiles):
            raise die("%s：tiles 文本里的条目比解析出来的多" % where)
        t = tiles[jdx[0]]
        jdx[0] += 1
        m = _AT.search(body)
        if m is None or m.group(1) != t["at"]:
            raise die("%s：tiles 第 %d 条的坐标对不上（文本 %s / 解析 %s）"
                      % (where, jdx[0], m.group(1) if m else "(没有 at)", t["at"]))
        body, n = _TILE_CELL.subn("", body)
        if n:
            out.append("格 %s 删 cell" % t["at"])
        if "type" not in t and parse_at(t["at"]) in SPECIAL:
            body = append_key(body, ', "type": "%s"' % tile_type_of(case, t))
            out.append("格 %s 补 type=%s（在特殊组织上）" % (t["at"], tile_type_of(case, t)))
        return body

    chunk, more = patch_span(chunk, "tiles", where, on_tile)
    notes += more
    if jdx[0] != len(tiles):
        raise die("%s：tiles 文本里的条目（%d）比解析出来的（%d）少" % (where, jdx[0], len(tiles)))
    return chunk, notes


def migrate_text(text: str, cases: list, where: str) -> tuple:
    heads = list(_CASE_HEAD.finditer(text))
    if len(heads) != len(cases):
        raise die("%s：文本里认出 %d 条用例，解析出 %d 条 —— 版式不是「  {换行    \"id\"」，人来看一眼"
                  % (where, len(heads), len(cases)))
    out, notes = [text[:heads[0].start()]] if heads else [text], []
    for i, h in enumerate(heads):
        end = heads[i + 1].start() if i + 1 < len(heads) else len(text)
        chunk, more = migrate_case(text[h.start():end], cases[i], h.group(1),
                                   h.group(2) == "schema")
        out.append(chunk)
        notes += ["%s：%s" % (cases[i]["id"], n) for n in more]
    return "".join(out), notes


# ---- 自证 ----

def postcheck(cases: list, where: str) -> None:
    for c in cases:
        cid = c.get("id", "(无 id)")
        if c.get("schema") != SCHEMA:
            raise die("%s：用例 %s 的 schema 不是 %s" % (where, cid, SCHEMA))
        world = c.get("world", {})
        for t in world.get("tiles", []):
            if "cell" in t:
                raise die("%s：用例 %s 的格 %s 上还有 cell" % (where, cid, t.get("at")))
            if "type" not in t and parse_at(t["at"]) in SPECIAL:
                raise die("%s：用例 %s 的格 %s 在特殊组织上却没写 type" % (where, cid, t["at"]))
        for p in world.get("players", []):
            if p.get("faction") == "cancer":
                if p.get("cancer_type") not in CANCER_TYPES:
                    raise die("%s：用例 %s 的癌席 %s 没有合法 cancer_type" % (where, cid, p.get("seat")))
            elif "cancer_type" in p:
                raise die("%s：用例 %s 的免疫席 %s 写了 cancer_type" % (where, cid, p.get("seat")))


def check_schema_is_first_line(text: str, where: str) -> None:
    for m in _CASE_HEAD.finditer(text):
        if m.group(2) != "schema":
            raise die("%s：有用例的第一行不是 schema" % where)


# ---- 主流程 ----

def migrate_file(path: str, dry_run: bool) -> bool:
    where = os.path.basename(path)
    with open(path, "r", encoding="utf-8", newline="") as f:
        text = f.read()
    if text.startswith(chr(0xFEFF)):   # BOM
        raise die("%s：带 BOM —— L0 用例一律 UTF-8 无 BOM" % where)
    cases = json.loads(text)
    if not isinstance(cases, list):
        raise die("%s 解不出用例数组" % where)

    new_text, notes = migrate_text(text, cases, where)

    # ① 独立复算：结果必须与从原树算出的目标树逐字相同
    got = json.loads(new_text)
    want = expected_tree(cases)
    if got != want:
        for a, b in zip(got, want):
            if a != b:
                print("  对不上的第一条：%s" % a.get("id", "(无 id)"), file=sys.stderr)
                break
        raise die("%s：文本手术的结果与独立算出的目标树不同 —— 不落盘" % where)
    # ② 键面自证
    postcheck(got, where)
    check_schema_is_first_line(new_text, where)
    # ③ 幂等：再跑一遍零改动
    again, _ = migrate_text(new_text, got, where)
    if again != new_text:
        raise die("%s：第二遍还有改动 —— 不幂等，不落盘" % where)

    if new_text == text:
        print("%s：无改动（已经是 cwxcase/2）" % where)
        return False
    print("%s：%d 条用例" % (where, len(got)))
    for n in notes:
        print("    · %s" % n)
    if not dry_run:
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write(new_text)
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description="L0 用例 cwxworld/1 → cwxcase/2（规格 §0.6.5 第 3 条）")
    ap.add_argument("--dir", default=os.path.join("game", "tests", "l0"))
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    files = sorted(glob.glob(os.path.join(args.dir, "*.json")))
    if not files:
        raise die("%s 下一个 .json 都没有" % args.dir)
    changed = sum(migrate_file(p, args.dry_run) for p in files)
    print("\n%d / %d 份文件有改动%s" % (changed, len(files),
                                        "（--dry-run，没写盘）" if args.dry_run else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
