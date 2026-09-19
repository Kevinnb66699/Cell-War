## mech_card_value.gd —— 单卡杠杆向量表（平衡研究产出，单杠杆归一化）
##
## 目标（2026-09-20 杠杆口径）：把每张卡拆成它**推动了哪些杠杆、各推多少**。
## 再进一层：**单杠杆归一化** —— 每个杠杆给一个「参考动作/单位」，把卡的推量
## 折算成 **×参考动作的倍数（q）**。排序只发生在**单杠杆内**，**绝不跨杠杆比**。
## —— 因为跨杠杆汇率（几格地盘 = 几能量 = 几点记忆）就是平衡问题本身，不是给定量。
##
## 杠杆 · 参考单位 · q 口径（对齐 MechValue）：
##   supply  十分位能量/次    q = 该事件能量增量（持续/规模靠 basis 标范围）
##   land    1 格净化/定殖   q = 净改动格数
##   solid   1 单位固化推进  q = 推进/拆除/冻结点
##   atk     标准攻击伤害点  q = 十分位伤害增量（EV 卡给 ΔEV/判定）
##   def     1 十分位减损    q = 减损点
##   ag      1 记忆点        q = 记忆点
##   mov     1 步            q = 省步估（传送≈省 2-3 步）
##   cost    1 十分位省费   q = 省费点/次
##   draw    1 张            q = 抽张
## 每杠杆条目 = { l, q, mag, basis }：q=×参考单位的数值；mag=单位描述；basis=范围/时机/持续。
## ⚠ q 是**单实例倍数**，不是整局总量；持续/规模不折叠进 q，写进 basis 供人按场面乘。
## ⚠ 无法量化成单数的（如「免死一次」）q=null，在单杠杆内排最后、标注「定性」。
##
## 覆盖：遍历 CWCardData.CARDS 断言**非事件卡**全有向量 + 杠杆键合法。
## ⚠ **事件卡不估值**（小组决定事件从游戏移除）。只估即时+永久技能卡。
##
## 运行：<godot> --headless --path game --script res://tests/mech_card_value.gd
extends SceneTree


## 事件卡剔除。
static func _is_event(name: String) -> bool:
	return int(CWCardData.CARDS[name]["kind"]) == CWCardData.Kind.EVENT


## 每个杠杆的参考单位与 q 口径。
const LEVER_REF := {
	"supply": {"u": "十分位能量/次", "note": "q=单事件能量增量; 持续/规模看 basis"},
	"land": {"u": "格", "note": "q=净改动格数"},
	"solid": {"u": "计数点", "note": "q=推进/拆除/冻结点"},
	"atk": {"u": "十分位伤害", "note": "q=伤害增量; EV卡给ΔEV/判定"},
	"def": {"u": "十分位减损", "note": "q=减损点"},
	"ag": {"u": "记忆点", "note": "q=记忆点; 每回合靠 basis"},
	"mov": {"u": "步", "note": "q=省步估; 传送≈2-3"},
	"cost": {"u": "十分位省费", "note": "q=省费点/次; 每回合靠 basis"},
	"draw": {"u": "张", "note": "q=抽张"},
}


## —— 杠杆向量 + 参考倍数表：卡名 → { levers:[{l,q,mag,basis}...], note } ——
const VALUES := {
	## ———— 免疫 · I 级池 ————
	"局部吞噬": {"levers": [
		{"l": "land", "q": 1.0, "mag": "1格净化", "basis": "即时; 断供反事实可精确算"},
		{"l": "ag", "q": 1.0, "mag": "+1记忆", "basis": "净化触发"},
	], "note": "净化1格 + 1抗原"},
	"代谢适应": {"levers": [
		{"l": "supply", "q": 0.5, "mag": "+0.5", "basis": "每次有氧·细胞"},
	], "note": "免疫有氧收入+0.5/细胞"},
	"模式识别增强": {"levers": [
		{"l": "supply", "q": 0.5, "mag": "+0.5", "basis": "每次首次净化·回合"},
	], "note": "免疫净化事件+0.5能"},
	"组织驻留": {"levers": [
		{"l": "cost", "q": 20.0, "mag": "2次健康迁移免费", "basis": "每回合(~10十分位/次)"},
	], "note": "免疫迁移财政宽松"},
	"炎症趋化": {"levers": [
		{"l": "cost", "q": 0.5, "mag": "省~0.5", "basis": "下次癌迁移"},
	], "note": "癌单次迁移降价"},
	"细胞膜修复": {"levers": [
		{"l": "def", "q": 1.5, "mag": "-1.5", "basis": "下次损失"},
	], "note": "免疫单次挨打减损"},
	"补体调理": {"levers": [
		{"l": "atk", "q": 0.17, "mag": "攻EV↑0.83→1.0", "basis": "Δ攻EV/判定"},
	], "note": "免疫攻击稳定性提升"},
	## ———— 免疫 · II 级池 ————
	"CXCR3趋化": {"levers": [
		{"l": "cost", "q": 0.5, "mag": "各-0.5", "basis": "×2次癌迁移"},
	], "note": "癌两次迁移降价"},
	"LFA-1黏附": {"levers": [
		{"l": "cost", "q": 0.4, "mag": "-0.4", "basis": "每回合首次癌迁移"},
	], "note": "癌每回合首次迁移降价"},
	"TNF-α局部炎症": {"levers": [
		{"l": "land", "q": 2.0, "mag": "1环癌-1(减win-progress)", "basis": "~2格面积"},
		{"l": "solid", "q": 1.0, "mag": "固化-1+冻结", "basis": "1环"},
	], "note": "削癌地盘+压固化"},
	"免疫增援": {"levers": [
		{"l": "mov", "q": 2.0, "mag": "传至队友2环", "basis": "省~2-3步"},
	], "note": "免疫重部署"},
	"基质降解": {"levers": [
		{"l": "solid", "q": 1.0, "mag": "拆1固化→癌", "basis": "相邻格"},
	], "note": "把固化癌组织打回普通癌"},
	"缺氧适应": {"levers": [
		{"l": "def", "q": 1.0, "mag": "-1", "basis": "下次压迫/癌技能损失"},
	], "note": "通用抗压减损"},
	"自分泌生存信号": {"levers": [
		{"l": "supply", "q": 0.8, "mag": "+0.8", "basis": "每次有氧·细胞"},
	], "note": "免疫有氧收入+0.8/细胞"},
	"效应记忆形成": {"levers": [
		{"l": "ag", "q": 1.0, "mag": "+1记忆", "basis": "首次净化·每回合"},
		{"l": "supply", "q": 0.5, "mag": "+0.5能", "basis": "首次净化·每回合"},
	], "note": "净化→记忆+能量滚雪球(疑似II级低定/超值)"},
	"组织浸润": {"levers": [
		{"l": "cost", "q": 0.3, "mag": "-0.3/次", "basis": "癌迁移"},
	], "note": "癌迁移持续降价"},
	"溶酶体强化": {"levers": [
		{"l": "land", "q": 2.0, "mag": "至多4格净化(~2原为按~2取值)", "basis": "即时"},
	], "note": "免疫清癌"},
	"炎症性趋化": {"levers": [
		{"l": "mov", "q": 3.0, "mag": "3步@0.2", "basis": "即时"},
		{"l": "land", "q": 3.0, "mag": "至多3净化", "basis": "即时"},
	], "note": "位移+清除"},
	"补体级联": {"levers": [
		{"l": "atk", "q": 1.0, "mag": "攻成功触发", "basis": "即时"},
		{"l": "land", "q": 2.0, "mag": "成功后2格净化", "basis": "即时"},
	], "note": "攻击后才出地盘回报"},
	"抗体依赖细胞毒作用": {"levers": [
		{"l": "atk", "q": 1.5, "mag": "2环贴健康癌-1(基底1.5)", "basis": "即时"},
	], "note": "癌特定位置伤害"},
	## ———— 免疫 · III 级池 ————
	"交叉呈递": {"levers": [
		{"l": "atk", "q": 1.0, "mag": "下次免疫伤害×2(~+1)", "basis": "标记后"},
	], "note": "为后续攻击上标记"},
	"免疫突触成熟": {"levers": [
		{"l": "atk", "q": 0.34, "mag": "攻ΔEV 0.83→1.17", "basis": "/判定"},
	], "note": "攻击判定整体上移"},
	"免疫记忆库": {"levers": [
		{"l": "draw", "q": 1.0, "mag": "免费抽卡", "basis": "首次净化·每回合"},
	], "note": "净化→抽卡(价值待实测)"},
	"吞噬体成熟": {"levers": [
		{"l": "atk", "q": 2.0, "mag": "斩杀低能量(阈值1.5)+回血", "basis": "巨噬"},
	], "note": "巨噬对低能量癌即斩"},
	"放疗": {"levers": [
		{"l": "land", "q": 10.0, "mag": "≤10格连片转健康+坏死", "basis": "即时(随机折扣)"},
	], "note": "大范围清癌(拔固化用另一剂量)"},
	"抗体亲和力成熟": {"levers": [
		{"l": "atk", "q": 0.5, "mag": "贴健康攻击+0.5", "basis": "持续"},
		{"l": "ag", "q": 1.0, "mag": "B抗体强化", "basis": "持续"},
	], "note": "贴邻净化侧伤害+记忆"},
	"抗原呈递强化": {"levers": [
		{"l": "atk", "q": 1.0, "mag": "攻击后施加标记", "basis": "持续"},
	], "note": "为后续伤害上标记"},
	"基质重塑": {"levers": [
		{"l": "land", "q": 2.0, "mag": "2净化", "basis": "即时"},
		{"l": "solid", "q": 2.0, "mag": "2固化→癌", "basis": "即时"},
	], "note": "拆固化+清癌地盘"},
	"穿孔素-颗粒酶": {"levers": [
		{"l": "atk", "q": 1.0, "mag": "下次攻击+1", "basis": "即时(T+2)"},
	], "note": "T单次攻击增伤"},
	"细胞因子网络": {"levers": [
		{"l": "supply", "q": 0.5, "mag": "下名免疫技能+0.5", "basis": "持续"},
	], "note": "接力放大后续技能"},
	"细胞毒性增强": {"levers": [
		{"l": "atk", "q": 1.0, "mag": "首次攻击+1", "basis": "每回合·T"},
	], "note": "T每回合首攻增伤"},
	"高亲和力克隆": {"levers": [
		{"l": "atk", "q": 1.0, "mag": "下次必大成功+1", "basis": "即时保底3伤"},
	], "note": "保底一次3伤攻击"},
	"组织巡航": {"levers": [
		{"l": "cost", "q": 10.0, "mag": "首次迁移免费+后续-0.2", "basis": "每回合"},
	], "note": "免疫持续迁移财政宽松"},
	"免疫监视": {"levers": [
		{"l": "land", "q": 2.0, "mag": "3环内防增生/侵蚀", "basis": "持续(防守)"},
	], "note": "防守地盘(护健康格)"},
	"耗竭抵抗": {"levers": [
		{"l": "def", "q": 1.5, "mag": "首发-1+压迫-0.5", "basis": "每回合"},
	], "note": "免疫持续减损"},
	"IFN-γ高峰": {"levers": [
		{"l": "land", "q": 2.0, "mag": "2环癌-1(减win-progress)", "basis": "指定免疫"},
		{"l": "solid", "q": 1.0, "mag": "固化-1", "basis": "指定免疫"},
	], "note": "定点削癌地盘+压固化"},
	## ———— 癌症池 ————
	"BCL-2抗凋亡": {"levers": [
		{"l": "def", "q": null, "mag": "免死一次", "basis": "一条命(不可量化)"},
	], "note": "癌保命/容错(定性)"},
	"DNA损伤修复": {"levers": [
		{"l": "def", "q": 1.5, "mag": "-1~2", "basis": "下次免疫损失"},
	], "note": "癌单次减损"},
	"GLUT1高表达": {"levers": [
		{"l": "supply", "q": 0.75, "mag": "+0.5-1/无氧·细胞", "basis": "规模×细胞×回合"},
	], "note": "癌无氧收入增益(规模杠杆)"},
	"PD-L1表达": {"levers": [
		{"l": "def", "q": 2.0, "mag": "攻击判定降一级", "basis": "下次(防大成功)"},
	], "note": "癌防免疫致命伤"},
	"RAS持续激活": {"levers": [
		{"l": "supply", "q": 0.5, "mag": "+0.3-0.7/回合", "basis": "首次定殖后"},
	], "note": "癌定殖后持续能量"},
	"上皮—间质转化": {"levers": [
		{"l": "cost", "q": 0.2, "mag": "1-3次迁移降0.2", "basis": "即时"},
	], "note": "癌单/多次迁移降价"},
	"乳酸酸化": {"levers": [
		{"l": "atk", "q": 1.4, "mag": "相邻免疫-0.8~2", "basis": "贴3癌再+0.5"},
	], "note": "癌近身消耗免疫能量(无对称反击)"},
	"代谢耦联": {"levers": [
		{"l": "supply", "q": 0.35, "mag": "接受方多得~0.2-0.5", "basis": "转账"},
	], "note": "能量搬运(转移而非新增)"},
	"克隆增殖": {"levers": [
		{"l": "land", "q": 2.0, "mag": "至多1-3格定殖(~2)", "basis": "即时"},
	], "note": "癌扩张地盘(连带供给/成本双杠杆)"},
	"基质硬化": {"levers": [
		{"l": "solid", "q": 1.5, "mag": "1格推进+1~2", "basis": "即时"},
	], "note": "推固化(≈提前固化回合)"},
	"癌症干性": {"levers": [
		{"l": "supply", "q": 4.0, "mag": "复活能量3-5", "basis": "复活时"},
		{"l": "cost", "q": 20.0, "mag": "前两次癌迁移免费", "basis": "复活后"},
	], "note": "癌复活容错+再展开廉价"},
	"癌症转移": {"levers": [
		{"l": "mov", "q": 2.0, "mag": "2环传送", "basis": "省~2-3步"},
		{"l": "land", "q": 1.0, "mag": "定殖(转癌)", "basis": "到达"},
	], "note": "癌机动扩张"},
	"肿瘤增援": {"levers": [
		{"l": "mov", "q": 2.0, "mag": "传癌至队友环内", "basis": "省~2-3步"},
	], "note": "癌重部署"},
	"肿瘤细胞募集": {"levers": [
		{"l": "mov", "q": 2.0, "mag": "队友传到自己环内", "basis": "省~2-3步"},
	], "note": "癌合流"},
}


func _initialize() -> void:
	_run()


func _run() -> void:
	## 覆盖断言 + 杠杆键合法
	var missing: Array = []
	var bad := []
	var live := 0
	for name in CWCardData.CARDS:
		if _is_event(name):
			continue
		live += 1
		if not VALUES.has(name):
			missing.append(name)
		else:
			for e in VALUES[name]["levers"]:
				if not LEVER_REF.has(e["l"]):
					bad.append("%s.%s" % [name, e["l"]])
	var extra: Array = []
	for name in VALUES:
		if not CWCardData.CARDS.has(name):
			extra.append(name)
		elif _is_event(name):
			extra.append(name + "（事件，应从估值表删除）")
	for m in missing:
		print("  !! 缺估值：%s" % m)
	for b in bad:
		print("  !! 未知杠杆：%s" % b)
	for e in extra:
		print("  !! %s" % e)
	print("覆盖：非事件卡 %d 张（事件已剔除），杠杆键全部合法 %s\n" % [
		live, "（全覆盖）" if missing.is_empty() and extra.is_empty() and bad.is_empty() else "（有出入！）"])
	if not missing.is_empty() or not extra.is_empty() or not bad.is_empty():
		quit(1)
		return

	## 按池列（immunI  I/II/III/X、癌症三期）：每卡 = 杠杆向量 + ×参考倍数
	var imm_levels := ["I", "II", "III", "X"]
	for lv in 4:
		var pool: Array = []
		for name in CWCardData.CARDS:
			if _is_event(name):
				continue
			if CWCardData.CARDS[name]["immune"][lv] > 0:
				pool.append(name)
		pool.sort()
		print("══ 免疫 %s 级池（%d 张）══" % [imm_levels[lv], pool.size()])
		for name in pool:
			_print_card(name)
		print()
	var can_phases := ["肿瘤I期", "肿瘤II期", "肿瘤III期"]
	for ph in 3:
		var pool: Array = []
		for name in CWCardData.CARDS:
			if _is_event(name):
				continue
			if CWCardData.CARDS[name]["cancer"][ph] > 0:
				pool.append(name)
		pool.sort()
		print("══ 癌症 · %s（%d 张）══" % [can_phases[ph], pool.size()])
		for name in pool:
			_print_card(name)
		print()

	## 按杠杆汇总：**单杠杆内按 q 数值降序**（q=×参考动作倍数；跨杠杆不做）。
	print("══ 按抽屉汇总（单杠杆内按 ×参考倍数 q 降序；跨杠杆不排序）══")
	for key in ["supply", "land", "solid", "atk", "def", "ag", "mov", "cost", "draw"]:
		var info: Dictionary = LEVER_REF[key]
		var rows: Array = []
		for name in VALUES:
			if _is_event(name):
				continue
			for e in VALUES[name]["levers"]:
				if e["l"] == key:
					rows.append([e["q"], name, e["mag"], e["basis"]])
					break
		if rows.size() == 0:
			continue
		## null（定性）排最后
		rows.sort_custom(func(a, b): return _q_sort(a[0], b[0]))
		print("▸ %s  (q=×[%s] · %s)  %d 张" % [key, info["u"], info["note"], rows.size()])
		for r in rows:
			var qs: String = "定性" if r[0] == null else "%4.2f×" % float(r[0])
			print("     %s  %-26s  %s" % [qs, r[1] + " " + r[2], "basis:" + r[3]])
		print()
	quit(0)


## q 排序：null(定性)恒排最后；否则数值降序。
static func _q_sort(a, b) -> bool:
	if a == null:
		return false
	if b == null:
		return true
	return float(a) > float(b)


func _print_card(namee: String) -> void:
	var v: Dictionary = VALUES[namee]
	var parts: Array = []
	for e in v["levers"]:
		var qs: String = "定性" if e["q"] == null else "×%.2f" % float(e["q"])
		parts.append("%s%s[%s]" % [e["l"], qs, e["mag"]])
	var note: String = String(v.get("note", ""))
	print("    %-9s [%s]  %s" % [namee, " · ".join(parts), note])