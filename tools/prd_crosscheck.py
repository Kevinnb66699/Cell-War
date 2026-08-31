# -*- coding: utf-8 -*-
"""PRD ↔ 引擎 反向交叉核对：拿引擎的每一个常量去 PRD 里找出处。

**为什么要有这个工具**：历次人工比对都是**单向**的——拿 PRD 逐条问「引擎做到了吗」。
那个方向查不出「引擎有、PRD 没有」这一类，而那正是最贵的一类：
【原发灶】（癌细胞出生格开局即固化）就这么漏了两周，最后是 Kevin 实测时问出来的。
2026-08-31 补做反向核对时，同样的方法立刻又抓到一条 `HAND_MAX`。

**用法**：
    python tools/prd_crosscheck.py

**它做什么**：把 `cw_data.gd` 里每个数值常量，对到 PRD 里应当出现的那句原文上，
去 PRD 里确认那句话真的存在。对不上 = 要么 PRD 改了没跟、要么引擎多做了一步。

**它不做什么**：不判断语义。机器分不清「1 抗原记忆」和「1.0 能量」，
所以这里只做「这句话在不在 PRD 里」的存在性检查——数字写在期望串里，
PRD 一改数字就会失配。语义仍然要人看。

**加了新常量怎么办**：补一条 MAP。**故意不给 MAP 兜底默认值** ——
没映射的常量会被单独列出来要求人工判断，这正是 HAND_MAX 暴露出来的路径。
"""
import io
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
PRD = os.path.join(os.path.dirname(REPO), "Cell_War PRD.md")   # PRD 在仓库外
DATA = os.path.join(REPO, "game", "scripts", "core", "cw_data.gd")

# 常量 -> PRD 里应当出现的原文片段。比对前两边都去掉空白，
# 所以片段里可以照抄 PRD 的换行与加粗；但 PRD 的 `\` 会被剥掉，LaTeX 要写成 frac/times。
MAP = {
    # ---- 棋盘与胜负 ----
    "TOTAL_TILES":            "127枚六边形组织格",
    "CANCER_WIN_WEIGHTED":    "癌组织格数+2times固化癌组织格数",
    "LIMIT_ROUND":            "30回合后",
    # ---- 开局 ----
    "INIT_ENERGY":            "免疫细胞初始拥有3点能量",
    "INIT_ENERGY_CANCER":     "癌细胞初始拥有6点能量",
    # ---- 收入 ----
    "AEROBIC_MULT":           "frac{健康组织格数-坏死格数}{总格数}times3",
    "AEROBIC_FLOOR":          "每个免疫细胞每回合由此获得的能量不低于2点",
    "ANAEROBIC_CAP":          "每个癌细胞每回合由此获得的能量不超过10点",
    "ANAEROBIC_PER_CANCER":   "癌组织个数times0.4",
    "ANAEROBIC_PER_SOLID":    "固化癌组织个数times1",
    # ---- 免疫行动 ----
    "IMMUNE_DRAW_COST":       "【基因表达】：消耗0.5**能量**抽卡，每回合最多发动3次",
    "DRAW_MAX_PER_TURN":      "每回合最多发动3次",
    "ATTACK_MAX_PER_TURN":    "每个免疫细胞每个行动回合最多发动3次攻击",
    "ATTACK_DMG_SUCCESS":     "1/2概率成功，癌细胞-1能量",
    "ATTACK_DMG_CRIT":        "1/6概率大成功，癌细胞-2能量",
    "COUNTER_DMG_ON_FAIL":    "1/3概率失败，不造成伤害，自身-0.5能量",
    "IMMUNE_RESPAWN_ENERGY":  "复活**，**初始1能量",
    "MACRO_HEAL_PURIFY":      "巨噬细胞每触发一次【净化】，恢复0.3能量",
    "ANTIBODY_COST":          "【抗体】：消耗1点能量",
    "ANTIBODY_DAMAGE":        "使所有与**健康组织**邻接的癌细胞**能量**-1",
    "ANTIBODY_MAX_PER_ROUND": "B细胞每**世界回合**最多发动2次【抗体】",
    "TOXIN_COST":             "【细胞毒素】：消耗1点能量",
    "TOXIN_MAX_PER_ROUND":    "T细胞每**世界回合**最多发动3次",
    "LYSE_COST":              "【裂解】：若T细胞位于**固化癌组织**，消耗1点能量",
    "NECROSIS_TOXIN":         "两轮完整的世界回合结束后「坏死」状态被移除",
    "IMMUNE_MOVE_CANCEROUS":  "【迁移】迁移到**癌性组织**的耗能降为0.7",
    "IMMUNE_MOVE_HEALTHY":    "消耗0.5**能量**移动到**健康组织",
    "LEVEL_MIN_MEMORY":       "III级别（16-30抗原记忆）",
    # ---- 癌方行动 ----
    "CANCER_DRAW_COST":       "【基因表达】：消耗1**能量**抽卡，每回合最多发动3次",
    "MUTATE_COST":            "【突变】：消耗0.5**能量，***每个癌细胞每世界回合最多发动1次*",
    "MUTATE_EXTRA_LOSS":      "1/3概率再扣除1**能量**，削减3**抗原记忆**",
    "CANCER_MOVE_CANCEROUS":  "消耗0.2能量向**癌性组织**移动1格",
    "CANCER_MOVE_HEALTHY":    "消耗1.2**能量**向**健康组织**移动1格",
    "REVIVE_ENERGY":          "复活，获得2能量",
    # ---- 癌细胞种类 ----
    "MELANOMA_HOMING_COST":   "【早期血行转移】：消耗1点能量",
    "PSEUDOPOD_COST":         "本次移动的能量消耗为0.5",
    "PSEUDOPOD_MIN_ADJ":      "若目标健康组织与至少2格癌性组织相邻",
    "MUCUS_MIN_ENERGY":       "消耗自身全部能量（至少2点）并死亡",
    "MUCUS_RADIUS":           "自身所在格及周围2格范围内所有组织进入“黏液侵染”状态",
    "MUCUS_MAX_CONVERT":      "系统从中随机选择最多8格立即转化为癌组织",
    "MUCUS_IMMUNE_LOSS":      "范围内的免疫细胞受到2能量损失",
    "ARMOR_REDUCTION":        "【囊性护甲】：每世界回合第一次能量损失-0.5点",
    "SCLC_MOVE_HEALTHY":      "移动至**健康组织**的能量消耗永久降低为0.7点",
    "METASTASIS_COST":        "【转移】：消耗1点能量向某方向跃进5格",
    "METASTASIS_RANGE":       "向某方向跃进5格",
    "WARBURG_PERCENT":        "在无氧呼吸中能获得110%原产出",
    # ---- 固化 / 场景事件 ----
    "SOLIDIFY_THRESHOLD":     "计数到达3时**癌组织**转为**固化癌组织**",
    "SOLIDIFY_STEP":          "【E-固化】：癌细胞停留的（非新生**）癌组织**的固化计数+1",
    "SOLIDIFY_DECAY":         "固化计数>0且没有癌细胞在其上的**癌组织**，固化计数-0.5",
    "SOLIDIFY_ACCEL_AT":      "癌组织固化计数从1达到>=2上时，立即转化为固化癌组织",
    "PRESSURE_PER_ADJ":       "则该免疫细胞损失（相邻**癌性组织**数量－2）×0.5能量",
    "PRESSURE_FREE_ADJ":      "相邻**癌性组织**不超过2格时，不造成能量损失",
    "PROLIFERATE_PER_ADJ":    "按「相邻癌性组织数x4%」概率被转为**癌组织**",
    # ---- 特殊组织 ----
    "CORE_STORE_MAX":         "代谢核心（3个）：S阶段产出能量，存储上限为2能量",
    "CORE_HEALTHY_PERIOD":    "健康时，每二回合产生1能量",
    "CORE_HEALTHY_GAIN":      "健康时，每二回合产生1能量",
    "CORE_CANCER_GAIN":       "癌症时，每回合产生0.4能量",
    "MARROW_STORE_MAX":       "骨髓（6个）：产出**抽卡机会**，存储上限为1张",
    "MARROW_HEALTHY_PERIOD":  "健康时，每三回合产生1张卡牌",
    "MARROW_CANCER_PERIOD":   "癌症时，每二回合产生1张卡牌",
    # ---- 卡牌 ----
    "INFLAM_CHEMO_COST":      "该次迁移费用降为0.5能量",
    "CXCR3_CUT":              "每次迁移费用-0.5，最低为0.2",
    "MOVE_CUT_MIN":           "最低为0.2",
    "EMT_MOVE_COST":          "每次移动费用降为0.2能量",
    "MEMBRANE_CUT":           "自身受到的下一次能量损失-1.5，最低为0",
    "IFN1_CUT":               "该次损失-1，最低为0",
    "HYPOXIA_CUT":            "或癌细胞技能造成的能量损失-1",
    "OPSONIN_EXTRA":          "该次攻击额外造成0.5能量损失",
    "PERFORIN_EXTRA":         "该次攻击额外造成1能量损失",
    "PERFORIN_EXTRA_T":       "改为额外造成2能量损失",
    "AFFINITY_EXTRA":         "直接视为大成功，并额外造成1能量损失",
    "CASCADE_MAX_TILES":      "随机从目标癌细胞相邻的普通癌组织中选择最多2格",
    "LFA1_CUT":               "该次迁移费用-0.4，最低为0.2",
    "INFILTRATE_CUT":         "迁移费用额外-0.3，最低为0.2",
    "CRUISE_CUT":             "此后本回合每次【迁移】费用额外-0.2，最低为0.2",
    "SKILL_HEAL":             "每世界回合自身第一次触发【净化】后，恢复0.5能量",
    "AEROBIC_ADAPT":          "自身每次结算【有氧呼吸】时额外获得0.5能量",
    "AEROBIC_AUTOCRINE":      "自身每次结算【有氧呼吸】时额外获得0.8能量",
    "EXHAUST_FIRST_CUT":      "每世界回合自身第一次受到能量损失时，该次能量损失-1",
    "EXHAUST_PRESSURE_CUT":   "自身受到的能量损失额外-0.5，最低为0",
    "MATURED_ATTACK_EXTRA":   "该次能量损失额外＋0.5",
    "MATURED_ANTIBODY_COST":  "【抗体】的能量消耗由1降低为0.5",
    "MATURED_ANTIBODY_DMG":   "【抗体】对每个癌细胞造成的能量损失由1提高至1.5",
    "PHAGO_THRESHOLD":        "若目标癌细胞剩余能量不超过0.5，则直接死亡",
    "PHAGO_THRESHOLD_MACRO":  "则该阈值提高至1.5",
    "CYTOTOX_EXTRA":          "使目标额外损失1能量",
    "WATCH_RANGE":            "自身所在格及自身相邻3格中的健康组织不进行【增生】判定",
    "RADIO_REGION":           "共15格且彼此连通的组织区域",
    "NECROSIS_RADIO":         "五轮完整的世界回合结束后「坏死」状态被移除",
    "CHEMOTAX_STEP_COST":     "自身立即连续移动最多3步，每步消耗0.2能量",
}

# 有意不映射的：不是「PRD 里的数」，而是从别的数推出来的、或电子版自己的东西。
# 每一条都要写清楚为什么，否则下次又会有人以为是漏了。
INTENTIONAL = {
    "BOARD_RADIUS":        "由 127 格推出（半径 6 蜂窝 = 1+3×6×7），PRD 只给格数",
    "LIMIT_CANCEROUS":     "PRD 写的是 ⌊1/3×总格数⌋，42 是算出来的",
    "IMMUNE_RESPAWN_DELAY": "PRD 没有「罚停」概念，0 = 下一个 S 阶段即复活，与 PRD 一致",
    "INIT_CANCER_TILES":   "按人数分档，PRD 已落字（4 人 15 / 6 人 21），字典结构不便做串匹配",
    "SOLID_AT_CANCER_SPAWN": "【原发灶】已于 2026-08-31 取消（口径 #85），false = 与 PRD 一致",
}


def main():
    if not os.path.exists(PRD):
        print("找不到 PRD：%s" % PRD)
        return 1
    prd_flat = re.sub(r"\s+", "", io.open(PRD, encoding="utf-8").read().replace("\\", ""))

    consts = {}
    for line in io.open(DATA, encoding="utf-8"):
        t = line.strip()
        m = re.match(r"const (\w+) *:= *(-?\d+)", t)
        if m:
            consts[m.group(1)] = int(m.group(2))
        m = re.match(r"const (\w+)(?:: *Array\[int\])? *:= *\[([\d, ]+)\]", t)
        if m:
            consts[m.group(1)] = [int(x) for x in m.group(2).split(",")]

    bad, unmapped = [], []
    for k in sorted(consts):
        if k in INTENTIONAL:
            continue
        if k not in MAP:
            unmapped.append(k)
            continue
        if re.sub(r"\s+", "", MAP[k]) not in prd_flat:
            bad.append(k)

    print("核对 %d 个常量：对上 %d，对不上 %d，没映射 %d"
          % (len(consts), len(consts) - len(bad) - len(unmapped) - len(INTENTIONAL),
             len(bad), len(unmapped)))
    for k in bad:
        v = consts[k]
        print("  ✗ %-24s %-14s PRD 里找不到：%s" % (k, v, MAP[k]))
    for k in unmapped:
        print("  ? %-24s %-14s 没有映射，要人工判断它在 PRD 的哪一句" % (k, consts[k]))
    if bad or unmapped:
        print("\n对不上 = PRD 改了引擎没跟，或引擎多做了一步（后者更贵，见 HAND_MAX / 原发灶）")
        return 1
    print("全部对上。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
