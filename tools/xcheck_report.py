#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""xcheck_report.py —— 闸三（测试迁移规格 A-8 / C-1 步 15）的计数器。

做三件事，口径**全部写死在本文件里**，不读任何配置：

① 按冻结口径数 `game/tests/headless_test.gd` 的 `check()` 站点：
   剥掉行内注释与字符串字面量后，按 `(?<![A-Za-z_0-9.])check\\s*\\(` 计数，
   排除 `func check` 自身；函数归属按最近的 `^func`；断言名取第二个实参里的
   第一个字符串字面量，带 `%` 的取 `%` 之前并 strip。
② 收 `game/tests/l0/**/*.json` 里所有用例的 `covers`，与 ① 的真实站点名求交集。
   **指不到任何真实断言的 `covers` 直接红** —— 挡住凭空造分子。
③ 用 `FUNC_SUBSYSTEM` 这张写死的表把站点分到子系统（迁移计划 §二点五 的去向表），
   `core` 那一档就是分母；`unclassified` 单独报出来，**不许有人把它当成 0**。

**计数单位是 GD 的 check 名，不是 JSON 用例数** —— 一条 `check(a and b and c)` 拆成三条用例，
分子只 +1。按用例数计，「拆条目」就能刷绿这条闸。

判据（退出码 1 = 红）：
* 有 `covers` 指不到真实断言；
* `covered_sites` 比 `xcheck/COUNT` 里记的少（单调不减）；
* 站点总数涨了超过 SOFT_GROWTH 条而 `covered_sites` 没涨（软化条款：涨幅 ≤20 只警告）。

本脚本自身的验收判据（规格 §0.6.5 第 6 条）：**两次跑逐字节相同**，且 `total_sites` 与当次
`grep -c 'check(' game/tests/headless_test.gd` **差恰好 2**（减掉 `xcheck(` 那一行与 `func check` 自身）。

跑法：
    python tools/xcheck_report.py --check    # 只报不写（`tools/run_l0.sh` 的调用行；不带参数同义）
    python tools/xcheck_report.py --write    # 同时刷新 xcheck/COUNT（只在人工抬 COUNT 时用）
`tools/run_l0.sh` 末尾会调它；也可以单独跑。两次跑输出逐字节相同（没有时间戳、没有遍历顺序依赖）。
"""

import argparse
import collections
import glob
import io
import json
import os
import re
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8")   # Windows 控制台默认 GBK，中文断言名会当场炸
    sys.stderr.reconfigure(encoding="utf-8")
except AttributeError:
    pass

# ---------------- 口径常量（改这里就是改闸，要在提交信息里说清楚） ----------------

CHECK_RE = re.compile(r"(?<![A-Za-z_0-9.])check\s*\(")
FUNC_RE = re.compile(r"^func\s+([A-Za-z_][A-Za-z_0-9]*)\s*\(")
STR_RE = re.compile(r"\"([^\"\\]*(?:\\.[^\"\\]*)*)\"|'([^'\\]*(?:\\.[^'\\]*)*)'")
SOFT_GROWTH = 20

SOURCE = os.path.join("game", "tests", "headless_test.gd")
CASE_GLOB = os.path.join("game", "tests", "l0", "**", "*.json")
COUNT_PATH = os.path.join("xcheck", "COUNT")

# 子系统分类：**按函数名**，逐条按顺序匹配，第一条命中的算数。
# 迁移计划 §二点五 的去向表只给了百分比，没给规则 —— 这张表就是那条规则的可执行版本。
# 新增测试函数落不进任何一条 ⇒ 进 unclassified 并被打印出来，逼人回来加一行。
FUNC_SUBSYSTEM = [
    # —— 测试设施与宿主自测（规格 §0.2 ③：验的是对拍机件本身，留 GD）——
    (r"^(check|make_board|make_game|bare_game|run_setup|finish_exit)$", "testinfra"),
    (r"^t_(xcheck|semkey_single_source|state_codec|snapshot|answer_semkey)$", "testinfra"),
    (r"^t_(kernel|obs|mirror|observe)_", "testinfra"),
    (r"^t_(determinism|step_atomic|roll_hook|rollout_isolation|tier_b_absent)$", "testinfra"),
    (r"^t_(design_required_checks|no_engine_in_ui)$", "testinfra"),
    (r"^_t_hash_knows_play_order$", "testinfra"),
    (r"^_mirror_of$", "testinfra"),
    # 测试迁移机件自测（步 8/9/13，2026-09-19）：装载键表 / 差分夹具 / 录制代理 + 两个 UNLOADABLE 断言助手
    (r"^t_(case_loader_keys|case_diff|rec_depth|rec_shape|rec_transparent|rec_contract_only)$", "testinfra"),
    (r"^_expect_(bad|unloadable)$", "testinfra"),
    # —— 热更 ——
    (r"^t_(hot_patch|patch_assets)$", "patch"),
    # —— 存档 / 回放持久化 ——
    (r"^t_(save_load|solidify_roundtrip)$", "persist"),
    # —— AI ——
    (r"^t_(ai_|heur_|eval_|mc_budget)", "ai"),
    # —— 教程 / 引导 ——
    (r"^t_(guide|tutorial)", "guide"),
    (r"^t_bridge_fx_overrides$", "guide"),
    # 教程 S5（2026-09-19）：`t_tutorial_c1` 的两个助手（照剧本打一关 / 带子双向核对），里面的 check 全是教程断言，跟着它们归 guide
    (r"^_(play_c1|check_tape)$", "guide"),
    # —— 联机 ——
    (r"^t_(net_|lan_|online_|watch_|match_online|replay)", "net"),
    (r"^t_(surrender|surrender_seats|barrier_release|chat_box)$", "net"),
    (r"^t_entry_smoke_(online|replay)$", "net"),
    (r"^_no_barrier_timeout$", "net"),
    # —— UI / 表现（决策 9 之后只剩排版，留 Godot）——
    # ⚠ 别用 `_fx$` 一刀切。规格 §0.6.5 第 6 条逐名点过：
    #   t_skill_fx / t_erosion_fx / t_prd_online_0907 归 core（规则断言）；
    #   t_effector_fx / t_attack_fx / t_spread_fx / t_teleport_fx / t_dice / t_human_ask / t_card_fx_hooks 归 ui。
    (r"^t_(attack_fx|card_draw_fx|chemo_blink|effector_fx)$", "ui"),
    (r"^t_(hunt_fx|issue31_fx|spread_fx|teleport_fx|ui_sfx)$", "ui"),
    (r"^t_.*_(panel|bar|box|row|tip|info|view|preview|marker|blink|glow|highlight|width|fit)$", "ui"),
    (r"^t_(action_bar_width|announce|board_view|breath_sheets|buttons_dim|codex)$", "ui"),
    (r"^t_(config_custom|config_panel|feedback|font_coverage|hex_pick|hover_layer)$", "ui"),
    (r"^t_(main_menu|opening|pause_and_teardown|quit_confirm|rules_page|settings)$", "ui"),
    (r"^t_(settle_screen|shader_no_return|solid_tissue_art|storm_preview|teardown_board)$", "ui"),
    (r"^t_(ui_bridge|ui_sfx|view_blend|human_ask|dice|feed_log|log_panel)$", "ui"),
    (r"^t_(hand|hand_.*|move_hand|play_queue|card_info|card_name_fit|skill_info)$", "ui"),
    (r"^t_(card_fx_hooks|card_played_signal|event_drawn_signal|income_display|production_row)$", "ui"),
    (r"^t_(entry_smoke_hotseat|entry_smoke_local|entry_smoke_tutorial|hotseat)$", "ui"),
    (r"^t_(mods_tip|skill_move_price_tag|store_ring|tier_highlight|mucus_row)$", "ui"),
    # `_t_move_cost_wiring` 的 4 条全是 CWUIBridge 的价目表接线（进/退迁移态、逐格抄 cost、动词文案），
    # 零规则量 —— 兜底规则 `^_?t_` 会把它扫进 core，按 §0.6.5 第 6 条逐名点法归 ui（批 1，core 分母 1114 → 1110）
    (r"^_t_move_cost_wiring$", "ui"),
    # 教程 S1（2026-09-19）：`t_board_active_tiles` 全是棋盘遮罩 / 浮现补间 / hex_at 的 UI 断言，零规则量，逐名归 ui（§0.6.5 第 6 条）
    (r"^t_board_active_tiles$", "ui"),
    # —— core 规则：剩下的 t_* / _t_* 全归它 ——
    (r"^_?t_", "core"),
]


# ---------------- ① 数站点 ----------------

def mask(line):
    """把字符串内容与行内注释换成同长度的空白，列号不变。"""
    out = []
    i, n, quote = 0, len(line), None
    while i < n:
        ch = line[i]
        if quote is None:
            if ch == "#":
                out.append(" " * (n - i))
                break
            out.append(ch)
            if ch in "\"'":
                quote = ch
            i += 1
        else:
            if ch == "\\" and i + 1 < n:
                out.append("  ")
                i += 2
                continue
            if ch == quote:
                quote = None
                out.append(ch)
            else:
                out.append(" ")
            i += 1
    return "".join(out)


def arg_name(lines, masked, row, col):
    """从 `check(` 的左括号右边开始，跨行扫到配平，取第二个顶层实参里的第一个字符串字面量。"""
    depth, args = 1, [""]
    i, j, guard = row, col, 0
    while i < len(lines) and guard < 4000:
        guard += 1
        line, mline = lines[i], masked[i]
        while j < len(line):
            mc = mline[j]
            if mc in "([{":
                depth += 1
            elif mc in ")]}":
                depth -= 1
                if depth == 0:
                    return pick(args)
            elif mc == "," and depth == 1:
                args.append("")
                j += 1
                continue
            args[-1] += line[j]
            j += 1
        args[-1] += " "
        i += 1
        j = 0
    return None


def pick(args):
    if len(args) < 2:
        return None
    m = STR_RE.search(args[1])
    if not m:
        return None
    text = m.group(1) if m.group(1) is not None else m.group(2)
    return text.split("%")[0].strip()


def scan_sites(path):
    """→ [(func, name_or_None, line_no)]"""
    text = io.open(path, encoding="utf-8").read()
    lines = text.split("\n")
    masked = [mask(l) for l in lines]
    sites, func = [], ""
    for row, raw in enumerate(lines):
        m = FUNC_RE.match(raw)
        if m:
            func = m.group(1)
        if func == "check":
            continue          # `func check` 自身不算站点
        for hit in CHECK_RE.finditer(masked[row]):
            sites.append((func, arg_name(lines, masked, row, hit.end()), row + 1))
    return sites


# ---------------- ③ 分类 ----------------

def subsystem(func):
    for pattern, tag in FUNC_SUBSYSTEM:
        if re.search(pattern, func):
            return tag
    return "unclassified"


# ---------------- ② covers ----------------

def read_covers(root):
    """→ {cover 字符串: [用例 id, ...]}"""
    out = collections.defaultdict(list)
    for path in sorted(glob.glob(os.path.join(root, CASE_GLOB), recursive=True)):
        try:
            cases = json.load(io.open(path, encoding="utf-8"))
        except ValueError as e:
            sys.stderr.write("✘ %s 解不出用例：%s\n" % (path, e))
            raise SystemExit(1)
        if not isinstance(cases, list):
            continue          # diff_fixture.json 之类的字典型夹具不是用例表
        for case in cases:
            if not isinstance(case, dict):
                continue
            for cover in case.get("covers", []):
                out[cover].append(case.get("id", "(无 id)"))
    return out


# ---------------- 主流程 ----------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只读校验（默认行为；run_l0.sh 的调用行写明它）")
    ap.add_argument("--write", action="store_true", help="刷新 xcheck/COUNT")
    args = ap.parse_args()

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    sites = scan_sites(os.path.join(root, SOURCE))

    real = set()
    unaddressable = 0
    for func, name, _ in sites:
        if name:
            real.add("%s::%s" % (func, name))
        else:
            unaddressable += 1

    by_sub = collections.Counter(subsystem(f) for f, _, _ in sites)
    funcs = sorted({f for f, _, _ in sites})
    core_funcs = [f for f in funcs if subsystem(f) == "core"]
    core_names = {"%s::%s" % (f, n) for f, n, _ in sites if n and subsystem(f) == "core"}
    unclassified_funcs = [f for f in funcs if subsystem(f) == "unclassified"]

    covers = read_covers(root)
    dangling = sorted(c for c in covers if c not in real)
    covered = sorted(c for c in covers if c in real)

    total = len(sites)
    core = by_sub["core"]
    pct = (100.0 * len(covered) / core) if core else 0.0

    print("headless_test.gd：%d 站点 / %d 个带断言的函数" % (total, len(funcs)))
    for tag in sorted(by_sub):
        print("  %-13s %5d" % (tag, by_sub[tag]))
    if unclassified_funcs:
        print("  ⚠ 没归属的函数（回 FUNC_SUBSYSTEM 加一行）：%s" % " / ".join(unclassified_funcs))
    print("core 候选集 %d 站点 / %d 函数；可被 covers 指到的不同名字 %d 个；已覆盖 %d（%.1f%%）"
          % (core, len(core_funcs), len(core_names), len(covered), pct))
    if core - len(core_names):
        print("  ⚠ core 里有 %d 个站点指不到（断言名为空、或同函数内重名）—— 覆盖率的天花板就在这儿"
              % (core - len(core_names)))
    if unaddressable:
        print("  ⚠ 全文 %d 个站点的第二个实参不是字符串字面量（多半是纯 %% 拼的名字）" % unaddressable)

    code = 0
    if dangling:
        print("✘ 这些 covers 指不到 headless_test.gd 里任何一条 check —— 分子是造出来的：")
        for c in dangling:
            print("    %s（用例 %s）" % (c, " / ".join(covers[c])))
        code = 1

    prev = {}
    count_path = os.path.join(root, COUNT_PATH)
    if os.path.exists(count_path):
        prev = json.load(io.open(count_path, encoding="utf-8"))
    prev_covered = int(prev.get("covered_sites", 0))
    prev_total = int(prev.get("total_sites", 0))
    if len(covered) < prev_covered:
        print("✘ covered_sites 退了：%d → %d（闸三要求单调不减）" % (prev_covered, len(covered)))
        code = 1
    elif total > prev_total and len(covered) == prev_covered and prev_total:
        grew = total - prev_total
        if grew > SOFT_GROWTH:
            print("✘ check 总数涨了 %d 条（>%d）而 covered_sites 没动 —— 新断言要同批补用例" % (grew, SOFT_GROWTH))
            code = 1
        else:
            print("⚠ check 总数涨了 %d 条而 covered_sites 没动（≤%d，只警告）" % (grew, SOFT_GROWTH))

    now = {
        "core_addressable": len(core_names),
        "core_funcs": len(core_funcs),
        "core_sites": core,
        "covered_sites": len(covered),
        "total_funcs": len(funcs),
        "total_sites": total,
        "unclassified_sites": by_sub["unclassified"],
    }
    if args.write:
        os.makedirs(os.path.join(root, "xcheck"), exist_ok=True)
        io.open(count_path, "w", encoding="utf-8", newline="\n").write(
            json.dumps(now, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
        print("已写 %s" % COUNT_PATH)
    else:
        print("（没加 --write，没动 %s）当前值：%s"
              % (COUNT_PATH, json.dumps(now, ensure_ascii=False, sort_keys=True)))

    if code == 0:
        print("✔ 闸三过")
    raise SystemExit(code)


if __name__ == "__main__":
    main()
