## cw_data.gd —— 全局静态数据：棋盘布局、特殊组织位置、数值常量、种类/等级表
##
## 重要约定：所有能量数值用「十分能量」整数表示（3.0 能量 = 30），
## 避免浮点误差，保证回放/联机确定性（见 docs/规则电子化说明.md #10）。
## 特殊组织位置是临时布局（说明 #3），换地图只需改本文件常量。
class_name CWData
extends RefCounted

enum Tissue { HEALTHY, CANCER, SOLID }          # 健康 / 癌组织 / 固化癌组织
enum Special { NONE, CORE, MARROW, VESSEL }     # 无 / 代谢核心 / 骨髓 / 血管
enum Faction { IMMUNE, CANCER }                 # 免疫方 / 癌症方
enum ImmuneType { BASIC, B_CELL, T_CELL, MACRO, DENDRITIC }
enum CancerType { MELANOMA, SIGNET, OSTEO, SCLC }  # 黑色素瘤 / 印戒 / 骨肉瘤 / 小细胞肺癌

# ---- 棋盘（2026-08-27 团队定案：半径 4 / 61 格 → 半径 6 / 127 格）----
const BOARD_RADIUS := 6                  # 半径 6 蜂窝 = 1 + 3×6×7 = 127 格
const TOTAL_TILES := 127
## 初始癌组织格数。**PRD 是固定 15 格、不随人数变化**，这里按人数分档，是 2026-08-31
## 的平衡定案（候选乙，Kevin 拍板）。理由：免疫方阵营总收入随人数线性增长
## （【S-有氧呼吸】每个免疫细胞各拿全额、不按细胞数均分），癌方不随人数变
## （【E-无氧呼吸】连通块供能按块内癌细胞数均分）—— 人越多免疫越强，
## 用开局布局把这一档补回来。实测斜率约 7 个百分点/格，够细。
## 2 人局不在平衡目标内（Kevin 2026-08-31），沿用 PRD 的 15。
## PRD 改字见 [PRD差异对照 §七](../../../docs/PRD差异对照.md)。
## 2026-09-01 定案乙：6 人 21→24。两种对称 AI 都说 6 人局癌方比 4 人局再弱 6~14 个点，
## 而全局杠杆动 4 人的幅度是动 6 人的两倍，只有这张按人数分档的表能单独补 6 人（启发式 +15 点）。
const INIT_CANCER_TILES := { 2: 15, 4: 15, 6: 24 }


## 按人数取初始癌组织格数。表里没有的人数退回 PRD 的 15 ——
## `balance_scan.gd` 会拿 5 人／7 人这类非正式人数扫席位，不能让它崩。
static func init_cancer_tiles(n_players: int) -> int:
	return INIT_CANCER_TILES.get(n_players, 15)

# ---- 胜负 ----
# 2026-08-28：全部回到 PRD 原值。此前 20/85/64 是 2026-08-26 依据平衡测试定的暂行值，
# PRD 这一版已明确写死，团队决定「按 PRD 实现，差异不再讨论」。
# 两个胜利条件现在**都是 E 类**，在 E 阶段最后统一判定（见 CWWorld.e_phase）。
## 2026-09-01 定案乙：85→90。PRD 原值 85 = ⌈2/3×127⌉；固化门槛同日从 3 回合降到 2 回合，
## 固化在这条式子里算 2 格，不配套抬门槛就等于「更容易固化 = 更容易占地胜」。
const CANCER_WIN_WEIGHTED := 90          # 癌+2×固化 ≥ 90 时癌症即胜（PRD 原值 85）
const CANCER_WIN_HOLD_ROUNDS := 2        # 要**连续**这么多个世界回合末都达标才判胜（团队 2026-09-01 定案 B：首次达标只拉警报）
const LIMIT_ROUND := 30                  # 终局世界回合数
const LIMIT_CANCEROUS := 63              # 终局判定线 ⌊1/2×127⌋

# ---- 原发灶 ----
# 「每个癌症玩家的出生格开局即为固化癌组织」，2026-08-26 团队定案加入，
# 用来破解「复活需固化组织、固化需停留 2 回合、停留就被打死」的死循环。
#
# ⚠ **2026-08-31 Kevin 定案取消**（口径 #85）。原因是它从来不在 PRD 里 ——
# PRD「游戏开始」第 6 条明写「所有癌组织固化计数初始为 0」，而这条偏离一直没记档，
# 是 Kevin 实测时问「为什么一开局就固化了两个癌组织」才暴露的。
# 关掉之后引擎与 PRD 一致，**癌方失去开局那次复活容错**。
#
# 机制保留成旋钮（`CWTuning.solid_at_cancer_spawn`）而不是删掉，是因为它是平衡实验里
# 分量最重的一根杠杆：2026-08-27 实测把它关掉，「规则原文」在 2/4/6 人局癌胜率全部归零。
const SOLID_AT_CANCER_SPAWN := false

# ---- 免疫死亡与复活（2026-08-26 团队定案）----
# 免疫细胞可被杀死，但罚停若干回合后在随机健康组织复活（无限次）。
# 注意：造成免疫死亡的手段尚未定案（反弹反击可被免疫主动规避，见开发日志），
# 所以这套机制目前基本不会触发——等癌方主动伤害手段定下来才会真正生效。
# PRD 没有罚停条款：死亡的免疫细胞在**下一个** S 阶段结算【复活】。
# 死于第 N 回合的玩家阶段 → 第 N+1 回合 S 阶段复活，天然就缺席了一整轮。
const IMMUNE_RESPAWN_DELAY := 0
const IMMUNE_RESPAWN_ENERGY := 10        # PRD：复活初始 1.0 能量（癌细胞是 2.0，见 REVIVE_ENERGY）

# ---- 能量与费用（十分能量）----
const INIT_ENERGY := 30                  # 初始 3.0（免疫方）
## 癌细胞初始能量。**PRD 是双方同为 3.0**；2026-08-31 团队定案改成 6.0（口径 #89）。
## 起因：取消【原发灶】后癌细胞**早期死了就回不来**（复活要落在固化癌组织上，
## 而固化要原地停留到计数满 3，可停留就会被免疫打死），开局多 3 点能量是给这个兜底。
const INIT_ENERGY_CANCER := 60           # 初始 6.0

## 收入护栏（PRD 没有这两个概念，2026-08-31 团队定案加入，口径 #89）。
## 单位十分能量、每细胞每回合；0 = 不启用。
## ⚠ **低保值不能贴到 3.0**：有氧公式 (健康−坏死)/127×3 的**上界就是 3.0**（全盘健康时），
## 而开局就有 15 格癌组织，所以低保一旦定到 3.0，免疫收入就恒等于 3.0、
## **再也不随地盘萎缩而下降** —— 那不是兜底，是把免疫侧的负反馈整个关掉。
## 团队 2026-08-31 先提 3.0、当天改为 **2.0**：开局 2.6，还留着 0.6 的衰减空间。
## （同类事故有前科：《平衡测试报告》§四记过 6 人局低保 2.0 撞上供能 2.0，
## 导致那一档的反馈从第 1 回合就是死的。改这个数前先算一遍它会不会贴到上界。）
const AEROBIC_FLOOR := 20                # 免疫有氧呼吸下限 2.0
## 2026-08-31 起**实际上关掉**（999.0），改由下面的 ENERGY_CAP_PER_ROUND 管天花板。
## 常量保留、不删：它是 balance_scan 的 `ecap` 旋钮，随时要能扫回来做对照。
## 为什么换个管法：封的是「每回合进账」时，癌方把进账**囤起来**照样能一次兑现
## （试玩里囤到 25.5 一口气换 63 格），封住存量比封住流量直接。
const ANAEROBIC_CAP := 9990              # 癌症无氧呼吸上限 999.0（= 形同不封顶）

## 【E-能量上限】每个世界回合结算末，所有存活细胞的能量削到这个数（Kevin 2026-08-31 定）。
## 管的是**存量不是流量**：一回合能占多少格，从「攒了多久」变回「这一回合赚了多少」。
const ENERGY_CAP_PER_ROUND := 150        # 15.0
# PRD【I-免疫记忆】：III 级「迁移到癌性组织的耗能降为 0.7」；X 级「迁移耗能均改为 0.5」。
# 健康组织那一档 PRD 从头到尾都是 0.5，没有等级加成。
const IMMUNE_MOVE_HEALTHY := [5, 5, 5, 5]     # 迁移→健康，按等级 I/II/III/X
## ⚠ **X 级偏离 PRD（PRD 是 0.5）**：2026-09-03 Kevin 拍板「①+②」（平衡方案对比 §9.4～9.5），
## X 级净化价 0.5→0.7，与 III 级同价。MC v2 标尺下乙基线癌胜 6 人 15% / 4 人 23%，
## ①+② 把两档抬进 40~50 带。旋钮 `CWTuning.immune_move_cancerous[3]`，balance_scan `mvx=5` 可扫回 PRD 值。
const IMMUNE_MOVE_CANCEROUS := [10, 10, 7, 7] # 迁移→癌性，按等级 I/II/III/X（X 级 PRD 原值 5）
# PRD【S-有氧呼吸】：能量 = (健康组织格数 - 坏死格数) ÷ 总格数 × 3，四舍五入到十分位。
# 每个免疫细胞各得这么多，**不按免疫细胞数均分**。等级加成（II 级 4、III 级 3）已从 PRD 删除。
const AEROBIC_MULT := 30                      # 十分能量，即公式里的「×3」
const LEVEL_MIN_MEMORY := [0, 6, 16, 31]      # I/II/III/X 记忆门槛（PRD：III = 16~30，X = 31+）
const DRAW_MAX_PER_TURN := 3             # 【基因表达】每个行动回合最多 3 次（双方同）
# 手牌上限。**PRD 没有这一条**，是团队 2026-08-28 为了界面能一眼读懂而定的
# （右侧竖条里手牌数画成 8 个方块，满与不满一眼可见）。
# 满 8 张时【基因表达】的抽卡选项直接不出现；踩到骨髓也不发卡，卡留在骨髓里下次再拿。
const HAND_MAX := 8
const IMMUNE_DRAW_COST := 5
const CANCER_DRAW_COST := 10
const CANCER_MOVE_CANCEROUS := 2
## ⚠ **偏离 PRD（PRD 是 0.5）**：2026-08-31 平衡定案「候选乙」，Kevin 拍板。
## 癌细胞每移动到一格健康组织就【定殖】一格，所以这个数就是**占地单价**；
## 免疫【净化】一格是 1.0。0.5 对 1.0 的结果是实测占地转化比 4.6:1、癌方 100% 胜。
## 下面【伪足穿透】【极简胞浆】两个折扣按同比例一起抬，保持相对关系。
## 依据见 [平衡方案_PRD版 §八](../../../docs/平衡方案_PRD版.md)，PRD 改字见 PRD差异对照 §七。
const CANCER_MOVE_HEALTHY := 12

# ---- 癌细胞种类专属（PRD 癌细胞种类）----
# 恶性黑色素瘤
const MELANOMA_HOMING_COST := 10         # 【早期血行转移】1.0 能量，每世界回合 1 次
const HOMING_SPREAD := 3                 # 落点相邻格再随机最多 3 格转为癌组织（PRD 2026-09-01）
## ⚠ 偏离 PRD（PRD 是 0.2）：随占地单价同比例抬，见 CANCER_MOVE_HEALTHY。
## 注意连带影响：抬到 0.5 之后，【上皮—间质转化】的「改为 0.2」对黑色素瘤
## 从空操作变成真有用（0.5 → 0.2）—— 这是新出现的组合，已补测试。
const PSEUDOPOD_COST := 5                # 【伪足穿透】目标健康组织邻接 ≥2 格癌性组织时的移动费
const PSEUDOPOD_MIN_ADJ := 2
# 印戒细胞癌
const MUCUS_MIN_ENERGY := 20             # 【黏液破裂】至少 2.0 能量才能发动
const MUCUS_RADIUS := 2                  # 自身所在格及周围 2 格
const MUCUS_MAX_CONVERT := 10            # 其中随机最多 10 格立即转为癌组织
const MUCUS_IMMUNE_LOSS := 20            # 范围内免疫细胞损失 2.0
const ARMOR_REDUCTION := 5               # 【囊性护甲】受到的能量损失 -0.5，每世界回合 1 次
# 骨肉瘤：【骨样硬化】见 SOLIDIFY_STEP 的用法
## 【刚性屏障】2026-09-01 由「不能被攻击」改为减伤：站在固化癌组织上时受到的
## 能量损失只剩 40%。它是**倍减**（能量损失计算顺序第 4 步），不是固定减免。
const OSTEO_BARRIER_PERCENT := 40        # 受到的能量损失 ×40%，向下取整到十分位
# 小细胞肺癌
## ⚠ 偏离 PRD（PRD 是 0.3）：随占地单价同比例抬，见 CANCER_MOVE_HEALTHY
const SCLC_MOVE_HEALTHY := 7             # 【极简胞浆】移动至健康组织永久 0.7
const METASTASIS_COST := 10              # 【转移】1.0 能量
const METASTASIS_RANGE := 5              # 向某方向跃进 5 格
const WARBURG_PERCENT := 110             # 【瓦伯格超速糖酵解】无氧呼吸 110%，向上取整到十分位
const MUTATE_COST := 5
const MUTATE_EXTRA_LOSS := 10            # 突变第 3 种结果再扣 1.0（效果扣减，可致死）
const ANTIBODY_COST := 10
const ANTIBODY_DAMAGE := 15              # 每目标 -1.5
## 无目标时改为转化癌组织：2/3 概率 2 格、1/3 概率 3 格（PRD 2026-09-01）
const ANTIBODY_NO_TARGET_X := [2, 3]
const TOXIN_COST := 10
const TOXIN_MAX_PER_ROUND := 3           # PRD：T 细胞每世界回合最多 3 次
## B 细胞【抗体】每世界回合上限。**0 = 不限**：PRD 2026-09-01 删掉了「最多 2 次」（Kevin 确认），旧 PRD 是 2。
## 留常量只为给 `CWTuning.antibody_max_per_round` 当默认值 —— 2026-09-02「免疫后期引擎」对比表要把上限扫回来试。
const ANTIBODY_MAX_PER_ROUND := 0
const LYSE_COST := 10
const REVIVE_ENERGY := 20                # 复活获得 2.0
## 免疫细胞每个**行动回合**最多攻击几次。0 = 不限。
## **2026-08-31 Kevin 定案 3（口径 #88）**，起因 sug 2「免疫可以无限攻击有点赖」。
## 此前无上限，攻击只受能量约束、失败又只是弹回原格（位置不变），
## 于是「原地对同一目标连刷」只有钱的成本 —— 实测双方蒙特卡洛下单回合出现过 **14 次**，
## 而启发式最多 8 次：这条线是**搜索找出来的**，惩罚的是不钻空子的玩家。
## 定 3 是因为 ≤3 次已覆盖 99.8%（启发式）/ 97.6%（MC）的免疫回合 —— 只封极端、不动正常打法，
## 实测对胜率没有可测影响（36% → 33%，噪声内）。数据见 docs/平衡方案_PRD版.md §十。
const ATTACK_MAX_PER_TURN := 3
const ATTACK_DMG_SUCCESS := 10
const ATTACK_DMG_CRIT := 20
## 攻击失败（1/3「被癌细胞反弹」）时攻击者自身的能量损失。
## PRD【迁移】：「1/3概率失败，不造成伤害，**自身-0.5能量**，免疫细胞移动后被癌细胞反弹」。
## 2026-08-31 补实装（口径 #84）——此前引擎写死 0，是 61 格旧规则留下的。
const COUNTER_DMG_ON_FAIL := 5
## ⚠ **偏离 PRD（PRD 是 0.3）**：2026-09-03 Kevin 拍板「①+②」，【吞噬】回能**不再适用于净化**
## （攻击成功后按受击方损失回能那一条照旧）。起因是手打 D 局暴露的 X 级巨噬雪球：净化净成本
## 0.2/格、一回合清 30 格。旋钮 `CWTuning.macro_heal_purify`，balance_scan `mheal=3` 可扫回 PRD 值。
const MACRO_HEAL_PURIFY := 0             # 巨噬【吞噬】：每次净化回多少（PRD 原值 3 = 0.3；0 = 不回）
## 由【迁移】触发的那次净化，回能不超过「实付 - 0.1」——**一次迁移的净支出至少 0.1**。
## （默认已不回能，这道封顶只在旋钮 `macro_heal_purify` > 0 时起作用；常量与测试都留着。）
## 不设这条的话：迁移减免的共同地板是 0.2，回能 0.3 就成了走一格赚 0.1；
## 只封到「不超过实付」也仍是净支出 0，照样走不完（队友 2026-09-01 报的「无穷动」）。
const MACRO_MOVE_NET_MIN := 1            # 0.1
# 攻击那一档 PRD 是 ⌈受击方损失能量 ÷ 2⌉，随伤害变化，不是常数 —— 见 CWGame.immune_hit

# ---- 无氧呼吸 / 固化 ----
const ANAEROBIC_PER_CANCER := 4          # 每癌组织供能 0.4
const ANAEROBIC_PER_SOLID := 10          # 每固化癌组织供能 1.0

# 固化计数也用「十分」整数存（10 = 1 点）。PRD 里它不再是整数：
# 衰减 -0.5、骨肉瘤【骨样硬化】+1.5、癌症卡【基质硬化】+1/+1.5/+2。
## 2026-09-01 定案乙：3.0→2.0。现行 3.0 下固化**从不出现**（癌细胞蹲 3 回合 = 放弃约 30 格扩张，
## 三局手打 36 次盘面快照全是 0），癌方因此没有复活据点、三个细胞一团灭就结束。
const SOLIDIFY_THRESHOLD := 20           # 计数达 2.0 → 固化癌组织（PRD 原值 3.0）
const SOLIDIFY_STEP := 10                # 癌细胞停留：+1.0
const SOLIDIFY_DECAY := 5                # 无癌细胞停留：每世界回合 -0.5
const SOLIDIFY_ACCEL_AT := 20            # 【固化加速】：从 <2.0 涨到 ≥2.0 立即转化（定案 W4）

# ---- 场景事件（PRD 场景事件）----
# 【E-微环境压迫】：相邻癌性组织 > 2 格时，免疫细胞损失（相邻数 - 2）× 0.5。
# 这是癌方**第一个稳定的伤害来源** —— 在此之前免疫细胞几乎不可能死（旧说明 #23）。
# 【E-增生】：没有免疫细胞的健康组织，按「相邻癌性组织数 × 4%」的概率转为癌组织。
# 这条原本是团队 2026-08-26 的提案（引擎里做成了默认关闭的旋钮），PRD 已正式采纳。
const PROLIFERATE_PER_ADJ := 30          # 千分率：每个相邻癌性组织贡献 3%

const PRESSURE_FREE_ADJ := 2             # 前 2 格不造成损失
const PRESSURE_PER_ADJ := 5              # 超出部分每格 0.5

# 「坏死」：该格不为免疫【有氧呼吸】供能，但可以被【定殖】。按格记「还剩几个世界回合」。
const NECROSIS_TOXIN := 2                # T 细胞【细胞毒素】造成：两轮完整世界回合
const NECROSIS_RADIO := 5                # 免疫卡【放疗】造成：五轮
const RADIO_REGION := 15                 # 【放疗】区域：含起点的随机连通 15 格
const CHEMOTAX_STEP_COST := 2            # 【炎症性趋化】每步基准 0.2（再过移动费修正）

# ---- 修饰卡的数值（一次性/短时修饰，条目挂在 cell["mods"] 上）----
# 【炎症趋化】下一次向癌性组织迁移：费用**改为** 0.5（2026-08-30 定案 A，口径 #74）。
# 是改写不是减免——排在它前面的卡把价钱压到 0.5 以下时，它会抬回 0.5。
const INFLAM_CHEMO_COST := 5
const CXCR3_CUT := 5                     # 【CXCR3趋化】接下来 2 次向癌性组织迁移：每次 -0.5
const MOVE_CUT_MIN := 2                  # 迁移/移动减免类的共同下限 0.2（各卡面都写 0.2）
const EMT_MOVE_COST := 2                 # 【上皮—间质转化】接下来 N 次向健康组织移动：费用 0.2
const MEMBRANE_CUT := 15                 # 【细胞膜修复】下一次能量损失 -1.5
const IFN1_CUT := 10                     # 【I型干扰素】每个免疫细胞下一次能量损失 -1.0
const HYPOXIA_CUT := 10                  # 【缺氧适应】下一次微环境压迫/癌细胞技能损失 -1.0
const OPSONIN_EXTRA := 5                 # 【补体调理】最终成功/大成功额外 +0.5
const PERFORIN_EXTRA := 10               # 【穿孔素-颗粒酶】下次攻击成功额外 +1.0
const PERFORIN_EXTRA_T := 20             #   —— T 细胞改为 +2.0
const AFFINITY_EXTRA := 10               # 【高亲和力克隆】直接大成功并额外 +1.0
const CASCADE_MAX_TILES := 2             # 【补体级联】成功后随机转化目标相邻最多 2 格

# ---- 永久技能的数值（装备在 cell["equipped"]，被动查询）----
const LFA1_CUT := 4                      # 【LFA-1黏附】每行动回合首次向癌性组织迁移 -0.4
const INFILTRATE_CUT := 3                # 【组织浸润】每次向癌性组织迁移 -0.3
const CRUISE_CUT := 2                    # 【组织巡航】首移免费之后，本回合每次迁移 -0.2
const SKILL_HEAL := 5                    # 多个技能共用的「恢复 0.5」（模式识别/效应记忆/细胞因子网络/吞噬体巨噬）
const AEROBIC_ADAPT := 5                 # 【代谢适应】每次有氧结算 +0.5
const AEROBIC_AUTOCRINE := 8             # 【自分泌生存信号】每次有氧结算 +0.8
const EXHAUST_FIRST_CUT := 10            # 【耗竭抵抗】每世界回合首次损失 -1.0
const EXHAUST_PRESSURE_CUT := 5          #   —— 微环境压迫的损失额外 -0.5
const MATURED_ANTIBODY_COST := 5         # 【抗体亲和力成熟】B 细胞：抗体费 1.0 → 0.5
const MATURED_ANTIBODY_DMG := 15         #   —— 抗体伤害 1.0 → 1.5
const MATURED_ATTACK_EXTRA := 5          #   —— 每行动回合首次攻击邻健康的癌细胞 +0.5
const PHAGO_THRESHOLD := 5               # 【吞噬体成熟】处决线：余量 ≤0.5 直接死亡
const PHAGO_THRESHOLD_MACRO := 15        #   —— 巨噬提高到 1.5，触发后自身恢复 0.5
const CYTOTOX_EXTRA := 10                # 【细胞毒性增强】攻击成功额外 +1.0
const WATCH_RANGE := 3                   # 【免疫监视】守护半径（「相邻3格」按 3 格范围读，⏳ #66）
const GLUT1_BONUS: Array[int] = [5, 8, 10]        # 【GLUT1高表达】无氧 +0.5/0.8/1.0（分期）
const RAS_HEAL: Array[int] = [3, 5, 7]            # 【RAS持续激活】首次定殖恢复（分期）
const BCL2_ENERGY: Array[int] = [5, 8, 10]        # 【BCL-2抗凋亡】免死后的能量（分期）
const STEMNESS_ENERGY: Array[int] = [25, 30, 35]  # 【癌症干性】复活能量（分期）

# ---- 特殊组织（2026-08-27 团队定案，轴坐标，中心 (0,0)）----
# 布局：**半径 3** 那一环的 6 个「角」上，代谢核心与骨髓**交替**排布（各 3 个）；
#      骨髓再在外缘（半径 6）的「边中格」补 3 个；左右两个最远角 (±6,0) 一对血管。
#      每个 120° 扇区正好分到 1 核心 + 1 内圈骨髓 + 1 外圈骨髓。
#
# 内圈为什么是半径 3 而不是 4：半径 4 时中心留出的空地有 37 格，团队认为太空旷；
# 收到半径 3 后空地缩到 19 格。实测半径 3 也是双方细胞踩到率最均衡的一圈
# （癌 36% / 免 36%，半径 4 是 35% / 29%），所以这一挪不偏袒任何一方。
#
# 外圈骨髓为什么补在「边中格」而不是边角：要保住内圈的 **3 重旋转对称**（转 120° 完全重合），
# 新增点必须是「转 120° 后落回自身」的一组。外缘满足条件的只有两类——6 个角和 6 个边中格，
# 而 6 个角分成的两组轨道**各被一个血管占了**，所以只剩边中格可选。
#
# 中央格原本也是骨髓，2026-08-27 移除——它与「初始癌组织必须包含中央格 + 癌组织不得与
# 特殊组织重合」这两条规则直接冲突（说明 #34），且会让癌方从第 0 回合白拿一个骨髓。
#
# 可视化参考：docs/地图布局_127格.svg（由 tools/render_map.py 从本文件生成，改坐标后重跑脚本）
const CORES: Array[Vector2i] = [Vector2i(0, -3), Vector2i(3, 0), Vector2i(-3, 3)]
const MARROWS: Array[Vector2i] = [
	Vector2i(3, -3), Vector2i(0, 3), Vector2i(-3, 0),      # 内圈：与核心交替
	Vector2i(6, -3), Vector2i(-3, 6), Vector2i(-3, -3),    # 外圈：外缘边中格
]
const VESSELS: Array[Vector2i] = [Vector2i(6, 0), Vector2i(-6, 0)]
const CORE_STORE_MAX := 20               # 代谢核心存储上限 2.0
const CORE_HEALTHY_PERIOD := 2           # 健康：每 2 世界回合 +1.0
const CORE_HEALTHY_GAIN := 10
const CORE_CANCER_GAIN := 4              # 癌性：每世界回合 +0.4
const MARROW_STORE_MAX := 1              # 骨髓存储上限 1 张
const MARROW_HEALTHY_PERIOD := 3
const MARROW_CANCER_PERIOD := 2

# ---- 行动顺序（规则只定义 4/6 人；2 人为电子版测试扩展，见说明 #5）----
const FACTION_ORDER := {
	2: [Faction.IMMUNE, Faction.CANCER],
	4: [Faction.IMMUNE, Faction.CANCER, Faction.IMMUNE, Faction.CANCER],
	## PRD「行动顺序」：6 名玩家 = 免疫A—癌A—免疫B—癌B—免疫C—癌C（严格交替）。
	## 2026-08-31 改正（口径 #84）——此前是 免A-癌A-癌B-免B-免C-癌C，
	## 那是 61 格旧规则的排法，PRD 升级时漏跟。4 人局两版一致，所以只看 4 人局发现不了。
	6: [Faction.IMMUNE, Faction.CANCER, Faction.IMMUNE,
		Faction.CANCER, Faction.IMMUNE, Faction.CANCER],
}

# ---- 名称表（日志/UI 用）----
## PRD 把原来 6 种设定型癌细胞换成了 4 种真实癌症，同一种每局最多出现 1 个 ——
## 所以**种类同时也是癌方的玩家身份**，棋盘上四张脸各不相同。
const CANCER_TYPE_NAMES := {
	CancerType.MELANOMA: "恶性黑色素瘤", CancerType.SIGNET: "印戒细胞癌",
	CancerType.OSTEO: "骨肉瘤", CancerType.SCLC: "小细胞肺癌",
}
const IMMUNE_TYPE_NAMES := {
	ImmuneType.BASIC: "免疫细胞", ImmuneType.B_CELL: "B细胞", ImmuneType.T_CELL: "T细胞",
	ImmuneType.MACRO: "巨噬细胞", ImmuneType.DENDRITIC: "树突状细胞",
}
## 四种分化细胞的规则原文（PRD「免疫细胞种类」一节，2026-09-03 版；公式写成能在点阵字里显示的样子，
## 改 PRD 时同步——不改写、不加解释，架构约定 #10）。分化提问里悬停种类按钮时由 CWCardInfo 浮出。
const IMMUNE_TYPE_TEXT := {
	ImmuneType.B_CELL: "【抗体】：消耗1点能量，使所有与健康组织邻接的癌细胞能量-1.5\n"
		+ "· 如果无目标则随机将与健康组织相邻的X格癌组织转为健康组织\n"
		+ "　· 2/3概率X=2，1/3概率X=3",
	ImmuneType.T_CELL: "【细胞毒素】：消耗1点能量，使与自己相邻的所有格中的癌组织转为健康组织，"
		+ "对范围内所有癌细胞造成1能量损失，并使范围内新生健康组织所有格处于「坏死」状态\n"
		+ "· T细胞每世界回合最多发动3次\n"
		+ "· 「坏死」状态的组织无法为免疫细胞【有氧呼吸】，可以被【定殖】\n"
		+ "· 两轮完整的世界回合结束后「坏死」状态被移除\n"
		+ "【裂解】：T细胞消耗1点能量可将相邻的固化癌组织转为健康组织",
	ImmuneType.MACRO: "【I-吞噬】：\n"
		+ "· 巨噬细胞触发【净化】不恢复能量\n"
		+ "· 巨噬细胞每次攻击成功造成能量损失后，恢复受击方损失能量的1/2（向上取整）",
	ImmuneType.DENDRITIC: "【I-各司其职】：树突状细胞发动攻击仅能造成1/2伤害，向下取整到十分位\n"
		+ "【I-标记】：树突状细胞相邻的癌细胞获得【标记】\n"
		+ "· 被标记的癌细胞下一次受到免疫细胞造成的能量损失时，该次能量损失×2，随后移除【标记】",
}
## 癌细胞种类的自带技能（PRD 原文，同 IMMUNE_TYPE_TEXT 的纪律：一个字不改写）。
## 被动技能永远不进行动栏，玩家此前只能翻规则书——右栏固定详情靠它把话说全（2026-09-04 Kevin 要的）
const CANCER_TYPE_TEXT := {
	CancerType.MELANOMA: "【早期血行转移】：消耗1点能量，若自身处于血管格，可立即移动至棋盘上任意一个未被免疫细胞占据的健康组织，"
		+ "并将其转化为癌组织，并将相邻格中随机最多3格转为癌组织。每世界回合限发动1次\n"
		+ "【伪足穿透】：移动时，若目标健康组织与至少2格癌性组织相邻，本次移动的能量消耗为0.5",
	CancerType.SIGNET: "【黏液破裂】：消耗自身全部能量（至少2点）并死亡。自身所在格及周围2格范围内所有组织进入「黏液侵染」状态，"
		+ "系统从中随机选择最多10格立即转化为癌组织，范围内的免疫细胞受到2能量损失\n"
		+ "· 「粘液」无法被技能清除，被免疫细胞接触后立即消失\n"
		+ "【囊性护甲】：每世界回合第一次能量损失-0.5，不限来源",
	CancerType.OSTEO: "【骨样硬化】：该细胞触发【E-固化】结算计数为+1.5\n"
		+ "【刚性屏障】：当骨肉瘤细胞位于固化癌组织上时，受到的能量损失为40%（向下取整到十分位）",
	CancerType.SCLC: "【极简胞浆】：体积极小，移动至健康组织的能量消耗永久降低为0.7点\n"
		+ "【转移】：消耗1点能量向某方向跃进5格\n"
		+ "· 跃进路径上无法触发【定殖】、代谢核心骨髓收取等效果，终点可以触发\n"
		+ "【瓦伯格超速糖酵解】：其在无氧呼吸中能获得110%原产出（向上取整到十分位）",
}

## 行动栏上每个主动技能的 PRD 原文（键 = CWUIBridge.ACT_TITLE 的键）。
## 两个阵营各有一套「迁移 / 移动」和「基因表达」，所以按阵营分两张表；
## 剩下的技能只属于一个阵营，合在一起不会撞键。
## ⚠ **数字照抄 PRD 原文**，不插值旋钮：这里是「规则怎么写的」，
## 而「本局实际多少钱」由按钮上的价签给（那一处才现读 CWData/CWTuning）。
const SKILL_TEXT_IMMUNE := {
	"move": "【迁移】：消耗0.5能量移动到健康组织 / 消耗1能量移动到癌性组织\n"
		+ "若移动后免疫细胞和癌细胞处于同一格，触发【攻击】\n"
		+ "· 1/3概率失败，不造成伤害，自身-0.5能量，弹回原格\n"
		+ "· 1/2概率成功，癌细胞-1能量\n"
		+ "· 1/6概率大成功，癌细胞-2能量\n"
		+ "若攻击后癌细胞死亡，免疫细胞进入该格；若癌细胞仍存活，免疫细胞返回原格\n"
		+ "每个免疫细胞每个行动回合最多攻击3次，失败反弹也计数\n"
		+ "【I-净化】：免疫细胞成功进入癌组织后，将其转为健康组织，免疫方积累1抗原记忆\n"
		+ "III级：迁移到癌性组织的耗能降为0.7",
	"draw": "【基因表达】：消耗0.5能量抽卡，每回合最多发动3次。",
}
const SKILL_TEXT_CANCER := {
	"move": "【移动】：消耗0.2能量向癌性组织移动1格 / 消耗1.2能量向健康组织移动1格\n"
		+ "【I-定殖】：癌细胞经过的健康组织转为癌组织",
	"draw": "【基因表达】：消耗1能量抽卡，每回合最多发动3次。",
}
const SKILL_TEXT := {
	"differentiate": "【分化】：分化为B细胞/T细胞/巨噬细胞/树突状细胞，"
		+ "每个细胞每局游戏仅能发动一次，每种细胞仅能有一个\n"
		+ "III级免疫等级解锁",
	"antibody": "【抗体】：消耗1点能量，使所有与健康组织邻接的癌细胞能量-1.5\n"
		+ "· 如果无目标则随机将与健康组织相邻的X格癌组织转为健康组织\n"
		+ "　· 2/3概率X=2，1/3概率X=3",
	"toxin": "【细胞毒素】：消耗1点能量，使与自己相邻的所有格中的癌组织转为健康组织，"
		+ "对范围内所有癌细胞造成1能量损失，并使范围内新生健康组织所有格处于「坏死」状态\n"
		+ "· T细胞每世界回合最多发动3次\n"
		+ "· 「坏死」状态的组织无法为免疫细胞【有氧呼吸】，可以被【定殖】\n"
		+ "· 两轮完整的世界回合结束后「坏死」状态被移除",
	"lyse": "【裂解】：T细胞消耗1点能量可将相邻的固化癌组织转为健康组织",
	"mutate": "【突变】：消耗0.5能量，每个癌细胞每世界回合最多发动1次\n"
		+ "· 1/3概率无事发生\n"
		+ "· 1/3概率抽卡，削减1抗原记忆\n"
		+ "· 1/3概率再扣除1能量，削减3抗原记忆",
	"homing": "【早期血行转移】：消耗1点能量，若自身处于血管格，可立即移动至棋盘上任意一个未被免疫细胞占据的健康组织，"
		+ "并将其转化为癌组织，并将相邻格中随机最多3格转为癌组织。每世界回合限发动1次",
	"mucus": "【黏液破裂】：消耗自身全部能量（至少2点）并死亡。自身所在格及周围2格范围内所有组织进入「黏液侵染」状态，"
		+ "系统从中随机选择最多10格立即转化为癌组织，范围内的免疫细胞受到2能量损失\n"
		+ "· 「粘液」无法被技能清除，被免疫细胞接触后立即消失",
	"jump": "【转移】：消耗1点能量向某方向跃进5格\n"
		+ "· 跃进路径上无法触发【定殖】、代谢核心骨髓收取等效果，终点可以触发",
	"end": "结束本回合的行动，交给下一位玩家。",
}


## 主动技能的显示名（行动栏按钮、右栏固定详情共用一份）。
## **住在这里而不是界面层**：两处都要用，各写一份必漂；
## 新增主动技能却忘了登记，t_action_ui 会当场报出来（护栏比对 CWActions.action_kinds）。
const ACT_NAMES := {
	"move": "迁移", "draw": "基因表达", "differentiate": "分化",
	"antibody": "抗体", "toxin": "细胞毒素", "lyse": "裂解",
	"mutate": "突变", "end": "结束回合",
	## 癌细胞种类专属（PRD 四种真实癌症）
	"homing": "血行转移", "mucus": "黏液破裂", "jump": "转移",
	## 手牌（按钮不进行动栏，由手牌交互出；名字给日志和护栏测试用）
	"play": "打出手牌", "discard": "弃牌",
}


## 技能的显示名。**「迁移」（免疫）和「移动」（癌症）在规则里是两个词，不能混用**——
## 行动栏、右栏固定详情、详情框标题一律走这里，别各写各的（CWUIBridge._move_title 同口径）
static func act_name(act: String, faction: int) -> String:
	if act == "move" and faction == Faction.CANCER:
		return "移动"
	return ACT_NAMES.get(act, act)


## 某个主动技能的 PRD 原文；faction 分「迁移 / 移动」「基因表达」两套措辞。
## 没登记的键返回空串（护栏测试盯着 ACT_TITLE 与这里的差集）
static func skill_text(act: String, faction: int) -> String:
	var per_faction: Dictionary = SKILL_TEXT_IMMUNE if faction == Faction.IMMUNE \
		else SKILL_TEXT_CANCER
	if per_faction.has(act):
		return per_faction[act]
	return SKILL_TEXT.get(act, "")


const LEVEL_NAMES := ["I", "II", "III", "X"]
const TISSUE_NAMES := { Tissue.HEALTHY: "健康组织", Tissue.CANCER: "癌组织", Tissue.SOLID: "固化癌组织" }

const DIRS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1),
	Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1),
]


static func is_on_board(c: Vector2i) -> bool:
	return abs(c.x) <= BOARD_RADIUS and abs(c.y) <= BOARD_RADIUS \
		and abs(c.x + c.y) <= BOARD_RADIUS


static func all_coords() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for q in range(-BOARD_RADIUS, BOARD_RADIUS + 1):
		for r in range(-BOARD_RADIUS, BOARD_RADIUS + 1):
			var c := Vector2i(q, r)
			if is_on_board(c):
				out.append(c)
	return out


static func neighbors(c: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for d in DIRS:
		var n: Vector2i = c + d
		if is_on_board(n):
			out.append(n)
	return out


static func hex_dist(a: Vector2i, b: Vector2i) -> int:
	var dq := a.x - b.x
	var dr := a.y - b.y
	return (abs(dq) + abs(dr) + abs(dq + dr)) / 2


static func is_edge(c: Vector2i) -> bool:
	# 棋盘外缘格：邻居不满 6 个
	return neighbors(c).size() < 6


static func special_of(c: Vector2i) -> Special:
	if c in CORES:
		return Special.CORE
	if c in MARROWS:
		return Special.MARROW
	if c in VESSELS:
		return Special.VESSEL
	return Special.NONE


static func is_world_event_round(r: int) -> bool:
	# PRD：第 3、6、10、15、20、25、30 世界回合，**到 30 为止**（30 也是终局回合）
	return r in [3, 6, 10, 15, 20, 25, 30]


## 十分能量 → 显示字符串（如 15 → "1.5"）
static func fmt(e: int) -> String:
	return "%d.%d" % [e / 10, abs(e) % 10]
