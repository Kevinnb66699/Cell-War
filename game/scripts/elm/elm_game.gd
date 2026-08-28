## elm_game.gd —— 迁移版中央 Game：不可变 state + 纯函数 update（被动一步转移）
##
## 对应 cw_game.gd 的目标形态（见 docs/重构API设计.md）：
##   · state 不可变（duplicate 模拟；差分/事件链后续优化）
##   · rng 进 state：掷骰 = 纯函数消耗 rng_state，不经过桥
##   · update(state, msg) -> {state, effects}，无 await / 无桥引用
##   · msg = {step} / {decision, idx}；ask 不是 msg（state 呈现的需求）
##   · 父 update 的显式状态机：pc + pending + 各阶段子指针，把 cw_game.run_game()
##     的 await 链摊平成 step 函数（决策点产出 ask effect，不等待）
##
## 状态机 pc：SETUP_BUILD -> SETUP_PLACE -> SETUP_DONE -> WORLD_S -> TURN_ACTIVE
##            -> WORLD_E -> (回 WORLD_S 或 DONE)。
## 子 Updater：ElmSetup / ElmWorld / ElmTurn(内联在 _advance_turn) / ElmActions / ElmCards。
class_name ElmGame
extends RefCounted

const MAX_ACTIONS_PER_TURN := 80


# ---- 纯函数 rng（精确复刻 cw_game.rng 语义）----
## seed -> 初始 state：真实代码 rng.seed=seed 后连续 randi_range；
## 迁移版把 rng.state 存进 state，每次掷骰 new RNG + 重设 state，序列逐位一致
## （已在 tests/rng_repro.gd 验证）。
static func _rng_state_from_seed(seed_value: int) -> int:
	var r := RandomNumberGenerator.new()
	r.seed = seed_value
	return r.state


static func _randi_range(rng_state: int, from_i: int, to_i: int) -> Dictionary:
	var r := RandomNumberGenerator.new()
	r.state = rng_state
	var v := r.randi_range(from_i, to_i)
	return { "value": v, "state": r.state }


## 复刻 cw_game.pick_random（均匀取 n 个不重复）
static func _pick_random(rng_state: int, arr: Array, n: int) -> Dictionary:
	var pool := arr.duplicate()
	var out: Array = []
	var st := rng_state
	while out.size() < n and not pool.is_empty():
		var rr := _randi_range(st, 0, pool.size() - 1)
		st = rr["state"]
		out.append(pool.pop_at(rr["value"]))
	return { "picked": out, "state": st }


# ---- state 构造（复刻 cw_game.init：players/order 生成 + rng seed）----
static func make_initial_state(seed_value: int, faction_list: Array, tune) -> Dictionary:
	var players: Array = []
	var order: Array = []
	var immune_i := 0
	var cancer_i := 0
	for i in faction_list.size():
		var f: int = faction_list[i]
		var seq := ""
		if f == CWData.Faction.IMMUNE:
			seq = char(65 + immune_i)
			immune_i += 1
		else:
			seq = char(65 + cancer_i)
			cancer_i += 1
		var pname := ("免疫" if f == CWData.Faction.IMMUNE else "癌症") + seq
		players.append({ "id": i, "name": pname, "faction": f, "cell_id": i })
		order.append(i)
	return {
		"pc": "SETUP_BUILD", "rng_state": _rng_state_from_seed(seed_value),
		"tiles": {}, "cells": [], "players": players, "order": order,
		"round_no": 1, "memory": 0, "immune_level": 0, "differentiated": [],
		"winner": -1, "win_reason": "", "win_kind": "",
		"tune": tune, "next_pid": 0, "pending": null, "logs": [],
		# ---- 显式状态机辅助字段（把 run_game 的 await 链摊平成 step 状态）----
		"phase_step": 0,      # WORLD_S 内部子步骤 0..7
		"revive_idx": 0,      # WORLD_S revive 循环指针（order 下标）
		"turn_index": 0,      # TURN_ACTIVE 玩家指针（order 下标）
		"turn_open_pid": -1,  # 已打过「▶ X 的回合」开场日志的 pid（防重复）
		"act": null,          # 正在执行的动作名（null = 在选动作）
		"act_state": "",      # 动作子步骤
		"act_data": {},       # 动作参数（to/cost...）
		"act_pid": -1,        # 执行动作的玩家 pid
		"action_guard": 0,    # 回合内选动作次数（防死循环，对应 MAX_ACTIONS_PER_TURN）
		"move_target_id": -1, # 攻击目标的 cell id（move_choose 阶段）
		"ab_eligible": [],    # 抗体无目标时的候选格
		"end_logged": false,  # 对局结束日志只打一次（对应 run_game 末尾）
		"setup_done": false,  # SETUP 阶段完成标志（供 run_to_setup 停点）
	}


# ---- 中央 update（被动一步转移，不等待）----
static func update(state: Dictionary, msg: Dictionary) -> Dictionary:
	var s: Dictionary = state.duplicate(true)
	var effects: Array = []
	match String(msg.get("kind", "")):
		"step":
			_advance(s, effects)
		"decision":
			_apply_decision(s, int(msg.get("idx", 0)), effects)
		_:
			pass
	return { "state": s, "effects": effects }


## 推进内部环节到下一个 ask 或阶段完成（状态机不自走，由 step/decision 触发）
static func _advance(s: Dictionary, effects: Array) -> void:
	# 状态机被动：state 停在 ask（pending 存续）时，step 是 no-op ——
	# 必须靠外界发 decision 才动（对应验证：发 step 时停在 ask 的 state 不变）
	if s["pending"] != null:
		return
	var guard := 0
	while guard < 2000:
		guard += 1
		match String(s["pc"]):
			"SETUP_BUILD":
				ElmSetup.build_board(s, effects)
				ElmSetup.place_initial_cancer(s, effects)
				ElmSetup.assign_cancer_types(s, effects)
				s["pc"] = "SETUP_PLACE"
				s["next_pid"] = 0
			"SETUP_PLACE":
				if s["next_pid"] >= s["order"].size():
					ElmSetup.place_primary_lesions(s, effects)
					update_marks(s)
					s["pc"] = "SETUP_DONE"
					continue
				var pid: int = s["order"][s["next_pid"]]
				var p: Dictionary = player(s, pid)
				var options: Array = ElmSetup.place_options(s, p)
				if options.is_empty():
					s["next_pid"] += 1
					continue
				ask_effect(s, effects, "setup_place", pid,
					"%s 选择初始位置" % p["name"], options)
				break
			"SETUP_DONE":
				if not s["setup_done"]:
					add_log(s, effects, "—— 开局完成，进入世界回合 ——")
					s["setup_done"] = true
					break  # 停在此刻，供 run_to_setup 捕捉；下一步 step 进世界回合
				s["pc"] = "WORLD_S"
				s["phase_step"] = 0
				s["revive_idx"] = 0
			"WORLD_S":
				ElmWorld.advance_s(s, effects)
				if s["pending"] != null:
					break  # 停在 ask（revive），等 decision
				continue
			"TURN_ACTIVE":
				_advance_turn(s, effects)
				if s["pending"] != null:
					break  # 停在 ask（action 或动作内 ask），等 decision
				continue
			"WORLD_E":
				ElmWorld.advance_e(s, effects)
				continue  # E 阶段全内部，advance_e 已改 pc（WORLD_S / DONE）
			"DONE":
				if not s["end_logged"]:
					add_log(s, effects, "=== 对局结束：%s ===" % s["win_reason"])
					s["end_logged"] = true
				break
			_:
				break


## 玩家回合状态机（复刻 cw_turn.run_all + _run_player_turn）：
## 按 order 逐玩家，每个玩家循环「选动作 -> 执行 -> 再选」直到结束回合。
static func _advance_turn(s: Dictionary, effects: Array) -> void:
	var guard := 0
	while guard < 300:
		guard += 1
		# 胜负：任何环节判定结束，立即收尾（对应 run_all 的 winner 检查）
		if s["winner"] >= 0:
			s["pc"] = "DONE"
			return
		if int(s["turn_index"]) >= s["order"].size():
			# 所有玩家回合完成 -> E 阶段
			s["pc"] = "WORLD_E"
			s["phase_step"] = 0
			s["revive_idx"] = 0
			s["act"] = null
			s["act_state"] = ""
			s["act_data"] = {}
			return
		var pid: int = s["order"][s["turn_index"]]
		var cell: Dictionary = cell_of(s, pid)
		if not cell["alive"]:
			# 复刻 cw_turn.run_all：进入回合时已死亡 -> 「跳过」；
			# 已打开过开场日志（中途死亡）-> 仍无条件打「结束回合」
			if s["turn_open_pid"] == pid:
				add_log(s, effects, "　%s 结束回合（能量 %s）" % [
					s["players"][pid]["name"], CWData.fmt(cell["energy"])])
			else:
				add_log(s, effects, "（%s 已死亡，跳过回合）" % s["players"][pid]["name"])
			s["turn_index"] += 1
			continue
		if s["act"] == null:
			# 选动作
			if s["turn_open_pid"] != pid:
				add_log(s, effects, "▶ %s 的回合（能量 %s）" % [
					s["players"][pid]["name"], CWData.fmt(cell["energy"])])
				s["turn_open_pid"] = pid
			var options: Array = ElmActions.build_options(s, cell)
			if int(s["action_guard"]) >= MAX_ACTIONS_PER_TURN:
				add_log(s, effects, "　%s 结束回合（动作上限，能量 %s）" % [
					s["players"][pid]["name"], CWData.fmt(cell["energy"])])
				s["turn_index"] += 1
				continue
			if options.size() <= 1:
				# 只剩「结束回合」
				add_log(s, effects, "　%s 结束回合（能量 %s）" % [
					s["players"][pid]["name"], CWData.fmt(cell["energy"])])
				s["turn_index"] += 1
				continue
			ask_effect(s, effects, "action", pid, "选择行动", options)
			return
		else:
			# 执行动作（可能产出动作内 ask 或完成）
			ElmActions.advance_action(s, effects)
			if s["act"] != null:
				return  # 动作未完成：停在 ask
			continue


## 应用一个 decision（按 pending.kind 路由到子 Updater），然后继续推进
static func _apply_decision(s: Dictionary, idx: int, effects: Array) -> void:
	if s["pending"] == null:
		return
	var p: Dictionary = s["pending"]
	match String(p.get("kind", "")):
		"setup_place":
			ElmSetup.apply_place(s, idx, effects)
			s["pending"] = null
			s["next_pid"] += 1
		"action":
			ElmActions.apply_action(s, idx, effects)
			s["pending"] = null
		"attack_target":
			ElmActions.apply_attack_target(s, idx, effects)
			s["pending"] = null
		"differentiate":
			ElmActions.apply_differentiate(s, idx, effects)
			s["pending"] = null
		"confirm":
			match String(p.get("tag", "")):
				"lyse_purge":
					ElmActions.apply_lyse_confirm(s, idx, effects)
				"remutate":
					ElmActions.apply_remutate_confirm(s, idx, effects)
			s["pending"] = null
		"remodel_target":
			ElmActions.apply_remodel_target(s, idx, effects)
			s["pending"] = null
		"revive":
			ElmWorld.apply_revive(s, idx, effects)
			s["pending"] = null
		_:
			pass
	_advance(s, effects)


# ---- 日志 / ask 辅助 ----

## 统一日志：写进 state.logs（历史）+ 产出 log effect（外壳打印/订阅）。
static func add_log(s: Dictionary, effects: Array, text: String) -> void:
	s["logs"].append(text)
	effects.append({ "kind": "log", "text": text })


## 统一产出 ask：设 state.pending（含 req，供 shell 构造桥请求）+ ask effect。
static func ask_effect(s: Dictionary, effects: Array, kind: String, pid: int,
		prompt: String, options: Array, tag: String = "") -> void:
	var req: Dictionary = { "kind": kind, "pid": pid, "prompt": prompt, "options": options }
	var p: Dictionary = { "kind": kind, "pid": pid, "options": options, "req": req }
	if tag != "":
		req["tag"] = tag
		p["tag"] = tag
	s["pending"] = p
	effects.append({ "kind": "ask", "pid": pid, "req": req })


# ---- 查询工具（复刻 cw_game 相关静态查询，签名带 state）----

static func player(s: Dictionary, pid: int) -> Dictionary:
	return s["players"][pid]


static func cell_of(s: Dictionary, pid: int) -> Dictionary:
	return s["cells"][s["players"][pid]["cell_id"]]


static func living_cells(s: Dictionary, faction: int = -1) -> Array:
	var out: Array = []
	for c in s["cells"]:
		if c["alive"] and (faction < 0 or c["faction"] == faction):
			out.append(c)
	return out


static func cells_at(s: Dictionary, pos: Vector2i, faction: int = -1) -> Array:
	var out: Array = []
	for c in s["cells"]:
		if c["alive"] and c["pos"] == pos and (faction < 0 or c["faction"] == faction):
			out.append(c)
	return out


static func tile(s: Dictionary, c: Vector2i) -> Dictionary:
	return s["tiles"][c]


static func is_cancerous(s: Dictionary, c: Vector2i) -> bool:
	var t: int = s["tiles"][c]["tissue"]
	return t == CWData.Tissue.CANCER or t == CWData.Tissue.SOLID


static func count_tissue(s: Dictionary, tissue: int) -> int:
	var n := 0
	for t in s["tiles"].values():
		if t["tissue"] == tissue:
			n += 1
	return n


## 组织连通块：返回 Array[Array[Vector2i]]，pred 决定哪些格属于同类
static func blocks_of(s: Dictionary, pred: Callable) -> Array:
	var seen := {}
	var out: Array = []
	for c in s["tiles"].keys():
		if seen.has(c) or not pred.call(c):
			continue
		var block: Array[Vector2i] = []
		var queue: Array[Vector2i] = [c]
		seen[c] = true
		while not queue.is_empty():
			var cur: Vector2i = queue.pop_back()
			block.append(cur)
			for n in CWData.neighbors(cur):
				if not seen.has(n) and pred.call(n):
					seen[n] = true
					queue.append(n)
		out.append(block)
	return out


# ---- 能量 / 伤害 / 死亡（复刻 cw_game）----

## 支付技能费用：不能使能量降至 0（规则总则），失败返回 false
static func pay(s: Dictionary, cell: Dictionary, cost: int) -> bool:
	if cell["energy"] <= cost:
		return false
	cell["energy"] -= cost
	return true


static func can_pay(s: Dictionary, cell: Dictionary, cost: int) -> bool:
	return cell["energy"] > cost


## 免疫来源的能量损失结算（攻击/抗体共用）：
## 顺序 = 基础 → 标记×2（消耗）→ 免疫逃逸-0.5（每世界回合一次）（说明 #19）
static func immune_hit(s: Dictionary, target: Dictionary, base: int,
		attacker: Dictionary, effects: Array) -> int:
	var dmg := base
	if target["marked"]:
		dmg *= 2
		target["marked"] = false
		add_log(s, effects, "　【标记】生效，伤害翻倍")
	if target["ctype"] == CWData.CancerType.ESCAPE and not target["escape_used"]:
		dmg = maxi(dmg - CWData.ESCAPE_REDUCTION, 0)
		target["escape_used"] = true
		add_log(s, effects, "　【免疫逃逸】减免 0.5")
	target["energy"] -= dmg
	add_log(s, effects, "　%s 损失 %s 能量（余 %s）" % [
		cell_name(s, target), CWData.fmt(dmg), CWData.fmt(maxi(target["energy"], 0))])
	if attacker["faction"] == CWData.Faction.IMMUNE \
			and attacker["itype"] == CWData.ImmuneType.MACRO and dmg > 0:
		attacker["energy"] += CWData.MACRO_HEAL_ATTACK
		add_log(s, effects, "　巨噬【吞噬】恢复 0.5 能量")
	if target["energy"] <= 0:
		kill(s, target, effects)
	update_marks(s)
	return dmg


static func kill(s: Dictionary, cell: Dictionary, effects: Array) -> void:
	cell["energy"] = 0
	cell["alive"] = false
	if cell["faction"] == CWData.Faction.CANCER:
		add_log(s, effects, "☠ %s 死亡" % cell_name(s, cell))
		check_immune_win(s)
		return
	# 免疫细胞：罚停若干回合后在随机健康组织复活（2026-08-26 团队定案）
	var delay: int = s["tune"].immune_respawn_delay
	if delay < 0:
		cell["respawn_round"] = -1
		add_log(s, effects, "☠ %s 死亡（不再复活）" % cell_name(s, cell))
		return
	cell["respawn_round"] = int(s["round_no"]) + 1 + delay
	add_log(s, effects, "☠ %s 死亡，罚停至第 %d 世界回合" % [
		cell_name(s, cell), cell["respawn_round"]])


# ---- 抗原记忆 / 免疫等级（复刻 cw_game）----
static func gain_memory(s: Dictionary, n: int) -> void:
	s["memory"] += n
	var lv: int = s["immune_level"]
	while lv < 3 and s["memory"] >= CWData.LEVEL_MIN_MEMORY[lv + 1]:
		lv += 1
	if lv > s["immune_level"]:
		s["immune_level"] = lv
		add_log(s, [], "★ 免疫等级升至 %s 级" % CWData.LEVEL_NAMES[lv])


static func reduce_memory(s: Dictionary, n: int) -> void:
	s["memory"] = maxi(s["memory"] - n, 0)  # 下限 0，等级不降（说明 #18）


# ---- 树突【标记】：光环式，相邻即获得；只增不减，消耗后若仍相邻会再次标记 ----
static func update_marks(s: Dictionary) -> void:
	for c in living_cells(s, CWData.Faction.CANCER):
		if c["marked"]:
			continue
		for n in CWData.neighbors(c["pos"]):
			var found := false
			for ic in cells_at(s, n, CWData.Faction.IMMUNE):
				if ic["itype"] == CWData.ImmuneType.DENDRITIC:
					found = true
					break
			if found:
				c["marked"] = true
				break


# ---- 胜负（复刻 cw_game）----

## 【I-免疫胜利】场上无活体癌细胞，且不存在可用于复活的固化癌组织（未被免疫占据）
static func check_immune_win(s: Dictionary) -> void:
	if s["winner"] >= 0 or not living_cells(s, CWData.Faction.CANCER).is_empty():
		return
	for c in s["tiles"].keys():
		if s["tiles"][c]["tissue"] == CWData.Tissue.SOLID \
				and cells_at(s, c, CWData.Faction.IMMUNE).is_empty():
			return  # 还有可复活据点
	s["winner"] = CWData.Faction.IMMUNE
	s["win_kind"] = "immune_clear"
	s["win_reason"] = "免疫胜利：癌细胞全灭且无可复活的固化癌组织"


## 【S-癌症胜利】癌组织 + 2×固化 ≥ 门槛（每世界回合 S 阶段开头判定）
static func check_cancer_s_win(s: Dictionary) -> void:
	if s["winner"] >= 0:
		return
	var w := count_tissue(s, CWData.Tissue.CANCER) + 2 * count_tissue(s, CWData.Tissue.SOLID)
	if w >= s["tune"].cancer_win_weighted:
		s["winner"] = CWData.Faction.CANCER
		s["win_kind"] = "cancer_weighted"
		s["win_reason"] = "癌症胜利：加权占地 %d ≥ %d" % [w, s["tune"].cancer_win_weighted]


# ---- 日志 / 名称 ----
static func cell_name(s: Dictionary, c: Dictionary) -> String:
	var tname: String
	if c["faction"] == CWData.Faction.IMMUNE:
		tname = CWData.IMMUNE_TYPE_NAMES[c["itype"]]
	else:
		tname = CWData.CANCER_TYPE_NAMES[c["ctype"]] + "癌细胞"
	return "%s(%s)" % [s["players"][c["pid"]]["name"], tname]


## 全状态哈希：复刻 cw_game.state_hash 的字符串构造，迁移版从 state 直接算。
## 与真实版同种子对比该值，可一键判定整个对局是否行为等价。
static func state_hash(s: Dictionary) -> String:
	var parts: PackedStringArray = []
	parts.append("r%d m%d lv%d w%d" % [
		s["round_no"], s["memory"], s["immune_level"], s["winner"]])
	var coords: Array = s["tiles"].keys()
	coords.sort()
	for c in coords:
		var t: Dictionary = s["tiles"][c]
		parts.append("%s:%d,%d,%d,%d,%d,%d,%d" % [str(c), t["tissue"], t["solid"],
			t["sticky"], 1 if t["newborn"] else 0, t["store"], t["cards"], t["prod"]])
	for cell in s["cells"]:
		parts.append("c%d:%d,%s,%d,%d,%d,%d,%d" % [cell["id"], cell["faction"],
			str(cell["pos"]), cell["energy"], 1 if cell["alive"] else 0,
			cell["itype"], cell["ctype"], cell["respawn_round"]])
	return "\n".join(parts).sha256_text()
