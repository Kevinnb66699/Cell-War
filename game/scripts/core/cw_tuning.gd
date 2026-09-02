## cw_tuning.gd —— 平衡旋钮：把「可能需要改动的数值」从规则常量里分离出来
##
## 默认值 = 规则原文（CWData 常量），所以 CWTuning.new() 就是「按规则跑」。
## 平衡测试时只改旋钮、不改引擎代码；旋钮定案后再回写规则文档与 CWData。
##
## 单位一律是「十分能量」（10 = 1.0 能量）。
class_name CWTuning
extends RefCounted

## 方案名（打印报告用）
var name := "规则原文"


## 2026-08-28：PRD 把 2026-08-27 那套推荐方案的**方向**吸收进了规则原文
## （免疫收入挂钩健康组织、癌方无氧呼吸提高、【E-增生】正式入规），但数值另定，
## 而且**只有癌方按己方细胞数均分、免疫方不均分**。默认值现在就是 PRD，所以
## `CWTuning.new()` = 按 PRD 跑，旧的 recommended() 已被 PRD 取代、删除。
##
## 下面这个预设保留的是 PRD **没有**解决的那一项：人数缩放。
## 《平衡测试报告》问题 #29 的根因是「癌方阵营总收入与人数无关，免疫方随人数线性增长」，
## 修法是两边都按己方细胞数均分。PRD 的公式结构和 #29 完全一样，
## 用开局盘面算阵营总收入是 2 人 2.6:6.0 / 4 人 5.2:6.0 / 6 人 7.8:6.0。
## 想验证这一条时用本预设跑 balance_sim 对照。
static func split_income() -> CWTuning:
	var t := CWTuning.new()
	t.name = "PRD + 免疫收入均分"
	t.aerobic_split = true
	return t


# ---- 收入 ----
var anaerobic_per_cancer := CWData.ANAEROBIC_PER_CANCER      # 每癌组织供能
var anaerobic_per_solid := CWData.ANAEROBIC_PER_SOLID        # 每固化癌组织供能
## 无氧呼吸是否按连通块内癌细胞数均分（关掉=每个癌细胞独享全额，大幅提升多细胞癌方收入）
var anaerobic_split := true

## 【S-有氧呼吸】公式里的乘数：每个免疫细胞得 (健康 - 坏死) ÷ 总格数 × 本值 ÷ 10。
var aerobic_mult := CWData.AEROBIC_MULT
## 【平衡候选①】有氧呼吸系数**随世界回合线性增长**：第 n 回合的系数
## = aerobic_mult + 本值 × (n - 1)，见 aerobic_mult_at()。单位十分能量。
## **0 = 关闭**（默认），此时系数恒定，与原来逐位相同。
## 团队 2026-09-01 提的四条平衡候选之一 —— 四条**刻意不并存**，各自独立扫。
var aerobic_mult_growth := 0
## 有氧呼吸是否再按免疫细胞数均分。
## **PRD 是不均分的**，所以默认 false；true 时两边阵营总收入都与人数无关
## （《平衡测试报告》#29 的修法，见 split_income()）。
var aerobic_split := false

# ---- 收入低保与封顶（Kevin 2026-08-26 提出「低保」，封顶是配套的另一半）----
## 收入挂钩地盘会形成雪球：领先方地盘涨、收入涨，落后方地盘跌、收入跌，双向加速。
## 低保防止落后方直接崩盘，封顶防止领先方滚雪球——两个一起用才是稳定器。
## 单位十分能量，每细胞每回合；0 = 不启用。
var anaerobic_floor := 0
var anaerobic_cap := CWData.ANAEROBIC_CAP     ## 999.0 = 形同不封顶（口径 #92）
var aerobic_floor := CWData.AEROBIC_FLOOR     ## 2.0（口径 #89）——别贴到 3.0，那是公式上界
var aerobic_cap := 0

## 【E-能量上限】每个世界回合结算末，所有存活细胞的能量削到这个数；0 = 不启用。
## 和上面四个「收入低保/封顶」不是一回事：那四个管**这一回合进多少**，
## 这个管**账上最多留多少**。囤积是靠这个封的（口径 #92）。
var energy_cap := CWData.ENERGY_CAP_PER_ROUND

## 【平衡候选③】癌细胞每个世界回合按**当前能量的百分比**自动损能（能量越多损失越多），
## 扣在 E 阶段【无氧呼吸】**之后**。整数百分比，**0 = 关闭**（默认）。
## 和上面的 energy_cap 职能重叠 —— 那个是硬顶（超过 15.0 削平），这个是按比例抽税，
## 曲线完全不同：硬顶对 15.0 以下毫无作用，抽税对每一档都起作用。
## 定案时两者大概率只留一个，所以扫的时候要有「③开 + energy_cap 关」的对照档。
var cancer_upkeep_pct := 0


## 【S-有氧呼吸】的系数在第 `n` 个世界回合的取值（n 从 1 起）。
## growth = 0 时恒等于 aerobic_mult —— 候选①关着的时候，这个函数必须是恒等式，
## 否则 924 条现有断言里凡是算过有氧收入的都会跟着漂。
func aerobic_mult_at(n: int) -> int:
	## 下限 0 的理由同 immune_attack_pct()：负系数（= 反方向，削免疫收入）是要扫的
	## 合法值，但系数本身不能为负 —— 负分子会让 `_aerobic()` 那次整数除法
	## 从「向下取整」翻成「向零截断」，取整口径当场翻面。
	## 2026-09-01 第一版漏了这句，负方向那批扫描数据因此不可用。
	return maxi(aerobic_mult + aerobic_mult_growth * maxi(n - 1, 0), 0)


## 免疫普攻倍率（百分点）：候选②按世界回合加、候选④按抗原记忆加。
## 两个旋钮都是 0 时**恒返回 100**，`_calculate` 里那次乘除因此逐位不变 ——
## 候选②④刻意不并存，但把它们放进同一个倍率是有意的：
## 一次乘法、一个取整点，比两条各自乘一遍少一次截断。
func immune_attack_pct(n: int, memory: int) -> int:
	var by_round := immune_attack_pct_growth * maxi(n - 1, 0)
	var by_memory := immune_attack_pct_per_memory * maxi(memory, 0)
	if immune_attack_pct_memory_cap > 0:
		## 封顶要**双向**：`mini()` 只挡上界，负加成（per_memory < 0 = 反方向削免疫）
		## 会一路穿过去，记忆攒到 20 时普攻倍率直接归零、整条曲线撞地板。
		## 第一版只写了 mini()，导致反方向那批扫描落在非线性区，数据不能线性外推。
		by_memory = clampi(by_memory, -immune_attack_pct_memory_cap,
			immune_attack_pct_memory_cap)
	## 下限 0：系数设成负数（= 削免疫）是要扫的合法方向，但倍率本身不能为负 ——
	## 负分子会让整数除法从「向下取整」翻成「向零截断」，取整口径当场翻面。
	return maxi(100 + by_round + by_memory, 0)


## 把每细胞收入钳制在低保与封顶之间
func clamp_income(gain: int, floor_v: int, cap_v: int) -> int:
	var out := gain
	if floor_v > 0:
		out = maxi(out, floor_v)
	if cap_v > 0:
		out = mini(out, cap_v)
	return out

# ---- 初始能量 ----
var init_energy_immune := CWData.INIT_ENERGY
var init_energy_cancer := CWData.INIT_ENERGY_CANCER

## 初始癌组织格数。**-1 = 按人数取**（`CWData.init_cancer_tiles`，现值 4 人 15 / 6 人 21）。
## 只有平衡测试要把所有人数钉成同一个数时才设具体值 —— 那是扫这条杠杆的唯一办法，
## 因为按人数分档的表本身就是被扫的对象。
var init_cancer_tiles := -1

# ---- 免疫行动费用 ----
var immune_move_healthy: Array = CWData.IMMUNE_MOVE_HEALTHY.duplicate()
var immune_move_cancerous: Array = CWData.IMMUNE_MOVE_CANCEROUS.duplicate()

# ---- 癌方移动费用 = 占地单价 ----
## 癌细胞每移动到一格健康组织就【定殖】一格，所以「移动费」就是「占地单价」。
## 《平衡方案_PRD版》第二节①认定的根因（转化比 4.6:1）全部落在这四个数上，
## 但它们此前是写死的常量、扫不了 —— 免疫那边一直有旋钮，这里补齐对称。
## 2026-08-31 口径 #82 已把 CWData 那三个默认值抬上去了（1.2 / 0.7 / 0.5），
## 所以这里的默认值**不再等于 PRD**，等于「引擎现值」。要跑 PRD 原样得显式传 PRD 的数。
var cancer_move_cancerous := CWData.CANCER_MOVE_CANCEROUS
var cancer_move_healthy := CWData.CANCER_MOVE_HEALTHY
## 小细胞肺癌【极简胞浆】：移动至健康组织**永久**走这个折后价
var sclc_move_healthy := CWData.SCLC_MOVE_HEALTHY
## 黑色素瘤【伪足穿透】：目标邻接 ≥2 格癌性组织时走这个折后价，**无次数限制**
var pseudopod_cost := CWData.PSEUDOPOD_COST

# ---- 攻击 ----
## 每个行动回合最多攻击几次，0 = 不限。现值 3（口径 #88）
var attack_max_per_turn := CWData.ATTACK_MAX_PER_TURN
var attack_dmg_success := CWData.ATTACK_DMG_SUCCESS
var attack_dmg_crit := CWData.ATTACK_DMG_CRIT

## 【平衡候选②】免疫**普攻**倍率随世界回合增长：第 n 回合 = 100 + 本值 ×(n−1) 个百分点。
## 单位百分点/回合，**0 = 关闭**（默认）。
##
## ⚠ **推不动胜率的是「斜坡」这个形状，不是普攻这根杠杆**（2026-09-01 实测，6 人局 300 局）：
##
## | 免疫普攻倍率 | 癌胜 |
## |---|---|
## | 100%（基线） | 31% |
## | **恒定** 200% | 22% |
## | **恒定** 400% | 15% |
## | 斜坡涨到 200%（本旋钮 =20） | 30% |
##
## 同样是 2 倍伤害：**恒定给值 −9 个百分点，涨上去只值 −1~3** —— 斜坡浪费掉三分之二。
## 因为它从 100% 起步，而对局在 6~10 个世界回合就结束，斜坡刚到顶局就完了。
##
## 这里先后写错过两版解释，都记在这儿免得有人再推一遍：
## ①「对局太短、斜坡走不完」—— 错。候选①（aerobic_mult_growth）是**完全相同的形状**，
##   在同样 6 回合里交付了 −25 个百分点。行程短不能解释②失效。
## ②「普攻每局只发生 2.5~6.4 次，乘多少都没用」—— 也错。次数确实少
##   （对比【净化】56~81 次），但恒定 ×2 就值 −9 个百分点，杠杆一点都不细。
##
## 结论：**要这条机制起作用就别做成斜坡，做成恒定倍率。**
var immune_attack_pct_growth := 0

## 【平衡候选④】免疫**普攻**倍率随抗原记忆增长：每 1 点 `CWGame.memory` +本值 个百分点。
## **0 = 关闭**（默认）。注意 memory 会**掉**（【突变】-1/-3），所以伤害也会往下走。
var immune_attack_pct_per_memory := 0

## 【候选④】记忆加成的封顶（百分点）；0 = 不封。
## 不是防呆而是必需：`memory` 没有上限（一局能到 20~40），线性缩放不封会直接爆掉，
## 不给这个旋钮的话候选④根本扫不出可用区间。
var immune_attack_pct_memory_cap := 0
## 攻击失败（1/3「被癌细胞反弹」）时，攻击者自身的能量损失。
## 2026-08-31 补齐到 PRD 值 0.5（口径 #84）；此前写死 0，是 61 格旧规则留下的。
## 留成旋钮是因为它直接决定「进攻型免疫打法的风险」，是重跑平衡时要扫的一档。
var counter_dmg_on_fail := CWData.COUNTER_DMG_ON_FAIL

# ---- 固化 ----
var solidify_threshold := CWData.SOLIDIFY_THRESHOLD

# ---- 胜负条件（PRD 原值：30 回合 / 加权 64 / 终局线 42）----
var limit_round := CWData.LIMIT_ROUND
var limit_cancerous := CWData.LIMIT_CANCEROUS
## 癌方即时胜利门槛（癌组织 + 2×固化）。规则原文 41 = ⌈2/3×61⌉。
## 注意：这个门槛如果太低，对局会在回合上限之前就结束，使上限规则形同虚设。
var cancer_win_weighted := CWData.CANCER_WIN_WEIGHTED
## 癌方占地胜利要**连续几个世界回合末**都达标才判定。默认 2 = 团队 2026-09-01 定案 B；1 = 定案前的旧规则（达标即胜）。
## 起因：行动顺序末位是癌方，最后一个癌细胞可以一口气铺到阈值、紧接着就是 E 阶段判定，免疫方零回应窗口。
## 2 时第一次达标只拉响警报，免疫方有整整一个世界回合把占地压回阈值以下；下一回合末仍达标才判胜，
## 中途掉下去计数归零。启发式 400 局对照：6 人 39%→33%、4 人 45%→42%，对局各 +1 回合（详见开发日志）。
var cancer_win_hold_rounds := CWData.CANCER_WIN_HOLD_ROUNDS

# ---- 原发灶：每个癌症玩家的出生格开局即为固化癌组织 ----
var solid_at_cancer_spawn := CWData.SOLID_AT_CANCER_SPAWN

# ---- 免疫死亡与复活 ----
## 额外罚停回合数；PRD 为 0（下一个 S 阶段即复活）。设为 -1 表示死后不再复活。
var immune_respawn_delay := CWData.IMMUNE_RESPAWN_DELAY
var immune_respawn_energy := CWData.IMMUNE_RESPAWN_ENERGY

# ---- 【E-增生】癌组织向外扩散（规则原文没有这条，团队 2026-08-26 提案）----
## 每个与癌性组织相邻的健康组织，按「相邻癌性组织数 × 本值」的概率转为癌组织。
## 单位千分率（40 = 每个相邻癌性组织贡献 4% = PRD 值），0 = 关闭。
## 作用是让地盘能脱离癌细胞自行生长，打破「癌细胞一死就彻底崩盘」的负反馈。
var proliferate_per_adjacent := CWData.PROLIFERATE_PER_ADJ
