#!/usr/bin/env python3
# batch1_test_fixtures.py —— 口径二 · 批 1 步 6+8：headless_test.gd 里「只换夹具」那一批的一次性迁移
#
# 为什么是脚本不是手改：这一批是几十条**逐字相同**的单行替换（t_hover_info 一条里就有 30 处
# `CWTileInfo.describe(g, ...)`），逐条写 old/new 片段既不唯一也没法复核。脚本按「测试函数的行范围 +
# 明确的正则」做，改前逐条打印原文与新文，改完打印总数；跑第二遍应当是 0 处改动（幂等）。
#
# 纪律（memory）：**不用 sed -i**（Git Bash 会把 CRLF 压成 LF）；这里走 python 二进制读写，行尾原样保留。
#
# 跑法：python tools/batch1_test_fixtures.py [--apply]
#   不带 --apply 只预览。行范围按**跑脚本那一刻**的文件重新定位（按 `func t_xxx(` 找起点、下一个顶层 func 找终点），
#   所以行号漂了也不会改错地方。

import io
import re
import sys

PATH = 'game/tests/headless_test.gd'

# 每条测试：函数名 -> [(正则, 替换)]。正则只在该函数的行范围内套用。
RULES = {
    # ① 档 —— CWTileInfo.describe / sync 形参换 CWMirror（A-6.1）
    't_hover_info': [
        (r'CWTileInfo\.describe\((g|pg), ', r'CWTileInfo.describe(_mirror_of(\1), '),
        (r'info\.sync\((0\.\d+), g, ', r'info.sync(\1, _mirror_of(g), '),
        (r'panel\.refresh\(g\)', r'panel.refresh(_mirror_of(g))'),
    ],
    't_chemo_info': [
        (r'CWTileInfo\.describe\(g, ', r'CWTileInfo.describe(_mirror_of(g), '),
    ],
    't_production_row': [
        (r'CWTileInfo\.describe\(g, ', r'CWTileInfo.describe(_mirror_of(g), '),
    ],
    # ① 档 —— CWMatchPanel.refresh / tip_rows / active_events_text / income_text（A-6.1；tip_rows 另收 q）
    't_match_panel': [
        (r'p\.refresh\((g|g4|g6)\)', r'p.refresh(_mirror_of(\1))'),
    ],
    't_income_display': [
        (r'p\.refresh\(g\)', r'p.refresh(_mirror_of(g))'),
    ],
    't_mods_tip': [
        (r'CWMatchPanel\.tip_rows\(g, ([^,]+), (true|false)\)',
         r'CWMatchPanel.tip_rows(_mirror_of(g), \1, \2, _query_of(g))'),
        (r'p\.refresh\(g\)', r'p.refresh(_mirror_of(g))'),
    ],
    't_skill_info': [
        (r'CWMatchPanel\.tip_rows\(g, ([^,]+), (true|false)\)',
         r'CWMatchPanel.tip_rows(_mirror_of(g), \1, \2, _query_of(g))'),
        (r'CWCardInfo\.describe_act_for\(g, ', r'CWCardInfo.describe_act_for(_query_of(g), '),
        (r'panel\.refresh\(g\)', r'panel.refresh(_mirror_of(g))'),
    ],
    't_doubled_marker': [
        (r'CWMatchPanel\.active_events_text\(g\)',
         r'CWMatchPanel.active_events_text(_mirror_of(g))'),
    ],
    # ① 档 —— CWSettleScreen.show_result 形参换 CWMirror（A-6.1 / A-6.2）
    't_settle_screen': [
        (r's\.show_result\((g|small)\)', r's.show_result(_mirror_of(\1))'),
    ],
    # ① 档 —— CWMatch.turn_mark_of 形参换 CWMirror（A-1.3）
    't_turn_mark': [
        (r'CWMatch\.turn_mark_of\(g\)', r'CWMatch.turn_mark_of(_mirror_of(g))'),
    ],
    # ② 档 —— m.game -> m.mirror 的同名查询机械改（19 处，规格 A-10 ②）
    't_tutorial': [
        (r'\bm\.game\.', r'm.mirror.'),
    ],
    't_tutorial_auto_advance': [
        (r'\bm\.game\.', r'm.mirror.'),
    ],
    't_opening': [
        (r'\bm\.game\.', r'm.mirror.'),
    ],
    't_board_small': [
        (r'\bm\.game\.', r'm.mirror.'),
    ],
    't_mark_aura': [
        (r'\bm\.game\.', r'm.mirror.'),
    ],
    't_watch_entry': [
        (r'\bm\.game\.', r'm.mirror.'),
    ],
    't_watch_live': [
        (r'\bm\.game\.', r'm.mirror.'),
    ],
}


def ranges(lines):
    """函数名 -> (起, 止) 行下标，止 = 下一个顶层 func 的下标"""
    heads = [(i, m.group(1)) for i, l in enumerate(lines)
             for m in [re.match(r'func (\w+)\(', l)] if m]
    out = {}
    for k, (i, name) in enumerate(heads):
        end = heads[k + 1][0] if k + 1 < len(heads) else len(lines)
        out.setdefault(name, (i, end))
    return out


def main():
    apply = '--apply' in sys.argv
    with io.open(PATH, 'r', encoding='utf-8', newline='') as f:
        text = f.read()
    lines = text.split('\n')
    span = ranges(lines)
    hits = 0
    for name, rules in RULES.items():
        if name not in span:
            print('!! 找不到 %s（函数改名了？）' % name)
            continue
        lo, hi = span[name]
        for i in range(lo, hi):
            new = lines[i]
            for pat, rep in rules:
                new = re.sub(pat, rep, new)
            if new != lines[i]:
                hits += 1
                print('%s:%d' % (name, i + 1))
                print('  -  %s' % lines[i].rstrip())
                print('  +  %s' % new.rstrip())
                lines[i] = new
    print('共 %d 处' % hits)
    if apply and hits:
        with io.open(PATH, 'w', encoding='utf-8', newline='') as f:
            f.write('\n'.join(lines))
        print('已写回 %s' % PATH)


if __name__ == '__main__':
    main()
