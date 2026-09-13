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

## Windows 控制台默认 GBK，编不出 ✗ 这类符号。2026-08-31 踩过：
## 工具**恰好在查到问题时**崩掉（没问题时不打这些行，反而看不出来）。
## 标记一律用 ASCII，并给 stdout 兜一层 errors="replace"。
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
PRD = os.path.join(os.path.dirname(REPO), "Cell_War_玩法PRD.md")   # PRD 在仓库外（2026-09-11 起叫这个名）
DATA = os.path.join(REPO, "game", "scripts", "core", "cw_data.gd")

# 常量 -> PRD 里应当出现的原文片段。比对前两边都去掉空白，
# 所以片段里可以照抄 PRD 的换行与加粗；但 PRD 的 `\` 会被剥掉，LaTeX 要写成 frac/times。
#
# **值可以是一个串，也可以是一串串**（2026-09-09 加）。数组/字典常量里装着好几个数，
# 一条锚点只能钉住其中一个 —— 比如 `IMMUNE_MOVE_CANCEROUS := [10, 8, 7, 7]`，
# 只对「降为0.7」的话，II 级那档从 0.8 改成别的值这里照样绿。给一串，每条都要找得到。
MAP = {
    # ---- 棋盘与胜负 ----
    "TOTAL_TILES":            "127枚六边形组织格",
    ## 定案 B（2026-09-01）：门槛要连续两个世界回合末都达标；常量 2 对应「连续两个」
    "CANCER_WIN_HOLD_ROUNDS":  "且该条件在**连续两个世界回合结束时**均成立",
    "CANCER_WIN_WEIGHTED":    "癌组织格数+2times固化癌组织格数",
    "LIMIT_ROUND":            "第15世界回合后",
    # ---- 开局 ----
    "INIT_ENERGY":            "免疫细胞初始拥有3点能量",
    "INIT_ENERGY_CANCER":     "癌细胞初始拥有6能量",
    # ---- 收入 ----
    ## AEROBIC_MULT / AEROBIC_FLOOR / ANAEROBIC_PER_CANCER 见 INTENTIONAL：都是**已停用的对照档**
    ## 线性式的老常量（`anaerobic_block_coef=0` 时才走）。新公式里固化是「+全图固化癌组织个数」，
    ## 系数 1.0 就藏在那个加号里 —— 对到公式那一句上，PRD 一改公式这里就会失配。
    "ANAEROBIC_PER_SOLID":    "times2.8+全图固化癌组织个数",
    ## 2026-09-07 换的两条呼吸公式：各段分别对一个常量（脚本先剥反斜杠、再去掉所有空白）
    ## v10（2026-09-10 issue #13）起有氧改按等级查表，四个数不等差；线性式的 BASE/STEP 挪进 INTENTIONAL
    "AEROBIC_BY_LEVEL":       "能量=2~|~3~|~4.5~|~5",
    "ANAEROBIC_BLOCK_EXP":    "连通块癌组织个数^{0.3}",
    ## 指数 2026-09-12 起也按人数分档：四人 0.3、六人 0.3（早上那版 0.35，issue #29 当晚改回）；外面的 max{2, …} 是每细胞兜底
    "ANAEROBIC_BLOCK_EXP_BY_PLAYERS": ["连通块癌组织个数^{0.3}times2.0", "连通块癌组织个数^{0.3}times2.8"],
    "ANAEROBIC_FLOOR":        "能量=max{2,",
    "ANAEROBIC_BLOCK_COEF":   "^{0.3}times2.8",
    ## 无氧系数**按人数分两档**（PRD 2026-09-09 落字）。两条锚点各钉一档 ——
    ## 只对其中一条的话，另一档被改了这里照样绿。
    ## 表里的 2 人局（2.8）PRD 没定，沿用六人档 —— 2 人局在平衡目标外，不是待办（《PRD差异对照》§7.6）。
    "ANAEROBIC_BLOCK_COEF_BY_PLAYERS": ["四人局$能量=max{2,frac{连通块癌组织个数^{0.3}times2.0",
                                        "六人局：$能量=max{2,frac{连通块癌组织个数^{0.3}times2.8"],
    "ANAEROBIC_SOLID_BONUS":  "+全图固化癌组织个数",
    # ---- 免疫行动 ----
    "IMMUNE_DRAW_COST":       "【基因表达】：消耗0.5**能量**抽卡，每行动回合最多发动3次",
    "DRAW_MAX_PER_TURN":      "每行动回合最多发动3次",
    "ATTACK_MAX_PER_TURN":    "每个免疫细胞每个行动回合最多攻击3次",
    "ATTACK_DMG_SUCCESS":     "1/2概率成功，癌细胞-1能量",
    "ATTACK_DMG_CRIT":        "1/6概率大成功，癌细胞-2能量",
    "COUNTER_DMG_ON_FAIL":    "1/3概率无效，不造成伤害，自身-0.5能量",
    "IMMUNE_RESPAWN_ENERGY":  "复活**，**初始1能量",
    "MACRO_HEAL_PURIFY":      "巨噬细胞每通过【迁移】触发一次【净化】，恢复0.2能量",
    "MACRO_MOVE_NET_MIN":     "恢复量不超过 本次迁移实际支付的能量-0.1",
    "ANTIBODY_COST":          "【抗体】：消耗1点能量",
    "ANTIBODY_DAMAGE":        "默认能损为**1.5能量**",
    "ANTIBODY_MAX_PER_ROUND": "【抗体】：消耗1点能量，使所有与**健康组织**邻接的癌细胞",
    "TOXIN_COST":             "【细胞毒素】：消耗1点能量",
    "TOXIN_MAX_PER_ROUND":    "T细胞每**世界回合**最多发动3次",
    "LYSE_COST":              "【裂解】：T细胞消耗1点能量可将1环内的",
    ## 2026-09-07 线上版把「坏死」收成一条通用状态、统一两个世界回合，
    ## 【放疗】卡面那句「五轮」随之消失 —— 两个常量现在对同一句话（来源不同，保留两个常量）。
    "NECROSIS_TOXIN":         "「坏死」持续两个世界回合",
    ## 数组常量：给多条锚点，每条都要在 PRD 里找到（II / III 两档 + I 级的基准价）
    "IMMUNE_MOVE_CANCEROUS":  ["耗能降为0.8", "消耗1**能量**移动到**癌性组织**"],   # III 级的 0.7 2026-09-12 删了
    "IMMUNE_MOVE_HEALTHY":    "消耗0.5**能量**移动到**健康组织",
    ## 这张是**六人档兼缺省**；四人档由 LEVEL_MIN_MEMORY_BY_PLAYERS 单独核
    "LEVEL_MIN_MEMORY":       ["6人10-29抗原记忆", "6人30-69抗原记忆", "6人≥70抗原记忆"],
    # ---- 卡牌规则 ----
    "HAND_MAX":               "每个细胞最多持有8张卡牌，超过8张时需要弃置到8张",
    # ---- 癌方行动 ----
    "CANCER_DRAW_COST":       "【基因表达】：消耗1**能量**抽卡，每行动回合最多发动3次",
    "MUTATE_COST":            "【突变】：消耗0.5**能量，***每个癌细胞每世界回合最多发动1次*",
    "MUTATE_EXTRA_LOSS":      "1/3概率再扣除0.8**能量**，削减2**抗原记忆**",
    "CANCER_MOVE_CANCEROUS":  "消耗0.2能量向**癌性组织**移动1格",
    "CANCER_MOVE_HEALTHY":    "消耗1.2**能量**向**健康组织**移动1格",
    "REVIVE_ENERGY":          "复活，获得2能量",
    # ---- 癌细胞种类 ----
    "MELANOMA_HOMING_COST":   "若自身处于血管格，可消耗1能量",
    ## issue #22（2026-09-11）：门槛之上每多一格再降 0.1。两个常量各钉公式的一段
    "PSEUDOPOD_COST":         "基础消耗能量=0.5-0.1times(目标健康组织相邻癌性组织数-3)",
    "PSEUDOPOD_DISCOUNT":     "0.5-0.1times(目标健康组织相邻癌性组织数-3)",
    "PSEUDOPOD_MIN_ADJ":      "若目标健康组织与至少3格癌性组织相邻",
    "MUCUS_MIN_ENERGY":       "消耗自身全部能量（至少2点）并死亡",
    "MUCUS_RADIUS":           "2环内所有组织进入「黏液侵染」状态",
    "MUCUS_MAX_CONVERT":      "随机选择最多10格健康组织立即转化为癌组织",
    "MUCUS_IMMUNE_LOSS":      "范围内的免疫细胞受到2能量损失",
    "ARMOR_REDUCTION":        "【I-囊性护甲】：每世界回合第一次能量损失-0.5，不限来源",
    "OSTEO_BARRIER_PERCENT":  "受到的能量损失为40%",
    "HOMING_SPREAD":          "并将相邻格中随机最多3格转为癌组织",
    "ANTIBODY_NO_TARGET_X":   "2/3概率X=2，1/3概率X=3",
    "SCLC_MOVE_HEALTHY":      "【I-极简胞浆】：迁移至**健康组织**的能量消耗降为0.7点",
    "METASTASIS_COST":        "【I-转移】：消耗1点能量向某方向跃进5格",
    "METASTASIS_RANGE":       "向某方向跃进5格",
    "WARBURG_PERCENT":        "在无氧呼吸中能获得110%原产出",
    # ---- 固化 / 场景事件 ----
    ## 环境恶化（2026-09-11）：三档表，I/II 期钉规则原句、III 期钉恶化效果那句
    "SOLIDIFY_THRESHOLD_BY_STAGE": ["计数到达3时**癌组织**转为**固化癌组织**", "【固化】所需的固化计数降低为2"],
    "SOLIDIFY_STEP":          "【E-固化】：癌细胞停留的**癌组织**的固化计数+1",
    "SOLIDIFY_DECAY":         "固化计数>0且没有癌细胞在其上的**癌组织**，固化计数-0.5",
    "SOLIDIFY_ACCEL_AT":      "癌组织固化计数从1达到>=2上时，立即转化为固化癌组织",
    "PRESSURE_PER_ADJ":       "则该免疫细胞损失（相邻**癌性组织**数量－2）×0.5能量",
    "PRESSURE_FREE_ADJ":      "相邻**癌性组织**不超过2格时，不造成能量损失",
    ## 环境恶化（2026-09-11）：基数与每固化各三档，每档钉 PRD 里对应那一句
    "PROLIFERATE_BASE_BY_STAGE": ["r_{增生概率}=3%+0.5%times所有相邻癌性组织联通块中固化癌组织数",
                                  "r_{增生概率}=3.5%+1%times所有相邻癌性组织联通块中固化癌组织数",
                                  "r_{增生概率}=4%+1%times所有相邻癌性组织联通块中固化癌组织数"],
    # ---- 特殊组织 ----
    "CORE_STORE_MAX":         "代谢核心（3个）：S阶段产出能量，存储上限为2能量",
    "CORE_HEALTHY_PERIOD":    "健康时，每2个世界回合产生1能量",
    "CORE_HEALTHY_GAIN":      "健康时，每2个世界回合产生1能量",
    "CORE_CANCER_GAIN":       "癌症时，每世界回合产生0.4能量",
    "MARROW_STORE_MAX":       "骨髓（6个）：S阶段产出**抽卡机会**，存储上限为1次",
    "MARROW_HEALTHY_PERIOD":  "健康时，每3个世界回合产生1次抽卡机会",
    "MARROW_CANCER_PERIOD":   "癌症时，每2个世界回合产生1次抽卡机会",
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
    # ---- 2026-09-09 补：此前「没映射」的那 20 条 ----
    "CHEMO_COST":             "【I-趋化源】：消耗3能量在全局任意位置建立趋化源",
    ## 时长口径 2026-09-13（issue #33）从「2 世界回合」换成「1 完整回合」——
    ## 两个数字都在 PRD 那一句里，各钉各的
    "CHEMO_FULL_TURNS":       "效果持续1完整回合",
    "CHEMO_COOLDOWN_ROUNDS":  "趋化源消失后，技能冷却1世界回合才能再次使用",
    "CHEMO_IMMUNE_PCT":       "费用减免30%",
    "CHEMO_SELF_PCT":         "自身减免50%",
    "CHEMO_CANCER_PCT":       "癌细胞向远离该格的方向迁移时，费用增加20%",
    "MARK_RANGE":             "任意时刻处于树突状细胞2环内的癌细胞自动获得【标记】",
    "SYSTEMIC_CLEAR":         "选择最多5格，将其转为健康组织",
    "MUCUS_MOVE_SURCHARGE":   "迁移进入「黏液侵染」格时，迁移耗能+0.2",
    "MUTATE_MEMORY_CUT":      "削减2**抗原记忆**",
    "NECROSIS_AEROBIC_PCT":   "站在「坏死」状态组织上的免疫细胞该世界回合获得【有氧呼吸】的能量减半",
    "DIFFERENTIATE_MIN_LEVEL": "解锁III级卡池、主动技能【分化】",
    "OSTEO_OSSIFY_COST":      "【I-骨样硬化】：消耗2能量，标记自身所在的**癌组织**",
    ## ⚠ 常量是 2 而 PRD 写「持续3世界回合」，**两者一致**：通用规则 3 说
    ## 「持续 n 世界回合」= 第「当前 + n − 1」回合 E 阶段，3 − 1 = 2。
    ## 所以这里只能对到那句话上、对不到数字上 —— PRD 的 3 一改，这条就会失配。
    "OSTEO_OSSIFY_ROUNDS":    "E-硬化：标记持续3世界回合",
    ## 微环境压迫公式：四个权重各对公式里的一段（脚本先剥反斜杠、再去空白）
    "PRESSURE_DIV":           "frac{1}{4}",
    "PRESSURE_CANCER_W":      "(相邻癌组织+",
    "PRESSURE_SOLID_W":       "相邻固化癌组织times2",
    "PRESSURE_HEALTHY_W":     "-相邻健康组织",
    ## 字典常量（工具 2026-09-09 起也扫，见 main 的解析）
    "INIT_CANCER_TILES":      ["4人局X=15", "6人局X=24"],
    "LEVEL_MIN_MEMORY_BY_PLAYERS": ["4人0~9抗原记忆", "4人10~19抗原记忆", "4人20~49抗原记忆", "4人≥50抗原记忆"],
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
    ## 卡面写的是「能量消耗降低0.5」——减量，不是「降为 0.5」。
    # ---- 【效应应答】与树突【E-组织黏连】（2026-09-07 实装）----
    "PROLIFERATE_SOLID_BY_STAGE": ["3%+0.5%times所有相邻癌性组织联通块中固化癌组织数",
                                   "3.5%+1%times所有相邻癌性组织联通块中固化癌组织数",
                                   "4%+1%times所有相邻癌性组织联通块中固化癌组织数"],
    "PRESSURE_MUL_BY_STAGE":  ["frac{1}{4}times(相邻癌组织+相邻固化癌组织times2-相邻健康组织)",
                               "【E-微环境压迫】能量损失为1.5倍", "【E-微环境压迫】能量损失为2倍"],
    "ROOTED_BY_STAGE":        ["相邻最多一格**癌组织**的固化计数+1", "相邻最多三格**癌组织**的固化计数+1"],
    "EFFECTOR_COST":          "每次发动统一消耗**20效应记忆**",
    "ADHESION_RANGE":         "传染给2环内的所有癌细胞",
    "HUNT_CHEMO_ROUNDS":      "【追踪趋化源】持续2世界回合",
    "CHAIN_PHAGO_MAX":        "最多触发5次",
    "CHAIN_PHAGO_BONUS":      "每连续净化1格，下一次攻击额外+0.5伤害",
    "EXCALIBUR_SPLASH_PCT":   "主射线相邻的所有癌组织有60%概率进入范围",
    "EXCALIBUR_RAY_DMG":      "主射线上的所有癌细胞损失2能量",
    "EXCALIBUR_SPLASH_DMG":   "侧向波及上的所有癌细胞损失1能量",
    "MATURED_ANTIBODY_CUT":   "【抗体】的能量消耗降低0.5",
    "MATURED_ANTIBODY_DMG":   "【抗体】对每个癌细胞造成的初始能量损失为2",
    "PHAGO_THRESHOLD":        "若目标癌细胞剩余能量不超过0.5，则直接死亡",
    "PHAGO_THRESHOLD_MACRO":  "则该阈值提高至1.5",
    "CYTOTOX_EXTRA":          "使目标额外损失1能量",
    "WATCH_RANGE":            "自身3环内的健康组织不进行【增生】和【侵蚀】判定",
    "RADIO_REGION":           "共10格且彼此连通的组织区域",
    "NECROSIS_RADIO":         "「坏死」持续两个世界回合",
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
    # 下面两条是 2026-08-31 的平衡实验（口径 #92），PRD 里都还没有对应措辞，
    # 定案后要回写 PRD 并把它们移回 MAP —— 见《PRD差异对照》§七
    "ANAEROBIC_CAP":       "PRD 写「不超过10点」；引擎改为 999.0 形同不封顶，改封账面余额",
    "ENERGY_CAP_PER_ROUND": "PRD 没有「细胞能量上限」这条，2026-08-31 新增的平衡实验",

    # ---- 2026-09-09 补：以下都**不是 PRD 里的数**，逐条写清为什么 ----
    ## 三个**已停用的对照档**：默认路径根本不走它们，PRD 里自然也没有对应句子。
    ## 想扫回旧行为时用对应旋钮（abase=0 / asqrt=0），那时才轮到它们。
    "AEROBIC_MULT":        "旧的盘面式有氧（(健康−坏死)/总格数×3）。09-04 换成等级式后只在 abase=0 时走",
    "AEROBIC_FLOOR":       "有氧低保，**值就是 0 = 已关**（09-05：等级式自带基数，低保会把六人局的 1.8 顶回 2.0）",
    "ANAEROBIC_PER_CANCER": "旧的线性无氧（每癌组织 ×0.4）。09-04 换成开方式后只在 asqrt=0 时走",
    ## 均分与按人数分档：PRD 只给一个共用公式，「怎么分给多个细胞」「几人局用哪个数」
    ## 都是电子版自己的事。两张分档表见《PRD差异对照》§10.17 / §七。
    "AEROBIC_SPLIT_REF":   "有氧均分的标定人数；均分默认已关（asplit=0），留作对照档",
    "AEROBIC_LEVEL_BASE_BY_PLAYERS": "09-05 方案 f 的按人数基数表，默认 abase=20 不走它，留作 abase=-1 的对照档",
    ## ANAEROBIC_BLOCK_COEF_BY_PLAYERS 2026-09-09 已移回 MAP —— Kevin 当天把 PRD 改成
    ## 按人数分两档，那是此前唯一一处**活跃**偏离，现在两边一致。
    ## 纯电子版的东西：一个是单位换算，一个是界面。
    "AEROBIC_LEVEL_BASE":  "09-07 线性式有氧的基数；v10 起改按等级查表（AEROBIC_BY_LEVEL 在 MAP 里），留作 abase 对照档",
    "AEROBIC_LEVEL_STEP":  "同上，线性式的步长，已停用",
    "FEED_KEEP":           "左侧出牌列最多留几张，纯界面，PRD 没有也不该有",
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
        ## 字典常量也要扫（2026-09-09）。**这是个真盲区**：按人数分档的表
        ## （INIT_CANCER_TILES / LEVEL_MIN_MEMORY_BY_PLAYERS …）装的全是规则数值，
        ## 却因为长得不像 `[1, 2]` 而整个躲过了核对。只收一行写完、值里只有数字和方括号的，
        ## 那正是分档表的样子；FACTION_ORDER 那类装枚举/字符串的不会被收进来。
        m = re.match(r"const (\w+) *:= *\{([\d,:\[\] ]+)\}$", t)
        if m:
            consts[m.group(1)] = "{%s}" % m.group(2).strip()

    bad, unmapped = [], []
    for k in sorted(consts):
        if k in INTENTIONAL:
            continue
        if k not in MAP:
            unmapped.append(k)
            continue
        want = MAP[k] if isinstance(MAP[k], (list, tuple)) else [MAP[k]]
        missing = [w for w in want if re.sub(r"\s+", "", w) not in prd_flat]
        if missing:
            bad.append((k, missing))

    print("核对 %d 个常量：对上 %d，对不上 %d，没映射 %d"
          % (len(consts), len(consts) - len(bad) - len(unmapped) - len(INTENTIONAL),
             len(bad), len(unmapped)))
    for k, missing in bad:
        v = consts[k]
        print("  [不符] %-22s %-14s PRD 里找不到：%s"
              % (k, v, "｜".join(str(m) for m in missing)))
    for k in unmapped:
        print("  [没映射] %-20s %-14s 要人工判断它在 PRD 的哪一句" % (k, consts[k]))
    if bad or unmapped:
        print("\n对不上 = PRD 改了引擎没跟，或引擎多做了一步（后者更贵，见 HAND_MAX / 原发灶）")
        return 1
    print("全部对上。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
