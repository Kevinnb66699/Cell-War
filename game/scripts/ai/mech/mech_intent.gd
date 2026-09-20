## mech_intent.gd —— 意图评估器骨架：把「我要做一件事」变成可执行的计划并评估
##
## 背景（2026-09-20 讨论）：
##   · 人类一回合 = 2~3 个「意图」（我要去踩这几格/净化这几格/跳过去成两块），
##     每个意图由一串原子动作组成；意图的价值 = 「做完之后的地图和能量」。
##   · 迁移会触发净化/定殖/攻击/特殊组织效果，所以**迁移路径是意图的最基本载体**——
##     本骨架先支持「一串迁移目标」，技能/卡牌等后续再加。
##   · 评估方式：在引擎副本上按序执行路径（引擎是唯一权威），读最终局面的杠杆读数，
##     然后**复原真局面**（评估不改动游戏）。这与 monte_carlo_bridge 同思路：
##     快照 → 试走 → 读数 → 回滚。
##
## ⚠ 本类方法含 await（pending/step 是协程），所以是实例方法而不是静态函数。
## ⚠ 执行时**不允许**出现「假执行」：找不到选项就失败（ok=false），绝不静默跳过。
##   读数是 MechValue 的引擎逐位对拍过的函数（total_supply 等）+ 引擎直接计数。
class_name MechIntent
extends RefCounted


## 在 g（须为 pending 边界）上按序执行 pid 的迁移路径，返回「做完之后的地图和能量」读数，
## 然后复原 g。path: Array[Vector2i]（cell 的下一个落点）。
## 返回 Dictionary：{ ok, steps_done, faction, round_no,
##   cancer_supply, cancer_tiles, solid_tiles, win_progress,
##   immune_level, memory, immune_energy, cancer_energy, state_hash }
func evaluate_path(g: CWGame, pid: int, path: Array, with_hash := false) -> Dictionary:
	var snap := g.snapshot()
	var steps := 0
	var ok := true
	for to in path:
		var req: Dictionary = await g.pending()
		if req.is_empty():
			ok = false
			break
		if int(req["pid"]) != pid:
			break   ## 换人/换阶段：该席回合已结束，路径执行完毕（不视为失败）
		var idx := _find_move(req, to)
		if idx < 0:
			ok = false
			break
		await g.step(idx)
		steps += 1
	## state_hash 全盘编码+HASH（O(board)），热路径逐候选算极贵且两个 scorer 都不用 →
	## 默认跳过（快 64%），需要时（回放/排错）以 with_hash=true 单独取一次。
	var metrics := _read_metrics(g, pid, with_hash)
	metrics["ok"] = ok
	metrics["steps_done"] = steps
	g.restore(snap)
	return metrics


## 在 req.options 里找「迁移到 to」的选项下标；没有返回 -1。
func _find_move(req: Dictionary, to: Vector2i) -> int:
	for i in req["options"].size():
		var d: Dictionary = req["options"][i]["data"]
		if d.get("act", "") == "move" and d.get("to", Vector2i(-999, -999)) == to:
			return i
	return -1


## 最终局面的杠杆读数：「做完之后的地图和能量」。
## 除全局量外，加**行动细胞局部读数**（评估后 = 做完后的状态）：
##   actor_energy：行动细胞能量（生存）；actor_solid_rounds：所在格到固化还需几回合（-1 = 非癌格）；
##   actor_min_immune_dist：到最近免疫的距离（威胁，越小越危险）。
func _read_metrics(g: CWGame, pid: int, with_hash := false) -> Dictionary:
	var faction: int = g.player(pid)["faction"]
	var ct: int = g.count_tissue(CWData.Tissue.CANCER)
	var st: int = g.count_tissue(CWData.Tissue.SOLID)
	var imm_energy := 0
	var can_energy := 0
	for c in g.living_cells(CWData.Faction.IMMUNE):
		imm_energy += int(c["energy"])
	for c in g.living_cells(CWData.Faction.CANCER):
		can_energy += int(c["energy"])
	## 行动细胞（该 pid 第一只活细胞；评估后位置 = 最后落点）
	var actor := {}
	for c in g.cells:
		if c["alive"] and int(c["pid"]) == pid:
			actor = c
			break
	var actor_energy := 0
	var actor_solid_rounds := -1
	var actor_min_immune_dist := 999
	if not actor.is_empty():
		actor_energy = int(actor["energy"])
		var ap: Vector2i = actor["pos"]
		if g.tiles[ap]["tissue"] == CWData.Tissue.CANCER:
			actor_solid_rounds = MechValue.rounds_to_solidify(
				int(g.tiles[ap]["solid"]), MechValue.solidify_threshold(g))
		for im in g.living_cells(CWData.Faction.IMMUNE):
			actor_min_immune_dist = mini(actor_min_immune_dist, CWData.hex_dist(ap, im["pos"]))
	## —— 战略读数（癌方「追杀免疫 + 踩骨髓」的度量）——
	## 癌方没有走过去攻击的对称机制，减免疫能量靠【微环境压迫】（E 阶段被动）。
	## 所以「追杀」= 让免疫被回合末压迫压死：用引擎 pressure_lethal 逐只判（含护盾减免）。
	## 读的是「此刻盘面」的压迫 —— 评估路径试走后盘面已含定殖转化，是真实下界。
	var immune_alive := 0
	var cancer_alive := 0
	var immune_pressure_total := 0
	var immune_lethal_count := 0
	var min_immune_energy := 0
	var first_immune := true
	for im in g.living_cells(CWData.Faction.IMMUNE):
		immune_alive += 1
		immune_pressure_total += g.world.pressure_at(im["pos"])
		if g.world.pressure_lethal(im):
			immune_lethal_count += 1
		var e: int = int(im["energy"])
		if first_immune or e < min_immune_energy:
			min_immune_energy = e
			first_immune = false
	cancer_alive = g.living_cells(CWData.Faction.CANCER).size()
	## 骨髓控制：健康骨髓 = 免疫复活点；癌化/固化 = 封掉复活点
	var healthy_marrows := 0
	var cancer_marrows := 0
	for mc in CWData.MARROWS:
		var mt: int = int(g.tiles[mc]["tissue"])
		if mt == CWData.Tissue.HEALTHY:
			healthy_marrows += 1
		elif mt == CWData.Tissue.CANCER or mt == CWData.Tissue.SOLID:
			cancer_marrows += 1
	return {
		"faction": faction, "round_no": g.round_no,
		"cancer_supply": MechValue.total_supply(g),
		"cancer_tiles": ct, "solid_tiles": st,
		"win_progress": ct + 2 * st,
		"immune_level": g.immune_level, "memory": g.memory,
		"immune_energy": imm_energy, "cancer_energy": can_energy,
		"actor_energy": actor_energy,
		"actor_solid_rounds": actor_solid_rounds,
		"actor_min_immune_dist": actor_min_immune_dist,
		"immune_alive": immune_alive,
		"cancer_alive": cancer_alive,
		"immune_pressure_total": immune_pressure_total,
		"immune_lethal_count": immune_lethal_count,
		"min_immune_energy": min_immune_energy,
		"healthy_marrows": healthy_marrows,
		"cancer_marrows": cancer_marrows,
		"state_hash": g.state_hash() if with_hash else "",
	}


## —— 意图候选生成与选择（意图级规划闭环）——

## 生成当前行动方的迁移候选路径（从 pending 的合法 move 目标）。
## **第一项永远是「不动」（空路径）**：评估器必须能说「这个局面下任何迁移都不如站着」，
## 让桥只在「动了更好」时接管，否则回落启发式（攻击/卡牌/结束回合交给它）。
## 默认生成 1 步 + **2 步**候选（回合内计划：走过去→蹲固化/踩核心/继续扩）：
## 对每个 1 步目标试走一步（快照→step→恢复），取可达的下一步目标前 K 个。
## 返回 Array[Array[Vector2i]]。
func candidates(g: CWGame, pid: int, max_steps := 2) -> Array:
	var req: Dictionary = await g.pending()
	if req.is_empty() or int(req["pid"]) != pid:
		return []
	var out: Array = [[]]   ## 不动基线
	var one_step: Array = []
	for opt in req["options"]:
		if opt["data"].get("act", "") == "move":
			one_step.append(opt["data"]["to"])
	for t in one_step:
		out.append([t])
	if max_steps < 2:
		return out
	## 2 步：对每个 1 步目标试走一步，取下一步可达目标前 K 个（控制候选数）
	for to1 in one_step:
		var idx := _find_move(req, to1)
		if idx < 0:
			continue
		var snap := g.snapshot()
		await g.step(idx)
		var req2: Dictionary = await g.pending()
		var second: Array = []
		if not req2.is_empty() and int(req2["pid"]) == pid:
			for opt in req2["options"]:
				if opt["data"].get("act", "") == "move":
					second.append(opt["data"]["to"])
		g.restore(snap)
		for to2 in second.slice(0, SECOND_STEP_MAX):
			out.append([to1, to2])
	return out


## 每个 1 步目标最多展开的 2 步分支数（控候选数防爆炸；评估成本 ×~2）。
const SECOND_STEP_MAX := 3


## 评估全部候选（每个 = { path, metrics }），评估后真局面复原。
func evaluate_candidates(g: CWGame, pid: int) -> Array:
	var cands: Array = await candidates(g, pid)
	var out: Array = []
	for path in cands:
		var m: Dictionary = await evaluate_path(g, pid, path)
		out.append({ "path": path, "metrics": m })
	return out


## 按注入的 scorer（metrics → float）选得分最高的候选。
## 返回 { path, metrics, score }；空候选集返回空字典。
func best_by(g: CWGame, pid: int, scorer: Callable) -> Dictionary:
	var evals: Array = await evaluate_candidates(g, pid)
	var best: Dictionary = {}
	var best_score := -INF
	for e in evals:
		var s: float = float(scorer.call(e["metrics"]))
		if s > best_score:
			best_score = s
			best = e.duplicate(true)
	best["score"] = best_score
	return best


# ==================== alpha-beta 搜索（意图级，2026-09-20） ====================
##
## 设计（三轮实测定位后的架构，见 mech_bridge 实锤记录）：
##   · 节点 = 一个细胞的**整回合计划**（候选由 candidates() 生成 = 动作知识层）；
##   · 叶估值 = MechValue.position_eval / position_eval_linear（预测器本职：评走完后的局面）；
##   · 免疫节点取 max、癌节点取 min（E 零和），深度 D = 往后看的席位数；
##   · 引擎快照→试走→读数→回滚（evaluate_path 已有），完全确定、可复现。
##
## 为什么是 alpha-beta 不是 MCTS：有验证过的估值函数（MCTS 反而用不上）+ 引擎滚整局太贵
## （MCTS 需成百上千次完整模拟，深度 2 的 alpha-beta 只需 K² 次叶评估）+ 项目要确定性。

## alpha-beta 主入口 v2：叶 = 【回合边界】（2026-09-20 epd 实验后的关键改动）。
## 原因：压迫出伤的因果链（包围 → E阶段结算 → 能量掉/死 → ia降）**结构性地落在
## 「走1-2步就评」的所有线之外**——静态叶永远看不见结算瞬间；而估值（训练分布=回合
## 边界）本来就认识"死了"（ia +3.6, 5/5）。把叶推到回合边界 = 压迫链进视野
## + 叶回到训练分布 + 其余席位的应对顺带完成（image 内各席桥作答）。
## 值统一在【搜索方视角】（leaf_eval 由桥按搜索方阵营翻号一次），节点 max/min 按行动方阵营。
func search_best(g: CWGame, pid: int, leaf_eval: Callable, depth := 2, top_k := 4) -> Dictionary:
	## 候选取**单步**：叶会把本回合剩余部分(含E阶段)整个模拟掉，计划只需选"下一手"——
	## 多步候选的额外分支在整回合模拟面前没有增量信息，只烧时间。
	var cands: Array = await candidates(g, pid, 1)
	var quick := MechBridge._cancer_score if g.player(pid)["faction"] == CWData.Faction.CANCER 		else MechBridge._immune_score
	var scored: Array = []
	for path in cands:
		var m: Dictionary = await evaluate_path(g, pid, path)
		scored.append({ "path": path, "q": float(quick.call(m)) })
	scored.sort_custom(func(a, b): return float(a["q"]) > float(b["q"]))
	if scored.size() > top_k:
		scored = scored.slice(0, top_k)
	var my_fac: int = g.player(pid)["faction"]
	var alpha := -INF
	var best: Dictionary = {}
	for c in scored:
		var snap: Dictionary = g.snapshot()
		var v: float = await _ab_line(g, pid, c["path"], my_fac, depth, alpha, INF, leaf_eval)
		g.restore(snap)
		if v > alpha or best.is_empty():
			alpha = v
			best = { "path": c["path"], "score": v }
	## 把最优线的**完整执行序列**抓下来（第一手 + 叶模拟里本席位的后续动作，
	## 含卡牌/pick/结束）交回桥缓存：同回合后续询问直接执行、不再重搜。
	## 根因修复（2026-09-20 人机实测）：每问重搜 + 假设"剩余由启发式打完"，但真实
	## 执行者是下一轮搜索 → 等值格之间互相追逐 = 无意义走动。执行 = 评估，搜索才诚实。
	var plan: Array = []
	if best.has("path") and best["path"].size() > 0:
		plan.append({ "kind": "action", "data": { "act": "move", "to": best["path"][0] } })
	var snap2: Dictionary = g.snapshot()
	var rec: Array = []
	await _ab_line(g, pid, best.get("path", []), my_fac, 1, -INF, INF, leaf_eval, rec)
	g.restore(snap2)
	plan.append_array(rec)
	best["plan"] = plan
	return best


## 一条线：落地 path → 推进到回合边界（其余席位+E阶段全结算）→ depth>1 则边界上的
## 下一席再选计划再推进 → 叶读数。值全在搜索方视角。
func _ab_line(g: CWGame, actor: int, path: Array, my_fac: int, depth: int,
		alpha: float, beta: float, leaf_eval: Callable, record = null) -> float:
	await _play_path(g, actor, path)
	var req: Dictionary = await _drive_to_round_end(g, record, actor)
	if depth <= 1 or req.is_empty():
		var m: Dictionary = _read_metrics(g, int(req.get("pid", actor)), false)
		return float(leaf_eval.call(m))
	var nxt: int = int(req["pid"])
	var nxt_fac: int = g.player(nxt)["faction"]
	var maximizing := nxt_fac == my_fac   ## 同阵营=友军节点也取 max（6人交错序必需）
	var sub: Array = await candidates(g, nxt)
	var quick := MechBridge._cancer_score if nxt_fac == CWData.Faction.CANCER 		else MechBridge._immune_score
	var subs: Array = []
	for p in sub:
		var m: Dictionary = await evaluate_path(g, nxt, p)
		subs.append({ "path": p, "q": float(quick.call(m)) })
	subs.sort_custom(func(a, b): return (float(a["q"]) > float(b["q"])) if maximizing 		else (float(a["q"]) < float(b["q"])))
	if subs.size() > OPP_TOP_K():
		subs = subs.slice(0, OPP_TOP_K())
	var best_v := -INF if maximizing else INF
	for sc in subs:
		var snap: Dictionary = g.snapshot()
		var v: float = await _ab_line(g, nxt, sc["path"], my_fac, depth - 1, alpha, beta, leaf_eval)
		g.restore(snap)
		if maximizing:
			best_v = maxf(best_v, v); alpha = maxf(alpha, v)
		else:
			best_v = minf(best_v, v); beta = minf(beta, v)
		if beta <= alpha:
			break
	return best_v


## 按序落地一条迁移路径（限本席位内；局面变了就地停，不视为失败）。
func _play_path(g: CWGame, pid: int, path: Array) -> void:
	for to in path:
		var req: Dictionary = await g.pending()
		if req.is_empty() or int(req["pid"]) != pid:
			return
		var idx := _find_move(req, to)
		if idx < 0:
			return
		await g.step(idx)


## 步进到本回合结束（其余席位按 image 内各自的桥作答 + E 阶段结算），
## 返回**跨入下一回合后的第一个询问**（= 回合边界，叶读数点）；终局返回空。
func _drive_to_round_end(g: CWGame, record = null, watch_pid: int = -1) -> Dictionary:
	var r0: int = g.round_no
	var guard := 0
	while guard < 240:
		guard += 1
		var req: Dictionary = await g.pending()
		if req.is_empty():
			return {}
		if int(g.round_no) != r0:
			return req
		var idx: int = await g.ask(req["pid"], req)
		## 录制 watch_pid 的每一步语义（move/play/pick/end…）——回放最优线时用，
		## 交给桥缓存执行：执行 = 叶评估时模拟的那条序列，计划-执行不再脱节。
		if record != null and int(req["pid"]) == watch_pid and idx < req["options"].size():
			record.append({ "kind": str(req["kind"]),
				"data": req["options"][idx]["data"] })
		await g.step(idx)
	return {}


## 对手节点的候选数（对手建模可以比己方粗糙——控成本）。
static func OPP_TOP_K() -> int:
	return 3
