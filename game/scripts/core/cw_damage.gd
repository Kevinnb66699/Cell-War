## cw_damage.gd —— 伤害结算系统
##
## 按队友《攻击与伤害结算系统设计》实装（2026-08-30 Kevin 拍板「以两份设计为准」）。
##
## 七阶段管线（设计 §五）：
##   建立事件 → 替代/免疫 → 数值计算 → 批量提交 → 濒死与死亡替代 → 批量死亡 → 伤后触发
##
## **三条铁律**：
## ① 计算是纯函数，**先把整批算完再动能量**（§5.5）。边遍历边扣能量、边死人，
##    数组顺序就会改变结果——范围伤害尤其怕这个。
## ② 「攻击成功后」看**判定**，「造成伤害后」看 `DamageResult.actual > 0`（§三末）。
##    吸血、统计、斩杀一律读 actual，不读理论伤害。
## ③ 「无视减伤」仍然是伤害事件，只是带 `UNPREVENTABLE` 标签；**不允许**为了绕过
##    减伤就直接 `target["energy"] -= v`，否则日志、BCL-2、死亡与统计会再次分叉（§4.1）。
class_name CWDamage
extends RefCounted

## 伤害来源（设计 §4.1）
enum Kind { ATTACK, CELL_SKILL, CARD, WORLD, REFLECT, SELF }

## 跨来源性质的标签
enum Tag {
	IMMUNE,          ## 免疫方造成
	CANCER,          ## 癌症方造成
	ATTACK,          ## 是「攻击」——树突【各司其职】减半、巨噬【吞噬】吸血只认它
	AREA,            ## 范围伤害（必须带 simultaneous_group）
	DIRECT,          ## 直击
	UNPREVENTABLE,   ## 跳过数值减免，但**不**跳过日志、BCL-2、死亡检查与统计
	NO_LIFESTEAL,
}

## 伤后触发的类别（设计 §5.7）。**枚举顺序即结算顺序**，别随手调换。
enum Trigger {
	ON_DEAL,       ## 1 造成伤害后
	ON_TAKE,       ## 2 受到伤害后
	LIFESTEAL,     ## 3 吸血 / 回复
	ON_HIT,        ## 4 攻击成功后
	ON_KILL,       ## 5 击杀后
	ON_DEATH,      ## 6 死亡后
	AFTER_ACTION,  ## 7 组织转化、抽牌等行动后续
}

## 同类触发的平局顺序（设计 §5.7 末）
enum Rank { PASSIVE, CARD, SKILL, WORLD }

var game: CWGame
var _next_id := 0
var _next_group := 0
var _queue: Array = []
var _queue_seq := 0


## 范围伤害的批次号（设计 §4.1 的 simultaneous_group）。
## 同一批的事件必须在同一份「批前状态」上计算，见 submit()。
func next_group() -> int:
	_next_group += 1
	return _next_group


# ============ ① 建立事件 ============

## 冻结来源、目标、基础伤害、固定额外伤害、位置与标签。
## 这一步不扣能量、不烧护盾、不检查死亡。
func event(source: Dictionary, target: Dictionary, base: int, kind: Kind,
		tags: Array, ability: String, add: int = 0, group: int = 0) -> Dictionary:
	_next_id += 1
	return {
		"id": _next_id,
		"source": source,
		"target": target,
		"base_amount": base,
		"bonus_amount": add,
		"source_kind": kind,
		"tags": tags,
		"ability": ability,
		"position": target["pos"],
		"simultaneous_group": group,
	}


## 提交伤害事件，返回等长的 DamageResult 数组（顺序与传入一致）。
##
## **批次由事件自己的 `simultaneous_group` 决定，不由「调用方碰巧塞进同一个数组」决定**
## （2026-08-31 队友审查问题 2）。四条语义写死在这里：
##   ① `group == 0` = 未编组，**每个事件自成一批**——单体伤害的默认；
##   ② 多批之间按**首次出现顺序**处理，后一批看得到前一批结算完的盘面；
##   ③ **不允许**同一个 group 跨多次 submit() 追加——批次边界必须在一次调用里闭合；
##   ④ 次级伤害（如 T 细胞【细胞毒性增强】的无视减伤那一下）归**当前批**。
##      拆开的话主伤害会先结算死亡、BCL-2 先把能量拉回分期值，次级伤害再补一刀，
##      反而可能绕过 BCL-2 把人打死。
func submit(events: Array) -> Array:
	if events.is_empty():
		return []
	var batches: Array = []
	var at := {}                    ## group -> 它在 batches 里的下标
	for ev in events:
		var g: int = int(ev["simultaneous_group"])
		if g != 0 and at.has(g):
			batches[at[g]].append(ev)
			continue
		if g != 0:
			at[g] = batches.size()
		batches.append([ev])
	var results: Array = []
	for b in batches:
		results.append_array(_submit_batch(b))
	return results


## 一个批次走完整的五步。**同批的每个目标都在同一份「批前状态」上计算**：
## 边遍历边扣能量、边死人的话，数组顺序就会改变结果（设计 §5.5）。
func _submit_batch(events: Array) -> Array:
	## ②③ 先把整批算完（纯计算，谁也不动）
	var plans: Array = []
	for ev in events:
		plans.append(_plan(ev))
	## ④ 再统一扣能量、消耗修饰
	var results: Array = []
	for plan in plans:
		results.append(_apply(plan))
	## ⑤⑥ 批次状态稳定后，统一走濒死 → 死亡替代 → 批量死亡
	_resolve_deaths(results)
	## ⑦ 最后才抛伤后触发（斩杀、吸血…），此时盘面已经稳定
	_queue_triggers(results)
	_flush_triggers()
	game.update_marks()   ## §6.2：光环重新施加标记只能在整批结算完之后
	return results


# ============ ②③ 替代/免疫 + 数值计算（纯函数）============

func _plan(ev: Dictionary) -> Dictionary:
	var target: Dictionary = ev["target"]
	var plan := {
		"event": ev,
		"replaced": false,
		"calculated": 0,
		"attempted": ev["base_amount"] + ev["bonus_amount"],
		"consume": [],      ## 提交时才真的扣掉的修饰 {name, uses_all}
		"marks": [],        ## 提交时才写的「每世界回合首次」闸门
		"logs": [],
	}
	## ② 替代与免疫：整个事件失效的效果先处理。被整体免疫的事件视为「未造成伤害」，
	## 不触发吸血、受伤与斩杀，**也不消耗数值层的修饰**（设计 §5.2）
	if _immune_to(ev):
		plan["replaced"] = true
		plan["logs"].append("　【抗原丢失】本回合攻击无法使癌细胞损失能量")
		return plan
	## ③ 数值计算：保留 PRD 五步数学
	plan["calculated"] = _calculate(ev, plan)
	return plan


## 【抗原丢失】：本回合攻击无法使癌细胞损失能量
func _immune_to(ev: Dictionary) -> bool:
	return Tag.ATTACK in ev["tags"] and game.event_stacks("抗原丢失") > 0


## 五步管线：max(floor((基础 + 固定增加) × 倍增 ÷ 倍减) - 固定减免, 0)
func _calculate(ev: Dictionary, plan: Dictionary) -> int:
	var target: Dictionary = ev["target"]
	var mult := 1
	var div := 1
	## ③ 倍增 —— 树突【标记】。ON_BENEFIT：只有确实抬高了伤害才消耗（设计 §6.2）
	if target["marked"] and ev["base_amount"] + ev["bonus_amount"] > 0:
		mult *= 2
		plan["consume"].append({ "kind": "mark" })
	## ④ 倍减 —— 树突【各司其职】，只认「攻击」
	if Tag.ATTACK in ev["tags"] and ev["source"].get("itype", -1) == CWData.ImmuneType.DENDRITIC:
		div *= 2
		plan["logs"].append("　【各司其职】树突状细胞只造成 1/2 伤害")
	var dmg: int = (ev["base_amount"] + ev["bonus_amount"]) * mult / div
	## ⑤ 固定减免。UNPREVENTABLE 跳过这一层——但日志、BCL-2、死亡检查照走（设计 §6.4）
	if Tag.UNPREVENTABLE in ev["tags"]:
		return maxi(dmg, 0)
	return maxi(_reduce(ev, dmg, plan), 0)


## 减免层。**同名多条一起算**（定案 #57：两张「下一次 -1.5」= 这一次减 3.0），
## 不同名的按打出先后逐组结算，每组走 ON_BENEFIT：这一组没把伤害压低就不消耗
## （设计 §5.4）。两条口径正交，互不冲突 —— 队友 2026-08-30 答复 b 已确认。
func _reduce(ev: Dictionary, dmg: int, plan: Dictionary) -> int:
	for g in _shield_groups(ev):
		if dmg <= 0:
			break                      ## 已经挡光了，后面的盾留着（ON_BENEFIT）
		var after: int = maxi(dmg - g["cut"], 0)
		if after == dmg:
			continue                   ## 这一组没起作用 → 不消耗
		plan["logs"].append("　【%s】减免 %s" % [g["name"], CWData.fmt(dmg - after)])
		if g.has("mod"):
			plan["consume"].append({ "kind": "mod", "name": g["name"] })
		if g.has("mark"):
			plan["marks"].append(g["mark"])
		if g.get("armor", false):
			plan["consume"].append({ "kind": "armor" })
		dmg = after
	return dmg


## 这次事件上，受击方有哪些减免可用。按「打出先后」排（同名合并成一组）。
func _shield_groups(ev: Dictionary) -> Array:
	var t: Dictionary = ev["target"]
	var out: Array = []
	## 印戒【囊性护甲】：每世界回合第一次能量损失 -0.5，不限来源（口径 #76）
	if t["ctype"] == CWData.CancerType.SIGNET and not t["armor_used"]:
		out.append({ "name": "囊性护甲", "cut": CWData.ARMOR_REDUCTION, "armor": true,
			"seq": -1 })
	for name in ["细胞膜修复", "I型干扰素", "缺氧适应", "DNA损伤修复"]:
		if not _shield_applies(name, ev):
			continue
		var entries: Array = game.mods_of(t, name)
		if entries.is_empty():
			continue
		out.append({ "name": name, "cut": _shield_value(name, entries.size()),
			"mod": true, "seq": int(entries[0].get("seq", 0)) })
	## 【耗竭抵抗】是永久技能，没有「打出先后」，排在最后
	if game.has_skill(t, "耗竭抵抗"):
		var cut := 0
		if not t["fx_round"].has("耗竭抵抗"):
			cut += CWData.EXHAUST_FIRST_CUT
		if ev["ability"] == "微环境压迫":
			cut += CWData.EXHAUST_PRESSURE_CUT
		if cut > 0:
			out.append({ "name": "耗竭抵抗", "cut": cut, "mark": "耗竭抵抗", "seq": 1 << 30 })
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["seq"] < b["seq"])
	return out


## 各护盾认哪些来源（设计 §6.5：按标签语义识别，不靠布尔分叉）
func _shield_applies(name: String, ev: Dictionary) -> bool:
	match name:
		"细胞膜修复", "I型干扰素":
			return true                        ## 任何来源的能量损失
		"缺氧适应":
			## 癌细胞技能（含癌方即时卡）**或**【微环境压迫】（口径 #62/#72）
			return ev["ability"] == "微环境压迫" \
				or (Tag.CANCER in ev["tags"] and ev["source_kind"] != Kind.WORLD)
		"DNA损伤修复":
			## 只挡免疫方的【事件】/【技能】，普通攻击是 PD-L1 的领地（口径 #62）
			return Tag.IMMUNE in ev["tags"] and not (Tag.ATTACK in ev["tags"])
	return false


func _shield_value(name: String, count: int) -> int:
	match name:
		"细胞膜修复":
			return CWData.MEMBRANE_CUT * count
		"I型干扰素":
			return CWData.IFN1_CUT * count
		"缺氧适应":
			return CWData.HYPOXIA_CUT * count
		"DNA损伤修复":
			## 按结算当刻的分期取值（定案 #64）
			return [10, 15, 20][CWCardData.cancer_phase(game.round_no)] * count
	return 0


# ============ ④ 提交（扣能量 + 消耗修饰）============

func _apply(plan: Dictionary) -> Dictionary:
	var ev: Dictionary = plan["event"]
	var target: Dictionary = ev["target"]
	var before: int = target["energy"]
	var calculated: int = plan["calculated"]
	## actual = 目标**实际失去**的能量，不能超过它结算前有多少（设计 §4.2）。
	## 吸血、伤害统计、「造成 X 伤害后」一律读这个值 —— 读理论值会多回血（审查附一）
	var actual: int = mini(calculated, maxi(before, 0))
	for line in plan["logs"]:
		game.log_msg(line)
	if not plan["replaced"]:
		for c in plan["consume"]:
			_consume(target, c)
		for m in plan["marks"]:
			game.first_this_round(target, m)
		target["energy"] = before - calculated
	if calculated > 0:
		game.log_msg("【%s】%s 损失 %s 能量（余 %s）" % [
			ev["ability"], game.cell_name(target), CWData.fmt(actual),
			CWData.fmt(maxi(target["energy"], 0))])
	return {
		"event_id": ev["id"], "event": ev,
		"attempted": plan["attempted"], "calculated": calculated, "actual": actual,
		"prevented": maxi(plan["attempted"] - calculated, 0),
		"energy_before": before, "energy_after": target["energy"],
		"was_replaced": plan["replaced"], "killed": false,
	}


func _consume(target: Dictionary, c: Dictionary) -> void:
	match c["kind"]:
		"mark":
			target["mark_left"] -= 1
			if target["mark_left"] <= 0:
				target["marked"] = false
				game.log_msg("　【标记】生效，伤害翻倍")
			else:
				game.log_msg("　【标记】生效，伤害翻倍（还可触发 %d 次）" % target["mark_left"])
		"armor":
			target["armor_used"] = true
		"mod":
			game.spend_mods(target, c["name"])   ## 同名一起扣（定案 #57）


# ============ ⑤⑥ 濒死 → 死亡替代 → 批量死亡 ============

## 设计 §5.6，**分三遍走**（2026-08-31 按队友审查报告 §六.3 拆开）：
##   一、纯挑选，谁也不动 —— 找出这一批被打到 0 以下的；
##   二、死亡替代（【BCL-2抗凋亡】等免死）—— 它会改能量，必须在批量宣死之前；
##   三、批量宣死 —— 到这一步盘面已经定了，各个 kill() 之间互不影响。
##
## 从前是一个循环里「查濒死 → 免死 → kill」连着做，虽然 kill() 副作用少、
## 当时没出错，但那是**结构上的数组顺序依赖**：一旦将来 kill() 带上「死亡后」连锁
## （掉落、光环消失、给相邻单位加护盾…），同一批里排在后面的目标就会看到变化后的盘面。
func _resolve_deaths(results: Array) -> void:
	## 一、挑出濒死的（同一目标可能在这一批里挨了不止一下，只收一次）
	var dying: Array = []
	for r in results:
		var t: Dictionary = r["event"]["target"]
		if r["was_replaced"] or r["actual"] <= 0 or not t["alive"] or t["energy"] > 0:
			continue
		dying.append(r)
	if dying.is_empty():
		return
	## 二、死亡替代
	var doomed: Array = []
	for r in dying:
		var t: Dictionary = r["event"]["target"]
		if t["energy"] > 0:
			continue                  ## 同一目标已被前一条的替代救回来了
		if _revive_by_bcl2(t):
			continue
		doomed.append(r)
	## 三、批量宣死
	for r in doomed:
		var t: Dictionary = r["event"]["target"]
		if not t["alive"]:
			continue                  ## 同一目标在这一批里挨了两下，只死一次
		game.kill(t)
		r["killed"] = true


## 【BCL-2抗凋亡】只救「受到的损失」（口径 #68）。返回 true 表示这次免于死亡。
func _revive_by_bcl2(cell: Dictionary) -> bool:
	if not game.has_skill(cell, "BCL-2抗凋亡"):
		return false
	var tier: int = CWData.BCL2_ENERGY[CWCardData.cancer_phase(game.round_no)]
	cell["energy"] = tier
	cell["equipped"].erase("BCL-2抗凋亡")
	game.log_msg("　【BCL-2抗凋亡】%s 免于死亡，能量改为 %s（本牌弃置，可重新抽取）" % [
		game.cell_name(cell), CWData.fmt(tier)])
	return true


## 「直接消灭」不由业务代码随手调 kill()，而是建一个 LethalEvent，
## **显式**标记能不能被死亡替代阻止（设计 §5.6，队友答复 d 确认是技术层要求）。
##
## ⚠ preventable 的默认值必须选对：口径 #68 定的是【吞噬体成熟】的处决
## **BCL-2 救不回**（先免死再被处决的顺序按字面走）。图省事让它默认可阻止的话，
## #68 会被静默改掉，而且现有断言一条都不会红 —— 所以默认写成不可阻止。
func lethal(target: Dictionary, reason: String, preventable: bool = false) -> bool:
	if not target["alive"]:
		return false
	if preventable and _revive_by_bcl2(target):
		return false
	game.log_msg("　【%s】%s 被直接消灭" % [reason, game.cell_name(target)])
	game.kill(target)
	game.update_marks()
	return true


# ============ ⑦ 伤后触发队列 ============
#
# 设计 §5.7：盘面稳定之后按固定类别入队，同类再按
# 「显式优先级 → 角色被动 → 卡牌 → 技能 → 世界事件 → 入场顺序」稳定排序。
#
# 现在真正登记进来的只有两条（【吞噬体成熟】的斩杀、巨噬【吞噬】的吸血）。
# 队列的价值不在条目多，而在于**加第三条时不用再想「它该插在哪、会不会被谁抢先」**
# —— 从前这两条一个在 CWDamage 里、一个在 CWActions 的攻击流程里，
# 顺序全靠调用位置，加新触发就得重新推理一遍。

func _enqueue(cat: Trigger, rank: Rank, label: String, fn: Callable) -> void:
	_queue_seq += 1
	_queue.append({ "cat": cat, "rank": rank, "seq": _queue_seq, "label": label, "fn": fn })


static func _trigger_order(a: Dictionary, b: Dictionary) -> bool:
	if a["cat"] != b["cat"]:
		return a["cat"] < b["cat"]
	if a["rank"] != b["rank"]:
		return a["rank"] < b["rank"]
	return a["seq"] < b["seq"]


## 触发自己也可能再入队（斩杀 → 击杀后 → …），所以要循环抽干。
## guard 是防呆护栏：正常对局远达不到，真撞上说明有环，宁可停下也别死循环。
func _flush_triggers() -> void:
	var guard := 0
	while not _queue.is_empty() and guard < 8:
		guard += 1
		var batch: Array = _queue
		_queue = []
		batch.sort_custom(_trigger_order)
		for e in batch:
			e["fn"].call()


func _queue_triggers(results: Array) -> void:
	## 「造成伤害后」类的触发要看**这一批的合计**，不是单条事件 ——
	## 同一个 (来源, 目标) 在一批里可能挨了不止一下（主攻击 + 无视减伤的次级伤害）
	var dealt := {}
	for r in results:
		if r["was_replaced"] or r["actual"] <= 0:
			continue
		var ev: Dictionary = r["event"]
		var src: Dictionary = ev["source"]
		var tgt: Dictionary = ev["target"]
		var key := "%d>%d" % [int(src.get("id", -1)), int(tgt["id"])]
		if not dealt.has(key):
			dealt[key] = { "source": src, "target": tgt, "total": 0, "attack": false }
		dealt[key]["total"] += int(r["actual"])
		if Tag.ATTACK in ev["tags"]:
			dealt[key]["attack"] = true
		## ③ 吸血 —— 巨噬【吞噬】：攻击造成能量损失后恢复 ⌈**受击方实际损失** ÷ 2⌉。
		## PRD 这里的取整符号外面没写「到十分位」，所以按**整数能量**向上取整。
		## 读 actual 而不是理论伤害 —— 残血目标身上两者能差出整整 1.0（审查附一）
		if Tag.ATTACK in ev["tags"] and not (Tag.NO_LIFESTEAL in ev["tags"]) \
				and src.get("itype", -1) == CWData.ImmuneType.MACRO:
			var heal: int = int(ceil(r["actual"] / 2.0 / 10.0)) * 10
			_enqueue(Trigger.LIFESTEAL, Rank.PASSIVE, "吞噬", func() -> void:
				src["energy"] += heal
				game.log_msg("　巨噬【吞噬】恢复 %s 能量" % CWData.fmt(heal)))
	## ① 造成伤害后 —— 【吞噬体成熟】的伤害后斩杀
	for d in dealt.values():
		_queue_execution(d)


## 【吞噬体成熟】是**伤害后斩杀**（设计 §5.6）：本批确实造成了损失、
## 目标经死亡替代后仍存活、且余量不高于阈值才成立 —— 攻击被完全减免时不该发生斩杀。
## 2026-08-31 从 CWActions 的攻击流程挪进来：从前它在伤害系统的死亡阶段**之后**
## 另起一刀，等于绕开了「死亡只在死亡阶段发生」这条约定。
func _queue_execution(d: Dictionary) -> void:
	var src: Dictionary = d["source"]
	if not d["attack"] or int(d["total"]) <= 0 or not src.has("equipped"):
		return
	if not game.has_skill(src, "吞噬体成熟"):
		return
	var target: Dictionary = d["target"]
	var macro: bool = src.get("itype", -1) == CWData.ImmuneType.MACRO
	var thr: int = CWData.PHAGO_THRESHOLD_MACRO if macro else CWData.PHAGO_THRESHOLD
	_enqueue(Trigger.ON_DEAL, Rank.SKILL, "吞噬体成熟", func() -> void:
		if not target["alive"] or target["energy"] > thr:
			return
		game.log_msg("　【吞噬体成熟】目标余量仅 %s（不高于 %s）" % [
			CWData.fmt(target["energy"]), CWData.fmt(thr)])
		lethal(target, "吞噬体成熟")
		if macro:
			src["energy"] += CWData.SKILL_HEAL
			game.log_msg("　【吞噬体成熟】巨噬恢复 0.5 能量"))
