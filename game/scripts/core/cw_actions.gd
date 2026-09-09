## cw_actions.gd —— 主动技能与移动/攻击结算
##
## build_options(cell) 生成当前所有合法行动（含费用校验），execute() 执行。
## enter_tile() 是「进入一格」的唯一入口：定殖 / 净化 / 特殊组织收取 / 标记刷新
## 都在这里统一触发（移动、血管传送、复活落位、各种传送共用，见说明 #9）。
##
## **一个组织内只能容纳一个细胞**（PRD 棋盘设定）。所以凡是「把细胞放到某格」的地方，
## 合法性判断都是 `game.cells_at(c).is_empty()`，不再区分敌我。
## 唯一的例外是免疫【迁移】进癌细胞所在格 —— 那一下是为了触发攻击，
## 而攻击结算完之后要么癌细胞死了（免疫进格）、要么免疫弹回原格，落定时仍是一格一个。
class_name CWActions
extends RefCounted

var game: CWGame


# ============ 行动菜单 ============

func build_options(cell: Dictionary) -> Array:
	var opts: Array = []
	if cell["faction"] == CWData.Faction.IMMUNE:
		_immune_options(cell, opts)
	else:
		_cancer_options(cell, opts)
	game.card_fx.hand_options(cell, opts)
	_discard_options(cell, opts)
	opts.append({ "label": "结束回合", "data": { "act": "end" } })
	return opts


func _immune_options(cell: Dictionary, opts: Array) -> void:
	var lvl := game.immune_level
	opts.append_array(immune_move_options(cell))
	if _can_draw(cell) and game.can_pay(cell, CWData.IMMUNE_DRAW_COST):
		opts.append({ "label": "基因表达：抽卡（0.5 能量）", "data": { "act": "draw" } })
	if lvl >= game.tune.differentiate_min_level and not cell["differentiated"]:
		for t in _diff_choices():
			opts.append({
				"label": "分化为%s（免费）" % CWData.IMMUNE_TYPE_NAMES[t],
				"data": { "act": "differentiate", "type": t },
			})
	## 【抗体】的「每世界回合最多 2 次」2026-09-01 起取消（PRD 删掉该条，Kevin 确认）
	if cell["itype"] == CWData.ImmuneType.B_CELL and _antibody_quota_left(cell) \
			and game.can_pay(cell, antibody_cost(cell)):
		## 标签带上「这一次打多少」：递减规则下同一个按钮的收益每次都不同，
		## 不写出来玩家就会白花 1.0 能量打 0 伤害
		opts.append({ "label": "抗体（%s 能量，伤害 %s）"
			% [CWData.fmt(antibody_cost(cell)), CWData.fmt(antibody_damage(cell))],
			"data": { "act": "antibody" } })
	## 树突【I-趋化源】：2.0 能量在**全局任意位置**建一个，持续 2 回合，同一时刻仅一个。
	## 「全局任意位置」有 127 格，全摊成顶层选项会把行动清单撑爆（AI 也没法推演），
	## 所以这里只出**一个入口**，落点由 `_do_chemo` 再问一次（kind = "chemo_target"）。
	if cell["itype"] == CWData.ImmuneType.DENDRITIC and game.chemo.is_empty() \
			and game.can_pay(cell, CWData.CHEMO_COST):
		opts.append({ "label": "趋化源（%s 能量）" % CWData.fmt(CWData.CHEMO_COST),
			"data": { "act": "chemo" } })
	## 【效应应答】：X 级解锁，四种分化各一个，费用是 15 **效应记忆**不是能量。
	## 门槛全在 `game.can_effector()` 里（只查不改），这里只负责摆一个入口；
	## 需要选目标的两个（免疫猎杀选癌细胞、Excalibur 选方向）在执行时再问一次 —— 同【趋化源】的理由。
	if game.can_effector(cell):
		var en: String = CWData.EFFECTOR_NAMES.get(cell["itype"], "")
		if en != "" and _effector_ready(cell, en):
			opts.append({ "label": "效应应答·%s（%d 效应记忆）" % [en, CWData.EFFECTOR_COST],
				"data": { "act": "effector" } })
	if cell["itype"] == CWData.ImmuneType.T_CELL:
		if cell["toxin_used"] < CWData.TOXIN_MAX_PER_ROUND \
				and game.can_pay(cell, CWData.TOXIN_COST) and not _toxin_targets(cell).is_empty():
			opts.append({ "label": "细胞毒素（1.0 能量）", "data": { "act": "toxin" } })
		## 【裂解】2026-09-01 改写：目标从「脚下」变成「相邻」，且一步直接变健康组织
		## （PRD 原文只说「转为健康组织」，不再提【净化】，所以**不给抗原记忆、
		## 也不走净化连锁**）。每个可裂解的相邻格摊成一个顶层选项，理由同别处：
		## 埋在 execute() 里再问一次，AI 就没法把一个行动当成原子来推演。
		if game.can_pay(cell, CWData.LYSE_COST):
			for c in _lyse_targets(cell):
				opts.append({ "label": "裂解→%s（1.0 能量）" % str(c),
					"data": { "act": "lyse", "to": c } })


## 免疫的迁移/攻击选项（含费用与可支付校验）。
## 单独成函数是因为【全身免疫动员】的「立即迁移 1 次」也用这一份 ——
## 迁移合法性和定价只定义一处，事件和行动栏永远口径一致。
func immune_move_options(cell: Dictionary) -> Array:
	var opts: Array = []
	for n in move_dests(cell):
		if not _is_move_legal_now(cell, n):
			continue          # 与提交时复验的是同一份谓词
		var enemies: Array = game.cells_at(n, CWData.Faction.CANCER)
		var cost := _move_cost_mod(cell, n, _move_base_cost(cell, n))
		if not game.can_pay(cell, cost):
			continue
		var tag := "攻击" if not enemies.is_empty() 			else ("穿过" if pass_through_mid(cell, n) != Vector2i.MAX else "迁移")
		opts.append({
			"label": "%s→%s %s（%s 能量）" % [tag, str(n), tissue_tag(n), CWData.fmt(cost)],
			"data": { "act": "move", "to": n, "cost": cost },
		})
	return opts




# ---- 路径规划器（2026-09-04 Kevin 要的「拖一条路，程序算总价」）----
#
# 为什么要引擎来算：一条路的**每一步价钱都取决于走到那一步时的盘面**——
# 癌细胞踩过的健康组织当场变癌组织（【定殖】），于是下一步可能从「健康 1.0」变成「癌性 0.2」，
# 黑色素瘤【伪足穿透】的「相邻 ≥3 格癌性」也会因此成立；免疫踩过癌组织当场【净化】成健康，
# 下一步反而变贵。界面自己拿单格价钱乘步数**必然算错**，所以这份账只能engine 算。
#
# **纯查询**：动过的字段算完原样放回，`cell` / `tiles` 的对象身份不变
# （不用 snapshot/restore —— 那会换掉整个 cells 数组，调用方手里的 cell 引用当场失效）。

## 沿 path 逐格报价。path 是**依次要落脚的格子**（不含起点），一步一格。
##
## 只模拟「会改变后续价钱**或后续付不付得起**」的三件事：细胞位置、脚下组织按
## 【定殖】/【净化】翻面、**踩上【代谢核心】收到的能量**。
##
## 核心收入 2026-09-08 补进来（Kevin 报「规划路径不会计算代谢核心给的能量」）：
## 它不改变任何一步的**单价**，但改变**账上还剩多少**，于是直接决定后面几步的 `afford`。
## 少算它的后果是「明明走得完的路，规划器说第 4 步钱不够」——玩家只能放弃这条路线。
## 取走之后本格 `store` 要清零，否则同一个核心来回踩两趟会被算成收两次钱。
##
## 仍不模拟的副作用（抗原记忆、日志、骨髓抽卡、RAS 回能）不影响价钱也不影响余额。
## **巨噬【吞噬】净化回能是个例外**：它确实进余额，但规划器目前没算——
## 少算它只会让规划器**偏保守**（说没钱、实际有），不会让玩家按错的账走进死路，
## 所以留着没动，要补是另一件事。
##
## 返回 { steps: [{ to, cost, mid, legal, afford, blocked }], total, ok, left, stop }
##   · legal  这一步在**走到它的时候**合法吗（与提交复验共用 `_is_move_legal_now`）
##   · afford 走到这一步时账上还付得起吗（逐步扣，不是拿总价比总能量）
##   · gain   这一步踩上【代谢核心】拿到的能量（0 = 没拿到）
##   · blocked 非空 = 为什么走不了，直接给玩家看
##   · ok     整条路都走得通；stop = 第一步走不通的下标（-1 = 全通）
##   · gained 全程从核心拿到的能量合计（`total` 仍是纯花费，两者不相抵）
func quote_path(cell: Dictionary, path: Array) -> Dictionary:
	var saved_pos: Vector2i = cell["pos"]
	var saved: Array = []          ## [[坐标, 动之前的组织字段]]，逆序放回
	var steps: Array = []
	var budget: int = cell["energy"]
	var total := 0
	var gained := 0
	var stop := -1
	for i in path.size():
		var to: Vector2i = path[i]
		var mid := pass_through_mid(cell, to)
		var occupied: bool = not game.cells_at(to).is_empty()
		var legal: bool = _is_move_legal_now(cell, to) and not occupied
		var cost := 0
		var blocked := ""
		if occupied:
			## 规划器只规划**移动**：撞上谁就停在这儿。攻击要玩家自己点，
			## 免得「拖过去」把一次攻击悄悄塞进路线里
			blocked = "有细胞占据 —— 攻击请单独点它"
		elif not legal:
			blocked = move_block_reason(cell, to)
			if blocked == "":
				blocked = "走不到这一格"
		else:
			cost = _move_cost_mod(cell, to, _move_base_cost(cell, to))
			if budget < cost:
				blocked = "能量只剩 %s，这一步要 %s" % [CWData.fmt(budget), CWData.fmt(cost)]
		var afford: bool = legal and blocked == ""
		var step := { "to": to, "cost": cost, "mid": mid,
			"legal": legal, "afford": afford, "blocked": blocked, "gain": 0 }
		steps.append(step)
		if not afford:
			stop = i
			break
		budget -= cost
		total += cost
		## 走过去：位置动，脚下组织按【定殖】/【净化】翻面（enter_tile 里那两条，同样的条件）
		var t: Dictionary = game.tile(to)
		saved.append([to, _price_fields(t)])
		## 收核心：**在付完这一步之后**，和真流程一致（先 pay 再 enter_tile→collect_special）。
		## 所以这一步的 afford 判的是收钱**之前**的余额，下一步才花得到它。
		var gain := core_gain(t)
		if gain > 0:
			step["gain"] = gain
			gained += gain
			budget += gain
			t["store"] = 0        ## 取空：来回踩两趟不能收两次
		if cell["faction"] == CWData.Faction.CANCER:
			if t["tissue"] == CWData.Tissue.HEALTHY:
				CWTissue.to_cancer(t, true)
		elif t["tissue"] == CWData.Tissue.CANCER:
			CWTissue.to_healthy(t)
		cell["pos"] = to
	## 原样放回（逆序：同一格可能被走过两次）
	cell["pos"] = saved_pos
	for k in range(saved.size() - 1, -1, -1):
		var t2: Dictionary = game.tile(saved[k][0])
		for key: String in saved[k][1]:
			t2[key] = saved[k][1][key]
	return { "steps": steps, "total": total, "gained": gained,
		"ok": stop < 0, "left": budget, "stop": stop }


## 规划器预演时会动、算完要原样放回的组织字段。
## `store` 2026-09-08 加进来：预演踩核心要把它清零（不清就会重复收钱），
## 不存回去的话**光是把路拖过去看一眼，盘面上的核心就被吸干了**——纯查询的契约当场破。
## `cards` / `prod` / `mucus` 规划器仍不碰（骨髓抽卡不影响价钱也不影响余额），所以不必存。
func _price_fields(tile: Dictionary) -> Dictionary:
	return { "tissue": tile["tissue"], "solid": tile["solid"],
		"newborn": tile["newborn"], "necrosis": tile["necrosis"],
		"store": tile["store"] }


## 从 `from` 出发，这一步能落脚的格（规划器用：只要**空格**，攻击不进路线）。
## 规划器每接一格都问一次这个 —— 起点是路径当前的末端，不是细胞此刻的位置。
func plan_next_dests(cell: Dictionary, from: Vector2i) -> Array:
	var saved: Vector2i = cell["pos"]
	cell["pos"] = from
	var out: Array = []
	for n in move_dests(cell):
		if game.cells_at(n).is_empty() and _is_move_legal_now(cell, n):
			out.append(n)
	cell["pos"] = saved
	return out


# ---- 合法性谓词：选项生成与提交复验**共用同一份** ----
#
# 2026-08-31 队友审查发现 CWCost.commit() 只重新报价、不复验合法性，而注释却写着
# 「重新验证 → 重新报价」。取消打断窗口后这条路暂时走不到（pending 生成选项后
# 紧接着就 step 执行），但它是契约债：联机延迟、重复提交、快照回滚后复用旧选择、
# 异步询问期间盘面变化，任何一条都会把它变成真 bug。
#
# **两边必须复用同一个函数。** 各写一套的话，就又长出了「标价与收费对不上」那类问题。

## 点了一格却点不动 —— 为什么？返回空串 = 没什么好解释的
## （不相邻、是空地、能量不够…看一眼棋盘就明白）。
## 只解释**规则挡住**的那种：敌人就在旁边、也走得到，却偏偏点不动。
##
## 放引擎不放界面：这是规则，抄到界面里迟早和 _is_move_legal_now 漂移（架构约定 #10）。
func move_block_reason(cell: Dictionary, to: Vector2i) -> String:
	## 树突撞在癌细胞上：这是【I-各司其职】，不是攻击次数用尽，得单独说清楚
	if cell["faction"] == CWData.Faction.IMMUNE \
			and cell["itype"] == CWData.ImmuneType.DENDRITIC \
			and not game.cells_at(to, CWData.Faction.CANCER).is_empty():
		return "【各司其职】树突状细胞不能攻击、也不能移向癌细胞占据的组织"
	if _is_move_legal_now(cell, to):
		## 盘面上合法却不在选项里 —— 选项生成只多做一道检查：付不付得起。那就把账算给玩家看：
		## 要多少、含哪些修正、账上多少、付完至少留 0.1。
		## 2026-09-02 Kevin 反馈「有能量为什么不能走癌组织」：【基质阻隔】把 1.0 翻成 2.0，
		## 账上正好 2.0 付完剩 0 不合规，可界面一个字都不说，看起来就像 bug。
		var q: Dictionary = game.cost.quote(CWCost.context(cell, CWCost.Action.MOVE,
			_move_base_cost(cell, to), to))
		if q["affordable"]:
			return ""
		var mods: Array = q["applied"]
		var why: String = "" if mods.is_empty() else "（含【%s】）" % "】【".join(PackedStringArray(mods))
		return "这一步要 %s%s，账上 %s —— 付完至少要留 0.1" % [
			CWData.fmt(int(q["final"])), why, CWData.fmt(cell["energy"])]
	if not cell["alive"] or not (to in CWData.neighbors(cell["pos"])):
		return ""
	## 友军挡路：这条要说 —— 「不能停但可以穿过去」是新规则（口径 #98），
	## 玩家点了队友那格没反应时，最需要知道的正是「该点它正后方那一格」
	var here: Array = game.cells_at(to)
	if not here.is_empty() and here[0]["faction"] == cell["faction"]:
		return "同阵营不能停留在同一格，但可以穿过去 —— 点它正后方那一格"
	if cell["faction"] != CWData.Faction.IMMUNE:
		return ""
	if game.cells_at(to, CWData.Faction.CANCER).is_empty():
		return ""      ## 不是攻击，是普通迁移被占位挡了 —— 一眼看得出来
	var cap: int = game.tune.attack_max_per_turn
	if cap > 0 and cell["attacks_used"] >= cap:
		return "本行动回合的攻击次数已用尽（%d/%d）" % [cell["attacks_used"], cap]
	return ""


## 迁移/攻击到相邻格是否合法。不看能量（那是报价的事），只看盘面。
## 「穿过友军」：`to` 不与自己相邻，但**与某个贴身友军相邻** —— 也就是绕到队友身后那一圈
## （团队 2026-09-01 定案：「同阵营可以穿过，但是不能停留在这一格」，落点是队友周围一圈）。
## 返回充当跳板的那个友军格；不是这种走法就返回 `Vector2i.MAX`。
##
## 一个贴身友军实际开放的是**3 格**：它周围六格里，一格是我自己，两格本来就和我相邻
## （走普通迁移更便宜，这里主动让开，免得同一个落点出两个选项）。
##
## 其中**正后方那一格**尤其值：它与我**只有一个公共邻格**，就是队友那格 ——
## 队友堵在那儿时绕路要走 3 步，所以按两格收费仍然省一步。另外两格绕路也是 2 步，
## 收两格的钱等于持平，不会凭空变强。
##
## 多个友军都能通到同一格时取**最便宜的中间格**（同价按 neighbors 的固定顺序，保证可复现）。
##
## **落点必须是空格，不能穿过去打人**：那会把「移动」和「攻击」两条结算链缠在一起
## （攻击失败要弹回**哪一格**？弹回中间那格就是站在友军身上）。攻击照旧只能从相邻格发起。
## 「借道前进」的全部落点与价钱：{ 落点 → [总费用, 第一跳的友军格] }。
##
## **2026-09-04 下午 PRD 把这条推广了**：原文从「穿过**该细胞**所在的格」改成
## 「一次【迁移】可落在细胞**连通块**临近的任意一格，消耗为从连通块内**无视细胞通过**所需能量之和」——
## 也就是可以**顺着一串友军一路借道**，不再限于一个。旧实现只认单个友军（口径 #98），
## 相当于新规则里链长为 1 的特例。
##
## 算法：从自己出发，只在**友军占据的格**上扩展（它们是「连通块」），
## 每进一格按该格自己的组织类型计费；从任何一个到达过的友军格，
## 其相邻的**空格**都是合法落点，费用 = 走到那个友军格的累计 + 落点自己的费用。
## 取最便宜的一条（Dijkstra 的小规模版本：棋盘 127 格、友军最多 3 个，队列很短）。
##
## 本来就与自己相邻的格**不进这张表** —— 那是普通迁移，价钱更低，不该出两个同名选项。
func pass_through_map(cell: Dictionary) -> Dictionary:
	var out := {}                ## 落点 → [费用, 第一跳]
	var reached := {}            ## 友军格 → [累计费用, 第一跳]
	var queue: Array = []
	for n in CWData.neighbors(cell["pos"]):
		if not _is_ally_tile(cell, n):
			continue
		reached[n] = [_one_step_base(cell, n), n]
		queue.append(n)
	while not queue.is_empty():
		var cur: Vector2i = queue.pop_front()
		var acc: int = reached[cur][0]
		var first: Vector2i = reached[cur][1]
		for m in CWData.neighbors(cur):
			if m == cell["pos"] or not game.is_on_board(m):
				continue
			var cost: int = acc + _one_step_base(cell, m)
			if _is_ally_tile(cell, m):
				if not reached.has(m) or cost < reached[m][0]:
					reached[m] = [cost, first]
					queue.append(m)      ## 更便宜的路径要重新往外推一次
			elif game.cells_at(m).is_empty():
				if not out.has(m) or cost < out[m][0]:
					out[m] = [cost, first]
	for n in CWData.neighbors(cell["pos"]):
		out.erase(n)             ## 相邻格走普通迁移更便宜
	return out


func _is_ally_tile(cell: Dictionary, c: Vector2i) -> bool:
	var occ: Array = game.cells_at(c)
	return not occ.is_empty() and occ[0]["faction"] == cell["faction"]


## 借道落点的第一跳友军格（界面用它打「穿过」标签）；不是借道走法就返回 `Vector2i.MAX`。
func pass_through_mid(cell: Dictionary, to: Vector2i) -> Vector2i:
	if not game.is_on_board(to) or to == cell["pos"]:
		return Vector2i.MAX
	if to in CWData.neighbors(cell["pos"]):
		return Vector2i.MAX          ## 本来就走得到 —— 那是普通迁移，别在这儿重复出一遍
	var m: Dictionary = pass_through_map(cell)
	return m[to][1] if m.has(to) else Vector2i.MAX


## 一次【迁移】能去的所有格：六个相邻格 + 穿过友军落在正后方的那几格。
## 选项生成和 AI 都走这里，别各自拼一份（口径 #81）。
func move_dests(cell: Dictionary) -> Array[Vector2i]:
	var out: Array[Vector2i] = CWData.neighbors(cell["pos"]).duplicate()
	for far: Vector2i in pass_through_map(cell):
		out.append(far)
	return out


func _is_move_legal_now(cell: Dictionary, to: Vector2i) -> bool:
	if not cell["alive"] or not game.is_on_board(to):
		return false
	if not (to in CWData.neighbors(cell["pos"])):
		## 「穿过友军」落在正后方第二格。落点必须**完全空着** ——
		## 不能停在人身上，也不允许穿过去发起攻击（见 pass_through_mid 头注）
		if pass_through_mid(cell, to) == Vector2i.MAX:
			return false
		return game.cells_at(to).is_empty()
	if cell["faction"] == CWData.Faction.CANCER:
		return game.cells_at(to).is_empty()          ## 一格一细胞
	## 免疫：空格才谈得上「迁移」；有癌细胞则这一下是攻击
	var enemies: Array = game.cells_at(to, CWData.Faction.CANCER)
	if enemies.is_empty():
		return game.cells_at(to).is_empty()
	## 树突【I-各司其职】（2026-09-04 新 PRD）：**无法通过【迁移】攻击癌细胞，
	## 也无法向癌细胞占据的组织移动**。攻击在本作里就是「走进敌人那一格」，
	## 所以这一条落在移动合法性上就够，不必再在攻击结算里补一道。
	## 旧机制（树突攻击只造成 1/2 伤害）已从 CWDamage 撤掉。
	if cell["itype"] == CWData.ImmuneType.DENDRITIC:
		return false
	## 每回合攻击次数上限。放在**共用谓词**里而不是选项生成里 ——
	## 口径 #81 要求「选项生成与提交复验共用同一份谓词」，写两处必然漂移。
	## 用完次数后只是这一格不能进（攻击不可选），别的迁移照常。
	var cap: int = game.tune.attack_max_per_turn
	if cap > 0 and cell["attacks_used"] >= cap:
		return false
	return true


## 黑色素瘤【早期血行转移】：站在血管格上、本世界回合还没用过、落点是空的健康组织
func _is_homing_legal_now(cell: Dictionary, to: Vector2i) -> bool:
	if not cell["alive"] or cell["metastasis_used"]:
		return false
	if CWData.special_of(cell["pos"]) != CWData.Special.VESSEL:
		return false
	return game.tile(to)["tissue"] == CWData.Tissue.HEALTHY and game.cells_at(to).is_empty()


## 小细胞肺癌【转移】：落点在棋盘上且无细胞占据，且本世界回合还有次数（旋钮，默认不限）
func _is_jump_legal_now(cell: Dictionary, to: Vector2i) -> bool:
	return cell["alive"] and _jump_quota_left(cell) \
		and game.is_on_board(to) and game.cells_at(to).is_empty()


## 【转移】本世界回合还有没有次数：旋钮 metastasis_max_per_round（0 = 不限）。
## 计数 `cell["jump_used"]` 随 cells 进快照，S 阶段重置；旧存档没有这个键，按 0 读。
func _jump_quota_left(cell: Dictionary) -> bool:
	var cap: int = game.tune.metastasis_max_per_round
	return cap <= 0 or int(cell.get("jump_used", 0)) < cap


## T 细胞【裂解】：目标是**相邻**的固化癌组织（2026-09-01 起，此前是脚下那一格）
func _is_lyse_legal_now(cell: Dictionary, to: Vector2i) -> bool:
	return cell["alive"] and (to in CWData.neighbors(cell["pos"])) 		and game.tile(to)["tissue"] == CWData.Tissue.SOLID


func _lyse_targets(cell: Dictionary) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for n in CWData.neighbors(cell["pos"]):
		if game.tile(n)["tissue"] == CWData.Tissue.SOLID:
			out.append(n)
	return out


func _cancer_options(cell: Dictionary, opts: Array) -> void:
	for n in move_dests(cell):
		if not _is_move_legal_now(cell, n):
			continue          # 与提交时复验的是同一份谓词
		var cost := _move_cost_mod(cell, n, _move_base_cost(cell, n))
		if not game.can_pay(cell, cost):
			continue
		opts.append({
			"label": "%s→%s %s（%s 能量）" % [
				"穿过" if pass_through_mid(cell, n) != Vector2i.MAX else "移动",
				str(n), tissue_tag(n), CWData.fmt(cost)],
			"data": { "act": "move", "to": n, "cost": cost },
		})
	if _can_draw(cell) and game.can_pay(cell, CWData.CANCER_DRAW_COST):
		opts.append({ "label": "基因表达：抽卡（1.0 能量）", "data": { "act": "draw" } })
	if not cell["mutate_used"] and game.can_pay(cell, CWData.MUTATE_COST):
		opts.append({ "label": "突变（0.5 能量）", "data": { "act": "mutate" } })
	_type_options(cell, opts)


## 四种癌细胞各自的主动技能（PRD 癌细胞种类）。
## 被【中和抗体】压住时整段不出选项 —— 这是四个癌种主动技能的唯一入口，一道闸管全部。
func _type_options(cell: Dictionary, opts: Array) -> void:
	if not game.type_ability_on(cell):
		return
	match cell["ctype"]:
		CWData.CancerType.MELANOMA:
			# 【早期血行转移】：站在血管格上，每世界回合 1 次
			var homing_cost := skill_move_cost(cell, CWData.MELANOMA_HOMING_COST)
			if not cell["metastasis_used"] \
					and CWData.special_of(cell["pos"]) == CWData.Special.VESSEL \
					and game.can_pay(cell, homing_cost):
				for c in _homing_targets():
					opts.append({
						"label": "早期血行转移→%s（%s 能量）" % [str(c), CWData.fmt(homing_cost)],
						"data": { "act": "homing", "to": c },
					})
		CWData.CancerType.SIGNET:
			# 【黏液破裂】：耗尽全部能量并死亡，至少要有 2.0
			if cell["energy"] >= CWData.MUCUS_MIN_ENERGY:
				opts.append({ "label": "黏液破裂（耗尽能量并死亡）", "data": { "act": "mucus" } })
		CWData.CancerType.OSTEO:
			# 【骨样硬化】（2026-09-05 重做）：花 2.0 标记脚下，2 回合后固化。脚下得是没标过的普通癌组织
			var ossify_cost: int = game.tune.osteo_ossify_cost
			if _can_ossify(cell) and game.can_pay(cell, ossify_cost):
				opts.append({
					"label": "骨样硬化（%s 能量，第 %d 回合固化）" % [
						CWData.fmt(ossify_cost), game.round_no + game.tune.osteo_ossify_rounds],
					"data": { "act": "ossify" },
				})
		CWData.CancerType.SCLC:
			# 【转移】：向某方向跃进 5 格（费用与每世界回合上限都是旋钮，默认 = PRD：1.0、不限）
			var jump_cost := skill_move_cost(cell, game.tune.metastasis_cost)
			if game.can_pay(cell, jump_cost) and _jump_quota_left(cell):
				for c in _jump_targets(cell):
					opts.append({
						"label": "转移：跃进至 %s（%s 能量）" % [str(c), CWData.fmt(jump_cost)],
						"data": { "act": "jump", "to": c },
					})


## 能不能抽卡：只看每回合 3 次上限。
## 手牌上限**不再挡抽卡**（PRD 2026-09-01 改成「超过 8 张时弃置到 8 张」），
## 超限由 CWCards.discard_to_limit 在抽完之后追问。
func _can_draw(cell: Dictionary) -> bool:
	return cell["draws_used"] < CWData.DRAW_MAX_PER_TURN


## 四个单价都走 `game.tune`（默认值 = CWData 常量 = PRD），
## 因为「占地单价」是平衡的根因，要能不改引擎就扫。见 CWTuning「癌方移动费用」那段。
func _cancer_move_cost(cell: Dictionary, dest: Vector2i) -> int:
	if game.is_cancerous(dest):
		return game.tune.cancer_move_cancerous
	# 小细胞肺癌【极简胞浆】：移动至健康组织的消耗**永久**降为折后价（口径 #82 后是 0.7）
	if cell["ctype"] == CWData.CancerType.SCLC and game.type_ability_on(cell):
		return game.tune.sclc_move_healthy
	# 黑色素瘤【伪足穿透】：目标健康组织与 ≥3 格癌性组织相邻时走折后价（口径 #82 后是 0.5；门槛 2026-09-06 由 2 改 3）
	if cell["ctype"] == CWData.CancerType.MELANOMA and game.type_ability_on(cell) \
			and _cancerous_adj(dest) >= CWData.PSEUDOPOD_MIN_ADJ:
		return game.tune.pseudopod_cost
	return game.tune.cancer_move_healthy


func _cancerous_adj(c: Vector2i) -> int:
	var n := 0
	for m in CWData.neighbors(c):
		if game.is_cancerous(m):
			n += 1
	return n


## 移动费的**基准价**（设计 §四 的第②层）：行动本身 + 免疫等级 + 细胞自带技能
## （黑色素瘤【伪足穿透】、小细胞肺癌【极简胞浆】都在 _cancer_move_cost 里）。
## 基准价之上的所有修饰交给 CWCost —— 卡牌、永久技能、世界事件一律以
## CostModifier 的形式登记在 CWCost.TEMPLATES，本文件不再自己判谁减多少。
func _move_base_cost(cell: Dictionary, dest: Vector2i) -> int:
	if not (dest in CWData.neighbors(cell["pos"])):
		## 借道前进：**沿途每一格各按自己的组织类型计一次**，取最便宜的那条路
		## （新 PRD「消耗为从连通块内无视细胞通过所需能量之和」）。
		## 摆在这里而不是各调用方：行动菜单、AI 评估、界面价签、提交复验全走这一个口。
		var m: Dictionary = pass_through_map(cell)
		if m.has(dest):
			return m[dest][0]
	return _one_step_base(cell, dest)


func _one_step_base(cell: Dictionary, dest: Vector2i) -> int:
	if cell["faction"] == CWData.Faction.CANCER:
		return _cancer_move_cost(cell, dest)
	if game.is_cancerous(dest):
		return game.tune.immune_move_cancerous[game.immune_level]
	return game.tune.immune_move_healthy[game.immune_level]


## 移动到某格要多少钱（**纯查询**，不消耗任何额度）。行动菜单、AI 评估、界面价签都走这个。
## 2026-08-30 起转由 CWCost 计算：修饰按语义阶段排序，来源顺序只是同阶段的平局规则。
func _move_cost_mod(cell: Dictionary, dest: Vector2i, base: int) -> int:
	return game.cost.quote(CWCost.context(cell, CWCost.Action.MOVE, base, dest))["final"]


## 技能移动（小细胞肺癌【转移】、黑色素瘤【早期血行转移】）的报价。
## 它们不是【迁移】，但也不能和骨样硬化等非位移技能共用费用类别——
## 【基质阻隔】只翻倍“移动能量花费”，所以单列 SKILL_MOVE。
## **公开给界面用**：行动栏的价签必须和「能不能用」读同一个数。
## 2026-09-08 之前价签直接打常量，于是【基质阻隔】生效时按钮写着 1.0、
## 细胞有 6.9 能量却是灰的（Kevin 报的）——玩家只能理解成 bug。
func skill_move_cost(cell: Dictionary, base: int) -> int:
	return game.cost.quote(CWCost.context(cell, CWCost.Action.SKILL_MOVE, base))["final"]


## 某个行动此刻实际受到哪些费用特效影响。给悬浮详情用，返回
## [{ name, changes: ["0.5→1.0"], targets, total }]；全程只调 CWCost.quote()，不消耗额度。
## 迁移逐个合法目的地报价，因此【黏液侵染】这类目标相关效果会标出影响了几格。
func cost_effects_for(cell: Dictionary, act: String) -> Array:
	var quotes: Array = []
	if act == "move":
		for to in move_dests(cell):
			if _is_move_legal_now(cell, to):
				quotes.append(game.cost.quote(CWCost.context(cell, CWCost.Action.MOVE,
					_move_base_cost(cell, to), to)))
	else:
		var base := _cell_skill_base(act)
		if base >= 0:
			var action := CWCost.Action.SKILL_MOVE if act in ["homing", "jump"] \
				else CWCost.Action.CELL_SKILL
			quotes.append(game.cost.quote(CWCost.context(cell, action, base)))
	var by_name := {}
	for quote: Dictionary in quotes:
		var hit := {}
		for step: Dictionary in quote["breakdown"]:
			if step["before"] == step["after"] and step["note"] == "":
				continue
			var name: String = step["name"]
			if not by_name.has(name):
				by_name[name] = { "name": name, "changes": PackedStringArray(),
					"targets": 0, "total": quotes.size() }
			var change := "%s→%s" % [CWData.fmt(step["before"]), CWData.fmt(step["after"])]
			if change not in by_name[name]["changes"]:
				by_name[name]["changes"].append(change)
			hit[name] = true
		for name: String in hit:
			by_name[name]["targets"] += 1
	var out: Array = by_name.values()
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["name"] < b["name"])
	return out


## 只有真正经 CWCost.Action.CELL_SKILL 付款的技能才在这里登记；其余常量费用没有费用修饰。
func _cell_skill_base(act: String) -> int:
	match act:
		"homing":
			return CWData.MELANOMA_HOMING_COST
		"jump":
			return game.tune.metastasis_cost
		"ossify":
			return game.tune.osteo_ossify_cost
		"lyse":
			return CWData.LYSE_COST
	return -1

## 这个细胞**理论上**会用到哪些主动技能，按「细胞种类 + 免疫等级」列，
## **不看当前能量、位置、次数**。返回的是 act 串，顺序即按钮从左到右的顺序。
##
## 只给界面用：团队 2026-08-28 定「按钮不消失、只变暗」，
## 那就需要一份**稳定的按钮集合** —— 否则花掉能量会让按钮凭空少一个，
## 行动栏宽度跟着跳，连数字快捷键的编号都会变。
##
## **引擎和 AI 一律走 build_options()**，那里只列当前合法的行动。
## 这两份清单的差集，就是界面上该画成灰色的那些按钮。
func action_kinds(cell: Dictionary) -> Array[String]:
	var out: Array[String] = ["move", "draw"]
	if cell["faction"] == CWData.Faction.IMMUNE:
		## 分化只在 II 级及以上解锁（团队 2026-09-04 从 III 下调）、且每个细胞一辈子一次
		## —— 用掉之后按钮就不该再占位了
		if game.immune_level >= game.tune.differentiate_min_level and not cell["differentiated"]:
			out.append("differentiate")
		match cell["itype"]:
			CWData.ImmuneType.B_CELL:
				out.append("antibody")
			CWData.ImmuneType.T_CELL:
				out.append("toxin")
				out.append("lyse")
			CWData.ImmuneType.DENDRITIC:
				out.append("chemo")
		## 【效应应答】的按钮**只看种类和等级**（X 级解锁），不看效应记忆够不够 ——
		## 这是行动栏「宽度不会跳」的依据（同 action_kinds 里其余各条）。
		if cell["itype"] != CWData.ImmuneType.BASIC and game.immune_level >= 3:
			out.append("effector")
	else:
		out.append("mutate")
		match cell["ctype"]:
			CWData.CancerType.MELANOMA:
				out.append("homing")
			CWData.CancerType.SIGNET:
				out.append("mucus")
			CWData.CancerType.SCLC:
				out.append("jump")
			CWData.CancerType.OSTEO:
				out.append("ossify")
	return out


# ============ 执行 ============

func execute(cell: Dictionary, data: Dictionary) -> void:
	match data["act"]:
		"move":
			await _do_move(cell, data["to"], data["cost"])
		"draw":
			await _do_draw(cell)
		"chemo":
			await _do_chemo(cell)
		"effector":
			await _do_effector(cell)
		"differentiate":
			_do_differentiate(cell, data["type"])
		"antibody":
			await _do_antibody(cell)
		"toxin":
			_do_toxin(cell)
		"lyse":
			_do_lyse(cell, data["to"])
		"mutate":
			await _do_mutate(cell)
		"homing":
			await _do_homing(cell, data["to"])
		"mucus":
			_do_mucus(cell)
		"jump":
			await _do_jump(cell, data["to"])
		"ossify":
			_do_ossify(cell)
		"play":
			await game.card_fx.play(cell, data)
		"discard":
			_do_discard(cell, data["card"])


# ---- 移动 / 攻击 ----

## 骰面 → 基础判定。默认 1~2 失败 / 3~5 成功 / 6 大成功；
## 攻击者装备【免疫突触成熟】时改为 1/6 失败、1/2 成功、1/3 大成功
## （d6 落法：1 失败 / 2~4 成功 / 5~6 大成功）。
func base_verdict(r: int, attacker: Dictionary = {}) -> String:
	if not attacker.is_empty() and game.has_skill(attacker, "免疫突触成熟"):
		return "crit" if r >= 5 else ("fail" if r == 1 else "success")
	return "crit" if r == 6 else ("fail" if r <= 2 else "success")


## 基础判定再套世界事件修正（并给，不重掷）——
## 【细胞毒】失败并给成功（PRD：5/6 成功、1/6 大成功）；
## 【免疫伪装】大成功并给成功（PRD：1/3 失败、2/3 成功；2026-08-29 按 PRD 改判）
func attack_outcome(r: int, attacker: Dictionary = {}) -> String:
	var out := base_verdict(r, attacker)
	if out == "fail" and game.event_stacks("抗原引导") > 0:
		out = "success"
	if out == "crit" and game.event_stacks("免疫伪装") > 0:
		out = "success"
	return out


## base = 报价的起点。默认 -1 表示「现算」（_move_base_cost）——
## 只有【炎症性趋化】那种自带基准价（每步 0.2）的调用点需要显式传进来。
##
## cost 是**调用方看到的旧价钱**，只用来核对；真正扣多少以 commit() 当场重算为准
## （设计 §七.2「不把旧价格当权威」）。两者不一致说明选项建好之后局面变了，
## 喊一声，别静默按另一个价钱扣费。
func _do_move(cell: Dictionary, to: Vector2i, cost: int, base: int = -1) -> void:
	var ctx := CWCost.context(cell, CWCost.Action.MOVE,
		base if base >= 0 else _move_base_cost(cell, to), to, 0,
		func() -> bool: return _is_move_legal_now(cell, to))
	var q := game.cost.commit(ctx)
	if q.is_empty():
		return          ## 不合法或付不起——能量、修饰、闸门一概没动
	if int(q["final"]) != cost:
		game.log_msg("! 移动费标价 %s 与兑现 %s 不一致（局面已变）" % [
			CWData.fmt(cost), CWData.fmt(int(q["final"]))])
	if cell["faction"] == CWData.Faction.CANCER:
		var was_healthy: bool = game.tile(to)["tissue"] == CWData.Tissue.HEALTHY
		await enter_tile(cell, to, int(q["final"]))
		## 【RAS持续激活】每行动回合第一次通过【移动】触发【定殖】→ 恢复（分期）。
		## 只认移动——enter_tile 也服务传送/复活，所以钩在这里而不是那里
		if was_healthy and game.has_skill(cell, "RAS持续激活") \
				and game.first_this_turn(cell, "RAS持续激活"):
			var ras: int = CWData.RAS_HEAL[CWCardData.cancer_phase(game.round_no)]
			cell["energy"] += ras
			game.log_msg("　【RAS持续激活】首次定殖：恢复 %s 能量（现 %s）" % [
				CWData.fmt(ras), CWData.fmt(cell["energy"])])
		return
	# 免疫迁移：目标格有癌细胞 → 触发攻击。一格一细胞，所以最多只有一个。
	var enemies: Array = game.cells_at(to, CWData.Faction.CANCER)
	if enemies.is_empty():
		await enter_tile(cell, to, int(q["final"]))
		return
	var target: Dictionary = enemies[0]
	## 计数在**发动**时加，不看判定结果 —— 与口径 #70「攻击发动即算攻过」一致：
	## 失败被反弹也占一次，否则上限就成了「成功次数上限」，失败反而不受约束。
	cell["attacks_used"] += 1
	## 把「还剩几次」说出来。上限用完之后，攻击选项会直接从行动栏消失 ——
	## 不报一声的话，玩家看到的就是「这一格刚才还能打，现在点不了了」，
	## 和 2026-08-31 癌方复活那次是同一类问题（口径 #93）。
	## 报在**用掉的这一刻**而不是事后解释：这一刻天然只发生一次，
	## 不必往 fx_turn（规则状态，进 state_hash）里塞一个界面用的标记。
	var cap: int = game.tune.attack_max_per_turn
	if cap > 0:
		var used: int = cell["attacks_used"]
		if used >= cap:
			game.log_msg("　【攻击】%s 本行动回合的攻击次数已用尽（%d/%d）"
				% [game.cell_name(cell), used, cap])
			game.announce("攻击次数已用尽（%d/%d）" % [used, cap], to, true)
		else:
			game.log_msg("　【攻击】第 %d/%d 次" % [used, cap])
	## ---- 判定链（定案 #59/#60）----
	## 骰面 → 世界事件并给（attack_outcome）→【补体调理】失败自动重掷（重掷严格不劣，
	## 不必发问）→ 防御方【PD-L1表达】最后压一级。【高亲和力克隆】不掷骰直接大成功，
	## 管骰面概率的世界事件因此不介入，但 PD-L1 照压（它压的是「判定」不是骰面）。
	## 补体调理/高亲和力克隆骑在「下一次攻击」上：无论结果如何，这次攻击就把它们消耗掉。
	var opsonin := game.spend_mods(cell, "补体调理")
	var affinity := game.spend_mods(cell, "高亲和力克隆")
	var was_marked: bool = target["marked"]   ## 【抗原呈递强化】要知道攻击前的标记状态
	## 【抗体亲和力成熟】攻击「与健康组织相邻」的癌细胞 +0.5。
	## 2026-09-07 卡面删掉了「每个行动回合第一次」这半句 → 变成**每次**都加，闸门随之取消。
	var matured := 0
	if game.has_skill(cell, "抗体亲和力成熟") and _adjacent_healthy(to):
		matured = CWData.MATURED_ATTACK_EXTRA
	var outcome: String
	var r := 0
	if affinity > 0:
		outcome = "crit"
		game.log_msg("　【高亲和力克隆】不进行随机判定，直接视为大成功")
	else:
		r = await game.roll_shown(6, "攻击", cell["pid"], to)
		outcome = _judged(r, cell)
		var rerolls := opsonin
		while outcome == "fail" and rerolls > 0:
			rerolls -= 1
			game.log_msg("　【补体调理】攻击失败：重新判定一次，以第二次结果为准")
			r = await game.roll_shown(6, "攻击", cell["pid"], to)
			outcome = _judged(r, cell)
	## 【PD-L1表达】**一次攻击只消耗一层**，多层时消耗**最早打出**的那层（团队 2026-09-01 裁定）。
	## 刻意不走定案 #57 的「同名一次全算」：那样两张会被同一次攻击一起吃掉，
	## 判定掉到「失败」之后再降也没有意义，第二张等于白扔。
	## 判定已经是失败时**照样消耗** —— 这是团队明确要的，所以也不加减伤那套 ON_BENEFIT。
	if game.spend_one_mod(target, "PD-L1表达"):
		var was := outcome
		outcome = _downgrade(outcome)
		var left: int = game.mods_of(target, "PD-L1表达").size()
		game.log_msg("　【PD-L1表达】判定下降一级（%s → %s）%s" % [
			VERDICT_NAMES[was], VERDICT_NAMES[outcome],
			"，还剩 %d 层" % left if left > 0 else ""])
	if outcome == "fail":
		game.log_msg("　攻击失败，%s 被反弹回原格" % game.cell_name(cell))
		game.announce("攻击失败", to)
		## 【抗原变异】攻击失败 → 被攻击的癌细胞抽牌（按层数）
		for i in game.event_stacks("抗原变异"):
			await game.cards.draw(target, "抗原变异")
		## PRD：攻击失败时攻击者「自身-0.5能量」（口径 #84）。走 cancer_hit 而不是直接扣，
		## 是为了让它和别的损失一样吃减伤/护盾/死亡检查——注意按口径 #62，
		## 反弹**不算**「癌细胞技能造成的损失」，【缺氧适应】挡不住它。
		if game.tune.counter_dmg_on_fail > 0:
			game.cancer_hit(cell, game.tune.counter_dmg_on_fail, "反弹")
			if not cell["alive"]:
				return
	else:
		var crit := outcome == "crit"
		var dmg: int = game.tune.attack_dmg_crit if crit else game.tune.attack_dmg_success
		game.announce("攻击%s" % ("大成功" if crit else "成功"), to)
		## 「攻击成功后」的修饰/技能在此消耗（定案 #58：含大成功）。
		## 额外伤害走管线第②步「固定数值增加」——被【标记】翻倍是管线顺序使然。
		var extra := CWData.OPSONIN_EXTRA * opsonin + CWData.AFFINITY_EXTRA * affinity + matured
		var perf := game.spend_mods(cell, "穿孔素-颗粒酶")
		if perf > 0:
			var per: int = CWData.PERFORIN_EXTRA_T if cell["itype"] == CWData.ImmuneType.T_CELL \
				else CWData.PERFORIN_EXTRA
			extra += per * perf
		## 【细胞毒性增强】非 T：每行动回合首次攻击成功 +1.0（进管线的②固定增加）；
		## T 细胞：每次成功 +1.0 且「不受减伤效果影响」（口径 #67）——按设计 §6.4
		## 做成**关联到主攻击的次级伤害事件**，带 UNPREVENTABLE：
		## 它跳过数值减免，但**不**跳过日志、实际伤害统计、BCL-2 与死亡检查。
		var cytotox_direct := 0
		if game.has_skill(cell, "细胞毒性增强"):
			if cell["itype"] == CWData.ImmuneType.T_CELL:
				cytotox_direct = CWData.CYTOTOX_EXTRA
			elif game.first_this_turn(cell, "细胞毒性增强"):
				extra += CWData.CYTOTOX_EXTRA
		## 【连续吞噬】连了几格，「下一次攻击」就多几个 0.5 —— 用掉即清，不按回合过期
		var chain: int = int(cell.get("chain_bonus", 0))
		if chain > 0:
			extra += chain
			cell["chain_bonus"] = 0
			game.log_msg("　【连续吞噬】连续净化的加成：本次攻击额外 +%s" % CWData.fmt(chain))
		if extra > 0:
			game.log_msg("　攻击类修饰：额外造成 %s 能量损失" % CWData.fmt(extra))
		## 「整体免疫掉一次伤害」的判定住在管线的「替代/免疫」层（设计 §5.2），这里不再自己拦：
		## 被整体免疫的事件视为未造成伤害，护盾、标记与斩杀都不会被骗掉
		## 主攻击与它的次级伤害**必须同批**（2026-08-31 队友审查问题 2 的第四条语义）：
		## 拆开的话主伤害先结算死亡、【BCL-2抗凋亡】先把能量拉回分期值，
		## 次级伤害再补一刀 —— 反而可能绕过 BCL-2 把人打死。
		var group := game.damage.next_group()
		var events: Array = [game.damage.event(cell, target, dmg, CWDamage.Kind.ATTACK,
			[CWDamage.Tag.IMMUNE, CWDamage.Tag.ATTACK], "攻击", extra, group)]
		if cytotox_direct > 0:
			events.append(game.damage.event(cell, target, cytotox_direct,
				CWDamage.Kind.ATTACK,
				[CWDamage.Tag.IMMUNE, CWDamage.Tag.ATTACK, CWDamage.Tag.DIRECT,
					CWDamage.Tag.UNPREVENTABLE, CWDamage.Tag.NO_LIFESTEAL],
				"细胞毒性增强", 0, group))
		## 【吞噬体成熟】的伤害后斩杀、巨噬【吞噬】的吸血都在 CWDamage 的伤后触发
		## 队列里（设计 §5.7）——2026-08-31 从这里挪走：死亡只该在死亡阶段发生，
		## 在攻击流程里另起一刀等于绕开那条约定
		var hits: Array = game.damage.submit(events)
		## PRD【迁移】：「累积与造成伤害的绝对值向下取整的抗原记忆」（Kevin 2026-09-07 定的措辞）。
		## 引擎此前**整条没实现**（只有【净化】给记忆）。按实际造成的伤害算，不是尝试值：
		## 被整体免疫掉、被减伤扣没了的部分不该换记忆。次级伤害（细胞毒性增强）同批计入。
		var dealt := 0
		for h in hits:
			dealt += int(h["actual"])
		if dealt >= 10:
			game.gain_memory(dealt / 10)   ## 十分能量的整数除法 = 向下取整
			game.log_msg("　【攻击】造成 %s 能量损失，+%d 抗原记忆（%d）"
				% [CWData.fmt(dealt), dealt / 10, game.memory])
		## 【补体级联】的组织转化不是能量损失，「整体免疫」那一层拦不住它
		for i in game.spend_mods(cell, "补体级联"):
			_cascade(target)
		## 【抗原变异】攻击大成功 → 攻击方抽牌（按层数）
		if crit:
			for i in game.event_stacks("抗原变异"):
				await game.cards.draw(cell, "抗原变异")
	## 【抗原呈递强化】每世界回合第一次攻击未被【标记】的癌细胞后 → 施加【标记】。
	## 「攻击…后」按**攻击发动**读（口径 #70）：判定失败算攻过，把目标当场打死也算攻过，
	## 所以额度在这里就烧掉。**alive 判断刻意放在闸门之后**（团队 2026-08-30 定案 C）——
	## 写成两层是为了让「打死了也扣额度」是个自觉的选择，而不是 and 求值顺序的副产品。
	if game.has_skill(cell, "抗原呈递强化") and not was_marked \
			and game.first_this_round(cell, "抗原呈递强化"):
		if target["alive"]:
			game.apply_mark(target, cell)
			game.log_msg("　【抗原呈递强化】为 %s 施加【标记】" % game.cell_name(target))
		else:
			## 不出这一句的话，玩家看不出本世界回合的施加额度已经没了
			game.log_msg("　【抗原呈递强化】目标已死亡，本世界回合的施加额度就此用掉")
	# 目标格已无存活癌细胞才进入（击杀进格；否则返回原格）
	if game.cells_at(to, CWData.Faction.CANCER).is_empty():
		await enter_tile(cell, to, int(q["final"]))
	else:
		game.log_msg("　%s 返回原格" % game.cell_name(cell))


const VERDICT_NAMES := { "fail": "失败", "success": "成功", "crit": "大成功" }


## 骰面 → 判定，顺带把世界事件的并给记进日志（重掷时会再走一遍）
func _judged(r: int, attacker: Dictionary) -> String:
	var base := base_verdict(r, attacker)
	var out := attack_outcome(r, attacker)
	if base == "fail" and out != "fail":
		game.log_msg("　【细胞毒】攻击不会失败：判定并给成功")
	elif base == "crit" and out != "crit":
		game.log_msg("　【免疫伪装】攻击不会大成功：判定并给成功")
	game.log_msg("　攻击掷骰 %d：%s" % [r, VERDICT_NAMES[out]])
	return out


## 【PD-L1表达】：大成功→成功、成功→失败、失败不变
func _downgrade(v: String) -> String:
	match v:
		"crit":
			return "success"
		"success":
			return "fail"
	return "fail"


## 【补体级联】攻击成功后：目标癌细胞相邻的普通癌组织里，随机最多 2 格无细胞占据 → 健康
func _cascade(target: Dictionary) -> void:
	var cands: Array[Vector2i] = []
	for n in CWData.neighbors(target["pos"]):
		if game.tile(n)["tissue"] == CWData.Tissue.CANCER and game.cells_at(n).is_empty():
			cands.append(n)
	var picked: Array = game.pick_random(cands, CWData.CASCADE_MAX_TILES)
	if picked.is_empty():
		game.log_msg("　【补体级联】目标相邻无可转化的癌组织，落空")
		return
	for c in picked:
		CWTissue.to_healthy(game.tile(c))
		game.log_msg("　【补体级联】%s 转为健康组织" % str(c))


## 进入一格的统一结算：癌细胞【定殖】、免疫【净化】、特殊组织收取、黏液清除、标记刷新。
## 是协程：踩上骨髓可能抽到要中途选择的事件卡（await 链见 cw_card_fx 头注），
## 所有调用点都要 await —— 漏了 await 的那条链会脱离结算顺序，复现测试会当场炸。
## paid = 这一步实际支付的能量；**-1 = 不是花钱走进来的**（传送 / 复活 / 血管 / 卡牌位移），
## 那种情况不设巨噬回能的上限。
func enter_tile(cell: Dictionary, dest: Vector2i, paid: int = -1) -> void:
	var from: Vector2i = cell["pos"]   ## 来路：【定殖】过场要说「癌从哪一侧进来」
	cell["pos"] = dest
	var t: Dictionary = game.tile(dest)
	## 挪了窝，上一格的「蹲守」就作废（还站在同一格的话下面会重新登记）
	if cell["faction"] == CWData.Faction.IMMUNE and int(cell.get("camp_round", -1)) >= 0 \
			and cell["camp_pos"] != dest:
		cell["camp_round"] = -1
	if cell["faction"] == CWData.Faction.CANCER and t["tissue"] == CWData.Tissue.HEALTHY:
		CWTissue.to_cancer(t, true)
		## 一步一步铺过去会刷一屏，连续的合并成一条（Kevin 2026-09-07）
		game.log_run("定殖:%d" % cell["pid"], str(dest), "　【定殖】", " 转为癌组织")
		## 过场与【侵蚀】【增生】同一套（癌吞掉一格健康组织、从哪一侧来）。方向 = **这一步的前进方向**（Kevin 2026-09-06）：
		## 癌从来路那一侧漫入、朝细胞前进的方向推进——相邻移动就是来路那一侧，跃进 / 传送落地取最接近来路的一侧；
		## 原地不动（复活、紊乱返回）没有前进方向，不演（-1）
		game.erosion_fx(dest, CWData.dir_toward(dest, from))
	elif cell["faction"] == CWData.Faction.IMMUNE and t["tissue"] == CWData.Tissue.CANCER \
			and int(t.get("ossify_at", 0)) > 0:
		## 骨肉瘤【骨样硬化】标记过的格：进来不能立刻净化，得停留一个世界回合
		## （下一回合 S 阶段由 CWWorld._resolve_camping 兑现；标记到期在 E 阶段末，晚它半轮）
		cell["camp_round"] = game.round_no
		cell["camp_pos"] = dest
		game.log_msg("　【骨样硬化】%s 正在硬化，%s 须在此停留一回合才能【净化】" % [
			str(dest), game.cell_name(cell)])
	elif cell["faction"] == CWData.Faction.IMMUNE and t["tissue"] == CWData.Tissue.CANCER:
		await purify_here(cell, dest, paid)
	# 「粘液」无法被技能清除，但被免疫细胞接触后立即消失（PRD 印戒细胞癌）
	if cell["faction"] == CWData.Faction.IMMUNE and t["mucus"]:
		t["mucus"] = false
		game.log_msg("　【黏液】%s 的黏液被免疫细胞清除" % str(dest))
	await collect_special(cell, dest)
	game.update_marks()


## 【I-净化】本体：转健康、记忆、巨噬回能、永久技能连锁。
## enter_tile 的正常进入和 _resolve_camping 的「蹲满一回合」两处共用 —— 口径只有这一份。
func purify_here(cell: Dictionary, dest: Vector2i, paid: int) -> void:
	var t: Dictionary = game.tile(dest)
	CWTissue.to_healthy(t)
	## 连续净化合并成一条（Kevin 2026-09-07）。三种情形各自成一串：尾巴不一样，混在一起会看不懂；
	## 正常那串的尾巴每次用最新的累计记忆数，正是想看的那个
	var run := "净化:%d" % cell["pid"]
	if not game.purify_gives_memory():
		## 卡牌连锁出来的净化（抽到的卡、打出的即时卡）不积累抗原记忆（Kevin 2026-09-07）
		game.log_run(run + ":卡牌", str(dest), "　【净化】", " 转为健康组织（卡牌造成：不获得抗原记忆）")
	else:
		game.gain_memory(1)
		game.log_run(run, str(dest), "　【净化】", " 转为健康组织（抗原记忆 %d）" % game.memory)
	if cell["itype"] == CWData.ImmuneType.MACRO:
		## 【I-吞噬】每次净化回 0.3 —— **但回的不能比这一步付的多**。
		## 迁移减免的共同地板是 0.2（各卡面都写「最低 0.2」），等级 X 走癌性组织
		## 本身也只要 0.2，回 0.3 就成了「走一格赚 0.1」：巨噬能在癌组织上无限走、
		## 顺手把整片净化掉（队友 2026-09-01 报的「巨噬细胞可以无穷动」）。
		## 治的是「靠移动赚钱」这个结构问题，而不是把某张减价卡调残。
		## 回多少走旋钮 `macro_heal_purify`（默认 = 常量 0.3；0 = 净化不回能，2026-09-02 后期引擎对比表扫它）。
		## **只有【迁移】触发的净化才回能**（PRD 2026-09-08 云端修订版写明「每通过【迁移】
		## 触发一次【净化】」）。传送 / 复活 / 血管 / 卡牌位移 / 蹲守净化都是 paid = -1，一律不回 ——
		## 这两个边界原来正好是**反的**：paid = -1 回满、免费迁移（paid = 0）反被封顶压成 0。
		##
		## 免费迁移回满 0.3 不会重演「无穷动」：那条封顶针对的是**付费**迁移 ——
		## 减免的共同地板是 0.2，回 0.3 就成了走一格赚 0.1，能一直走下去；
		## 而免费迁移的次数由给它的那个效果自己限着，走不了几步。
		var heal: int = game.tune.macro_heal_purify
		if paid < 0:
			heal = 0
		elif paid > 0:
			heal = mini(heal, maxi(paid - CWData.MACRO_MOVE_NET_MIN, 0))
		if heal > 0:
			cell["energy"] += heal
			game.log_msg("　巨噬【吞噬】恢复 %s 能量%s" % [CWData.fmt(heal),
				"（本次迁移实付 %s，净支出至少 %s）" % [
					CWData.fmt(paid), CWData.fmt(CWData.MACRO_MOVE_NET_MIN)]
					if heal < game.tune.macro_heal_purify else ""])
	await _on_purify(cell)
	## 巨噬【效应应答·连续吞噬】：本行动回合第一次【净化】之后接上连锁（见 _chain_phagocytosis）
	if cell["itype"] == CWData.ImmuneType.MACRO and int(cell.get("chain_left", 0)) > 0 \
			and not cell.get("chain_running", false):
		await _chain_phagocytosis(cell)


## 收取特殊组织存储（进入时 & 产出瞬间站于其上时调用）
## 踩上这一格能从【代谢核心】拿到多少能量（0 = 拿不到：不是核心、或者已经被取空）。
##
## 抽出来是因为**要有两个调用方**：`collect_special()` 真收，`quote_path()` 预演。
## 规划器抄第二份必然漂 —— 【代谢加速】那个翻倍是世界事件给的，忘了跟就会少算一半。
## 同 `CWWorld.pressure_at` 的纪律：一条算式只留一份。
func core_gain(t: Dictionary) -> int:
	if t["special"] != CWData.Special.CORE or t["store"] <= 0:
		return 0
	var gain: int = t["store"]
	for i in game.event_stacks("代谢加速"):
		gain *= 2   ## 【代谢加速】进入代谢核心获得的能量翻倍
	return gain


func collect_special(cell: Dictionary, c: Vector2i) -> void:
	var t: Dictionary = game.tile(c)
	var gain := core_gain(t)
	if gain > 0:
		cell["energy"] += gain
		game.log_msg("　%s 从代谢核心获取 %s 能量" % [game.cell_name(cell), CWData.fmt(gain)])
		t["store"] = 0
	elif t["special"] == CWData.Special.MARROW and t["cards"] > 0:
		## 手牌满也照发（PRD 2026-09-01：超限改成抽完再弃），
		## 所以「卡留在骨髓里下次再拿」那条随之取消
		t["cards"] = 0
		await game.cards.draw(cell, "骨髓")


# ---- 通用技能 ----

## 【基因表达】：每个行动回合最多 3 次（PRD 主动技能）
func _do_draw(cell: Dictionary) -> void:
	var cost: int = CWData.IMMUNE_DRAW_COST if cell["faction"] == CWData.Faction.IMMUNE \
		else CWData.CANCER_DRAW_COST
	if game.pay(cell, cost):
		cell["draws_used"] += 1
		await game.cards.draw(cell, "基因表达")


## 手牌可随时弃置（PRD 卡牌规则 3）。手牌满想抽新卡时先弃再抽（团队 2026-08-28 定）。
func _discard_options(cell: Dictionary, opts: Array) -> void:
	for card in cell["hand"]:
		opts.append({ "label": "弃置【%s】" % card, "data": { "act": "discard", "card": card } })


func _do_discard(cell: Dictionary, card: String) -> void:
	if card in cell["hand"]:
		cell["hand"].erase(card)
		game.log_msg("%s 弃置【%s】（手牌余 %d）" % [
			game.cell_name(cell), card, cell["hand"].size()])


# ---- 免疫技能 ----

## 树突【I-趋化源】：问落点（全局任意一格）→ 付 2.0 → 场上立一个，持续 2 回合。
##
## 落点**不限组织类型、也不限有没有人站着** —— PRD 只说「全局任意位置」。
## 建立本身不是移动：不触发【定殖】/【净化】、不占迁移次数。
## 走普通 `Action.CELL_SKILL` 报价；它不是位移，不能吃【基质阻隔】的移动费翻倍。
func _do_chemo(cell: Dictionary) -> void:
	if not game.chemo.is_empty():
		return                      ## 同一时刻仅一个；选项那边也拦，这里是提交前复验
	var spots: Array = []
	for c: Vector2i in game.tiles:
		spots.append({ "label": "趋化源→%s" % str(c), "data": { "to": c } })
	var pick: int = await game.ask(cell["pid"], {
		"kind": "chemo_target",
		"prompt": "选择趋化源的位置（全局任意一格）", "options": spots,
	})
	var at: Vector2i = spots[pick]["data"]["to"]
	if game.cost.commit(CWCost.context(cell, CWCost.Action.CELL_SKILL,
			CWData.CHEMO_COST, at, 0,
			func() -> bool: return game.chemo.is_empty())).is_empty():
		return
	game.chemo = { "at": at, "left": CWData.CHEMO_ROUNDS, "by": cell["pid"] }
	game.log_msg("【趋化源】%s 在 %s 建立趋化源（持续 %d 回合：免疫朝它 -%d%%、癌方背它 +%d%%）" % [
		game.cell_name(cell), str(at), CWData.CHEMO_ROUNDS,
		100 - CWData.CHEMO_IMMUNE_PCT, CWData.CHEMO_CANCER_PCT - 100])
	game.announce("趋化源", at, true)


func _diff_choices() -> Array:
	var out: Array = []
	for t in [CWData.ImmuneType.B_CELL, CWData.ImmuneType.T_CELL,
			CWData.ImmuneType.MACRO, CWData.ImmuneType.DENDRITIC]:
		if t not in game.differentiated:  # 每种细胞全阵营仅能有一个
			out.append(t)
	return out


func _do_differentiate(cell: Dictionary, t: int) -> void:
	cell["itype"] = t
	cell["differentiated"] = true
	game.differentiated.append(t)
	game.log_msg("【分化】%s 分化为 %s" % [game.player(cell["pid"])["name"], CWData.IMMUNE_TYPE_NAMES[t]])
	game.update_marks()  # 分化出树突 → 立即标记相邻癌细胞


## 【抗体】本世界回合还有没有额度。旋钮 `antibody_max_per_round` 0 = 不限，是现行 PRD
## （2026-09-01 删掉了「每世界回合最多 2 次」）；上限留成旋钮是 2026-09-02 后期引擎对比表要扫它。
## 计数 `antibody_used` 与 `toxin_used` 同一处重置（CWWorld._reset_round_flags），随 cells 进快照。
func _antibody_quota_left(cell: Dictionary) -> bool:
	var cap: int = game.tune.antibody_max_per_round
	return cap <= 0 or cell["antibody_used"] < cap


## 落点是什么组织，直接写进选项标签。
##
## **为什么。** 2026-09-05 的智能体对局里，好几个席位报告说 13×13 的 ASCII 棋盘
## 「双字符 token 和单字符混排容易错位」，干脆放弃逐格核对、只信细胞列表的坐标；
## 还有一位把「花费 1.0」误读成「这一步净化了癌格」（其实是两段 0.5 的健康格移动）。
## 「这一步落到什么组织上」是移动决策里最要紧的一条信息，让人从网格里数出来是自找麻烦 ——
## 标签里多五个字，比把棋盘画得再漂亮都管用。真 UI 那边有格子详情框，不需要这个。
func tissue_tag(c: Vector2i) -> String:
	match int(game.tile(c)["tissue"]):
		CWData.Tissue.HEALTHY:
			return "健康"
		CWData.Tissue.SOLID:
			return "固化"
		_:
			return "癌"


## 【抗体】这一次实际打多少。**同一世界回合内每多放一次就减半**（团队 2026-09-04 定）：
## 第 1 次 1.5、第 2 次 0.7、第 3 次 0.3、第 4 次 0.1、之后 0。
##
## **为什么要有这条**：2026-09-05 的智能体对局里，一个 B 细胞单回合连放 8 次
## 把骨肉瘤从 14.7 打到 2.7 —— 抗体是免疫方唯一「不掷骰、不限次、无射程」的输出，
## 而同阵营其他手段（普通攻击 3 次且 1/3 会失败、【细胞毒素】3 次、基因表达 3 次）全都写了限次。
## 递减比硬性次数上限温和：第一次的强度一点没动，只是不能刷。
##
## 取整向下（十分能量的整数除法），所以会自然衰减到 0 而不是永远留个尾巴。
## 旋钮 `antibody_halve` 关掉就是 2026-09-01~09-04 那版「每次都打满」的老行为，用来做对照局。
func antibody_damage(cell: Dictionary) -> int:
	var dmg: int = CWData.MATURED_ANTIBODY_DMG if game.has_skill(cell, "抗体亲和力成熟") \
		else CWData.ANTIBODY_DAMAGE
	if not game.tune.antibody_halve:
		return dmg
	for _i in int(cell["antibody_used"]):
		dmg /= 2
	return dmg


## 【抗体亲和力成熟】B 细胞强化：抗体费**降低** 0.5（卡面 2026-09-07 从「降低为 0.5」改成「降低 0.5」，
## 基础费 1.0 时两种读法同值，但基础费一旦变动，减量才是卡面说的那件事）
func antibody_cost(cell: Dictionary) -> int:
	if not game.has_skill(cell, "抗体亲和力成熟"):
		return CWData.ANTIBODY_COST
	return maxi(CWData.ANTIBODY_COST - CWData.MATURED_ANTIBODY_CUT, 0)


func _do_antibody(cell: Dictionary) -> void:
	if not game.pay(cell, antibody_cost(cell)):
		return
	## 顺序要紧：先按**本次之前**的使用次数算伤害，再累加计数
	var dmg := antibody_damage(cell)
	cell["antibody_used"] += 1
	var targets: Array = []
	for c in game.living_cells(CWData.Faction.CANCER):
		for n in CWData.neighbors(c["pos"]):
			if game.tile(n)["tissue"] == CWData.Tissue.HEALTHY:
				targets.append(c)
				break
	if not targets.is_empty():
		game.log_msg("【抗体】命中 %d 个与健康组织邻接的癌细胞" % targets.size())
		## 多目标同时结算（设计 §5.5）。attack=false：抗体是「技能」不是普通攻击——
		## 树突/巨噬那两条挂不上（B 细胞专属，本就挂不上），
		## 而【DNA损伤修复】明写挡「技能」，要挡得到它
		game.immune_hit_area(targets, dmg, cell, "抗体")
		return
	# 无目标 → 随机将与健康组织相邻的 X 格癌组织转为健康（2/3→1，1/3→2）
	var eligible: Array[Vector2i] = []
	for c in game.tiles.keys():
		if game.tiles[c]["tissue"] != CWData.Tissue.CANCER:
			continue
		if not game.cells_at(c, CWData.Faction.CANCER).is_empty():
			continue  # 说明 #20：不转化有癌细胞停留的格
		for n in CWData.neighbors(c):
			if game.tile(n)["tissue"] == CWData.Tissue.HEALTHY:
				eligible.append(c)
				break
	if eligible.is_empty():
		game.log_msg("【抗体】无目标且无可转化癌组织，效果落空")
		return
	var roll: int = await game.roll_shown(3, "抗体", cell["pid"], cell["pos"])
	var x: int = CWData.ANTIBODY_NO_TARGET_X[0 if roll <= 2 else 1]
	game.announce("抗体：转化 %d 格" % x, cell["pos"])
	for c in game.pick_random(eligible, x):
		CWTissue.to_healthy(game.tile(c))
		game.log_msg("【抗体】无目标 → %s 转为健康组织" % str(c))


## **1 环 = 含自己脚下那格**（PRD 2026-09-08 换的术语，Kevin 同日确认「是的」）。
## 原来是 `neighbors()`，不含中心。免疫细胞**确实可能站在癌组织上**——
## 骨样硬化标记过的格要蹲一回合才净化、传送/卡牌位移进来的也没净化，
## 所以这一格的有无是真的会差一格结果，不是纸面差别。
func _toxin_targets(cell: Dictionary) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for n in CWData.ring(cell["pos"], 1):
		if game.tile(n)["tissue"] == CWData.Tissue.CANCER:
			out.append(n)
	return out


## 【细胞毒素】（PRD T 细胞）：消耗 1.0，使**1 环内**（含自己脚下那格）的癌组织转为健康组织，
## 对范围内所有癌细胞造成 1.0 能量损失，并使范围内**新生健康组织**所有格进入「坏死」。
## 每世界回合最多 3 次。
##
## 注意这里**不再**回避「有癌细胞站着的格」（旧说明 #20）—— PRD 写的是「所有格中的癌组织」，
## 而且同一条技能紧接着就要对那些癌细胞造成伤害，显然是打算连人带地一起处理。
## 癌细胞站在健康组织上是合法的过渡态：【定殖】只在「经过」时触发（说明 #9），
## 已经站着的不会重新把脚下染回去。
func _do_toxin(cell: Dictionary) -> void:
	var targets := _toxin_targets(cell)
	if targets.is_empty() or not game.pay(cell, CWData.TOXIN_COST):
		return
	cell["toxin_used"] += 1
	for c in targets:
		CWTissue.to_necrotic(game.tile(c), CWData.NECROSIS_TOXIN)
	game.log_msg("【细胞毒素】1 环内 %d 格癌组织转为健康组织并进入「坏死」（不积累记忆）" % targets.size())
	## 伤害范围同样按 1 环。中心格上站着的就是施法者自己（一格只容一个细胞），
	## 所以这里含不含中心其实不改结果 —— 写成 ring 是为了**和上面那半用同一把尺**，
	## 免得将来有人只改一处。
	var victims: Array = []
	for n in CWData.ring(cell["pos"], 1):
		victims.append_array(game.cells_at(n, CWData.Faction.CANCER))
	## attack=false：细胞毒素是「技能」，同上（T 细胞专属）；【DNA损伤修复】可挡
	game.immune_hit_area(victims, CWData.ATTACK_DMG_SUCCESS, cell, "细胞毒素")


func _do_lyse(cell: Dictionary, to: Vector2i) -> void:
	if game.cost.commit(CWCost.context(cell, CWCost.Action.CELL_SKILL, CWData.LYSE_COST,
			to, 0, func() -> bool: return _is_lyse_legal_now(cell, to))).is_empty():
		return
	var t: Dictionary = game.tile(to)
	CWTissue.to_healthy(t)
	game.log_msg("【裂解】%s 由固化癌组织转为健康组织" % str(to))


## 净化后的永久技能连锁——enter_tile 与裂解的「顺带净化」共用一个口。
## 是协程：【免疫记忆库】要抽卡（抽到事件卡还可能连锁发问）
func _on_purify(cell: Dictionary) -> void:
	if game.has_skill(cell, "模式识别增强") and game.first_this_round(cell, "模式识别增强"):
		cell["energy"] += CWData.SKILL_HEAL
		game.log_msg("　【模式识别增强】本世界回合首次净化：恢复 0.5 能量")
	if game.has_skill(cell, "效应记忆形成") and game.first_this_round(cell, "效应记忆形成"):
		game.gain_memory(1)
		cell["energy"] += CWData.SKILL_HEAL
		game.log_msg("　【效应记忆形成】本世界回合首次净化：+1 抗原记忆，恢复 0.5 能量")
	if game.has_skill(cell, "免疫记忆库") and game.first_this_round(cell, "免疫记忆库"):
		game.log_msg("　【免疫记忆库】本世界回合首次净化：免费抽取 1 张")
		await game.cards.draw(cell, "免疫记忆库")


# ---- 癌症通用技能 ----

func _do_mutate(cell: Dictionary) -> void:
	if not game.pay(cell, CWData.MUTATE_COST):
		return
	cell["mutate_used"] = true
	await roll_mutation(cell)


## 掷骰 + 结算拆成两半：【基因组不稳定】第 20 回合起要「掷两次、玩家挑一个结果」，
## 它只想复用结算那一半（apply_mutation），掷骰自己另掷
func roll_mutation(cell: Dictionary) -> void:
	var r: int = await game.roll_shown(3, "突变", cell["pid"], cell["pos"])
	await apply_mutation(cell, r)


func apply_mutation(cell: Dictionary, r: int) -> void:
	match r:
		1:
			game.log_msg("【突变】无事发生")
			game.announce("突变：无事发生", cell["pos"])
		2:
			game.log_msg("【突变】抽卡，并削减 1 抗原记忆")
			game.announce("突变：抽一张 · 记忆 -1", cell["pos"])
			await game.cards.draw(cell, "突变")
			game.reduce_memory(1)
		3:
			# 效果扣减可致死（区别于费用支付，见规则总则）
			cell["energy"] -= CWData.MUTATE_EXTRA_LOSS
			game.log_msg("【突变】再扣 %s 能量（余 %s），削减 %d 抗原记忆" % [
				CWData.fmt(CWData.MUTATE_EXTRA_LOSS), CWData.fmt(maxi(cell["energy"], 0)),
				CWData.MUTATE_MEMORY_CUT])
			game.announce("突变：能量 -%s · 记忆 -%d" % [
				CWData.fmt(CWData.MUTATE_EXTRA_LOSS), CWData.MUTATE_MEMORY_CUT], cell["pos"])
			game.reduce_memory(CWData.MUTATE_MEMORY_CUT)
			if cell["energy"] <= 0:
				game.kill(cell)


# ---- 恶性黑色素瘤 ----

## 【早期血行转移】的落点：全场任意一个**无细胞占据**的健康组织。
## PRD 原文写的是「未被免疫细胞占据」，但棋盘规则是一格只能有一个细胞，
## 所以实际约束更严 —— 己方细胞占着的格同样去不了。
func _homing_targets() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for c in game.tiles.keys():
		if game.tiles[c]["tissue"] == CWData.Tissue.HEALTHY and game.cells_at(c).is_empty():
			out.append(c)
	out.sort()   # 固定候选顺序，保证同种子可复现
	return out


func _do_homing(cell: Dictionary, to: Vector2i) -> void:
	if game.cost.commit(CWCost.context(cell, CWCost.Action.SKILL_MOVE,
			CWData.MELANOMA_HOMING_COST, to, 0,
			func() -> bool: return _is_homing_legal_now(cell, to))).is_empty():
		return
	cell["metastasis_used"] = true
	game.log_msg("【早期血行转移】%s 自血管转移至 %s" % [game.cell_name(cell), str(to)])
	await enter_tile(cell, to)   # 落地即【定殖】，把该格转为癌组织
	## PRD 2026-09-01 追加：「并将相邻格中随机最多 3 格转为癌组织」。
	## 只取**健康组织**——癌组织已经是癌了，固化更不该被降级。
	var spread: Array[Vector2i] = []
	for n in CWData.neighbors(to):
		if game.tile(n)["tissue"] == CWData.Tissue.HEALTHY:
			spread.append(n)
	for c in game.pick_random(spread, CWData.HOMING_SPREAD):
		CWTissue.to_cancer(game.tile(c), true)
		game.erosion_fx(c, CWData.dir_toward(c, to))   ## 过场：癌从落点那一侧漫入（Kevin 2026-09-06：这些也接）
		game.log_msg("　【早期血行转移】%s 转为癌组织" % str(c))


# ---- 印戒细胞癌 ----

## 【黏液破裂】：耗尽全部能量（至少 2.0）并死亡。自身所在格及周围 2 格所有组织进入
## 「黏液侵染」，其中随机最多 8 格立即转为癌组织，范围内的免疫细胞损失 2.0 能量。
##
## ⚠ PRD 只说了「粘液」无法被技能清除、被免疫细胞接触后消失，**没有写它本身有什么效果**。
## 这里如实实现成一个标记：会随棋盘存续、会被免疫细胞踩掉，但不产生任何结算影响。
## 等 PRD 补上效果再往 t["mucus"] 上挂。
func _do_mucus(cell: Dictionary) -> void:
	var area: Array[Vector2i] = []
	for c in game.tiles.keys():
		if CWData.hex_dist(c, cell["pos"]) <= CWData.MUCUS_RADIUS:
			area.append(c)
	area.sort()
	for c in area:
		game.tile(c)["mucus"] = true
	var healthy: Array[Vector2i] = []
	for c in area:
		if game.tile(c)["tissue"] == CWData.Tissue.HEALTHY:
			healthy.append(c)
	var picked: Array = game.pick_random(healthy, CWData.MUCUS_MAX_CONVERT)
	for c in picked:
		CWTissue.to_cancer(game.tile(c), true)
		## 过场：癌从引爆者那一侧漫入；引爆者自己脚下那格取不出方向（-1），引擎那头就不广播
		game.erosion_fx(c, CWData.dir_toward(c, cell["pos"]))
	game.log_msg("【黏液破裂】%s 引爆：%d 格进入黏液侵染，其中 %d 格转为癌组织" % [
		game.cell_name(cell), area.size(), picked.size()])
	game.announce("黏液破裂", cell["pos"], true)
	var victims: Array = []
	for c in area:
		victims.append_array(game.cells_at(c, CWData.Faction.IMMUNE))
	game.cancer_hit_area(victims, CWData.MUCUS_IMMUNE_LOSS, "黏液破裂", true)
	game.kill(cell)   # 自毁型技能：耗尽能量并死亡（说明 #8 的同类）
	game.update_marks()


# ---- 骨肉瘤 ----

func _can_ossify(cell: Dictionary) -> bool:
	var t: Dictionary = game.tile(cell["pos"])
	return t["tissue"] == CWData.Tissue.CANCER and int(t.get("ossify_at", 0)) == 0 \
		and CWTissue.solidifiable(t)   ## 血管不可固化（Kevin 2026-09-06）：标都不让标


## 【骨样硬化】（2026-09-05 重做）：花 osteo_ossify_cost 标记脚下的癌组织，
## 第 (当前 + osteo_ossify_rounds) 世界回合的 E 阶段转为固化癌组织（CWWorld._ossify）。
## 取代旧版「触发【E-固化】计数 +1.5」—— 那条在阈值 2.0 之下一回合都没省。
## 新版的意义是**先标记、再走开**：骨肉瘤不必被钉在原地蹲两回合。
## 代价：比蹲着慢一回合、要花 2.0、而且免疫蹲进来一回合就能拆掉。
func _do_ossify(cell: Dictionary) -> void:
	var at: Vector2i = cell["pos"]
	if game.cost.commit(CWCost.context(cell, CWCost.Action.CELL_SKILL, game.tune.osteo_ossify_cost,
			at, 0, func() -> bool: return _can_ossify(cell))).is_empty():
		return
	var t: Dictionary = game.tile(at)
	t["ossify_at"] = game.round_no + game.tune.osteo_ossify_rounds
	game.log_msg("【骨样硬化】%s 标记 %s，第 %d 世界回合 E 阶段转为固化癌组织" % [
		game.cell_name(cell), str(at), t["ossify_at"]])


# ---- 小细胞肺癌 ----

## 【转移】：向某方向跃进 5 格。落点必须在棋盘上且无细胞占据。
func _jump_targets(cell: Dictionary) -> Array:
	var out: Array = []
	for d in CWData.DIRS:
		var to: Vector2i = cell["pos"] + d * CWData.METASTASIS_RANGE
		if game.is_on_board(to) and game.cells_at(to).is_empty():
			out.append(to)
	return out


## 跃进路径上不触发【定殖】、代谢核心/骨髓收取等效果，**终点可以触发**（PRD）——
## 所以这里直接 enter_tile 到终点，中间格连碰都不碰。
func _do_jump(cell: Dictionary, to: Vector2i) -> void:
	if game.cost.commit(CWCost.context(cell, CWCost.Action.SKILL_MOVE,
			game.tune.metastasis_cost, to, 0,
			func() -> bool: return _is_jump_legal_now(cell, to))).is_empty():
		return
	cell["jump_used"] = int(cell.get("jump_used", 0)) + 1
	game.log_msg("【转移】%s 跃进 5 格至 %s" % [game.cell_name(cell), str(to)])
	await enter_tile(cell, to)


func _adjacent_healthy(pos: Vector2i) -> bool:
	for n in CWData.neighbors(pos):
		if game.tile(n)["tissue"] == CWData.Tissue.HEALTHY:
			return true
	return false


# ============ 【效应应答】（PRD「I-效应应答」，2026-09-07 实装）============
##
## 四个大招共用一条路：`can_effector` 把门槛全查完 → 各自问目标 → `spend_effector` 扣 15 效应记忆
## 并烧掉两处额度（本细胞每局 1 次、免疫方每世界回合 1 次）。**扣费放在问完目标之后**：
## 中途退出不该白花记忆（同 `_do_chemo` 的先问后付）。

## 有没有可打的目标 —— 没目标的大招不该出现在行动栏上（点了也只能空放）。
func _effector_ready(cell: Dictionary, what: String) -> bool:
	match what:
		"免疫猎杀":
			return not game.living_cells(CWData.Faction.CANCER).is_empty()
		"中和抗体":
			return not _neutralize_targets().is_empty()
		_:
			return true      ## 连续吞噬（挂个待触发的闸门）、Excalibur（六个方向永远打得出去）


func _do_effector(cell: Dictionary) -> void:
	var what: String = CWData.EFFECTOR_NAMES.get(cell["itype"], "")
	if what == "" or not game.can_effector(cell) or not _effector_ready(cell, what):
		return           ## 提交前复验：选项摆出来之后盘面可能已经变了
	match what:
		"免疫猎杀":
			await _effector_hunt(cell)
		"连续吞噬":
			_effector_chain(cell)
		"中和抗体":
			_effector_neutralize(cell)
		"Excalibur":
			await _effector_excalibur(cell)


## 树突【免疫猎杀】：选定全局任意一个癌细胞 → 给它【标记】，并在它身上附一个跟随的【追踪趋化源】。
## 追踪源与普通趋化源**并存**（PRD 只说「同一时刻场上仅能存在一个**普通**趋化源」）。
func _effector_hunt(cell: Dictionary) -> void:
	var opts: Array = []
	for c in game.living_cells(CWData.Faction.CANCER):
		opts.append({ "label": "猎杀→%s" % game.cell_name(c), "data": { "cid": c["id"] } })
	var pick: int = await game.ask(cell["pid"], {
		"kind": "effector_target",
		"prompt": "【免疫猎杀】选择一个癌细胞（全局任意）", "options": opts,
	})
	var target: Dictionary = game.cells[int(opts[pick]["data"]["cid"])]
	game.spend_effector(cell, "免疫猎杀")
	game.apply_mark(target, cell)
	game.chemo_track = { "cid": int(target["id"]), "at": target["pos"],
		"left": CWData.HUNT_CHEMO_ROUNDS }
	game.log_msg("　【免疫猎杀】%s 被标记并附上【追踪趋化源】（持续 %d 回合，它自己怎么走都算「远离」）"
		% [game.cell_name(target), CWData.HUNT_CHEMO_ROUNDS])
	game.announce("免疫猎杀", target["pos"], true)


## 巨噬【连续吞噬】：发动只是**架好闸门**，真正的连锁在本行动回合第一次【净化】之后触发
## （见 `_chain_phagocytosis`）。所以这里不问目标、也不需要盘面条件。
func _effector_chain(cell: Dictionary) -> void:
	game.spend_effector(cell, "连续吞噬")
	cell["chain_left"] = CWData.CHAIN_PHAGO_MAX
	game.log_msg("　【连续吞噬】本行动回合首次【净化】后可连续免费迁移，最多 %d 次；每连一格下一击 +%s"
		% [CWData.CHAIN_PHAGO_MAX, CWData.fmt(CWData.CHAIN_PHAGO_BONUS)])


## B【中和抗体】：所有与健康组织相邻的癌细胞，其**种类特殊效果 / 永久卡牌效果**失效，**持续 1 世界回合**。
##
## 2026-09-08 云端修订版由「当前回合与下一回合」改成「持续 1 世界回合」，按新的通用规则 3
## （「持续 n 世界回合」= 第「当前 + n − 1」世界回合 E 阶段结束）就是**只到本回合末**，短了一半。
func _neutralize_targets() -> Array:
	var out: Array = []
	for c in game.living_cells(CWData.Faction.CANCER):
		if _adjacent_healthy(c["pos"]):
			out.append(c)
	return out


func _effector_neutralize(cell: Dictionary) -> void:
	var targets := _neutralize_targets()
	game.spend_effector(cell, "中和抗体")
	for t in targets:
		## 记「到第几个世界回合末为止」而不是倒计时：中途存档读档、快照回滚都不会走样。
		## 持续 1 世界回合 = 到**本**回合末（通用规则 3：第「当前 + 1 − 1」回合 E 阶段结束）
		t["neutral_until"] = game.round_no
	game.log_msg("　【中和抗体】%d 个与健康组织相邻的癌细胞：种类技能与永久卡本回合和下一回合失效"
		% targets.size())


## T【Excalibur】：选一个方向，主射线打到棋盘边缘；主射线相邻的癌组织各有 60% 概率被波及。
## 范围内**癌组织**转健康并进入「坏死」（固化癌组织不转）；主射线上的癌细胞 -2.0、侧向 -1.0。
func _effector_excalibur(cell: Dictionary) -> void:
	var opts: Array = []
	for i in CWData.DIRS.size():
		opts.append({ "label": "Excalibur→%s" % str(cell["pos"] + CWData.DIRS[i]),
			"data": { "dir": i, "to": cell["pos"] + CWData.DIRS[i] } })
	var pick: int = await game.ask(cell["pid"], {
		"kind": "effector_target",
		"prompt": "【Excalibur】选择释放方向", "options": opts,
	})
	var dir: Vector2i = CWData.DIRS[int(opts[pick]["data"]["dir"])]
	game.spend_effector(cell, "Excalibur")
	## 主射线：从自己所在格沿方向一路到棋盘外（不含起点）
	var ray: Array[Vector2i] = []
	var at: Vector2i = cell["pos"] + dir
	while game.tiles.has(at):
		ray.append(at)
		at += dir
	## 侧向波及：主射线**相邻的癌组织**各掷一次 60%（顺序固定 = 同种子可复现）
	var splash: Array[Vector2i] = []
	var seen := {}
	for c in ray:
		seen[c] = true
	for c in ray:
		for n in CWData.neighbors(c):
			if seen.has(n) or not game.tiles.has(n):
				continue
			if game.tile(n)["tissue"] != CWData.Tissue.CANCER:
				continue
			seen[n] = true
			if game.rng.randi_range(1, 100) <= CWData.EXCALIBUR_SPLASH_PCT:
				splash.append(n)
	game.log_msg("　【Excalibur】主射线 %d 格，侧向波及 %d 格" % [ray.size(), splash.size()])
	_excalibur_sweep(ray, CWData.EXCALIBUR_RAY_DMG)
	_excalibur_sweep(splash, CWData.EXCALIBUR_SPLASH_DMG)
	game.announce("Excalibur", cell["pos"], true)


## 扫一串格子：癌组织 → 健康 + 坏死（**固化癌组织不转**，PRD 明写），上面的癌细胞挨一下。
## **先转组织再打伤害**：打死的细胞会走死亡结算，顺序反过来会让死亡格的组织状态不一致。
## 伤害走 `cancer_hit_area` 而不是逐个 `cancer_hit`：同一次技能必须是同一批
## （设计 §5.5——边打边死会让后面的目标在不同的盘面上结算）。
func _excalibur_sweep(cells_at: Array, dmg: int) -> void:
	for c in cells_at:
		var t: Dictionary = game.tile(c)
		if t["tissue"] == CWData.Tissue.CANCER:
			CWTissue.to_healthy(t)
			t["necrosis"] = CWData.NECROSIS_TOXIN
	var hit: Array = []
	for c in cells_at:
		hit.append_array(game.cells_at(c, CWData.Faction.CANCER))
	if not hit.is_empty():
		game.cancer_hit_area(hit, dmg, "Excalibur", true)


## 巨噬【效应应答·连续吞噬】的连锁：净化之后只要还能免费迁进相邻的**癌组织**就可以继续，
## 最多 `CHAIN_PHAGO_MAX` 次；每连一格，下一次攻击额外 +0.5。
##
## `chain_running` 是**再入闸**：连锁里的每一步迁移都会再触发一次【净化】，
## 而【净化】末尾又挂着这个钩子 —— 不拦就是无限递归。
## 免费迁移走 `enter_tile`（同卡牌的 `_free_walk`）：那条路根本不进费用管线，所以是真免费。
func _chain_phagocytosis(cell: Dictionary) -> void:
	cell["chain_running"] = true
	var linked := 0
	while int(cell.get("chain_left", 0)) > 0 and cell["alive"]:
		var opts: Array = []
		for n in CWData.neighbors(cell["pos"]):
			if game.tile(n)["tissue"] == CWData.Tissue.CANCER and game.cells_at(n).is_empty():
				opts.append({ "label": "连续吞噬→%s（免费）" % str(n), "data": { "to": n } })
		if opts.is_empty():
			break
		opts.append({ "label": "结束连续吞噬", "data": { "stop": true } })
		var pick: int = await game.ask(cell["pid"], {
			"kind": "free_move", "tag": "连续吞噬",
			"prompt": "【连续吞噬】免费迁移到相邻癌组织（还可连 %d 次）" % int(cell["chain_left"]),
			"options": opts,
		})
		if opts[pick]["data"].get("stop", false):
			break
		cell["chain_left"] = int(cell["chain_left"]) - 1
		linked += 1
		game.log_msg("　【连续吞噬】%s 免费迁移至 %s" % [game.cell_name(cell), str(opts[pick]["data"]["to"])])
		await enter_tile(cell, opts[pick]["data"]["to"])
	cell["chain_running"] = false
	if linked > 0:
		cell["chain_bonus"] = int(cell.get("chain_bonus", 0)) + linked * CWData.CHAIN_PHAGO_BONUS
		game.log_msg("　【连续吞噬】连续净化 %d 格，下一次攻击额外 +%s"
			% [linked, CWData.fmt(int(cell["chain_bonus"]))])
