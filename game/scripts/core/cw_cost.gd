## cw_cost.gd —— 费用结算系统
##
## 按队友《费用结算系统设计》实装（2026-08-30 Kevin 拍板「以两份设计为准」）。
## 它**取代**了口径 #73 在费用侧的「卡牌按打出先后逐张结算」，见规则说明 #79；
## 连带作废定案 A（【炎症趋化】的抬价）与定案 D 乙案（限次折扣照扣）。
##
## 一条管线：
##   建上下文 → quote() 纯查询报价 → UI/AI 决策 → commit() 重新报价并原子扣费
##
## **报价是纯查询**（设计 §七.1）：quote() 不扣能量、不消耗修饰、不烧闸门、
## 不写日志、不碰 rng，所以 UI 每帧刷新、AI 枚举、快照推演都可以随便调。
## 闸门（「每行动回合首次」）在报价阶段只**读** `cell["fx_turn"]`，要写的名字记进
## `usage_marks`，等 commit 时才落笔 —— 这就是设计里说的「把查询+标记拆成两半」。
##
## **提交是原子的**（设计 §七.2）：commit() 重新验证 → 按当前状态重新报价 →
## 检查 payment_floor → 一次性扣费 → 只消耗 `consume_on_commit` 列出的修饰 →
## 写 `usage_marks`。第三步失败则后面全不发生。
##
## **修饰按语义阶段排序，来源顺序只是同阶段的平局规则**（设计 §四/§六）。
class_name CWCost
extends RefCounted

## 行为类型。目前只有 MOVE / PURIFY / PLAY_CARD 真的有修饰挂上来，
## 其余几种先占位：它们的费用是常量，走 quote() 只是为了口径统一。
enum Action { MOVE, DRAW, PURIFY, DIFFERENTIATE, CELL_SKILL, PLAY_CARD }

## 语义阶段（设计 §四的 11 步里，属于「修饰」的那几层）。
## 顺序即枚举顺序，`_order()` 直接比它的整数值。
enum Phase {
	REPLACE,     ## ③ 基础值替换：「费用改为 X」
	FLAT_ADD,    ## ④ 固定加费：「费用 +X」
	FLAT_CUT,    ## ⑤ 固定减费：「费用 -X」，带该减费**自己**的局部下限
	MULT,        ## ⑥ 倍增
	DIV,         ## ⑦ 倍减
	FREE,        ## ⑨ 免费豁免（进竞争组，一次最多选中一个）
	SURCHARGE,   ## ⑪ 不可豁免附加费：「额外支付 X」，免费也豁免不掉
}

## 同阶段同优先级时的平局顺序（设计 §六）
enum Source { PASSIVE, CARD, SKILL, WORLD }

## 消耗策略（设计 §七.3）。默认 ON_BENEFIT：实际改变了费用才消耗。
enum Consume { ON_COMMIT, ON_BENEFIT }

## 修饰条目住在哪儿——决定 commit 时怎么把它消耗掉
enum Store { MOD, GATE, EVENT_FREE, NONE }

## 支付后必须保留的能量下限。规则总则「不能使能量降至 0」= 至少留 0.1。
## 从前藏在 `CWGame.pay()` 的 `<=` 里，现在按设计 §二 显式化。
const DEFAULT_PAYMENT_FLOOR := 1

var game: CWGame


# ============ 修饰模板表 ============
## 名字 → 它提供的费用修饰（一个效果可以提供多条，如【组织巡航】的「免费 + 之后 -0.2」）。
##
## 字段：
##   action   只对这种行为生效
##   phase    语义阶段（见 Phase）
##   value    数值；FLAT_CUT 的 floor 是**该减费自己的**局部下限（设计 §五）
##   cond     额外条件谓词名，见 _cond_ok()
##   spec     「适用范围有多窄」。设计 §八 原本用它排免费竞争，但队友 2026-08-30
##            答复 c 改为「沿用打出先后」，所以它现在只是备查字段，不参与排序
##   source   平局用
##   store    消耗方式
##   consume  消耗策略
const TEMPLATES := {
	# ---- 免疫方即时卡 ----
	"炎症趋化": [{
		"action": Action.MOVE, "phase": Phase.REPLACE, "value": 5,
		"cond": ["to_cancerous"], "source": Source.CARD, "store": Store.MOD,
	}],
	"CXCR3趋化": [{
		"action": Action.MOVE, "phase": Phase.FLAT_CUT, "value": 5, "floor": 2,
		"cond": ["to_cancerous"], "source": Source.CARD, "store": Store.MOD,
	}],
	# ---- 免疫方永久技能 ----
	"LFA-1黏附": [{
		"action": Action.MOVE, "phase": Phase.FLAT_CUT, "value": 4, "floor": 2,
		"cond": ["to_cancerous", "gate_open"], "source": Source.SKILL, "store": Store.GATE,
	}],
	"组织浸润": [{
		"action": Action.MOVE, "phase": Phase.FLAT_CUT, "value": 3, "floor": 2,
		"cond": ["to_cancerous"], "source": Source.SKILL, "store": Store.NONE,
	}],
	## 设计 §九.2 的目标文案：「每行动回合**一次**，任意迁移免费；
	## 该额度**使用后**，本回合后续迁移 -0.2」。所以 -0.2 那条以 gate_closed 为条件。
	"组织巡航": [
		{
			"action": Action.MOVE, "phase": Phase.FREE, "spec": 1,   ## 任意迁移
			"cond": ["gate_open"], "source": Source.SKILL, "store": Store.GATE,
		},
		{
			"action": Action.MOVE, "phase": Phase.FLAT_CUT, "value": 2, "floor": 2,
			"cond": ["gate_closed"], "source": Source.SKILL, "store": Store.NONE,
		},
	],
	## 只管「向健康组织」，比【组织巡航】的「任意迁移」窄 → 免费竞争时优先（设计 §九）
	"组织驻留": [{
		"action": Action.MOVE, "phase": Phase.FREE, "spec": 2,
		"cond": ["to_healthy", "gate_open"], "source": Source.SKILL, "store": Store.GATE,
	}],
	# ---- 癌症方 ----
	"上皮—间质转化": [{
		"action": Action.MOVE, "phase": Phase.REPLACE, "value": 2,
		"cond": ["to_healthy"], "source": Source.CARD, "store": Store.MOD,
	}],
	## 【癌症干性】是永久技能，但生效与否看复活时发的限次额度（mods 里的同名条目），
	## 所以它从 mods 里收集，用完额度自然就不出现了
	## has_allowance：额度是复活时发的限次 mod 条目，用完这条修饰就不该再出现
	"癌症干性": [{
		"action": Action.MOVE, "phase": Phase.FREE, "spec": 2,
		"cond": ["to_cancerous", "has_allowance"], "source": Source.SKILL, "store": Store.MOD,
	}],
	# ---- 世界事件 ----
	## 「净化的钱不是迁移的钱」（口径 #65）→ 落在不可豁免附加费层，
	## 既砍不掉也免不掉（设计 §五的「额外支付 X」）
	"免疫抑制因子": [
		{
			"action": Action.MOVE, "phase": Phase.SURCHARGE, "value": 2,
			"cond": ["immune", "to_plain_cancer"], "source": Source.WORLD, "store": Store.NONE,
		},
		## 【裂解】顺带净化的那一档，同一笔净化费
		{
			"action": Action.PURIFY, "phase": Phase.SURCHARGE, "value": 2,
			"cond": [], "source": Source.WORLD, "store": Store.NONE,
		},
	],
	## 【细胞应激】打出卡牌需支付 0.5/层。是普通加费，不是附加费——
	## 将来若有「打牌免费」的卡，应当能豁免掉它
	"细胞应激": [{
		"action": Action.PLAY_CARD, "phase": Phase.FLAT_ADD, "value": 5,
		"cond": [], "source": Source.WORLD, "store": Store.NONE,
	}],
	## 「癌细胞移动 +0.2」是普通加费，按设计 §六 进固定加费层，不因来源是世界事件就覆盖一切
	"免疫伪装": [{
		"action": Action.MOVE, "phase": Phase.FLAT_ADD, "value": 2,
		"cond": ["cancer"], "source": Source.WORLD, "store": Store.NONE,
	}],
	"基质阻隔": [
		{
			"action": Action.MOVE, "phase": Phase.MULT, "value": 2,
			"cond": [], "source": Source.WORLD, "store": Store.NONE,
		},
		## 技能移动（小细胞肺癌【转移】、黑色素瘤【早期血行转移】）也翻倍
		{
			"action": Action.CELL_SKILL, "phase": Phase.MULT, "value": 2,
			"cond": [], "source": Source.WORLD, "store": Store.NONE,
		},
	],
	## 全场免疫细胞的每回合首次移动，适用范围最宽 → 竞争时排在细胞自己的额度之后
	"迁移激活": [{
		"action": Action.MOVE, "phase": Phase.FREE, "spec": 0,
		"cond": ["immune", "free_move_left"], "source": Source.WORLD, "store": Store.EVENT_FREE,
	}],
}


# ============ 上下文 ============

## 建一个费用上下文。base_cost 由调用方给（行动本身 + 免疫等级 + 细胞自带技能）。
static func context(actor: Dictionary, action: Action, base_cost: int,
		to: Vector2i = Vector2i.MAX, hard_floor: int = 0) -> Dictionary:
	return {
		"actor": actor,
		"action": action,
		"from": actor["pos"],
		"to": to,
		"base_cost": base_cost,
		"payment_floor": DEFAULT_PAYMENT_FLOOR,
		"hard_floor": hard_floor,   ## ⑩ 行动级最终硬下限，免费也压不下去
	}


# ============ 报价（纯查询）============

## 返回 CostQuote：
##   base / normal_cost / mandatory_extra / final / affordable
##   applied（真正改了价的效果名）/ applicable_but_unused（适用但没被选中的免费）
##   consume_on_commit（提交时要消耗的条目）/ usage_marks（提交时要写的闸门）
##   breakdown（每一步的来源、前值、后值，供 UI、日志与测试共用）
##
## **不产生任何副作用。** 反复调用不改变快照与 state_hash。
func quote(ctx: Dictionary) -> Dictionary:
	var mods := _collect(ctx)
	mods.sort_custom(_order)
	var cost: int = ctx["base_cost"]
	var breakdown: Array = []
	var applied: Array = []
	var consume: Array = []
	var marks: Array = []
	var unused: Array = []
	var free_group: Array = []
	var surcharge := 0

	for m in mods:
		match m["phase"]:
			Phase.FREE:
				free_group.append(m)     ## 先攒着，普通费用算完再竞争
				continue
			Phase.SURCHARGE:
				surcharge += int(m["value"])
				breakdown.append(_step(m, cost, cost, "附加 %s" % CWData.fmt(int(m["value"]))))
				applied.append(m["name"])
				_take(m, consume, marks)
				continue
		var before := cost
		cost = _apply(m, cost)
		breakdown.append(_step(m, before, cost, ""))
		if cost != before or m.get("consume", Consume.ON_BENEFIT) == Consume.ON_COMMIT:
			applied.append(m["name"])
			_take(m, consume, marks)

	var normal_cost: int = maxi(cost, 0)
	## ⑨ 免费豁免：同一竞争组里**最多选中一个**（设计 §八）。
	## 已经是 0 就没有可豁免的东西 —— 按 ON_BENEFIT 谁也不消耗。
	var chosen: Dictionary = {}
	if not free_group.is_empty():
		free_group.sort_custom(_free_order)
		if normal_cost > 0:
			chosen = free_group[0]
			applied.append(chosen["name"])
			_take(chosen, consume, marks)
			breakdown.append(_step(chosen, normal_cost, 0, "免费豁免"))
		for m in free_group:
			if chosen.is_empty() or m["name"] != chosen["name"]:
				unused.append(m["name"])

	var after_free: int = 0 if not chosen.is_empty() else normal_cost
	## ⑩ 行动硬下限压在免费之后、⑪ 附加费加在最后 —— 两者免费都豁免不掉
	var final_cost: int = maxi(after_free, int(ctx["hard_floor"])) + surcharge
	var actor: Dictionary = ctx["actor"]
	return {
		"base": ctx["base_cost"],
		"normal_cost": normal_cost,
		"mandatory_extra": surcharge,
		"final": final_cost,
		"affordable": actor["energy"] - final_cost >= int(ctx["payment_floor"]),
		"applied": applied,
		"applicable_but_unused": unused,
		"consume_on_commit": consume,
		"usage_marks": marks,
		"breakdown": breakdown,
	}


## 纯判定：付得起吗（含 payment_floor）
func can_pay(ctx: Dictionary) -> bool:
	return quote(ctx)["affordable"]


# ============ 提交（原子）============

## 重新报价 → 校验 → 扣费 → 只消耗报价选中的修饰 → 写闸门。
## 返回实际使用的报价；付不起则返回空字典，**任何副作用都不发生**。
func commit(ctx: Dictionary) -> Dictionary:
	var q := quote(ctx)              ## 按**当前**状态重算，不信调用方存的旧价钱
	if not q["affordable"]:
		return {}
	var actor: Dictionary = ctx["actor"]
	actor["energy"] -= int(q["final"])
	for c in q["consume_on_commit"]:
		_consume(actor, c)
	for name in q["usage_marks"]:
		game.first_this_turn(actor, name)
	for s in q["breakdown"]:
		if s["before"] != s["after"] or s["note"] != "":
			game.log_msg("　【%s】%s" % [s["name"], _describe(s)])
	return q


# ============ 内部 ============

## 把这个细胞与场上事件提供的费用修饰收集成一张表（只收适用于本上下文的）
func _collect(ctx: Dictionary) -> Array:
	var out: Array = []
	var actor: Dictionary = ctx["actor"]
	## 即时卡与限次额度：住在 cell["mods"]，applied_seq 取条目的 seq
	for m in actor["mods"]:
		_emit(out, ctx, m["name"], Store.MOD, m.get("seq", 0))
	## 永久技能：住在 cell["equipped"]，applied_seq 取 equip_seq
	for s in actor["equipped"]:
		if actor["mods"].any(func(m: Dictionary) -> bool: return m["name"] == s):
			continue   ## 已经从 mods 那边收过了（【癌症干性】那种「技能+限次额度」）
		_emit(out, ctx, s, Store.GATE, int(actor["equip_seq"].get(s, 0)))
	## 世界事件与卡牌挂的全局条目
	for e in game.events["active"]:
		_emit(out, ctx, e["name"], Store.EVENT_FREE, 0, e["stacks"])
	return out


## 按模板生成一条 CostModifier（条件不符就不生成）
func _emit(out: Array, ctx: Dictionary, name: String, from_store: int,
		seq: int, stacks: int = 1) -> void:
	if not TEMPLATES.has(name):
		return
	for t in TEMPLATES[name]:
		if t["action"] != ctx["action"]:
			continue
		var ok := true
		for c in t["cond"]:
			if not _cond_ok(c, ctx, name):
				ok = false
				break
		if not ok:
			continue
		out.append({
			"name": name,
			"phase": t["phase"],
			"value": int(t.get("value", 0)) * (stacks if t["source"] == Source.WORLD else 1),
			"floor": int(t.get("floor", 0)),
			"source": t["source"],
			"store": t.get("store", from_store),
			"consume": t.get("consume", Consume.ON_BENEFIT),
			"priority": int(t.get("priority", 0)),
			"specificity": int(t.get("spec", 0)),
			"applied_seq": seq,
			"stacks": stacks,
		})


func _cond_ok(cond: String, ctx: Dictionary, name: String) -> bool:
	var actor: Dictionary = ctx["actor"]
	var to: Vector2i = ctx["to"]
	match cond:
		"to_cancerous":
			return game.is_cancerous(to)
		"to_healthy":
			return game.tile(to)["tissue"] == CWData.Tissue.HEALTHY
		"to_plain_cancer":
			return game.tile(to)["tissue"] == CWData.Tissue.CANCER
		"immune":
			return actor["faction"] == CWData.Faction.IMMUNE
		"cancer":
			return actor["faction"] == CWData.Faction.CANCER
		"gate_open":
			return not actor["fx_turn"].has(name)
		"gate_closed":
			return actor["fx_turn"].has(name)
		"free_move_left":
			return game.world_fx.free_move_available(actor)
		"has_allowance":
			## 【癌症干性】那种「永久技能 + 复活时发的限次额度」：额度住在 mods 里，
			## 用完就不该再从 equipped 那边冒出来
			return not game.mods_of(actor, name).is_empty()
	return false


## 一条修饰作用在当前价上。FLAT_CUT 的下限是**这一条自己的**局部下限，
## 不能收集所有下限后取最大值（设计 §五）。
func _apply(m: Dictionary, cost: int) -> int:
	match m["phase"]:
		Phase.REPLACE:
			return int(m["value"])
		Phase.FLAT_ADD:
			return cost + int(m["value"])
		Phase.FLAT_CUT:
			return maxi(cost - int(m["value"]), mini(cost, int(m["floor"])))
		Phase.MULT:
			var v := cost
			for i in int(m["stacks"]):
				v *= int(m["value"])
			return v
		Phase.DIV:
			return cost / int(m["value"])
	return cost


## 语义阶段 → 显式优先级 → 来源 → applied_seq → 名字（设计 §六）
static func _order(a: Dictionary, b: Dictionary) -> bool:
	if a["phase"] != b["phase"]:
		return a["phase"] < b["phase"]
	if a["priority"] != b["priority"]:
		return a["priority"] > b["priority"]
	if a["source"] != b["source"]:
		return a["source"] < b["source"]
	if a["applied_seq"] != b["applied_seq"]:
		return a["applied_seq"] < b["applied_seq"]
	return a["name"] < b["name"]


## 免费竞争组的选择顺序（设计 §八，队友 2026-08-30 答复 c 修订）：
##   显式优先级 → 来源 → **打出/装备先后** → 名字
##
## 设计原文排的是「适用范围更窄者优先」（§九 举例：向健康组织时【组织驻留】比
## 【组织巡航】窄，应当先用驻留）。队友答复：「本质竞争组优先级问题，**按方便记忆
## 可沿用打出先后顺序**」——玩家记「谁先上场谁先用」比记「谁的条件更窄」容易得多，
## 所以这里按打出先后排，specificity 只留作字段备查、不参与排序。
##
## 来源仍排在打出先后之前：世界事件（如【迁移激活】）没有「被谁打出」的时刻，
## applied_seq 恒为 0，不先按来源分层的话它会永远抢在细胞自己的额度前面。
static func _free_order(a: Dictionary, b: Dictionary) -> bool:
	if a["priority"] != b["priority"]:
		return a["priority"] > b["priority"]
	if a["source"] != b["source"]:
		return a["source"] < b["source"]     ## 角色被动 → 卡牌 → 技能 → 世界事件
	if a["applied_seq"] != b["applied_seq"]:
		return a["applied_seq"] < b["applied_seq"]
	return a["name"] < b["name"]


## 记下「提交时要消耗什么」。闸门写进 usage_marks，其余写进 consume_on_commit。
static func _take(m: Dictionary, consume: Array, marks: Array) -> void:
	match m["store"]:
		Store.GATE:
			if not marks.has(m["name"]):
				marks.append(m["name"])
		Store.MOD, Store.EVENT_FREE:
			consume.append({ "name": m["name"], "store": m["store"] })


func _consume(actor: Dictionary, c: Dictionary) -> void:
	match c["store"]:
		Store.MOD:
			_spend_one_mod(actor, c["name"])
		Store.EVENT_FREE:
			game.world_fx.consume_free_move(actor)


## 消耗**一条**同名修饰条目（用尽即移除），取最早打出的那条。
## 费用是逐条结算的，所以一次只扣一条——区别于伤害管线的 CWGame.spend_mods。
static func _spend_one_mod(cell: Dictionary, mod_name: String) -> bool:
	for i in cell["mods"].size():
		var m: Dictionary = cell["mods"][i]
		if m["name"] != mod_name:
			continue
		m["uses"] -= 1
		if m["uses"] <= 0:
			cell["mods"].remove_at(i)
		return true
	return false


static func _step(m: Dictionary, before: int, after: int, note: String) -> Dictionary:
	return { "name": m["name"], "phase": m["phase"],
		"before": before, "after": after, "note": note }


static func _describe(s: Dictionary) -> String:
	if s["note"] != "":
		return "%s（%s → %s）" % [s["note"], CWData.fmt(s["before"]), CWData.fmt(s["after"])]
	return "费用 %s → %s" % [CWData.fmt(s["before"]), CWData.fmt(s["after"])]
