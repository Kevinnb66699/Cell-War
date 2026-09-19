## mech_card_value.gd —— 单卡估值表：68 张卡 → 能量当量（平衡研究产出）
##
## 目标（2026-09-20）：把每张卡折算成**能量当量**（1.0 = 1 能量），排序成表，
## 找出同池/同级里被高估或低估的卡 —— 这是平衡研究的直接产出，也是训练的先验特征。
##
## 方法论（**模型化估计，不是实测**）：
##   · 一切折算成能量。直接能量损益照卡面；地盘 / 固化 / 抗原 / 持续性效果用下面的
##     **换算常数**折现 —— 这些常数本身就是平衡研究要讨论的对象，可调、可质疑。
##   · 永久/持续效果 × ROUNDS（一局 15 回合、按第 8 回合拿到算，剩 ~7 回合）。
##   · 地盘/固化/抗原的折算借 MechValue 的机制量级（无氧供给边际、固化=复活点+全图加成）。
##   · 结果是**相对排序**有意义，不是绝对精度。同级内比较最能暴露超值/亏值。
##
## 覆盖：直接遍历 CWCardData.CARDS，断言**非事件卡**全有估值 —— 漏一张就报错。
## ⚠ **事件卡不估值**（2026-09-20 小组决定：事件从游戏移除、现在对局都关事件）。
##    只估值【即时】与【永久】两类技能卡。
##
## 运行：<godot> --headless --path game --script res://tests/mech_card_value.gd
extends SceneTree


## 事件卡剔除：小组决定删事件、对局都关事件 → 不在平衡估值范围内。
static func _is_event(name: String) -> bool:
	return int(CWCardData.CARDS[name]["kind"]) == CWCardData.Kind.EVENT


## —— 换算常数（能量当量；平衡研究的讨论对象，可调）——
const TILE := 2.0      ## 1 格癌性组织：1 胜利进度 + 无氧供给边际(回现) + 扩张成本递减
const SOLID := 5.0     ## 1 格固化癌组织：2 进度 + 复活点 + 全图供给加成 + 不可净化
const ANTIGEN := 1.0   ## 1 抗原记忆：免疫升级进度（II/III 级降迁移费/解锁分化）
const ROUNDS := 7.0    ## 持续效果的剩余回合折现（15 回合制、按第 8 回合拿到）
const DRAW := 1.5      ## 一次抽卡的期望价值（卡池均值）

## —— 估值表：卡名 → [能量当量, 类别, 折算依据] ——
## 类别：energy 直接能量 / cost 费用减免 / attack 攻击强化 / defense 防御 /
##       territory 地盘(净化/定殖) / solidify 固化 / antigen 抗原 / mobility 机动 / special 特殊
const VALUES := {
	## ———— 免疫 · I 级池 ————
	"局部吞噬": [3.0, "territory", "净化1格(TILE) + 1抗原(ANTIGEN)"],
	"代谢适应": [3.5, "energy", "+0.5/有氧 × ROUNDS"],
	"模式识别增强": [3.5, "energy", "+0.5/首次净化·回合 × ROUNDS"],
	"组织驻留": [7.0, "cost", "每回合2次健康迁移免费（~1.0/回合 × ROUNDS）"],
	"炎症趋化": [0.5, "cost", "下次癌迁移降为0.5（省~0.5）"],
	"细胞膜修复": [1.5, "defense", "下次损失-1.5"],
	"补体调理": [1.5, "attack", "无效重掷+成功+0.5（攻击EV提升）"],
	## ———— 免疫 · II 级池 ————
	"CXCR3趋化": [1.0, "cost", "2次癌迁移各-0.5"],
	"LFA-1黏附": [2.8, "cost", "每回合首次癌迁移-0.4 × ROUNDS"],
	"TNF-α局部炎症": [3.0, "attack", "1环癌-1（~2只）+ 固化-1 + 冻结固化"],
	"免疫增援": [1.5, "mobility", "传送至队友2环（省数步迁移）"],
	"基质降解": [2.5, "territory", "相邻固化→癌（拆1固化，未全净化）"],
	"缺氧适应": [1.0, "defense", "下次压迫/癌技能损失-1"],
	"自分泌生存信号": [5.6, "energy", "+0.8/有氧 × ROUNDS"],
	"效应记忆形成": [10.5, "antigen", "首次净化+1抗原+0.5能 × ROUNDS"],
	"组织浸润": [2.1, "cost", "癌迁移-0.3 × ROUNDS"],
	"溶酶体强化": [4.0, "territory", "至多4格净化（按~2格 2×TILE）"],
	"炎症性趋化": [6.9, "territory", "3步@0.2 + 至多3净化(3×TILE+省费)"],
	"补体级联": [3.2, "territory", "攻击成功后2格净化(2×TILE，×成功概率)"],
	"抗体依赖细胞毒作用": [1.2, "attack", "2环贴健康癌-1(B-1.5)"],
	## ———— 免疫 · III 级池 ————
	"交叉呈递": [1.5, "attack", "标记→下次免疫伤害×2（~+1）"],
	"免疫突触成熟": [4.6, "attack", "攻击判定1/6败1/2成1/3大（EV 0.83→1.17，~2攻/回合×ROUNDS）"],
	"免疫记忆库": [10.5, "special", "首次净化免费抽卡(DRAW × ROUNDS)"],
	"吞噬体成熟": [3.0, "attack", "斩杀低能量目标（巨噬阈值1.5+回血）"],
	"放疗": [10.0, "territory", "10格连通区转健康+坏死（~10×TILE×随机折扣）"],
	"抗体亲和力成熟": [3.0, "attack", "贴健康攻击+0.5 × ROUNDS；B抗体强化"],
	"抗原呈递强化": [2.0, "attack", "攻击后施加标记 × ROUNDS"],
	"基质重塑": [9.0, "territory", "2固化→癌(2×~2.5) + 2净化(2×TILE)"],
	"穿孔素-颗粒酶": [1.5, "attack", "下次攻击+1(T+2)"],
	"细胞因子网络": [3.5, "energy", "下名免疫技能+0.5 × ROUNDS"],
	"细胞毒性增强": [7.0, "attack", "首次攻击+1/回合 × ROUNDS（T每次）"],
	"高亲和力克隆": [3.0, "attack", "下次攻击必大成功+1（保底3伤）"],
	"组织巡航": [5.0, "cost", "首次迁移免费+后续-0.2/回合 × ROUNDS"],
	"免疫监视": [3.0, "defense", "3环健康不增生/不侵蚀（防御性地盘）"],
	"耗竭抵抗": [5.0, "defense", "每回合首次损失-1 + 压迫再-0.5（按~半数回合受损 × ROUNDS）"],
	"IFN-γ高峰": [2.0, "attack", "指定免疫 2环癌-1 + 固化-1"],
	## ———— 癌症池（不分级，按肿瘤分期）————
	"BCL-2抗凋亡": [2.0, "defense", "免死一次，能量改0.5-1（一条命）"],
	"DNA损伤修复": [1.5, "defense", "下次免疫事件/技能损失-1~2"],
	"GLUT1高表达": [5.6, "energy", "+0.5-1/无氧 × ROUNDS"],
	"PD-L1表达": [1.5, "defense", "下次攻击判定降一级（防大成功）"],
	"RAS持续激活": [3.5, "energy", "首次定殖+0.3-0.7/回合 × ROUNDS"],
	"上皮—间质转化": [2.0, "cost", "1-3次健康迁移降为0.2（省~1-3）"],
	"乳酸酸化": [2.0, "attack", "相邻免疫-0.8~2（贴3癌再+0.5）"],
	"代谢耦联": [1.0, "energy", "细胞间转账，接受方多得~0.2-0.5"],
	"克隆增殖": [4.0, "territory", "至多1-3格定殖（按2格 2×TILE）"],
	"基质硬化": [2.5, "solidify", "1格固化+1~2（推进SOLID的部分价值）"],
	"癌症干性": [2.0, "defense", "复活能量3-5 + 前两次癌迁移免费"],
	"癌症转移": [3.5, "mobility", "2环传送 + 定殖(TILE)"],
	"肿瘤增援": [1.5, "mobility", "传送至队友环内癌性格"],
	"肿瘤细胞募集": [1.5, "mobility", "把队友传送到自己环内"],
}


func _initialize() -> void:
	_run()


func _run() -> void:
	## 覆盖断言：CWCardData.CARDS 每张**非事件卡**都得有估值
	var missing: Array = []
	var live := 0
	for name in CWCardData.CARDS:
		if _is_event(name):
			continue
		live += 1
		if not VALUES.has(name):
			missing.append(name)
	var extra: Array = []
	for name in VALUES:
		if not CWCardData.CARDS.has(name):
			extra.append(name)
		elif _is_event(name):
			extra.append(name + "（事件，应从估值表删除）")
	for m in missing:
		print("  !! 缺估值：%s" % m)
	for e in extra:
		print("  !! %s" % e)
	print("覆盖：非事件卡 %d 张（事件卡已剔除）%s\n" % [
		live, "（全覆盖）" if missing.is_empty() and extra.is_empty() else "（有出入！）"])
	if not missing.is_empty() or not extra.is_empty():
		quit(1)
		return

	## 按池分组打印（免疫 I/II/III/X、癌症 I/II/III 期）
	var imm_levels := ["I", "II", "III", "X"]
	for lvl in 4:
		var pool: Array = []   ## [[value, name, cat, note, weight]]
		for name in CWCardData.CARDS:
			if _is_event(name):
				continue
			var c: Dictionary = CWCardData.CARDS[name]
			var w: int = c["immune"][lvl]
			if w > 0:
				var v: Array = VALUES[name]
				pool.append([v[0], name, v[1], v[2], w])
		pool.sort_custom(func(a, b): return a[0] > b[0])
		print("══ 免疫 %s 级池（%d 张）══" % [imm_levels[lvl], pool.size()])
		_print_pool(pool)
		print()
	var can_phases := ["肿瘤I期", "肿瘤II期", "肿瘤III期"]
	for ph in 3:
		var pool: Array = []
		for name in CWCardData.CARDS:
			if _is_event(name):
				continue
			var c: Dictionary = CWCardData.CARDS[name]
			var w: int = c["cancer"][ph]
			if w > 0:
				var v: Array = VALUES[name]
				pool.append([v[0], name, v[1], v[2], w])
		pool.sort_custom(func(a, b): return a[0] > b[0])
		print("══ 癌症 · %s（%d 张）══" % [can_phases[ph], pool.size()])
		_print_pool(pool)
		print()

	## 全局最贵 / 最便宜
	var all_rows: Array = []
	for name in VALUES:
		if _is_event(name):
			continue
		var v: Array = VALUES[name]
		all_rows.append([v[0], name, v[1], v[2]])
	all_rows.sort_custom(func(a, b): return a[0] > b[0])
	print("══ 全局 TOP 10 ══")
	for i in mini(10, all_rows.size()):
		var r: Array = all_rows[i]
		print("  %5.1f  %s [%s]" % [r[0], r[1], r[2]])
	print("══ 全局 BOTTOM 10 ══")
	for i in range(maxi(0, all_rows.size() - 10), all_rows.size()):
		var r: Array = all_rows[i]
		print("  %5.1f  %s [%s]" % [r[0], r[1], r[2]])
	quit(0)


func _print_pool(pool: Array) -> void:
	for r in pool:
		print("  %5.1f  %-8s [%s] w%d  %s" % [r[0], r[1], r[2], r[4], r[3]])
