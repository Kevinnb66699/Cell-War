# -*- coding: utf-8 -*-
"""从 PRD 生成 cw_card_data.gd —— 卡名/类别/各池权重 + **效果原文**。

效果文本是 2026-09-01 加的，为了「悬停查看详情」。**逐字照抄 PRD，不做任何改写**：
一改写就等于把规则抄了第二份（架构约定 #10），PRD 一动就对不上。
所以卡面上会原样出现「0.8 / 1.5 / 2」这种分档写法 —— 那正是 PRD 的写法。

⚠ **没有任何东西保证引擎的实现与这段文字一致**。分档数值是写死在
`cw_card_fx.gd` 里的字面量（如 `[8, 15, 20][_phase()]`），既不在 CWData 也不在
CWTuning，`prd_crosscheck.py` 那套反向核对够不着它们。这是行为层本来就有的空白
（见架构说明书「行为层没有自动化守护」），不是这次新引入的——但卡面把它变得**可见**了：
以前实现和 PRD 对不上只有读代码的人知道，现在玩家会照着卡面做决策。
改 `cw_card_fx.gd` 里的数时，请同步改 PRD 并重跑本脚本。
"""
import re, io

PRD = "D:/Projects/SpringSense/2026-2027/Cell War/Cell_War PRD.md"
OUT = "D:/Projects/SpringSense/2026-2027/Cell War/Cell-War/game/scripts/core/cw_card_data.gd"

L = [l.rstrip() for l in io.open(PRD, encoding="utf-8")]
clean = lambda s: s.replace("\\", "").strip()
start = next(i for i, l in enumerate(L) if l.startswith("## 免疫卡池"))
end = next(i for i, l in enumerate(L) if l.startswith("# 世界事件"))

POOL_KEY = {"I级卡池": 0, "II级卡池": 1, "III级卡池": 2, "X级卡池": 3}
KIND = {"事件": "EVENT", "即时技能": "INSTANT", "永久技能": "PERMANENT"}


def _flush(pending):
    """把攒好的一段效果文写回卡上。

    **必须在边界上一次性写，不能边读边写**：卡是靠「下一张卡的标题」收尾的，
    没有结束事件；而同名卡会在多个免疫池里各出现一次（I/II/III/X），
    边读边写的话，第二次出现刚读到「效果：」这一行（内容在下一行）时，
    卡上就先被写成了空串，再和第一次的正文一比就炸。

    只做两件排版上的事，不碰字：去掉 markdown 的 `**` 粗体标记（点阵字渲染不了），
    列表项的 `- ` 换成 `· `（行首减号在满是数值的卡面上会被读成负号）。
    """
    if pending is None:
        return
    card, is_cancer, buf = pending
    if not buf:
        return
    text = re.sub(r"^- ", "· ", "\n".join(buf).replace("**", ""), flags=re.M)
    ## **同一阵营内**效果文应当一字不差（免疫卡会在 I/II/III/X 四个池里重复出现）。
    ## 不一致就是 PRD 自己的问题，得人去看。
    ##
    ## 跨阵营则允许不同：【代谢耦联】两边都有，措辞按阵营镜像
    ## （免疫版写「其他免疫细胞」、癌症版写「其他癌细胞」）。它是目前唯一一张。
    old = card["_eff"].get(is_cancer)
    assert old in (None, text), \
        "同名卡在同阵营的不同池里效果文不一致：\n[旧]%r\n[新]%r" % (old, text)
    card["_eff"][is_cancer] = text

pool = None
cards = {}          # name -> {kind, immune:[0,0,0,0], cancer:[0,0,0], effect}
cur = None
pending = None      # 非 None = (卡, 已攒的效果行)，在边界上由 _flush 写回
for raw in L[start:end]:
    s = clean(raw)
    if not s:
        continue
    if s.startswith("## ") or s.startswith("### "):
        _flush(pending); pending = None
        pool = s.lstrip("#").strip()
        cur = None
        continue
    m = re.fullmatch(r"\**【(.+?)】\**", s)
    if m:
        _flush(pending); pending = None
        n = m.group(1)
        cur = cards.setdefault(n, {"kind": None, "immune": [0, 0, 0, 0],
                                   "cancer": [0, 0, 0], "_eff": {}})
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
    elif s.startswith("效果："):
        ## PRD 里「效果：」有时自成一行、正文在下一行，所以内容为空是正常的
        assert pending is None, "一张卡出现了两段「效果：」：%s" % s
        pending = (cur, cur["_pool"] == "癌症卡池", [s[3:]] if s[3:] else [])
    elif pending is not None:
        ## 「效果：」后面的续行也算正文：列表项（- xxx）和补充段落都在这儿
        pending[2].append(s)
_flush(pending)      # 最后一张卡没有「下一张」来收尾

for c in cards.values():
    c.pop("_pool", None)
    assert c["_eff"], "没抽到效果文"
    ## effect = 这张卡所在池的正文；两边都有且措辞不同时，癌方那份放进 effect_cancer。
    ## 只有【代谢耦联】会走到第二种情况，所以不给 65 张卡都套一层阵营字典。
    c["effect"] = c["_eff"].get(False) or c["_eff"][True]
    other = c["_eff"].get(True)
    c["effect_cancer"] = other if other and other != c["effect"] else None
    c.pop("_eff")

def gd_str(s):
    """写成 GDScript 字符串字面量。换行必须转义成 \\n —— 生成的是单行 const 表，
    真换行会把 .gd 直接写坏（而且是在 66 张卡里找一处，很难查）。"""
    return '"%s"' % (s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n"))


names = sorted(cards)          # 固定顺序 —— 权重抽取要同种子可复现
lines = []
A = lines.append
A("## cw_card_data.gd —— 卡牌的**身份**：卡名、类别、各池权重、**效果原文**")
A("##")
A("## **本文件由 tools 从 PRD 生成，不要手改** —— 改了下次重生成就没了。")
A("## PRD 改卡池或改卡面文字时重跑 `tools/gen_card_data.py`。")
A("##")
A("## `effect` 是**给玩家看的 PRD 原文**（2026-09-01 加，为了手牌悬停详情），")
A("## 不是引擎的执行依据 —— 效果怎么算住在 `cw_card_fx.gd`。")
A("## ⚠ **两边没有自动核对**：分档数值是 fx 里的字面量（如 `[8, 15, 20][_phase()]`），")
A("## `prd_crosscheck.py` 够不着。改 fx 里的数时请同步改 PRD 并重跑生成脚本，")
A("## 否则卡面会拿着 PRD 的旧数字骗玩家。")
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
A("## 卡名 → { kind, immune: [I, II, III, X], cancer: [前期, 中期, 后期], effect }")
A("const CARDS := {")
for n in names:
    c = cards[n]
    A('\t"%s": { "kind": Kind.%s, "immune": %s, "cancer": %s,'
      % (n, c["kind"], str(c["immune"]).replace(" ", ""), str(c["cancer"]).replace(" ", "")))
    if c["effect_cancer"]:
        A('\t\t"effect": %s,' % gd_str(c["effect"]))
        A('\t\t"effect_cancer": %s },' % gd_str(c["effect_cancer"]))
    else:
        A('\t\t"effect": %s },' % gd_str(c["effect"]))
A("}")
A("")
A("")
A("## 给玩家看的效果原文。**只有【代谢耦联】两边措辞不同**（免疫版说「其他免疫细胞」、")
A("## 癌症版说「其他癌细胞」），它是唯一同时进两个卡池的卡，所以只有它带 effect_cancer。")
A("## 其余卡两边共用一份 —— 不给 65 张卡都套一层阵营字典。")
A("static func effect_of(name: String, faction: int) -> String:")
A("\tvar c: Dictionary = CARDS.get(name, {})")
A("\tif c.is_empty():")
A('\t\treturn ""')
A("\tif faction == CWData.Faction.CANCER and c.has(\"effect_cancer\"):")
A('\t\treturn c["effect_cancer"]')
A('\treturn c["effect"]')
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
