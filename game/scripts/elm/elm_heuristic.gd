## elm_heuristic.gd —— 启发式 AI 桥（Elm 版，纯函数决策）
##
## 给免疫/癌症双方提供基础决策，用于平衡模拟与人机对战。
## 与旧 `CWHeuristicBridge` 的**唯一区别**：不再持 `game`（CWGame）引用、不再穿透读
## game.xxx —— 决策输入是 **state 快照 + req**，内部只读 state，调用 ElmGame/ElmActions
## 的静态查询工具。纯函数 → 可复现、可锁步、可放进 MCTS 副本。
##
## 接口：`ask(state, req) -> int`（返回 req.options 下标）。shell/session 每次发 decision
## 前把**当前 state** 传进来（快照语义：同种子里此刻的 state 就是决策所见）。
##
## 策略只依赖对局状态、不使用任何随机数 → 同一种子的对局完全可复现（确定性测试依赖这一点）。
## 数值阈值都是「十分能量」。（旧桥里的 delay 观战节流属于表现层，已移到 UI/会话层做，
## 不在决策函数内 —— 保证 ask 是纯同步纯函数，session 调用无需 await。）
class_name ElmHeuristicBridge
extends RefCounted


func ask(state: Dictionary, req: Dictionary) -> int:
	var pid: int = req["pid"]
	var options: Array = req["options"]
	match req["kind"]:
		"setup_place":
			return _setup_place(state, pid, options)
		"action":
			if ElmGame.player(state, pid)["faction"] == CWData.Faction.IMMUNE:
				return _immune_action(state, pid, options)
			return _cancer_action(state, pid, options)
		"attack_target":
			return _pick_weakest(state, options)
		"differentiate":
			return _pick_differentiation(options)
		"revive":
			return _pick_revive(state, options)
		"remodel_target":
			return 0
		"confirm":
			if req.get("tag", "") == "remutate":
				return 0 if ElmGame.cell_of(state, pid)["energy"] >= 20 else 1
			return 0  # lyse_purge：总是立刻净化
	return 0


# ============ 开局落子 ============

func _setup_place(state: Dictionary, pid: int, options: Array) -> int:
	var faction: int = ElmGame.player(state, pid)["faction"]
	var best := 0
	var best_score := -999999
	for i in options.size():
		var c: Vector2i = options[i]["data"]["to"]
		var score: int
		if faction == CWData.Faction.CANCER:
			# 远离已落子的免疫细胞是第一要务（开局 3.0 能量扛不住围攻），其次靠中心、独占一格
			var safety := 99
			for other in ElmGame.living_cells(state, CWData.Faction.IMMUNE):
				safety = mini(safety, CWData.hex_dist(c, other["pos"]))
			score = mini(safety, 6) * 5 - CWData.hex_dist(c, Vector2i.ZERO) * 2 \
				- ElmGame.cells_at(state, c).size() * 3
		else:
			# 距最近癌性组织 2 格最理想（首回合可接敌但不至于立刻被围），并与队友拉开距离
			var d := _dist_to_nearest_cancerous(state, c)
			var spread := 99
			for other in ElmGame.living_cells(state, CWData.Faction.IMMUNE):
				spread = mini(spread, CWData.hex_dist(c, other["pos"]))
			score = -absi(d - 2) * 10 + mini(spread, 6)
		if score > best_score:
			best_score = score
			best = i
	return best


# ============ 免疫回合 ============

func _immune_action(state: Dictionary, pid: int, options: Array) -> int:
	var me: Dictionary = ElmGame.cell_of(state, pid)
	var e: int = me["energy"]
	var tune: CWTuning = state["tune"]
	# 1. 分化免费，永远优先
	var i := _find(options, "differentiate")
	if i >= 0:
		return i
	# 2. T 细胞站在固化格上 → 裂解+净化
	i = _find(options, "lyse")
	if i >= 0 and e >= 20:
		return i
	# 3. B 细胞抗体：目标够多才划算
	i = _find(options, "antibody")
	if i >= 0:
		var n := _antibody_target_count(state)
		if (n >= 2 and e >= 25) or (n >= 1 and e >= 40):
			return i
	# 4. T 细胞毒素：一次至少清 2 格
	i = _find(options, "toxin")
	if i >= 0 and e >= 25 and ElmActions._toxin_targets(state, me).size() >= 2:
		return i
	# 5. 攻击相邻癌细胞。留足「攻击费 + 反弹反击」的储备避免自杀式进攻——
	# 这正是免疫方能主动规避反击威胁的原因（团队 2026-08-26 已确认此问题）。
	var atk_reserve: int = tune.immune_move_cancerous[state["immune_level"]] \
		+ tune.counter_dmg_on_fail + 10
	if e >= maxi(25, atk_reserve):
		var atk := _best_attack(state, options)
		if atk >= 0:
			return atk
	# 6. 净化：进入相邻的无人癌组织
	var purge_cost: int = tune.immune_move_cancerous[state["immune_level"]]
	if e >= purge_cost + 10:
		var purge := _best_purge_move(state, options)
		if purge >= 0:
			return purge
	# 7. 接近最近的癌性组织
	if e >= 20:
		var approach := _best_approach(state, options, me)
		if approach >= 0:
			return approach
	return _find(options, "end")


func _antibody_target_count(state: Dictionary) -> int:
	var n := 0
	for c in ElmGame.living_cells(state, CWData.Faction.CANCER):
		for nb in CWData.neighbors(c["pos"]):
			if ElmGame.tile(state, nb)["tissue"] == CWData.Tissue.HEALTHY:
				n += 1
				break
	return n


## 攻击目标格里能量最低的敌人所在选项
func _best_attack(state: Dictionary, options: Array) -> int:
	var best := -1
	var best_energy := 999999
	for i in options.size():
		var d: Dictionary = options[i]["data"]
		if d["act"] != "move":
			continue
		var enemies: Array = ElmGame.cells_at(state, d["to"], CWData.Faction.CANCER)
		if enemies.is_empty():
			continue
		for en in enemies:
			if en["energy"] < best_energy:
				best_energy = en["energy"]
				best = i
	return best


## 可净化的相邻癌组织（无人、非固化），优先癌性邻格多的（顺着癌区推进）
func _best_purge_move(state: Dictionary, options: Array) -> int:
	var best := -1
	var best_score := -1
	for i in options.size():
		var d: Dictionary = options[i]["data"]
		if d["act"] != "move":
			continue
		var to: Vector2i = d["to"]
		if ElmGame.tile(state, to)["tissue"] != CWData.Tissue.CANCER:
			continue
		if not ElmGame.cells_at(state, to, CWData.Faction.CANCER).is_empty():
			continue
		var score := 0
		for n in CWData.neighbors(to):
			if ElmGame.is_cancerous(state, n):
				score += 1
		if score > best_score:
			best_score = score
			best = i
	return best


func _best_approach(state: Dictionary, options: Array, me: Dictionary) -> int:
	# 目标：无人癌性组织（树突：癌细胞的相邻格——它只能靠光环输出）
	var targets: Array[Vector2i] = []
	if me["itype"] == CWData.ImmuneType.DENDRITIC:
		for c in ElmGame.living_cells(state, CWData.Faction.CANCER):
			for n in CWData.neighbors(c["pos"]):
				if ElmGame.cells_at(state, n, CWData.Faction.CANCER).is_empty():
					targets.append(n)
	else:
		for c in state["tiles"].keys():
			if ElmGame.is_cancerous(state, c) \
					and ElmGame.cells_at(state, c, CWData.Faction.CANCER).is_empty():
				targets.append(c)
	if targets.is_empty():
		return -1
	var dist := _dist_map(targets, func(c: Vector2i) -> bool:
		return not ElmGame.cells_at(state, c, CWData.Faction.CANCER).is_empty())
	var now: int = dist.get(me["pos"], 9999)
	var best := -1
	var best_d := now  # 必须严格变近，否则原地攒能量
	for i in options.size():
		var d: Dictionary = options[i]["data"]
		if d["act"] != "move":
			continue
		if not ElmGame.cells_at(state, d["to"], CWData.Faction.CANCER).is_empty():
			continue  # 接近阶段不打架
		var nd: int = dist.get(d["to"], 9999)
		if nd < best_d:
			best_d = nd
			best = i
	return best


# ============ 癌症回合 ============

func _cancer_action(state: Dictionary, pid: int, options: Array) -> int:
	var me: Dictionary = ElmGame.cell_of(state, pid)
	var e: int = me["energy"]
	var threat := _dist_to_nearest_immune(state, me["pos"])
	# 1. 自爆：范围收益大且有复活据点时才引爆
	var i := _find(options, "blast")
	if i >= 0:
		var n: int = ElmActions._blast_targets(state, me).size()
		if n >= 6 and ElmGame.count_tissue(state, CWData.Tissue.SOLID) >= 1:
			return i
	# 2. 基质重塑：不挪窝就能占地
	i = _find(options, "remodel")
	if i >= 0 and e >= 25:
		return i
	# 3. 突变：免疫方有记忆可削时才赌
	i = _find(options, "mutate")
	if i >= 0 and e >= 30 and state["memory"] >= 2:
		return i
	# 4. 蹲点固化：安全时停在原地，把脚下癌组织熬成固化癌组织（复活据点+高供能）
	if threat >= 3 and _worth_solidifying(state, me):
		return _find(options, "end")
	# 5. 移动：安全 / 占地 / 前景 / 成本 统一打分
	var mv := _best_cancer_move(state, options, me, threat)
	if mv >= 0:
		return mv
	return _find(options, "end")


func _dist_to_nearest_immune(state: Dictionary, from: Vector2i) -> int:
	var best := 99
	for c in ElmGame.living_cells(state, CWData.Faction.IMMUNE):
		best = mini(best, CWData.hex_dist(from, c["pos"]))
	return best


## 脚下这格值不值得蹲：必须是能继续累计固化计数的癌组织
func _worth_solidifying(state: Dictionary, me: Dictionary) -> bool:
	var t: Dictionary = ElmGame.tile(state, me["pos"])
	if t["tissue"] != CWData.Tissue.CANCER or t["newborn"]:
		return false
	if t["solid"] >= state["tune"].solidify_threshold - 1:
		return true  # 差最后一轮就固化，值得停
	# 场上还没有任何复活据点时，值得从头熬一个
	return ElmGame.count_tissue(state, CWData.Tissue.SOLID) == 0


## 距免疫细胞不同距离的安全分。免疫每回合能连打 3 次（每次期望 0.83 伤害），
## 而癌细胞只有 3.0 能量：停在免疫身边基本等于送死，所以 1 格处是断崖式惩罚。
const SAFETY_BY_DIST := [-999, -40, -5, 6, 12]


## 癌细胞移动打分：安全（保命）+ 定殖健康组织（占地=收入=胜利条件）+ 扩张前景 − 能量成本
## threat = 当前距最近免疫细胞的距离，贴脸时连「原地不动」都要重新估值。
func _best_cancer_move(state: Dictionary, options: Array, me: Dictionary, _threat: int) -> int:
	var best := -1
	var best_score := -999999
	for i in options.size():
		var d: Dictionary = options[i]["data"]
		if d["act"] != "move":
			continue
		var to: Vector2i = d["to"]
		if me["energy"] < d["cost"] + 5:
			continue  # 留 0.5 储备，别把自己走到濒死
		var score: int = SAFETY_BY_DIST[mini(_dist_to_nearest_immune(state, to), 4)]
		if not ElmGame.is_cancerous(state, to):
			score += 15  # 定殖：永久 +1 格地盘，是癌方的核心收益
		for n in CWData.neighbors(to):
			if ElmGame.tile(state, n)["tissue"] == CWData.Tissue.HEALTHY:
				score += 2  # 前景：周围还有多少可扩张空间
		score -= d["cost"]
		if score > best_score:
			best_score = score
			best = i
	# 原地不动的价值（不花能量，但也不占地）；比它差的移动一律不做
	var stay_score: int = SAFETY_BY_DIST[mini(_dist_to_nearest_immune(state, me["pos"]), 4)]
	return best if best_score > stay_score else -1


# ============ 子询问 ============

func _pick_weakest(state: Dictionary, options: Array) -> int:
	var best := 0
	var best_energy := 999999
	for i in options.size():
		var cell: Dictionary = state["cells"][options[i]["data"]["cid"]]
		if cell["energy"] < best_energy:
			best_energy = cell["energy"]
			best = i
	return best


func _pick_differentiation(options: Array) -> int:
	# 优先级：T（拆固化+范围净化）> B（全场压制）> 巨噬（续航）> 树突（辅助）
	for want in [CWData.ImmuneType.T_CELL, CWData.ImmuneType.B_CELL,
			CWData.ImmuneType.MACRO, CWData.ImmuneType.DENDRITIC]:
		for i in options.size():
			if options[i]["data"]["type"] == want:
				return i
	return 0


func _pick_revive(state: Dictionary, options: Array) -> int:
	# options[0] 恒为「放弃」；有位置就复活，选癌性邻格最多的（回中心腹地）
	var best := 0
	var best_score := -1
	for i in range(1, options.size()):
		var c: Vector2i = options[i]["data"]["to"]
		var score := 0
		for n in CWData.neighbors(c):
			if ElmGame.is_cancerous(state, n):
				score += 1
		if score > best_score:
			best_score = score
			best = i
	return best


# ============ 工具 ============

func _find(options: Array, act: String) -> int:
	for i in options.size():
		if options[i]["data"].get("act", "") == act:
			return i
	return -1


func _dist_to_nearest_cancerous(state: Dictionary, from: Vector2i) -> int:
	var best := 99
	for c in state["tiles"].keys():
		if ElmGame.is_cancerous(state, c):
			best = mini(best, CWData.hex_dist(from, c))
	return best


## 多源 BFS：返回 每格→到最近目标的步数；blocked(c) 为 true 的格不可通行（目标本身除外）
func _dist_map(targets: Array[Vector2i], blocked: Callable) -> Dictionary:
	var dist := {}
	var queue: Array[Vector2i] = []
	for t in targets:
		if not dist.has(t):
			dist[t] = 0
			queue.append(t)
	var head := 0
	while head < queue.size():
		var cur: Vector2i = queue[head]
		head += 1
		for n in CWData.neighbors(cur):
			if dist.has(n) or blocked.call(n):
				continue
			dist[n] = dist[cur] + 1
			queue.append(n)
	return dist
