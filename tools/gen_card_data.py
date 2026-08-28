# -*- coding: utf-8 -*-
"""从 PRD 生成 cw_card_data.gd —— 只抽取「身份」（卡名/类别/各池权重），不含效果。"""
import re, io

PRD = "D:/Projects/SpringSense/2026-2027/Cell War/Cell_War PRD.md"
OUT = "D:/Projects/SpringSense/2026-2027/Cell War/Cell-War/game/scripts/core/cw_card_data.gd"

L = [l.rstrip() for l in io.open(PRD, encoding="utf-8")]
clean = lambda s: s.replace("\\", "").strip()
start = next(i for i, l in enumerate(L) if l.startswith("## 免疫卡池"))
end = next(i for i, l in enumerate(L) if l.startswith("# 世界事件"))

POOL_KEY = {"I级卡池": 0, "II级卡池": 1, "III级卡池": 2, "X级卡池": 3}
KIND = {"事件": "EVENT", "即时技能": "INSTANT", "永久技能": "PERMANENT"}

pool = None
cards = {}          # name -> {kind, immune:[0,0,0,0], cancer:[0,0,0]}
cur = None
for raw in L[start:end]:
    s = clean(raw)
    if not s:
        continue
    if s.startswith("## ") or s.startswith("### "):
        pool = s.lstrip("#").strip()
        continue
    m = re.fullmatch(r"\**【(.+?)】\**", s)
    if m:
        n = m.group(1)
        cur = cards.setdefault(n, {"kind": None, "immune": [0, 0, 0, 0], "cancer": [0, 0, 0]})
        cur["_pool"] = pool
        continue
    if cur is None:
        continue
    if s.startswith("类别："):
        k = KIND[s[3:]]
        assert cur["kind"] in (None, k), "类别不一致：%s" % s
        cur["kind"] = k
    elif s.startswith("权重："):
        w = s[3:]
        if cur["_pool"] == "癌症卡池":
            parts = [int(x.strip()) for x in w.split("/")]
            assert len(parts) == 3, w
            cur["cancer"] = parts
        else:
            cur["immune"][POOL_KEY[cur["_pool"]]] = int(w)

for c in cards.values():
    c.pop("_pool", None)

names = sorted(cards)          # 固定顺序 —— 权重抽取要同种子可复现
lines = []
A = lines.append
A("## cw_card_data.gd —— 卡牌的**身份**：卡名、类别、各池权重")
A("##")
A("## **本文件由 tools 从 PRD 生成，不要手改** —— 改了下次重生成就没了。")
A("## PRD 改卡池时重跑生成脚本。**效果不在这里**：这一版只解决「抽到的是哪张卡」，")
A("## 66 张卡的效果是另一个量级的工作，见 docs/PRD差异对照.md 第五节。")
A("##")
A("## 两套池的结构不一样（PRD 卡牌设定）：")
A("##   免疫 —— 按抗原记忆等级切池，`immune[等级]` 是它在该池的权重，0 = 不在该池")
A("##   癌症 —— 不分等级，永远一个池，但**按世界回合分三期**（1—9 / 10—19 / 20—30），")
A("##            `cancer[期]` 是该期的权重")
A("class_name CWCardData")
A("extends RefCounted")
A("")
A("enum Kind { EVENT, INSTANT, PERMANENT }   ## 事件 / 即时技能 / 永久技能")
A("")
A("const KIND_NAMES := {")
A('\tKind.EVENT: "事件", Kind.INSTANT: "即时", Kind.PERMANENT: "永久",')
A("}")
A("")
A("## 卡名 → { kind, immune: [I, II, III, X], cancer: [前期, 中期, 后期] }")
A("const CARDS := {")
for n in names:
    c = cards[n]
    A('\t"%s": { "kind": Kind.%s, "immune": %s, "cancer": %s },'
      % (n, c["kind"], str(c["immune"]).replace(" ", ""), str(c["cancer"]).replace(" ", "")))
A("}")
A("")
A("")
A("## 癌症卡池的分期：第 1—9 回合 = 前期，10—19 = 中期，20—30 = 后期。")
A("static func cancer_phase(round_no: int) -> int:")
A("\tif round_no < 10:")
A("\t\treturn 0")
A("\treturn 1 if round_no < 20 else 2")
A("")
A("")
A("## 某一方此刻的候选池：返回 [{ name, weight }]，权重 > 0 的才在里面。")
A("## **顺序固定**（卡名字典序）—— 权重抽取要同种子可复现。")
A("static func pool_of(faction: int, immune_level: int, round_no: int) -> Array:")
A("\tvar out: Array = []")
A("\tvar phase := cancer_phase(round_no)")
A("\tfor name in CARDS:")
A("\t\tvar c: Dictionary = CARDS[name]")
A("\t\tvar w: int = c[\"immune\"][immune_level] if faction == CWData.Faction.IMMUNE \\")
A("\t\t\telse c[\"cancer\"][phase]")
A("\t\tif w > 0:")
A('\t\t\tout.append({ "name": name, "weight": w })')
A("\treturn out")
io.open(OUT, "w", encoding="utf-8", newline="\n").write("\n".join(lines) + "\n")

ev = sum(1 for c in cards.values() if c["kind"] == "EVENT")
ins = sum(1 for c in cards.values() if c["kind"] == "INSTANT")
per = sum(1 for c in cards.values() if c["kind"] == "PERMANENT")
print("%d 张唯一卡：事件 %d / 即时 %d / 永久 %d" % (len(cards), ev, ins, per))
for lv, nm in enumerate(["I", "II", "III", "X"]):
    sub = [n for n in names if cards[n]["immune"][lv] > 0]
    print("  免疫 %-3s 池 %2d 张，权重合计 %d" % (nm, len(sub), sum(cards[n]["immune"][lv] for n in sub)))
for ph, nm in enumerate(["前期", "中期", "后期"]):
    sub = [n for n in names if cards[n]["cancer"][ph] > 0]
    print("  癌症 %s 池 %2d 张，权重合计 %d" % (nm, len(sub), sum(cards[n]["cancer"][ph] for n in sub)))
