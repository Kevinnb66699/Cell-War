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

## alpha-beta 主入口：为 pid 选「考虑对手最优应对后」最优的整回合计划。
## 返回 { path, score }；leaf_eval(metrics)->float 由桥注入（含阵营翻号）。
## depth = 往后看的席位数（1 = 只看自己，2 = 自己+下一席应对）。
func search_best(g: CWGame, pid: int, leaf_eval: Callable, depth := 2, top_k := 6) -> Dictionary:
	var cands: Array = await candidates(g, pid)
	## 用动作知识层（旧手拍式快评）给候选**排序**——alpha-beta 剪枝效率全靠好序
	var quick := MechBridge._cancer_score if g.player(pid)["faction"] == CWData.Faction.CANCER \
		else MechBridge._immune_score
	var scored: Array = []
	for path in cands:
		var m: Dictionary = await evaluate_path(g, pid, path)
		scored.append({ "path": path, "metrics": m, "q": float(quick.call(m)) })
	scored.sort_custom(func(a, b): return float(a["q"]) > float(b["q"]))
	if scored.size() > top_k:
		scored = scored.slice(0, top_k)
	var alpha := -INF
	var best: Dictionary = {}
	for c in scored:
		var snap: Dictionary = g.snapshot()
		var v: float = await _ab_recurse(g, pid, c, leaf_eval, depth - 1, alpha, INF)
		g.restore(snap)
		if v > alpha or best.is_empty():
			alpha = v
			best = { "path": c["path"], "score": v }
	return best


## 递归：己方计划 c 已在盘上（调用方负责快照），继续往下 depth-1 席。
## 下一席 = 引擎行动顺序里 pid 之后的下一个活席位（min/max 按其阵营）。
func _ab_recurse(g: CWGame, pid: int, c: Dictionary, leaf_eval: Callable, depth: int, alpha: float, beta: float) -> float:
	## 落地当前计划（真走，不回滚——回滚由最外层统一做）
	var played := true
	for to in c["path"]:
		var req: Dictionary = await g.pending()
		if req.is_empty() or int(req["pid"]) != pid:
			played = false
			break
		var idx := _find_move(req, to)
		if idx < 0:
			played = false
			break
		await g.step(idx)
	if depth <= 0 or not played:
		return float(leaf_eval.call(c["metrics"]))
	## 下一席：顺序里 pid 之后第一个活席
	var nxt := -1
	var n := g.order.size()
	for k in range(1, n + 1):
		var q: int = g.order[(g.order.find(pid) + k) % n]
		if g.player(q)["faction"] >= 0:
			nxt = q
			break
	if nxt < 0:
		return float(leaf_eval.call(c["metrics"]))
	var nxt_fac: int = g.player(nxt)["faction"]
	var maximizing := nxt_fac == CWData.Faction.IMMUNE
	var sub: Array = await candidates(g, nxt)
	var quick := MechBridge._cancer_score if nxt_fac == CWData.Faction.CANCER \
		else MechBridge._immune_score
	var subs: Array = []
	for path in sub:
		var m: Dictionary = await evaluate_path(g, nxt, path)
		subs.append({ "path": path, "metrics": m, "q": float(quick.call(m)) })
	subs.sort_custom(func(a, b): return (float(a["q"]) > float(b["q"])) if maximizing else (float(a["q"]) < float(b["q"])))
	if subs.size() > top_k_const():
		subs = subs.slice(0, top_k_const())
	var best_v := -INF if maximizing else INF
	for sc in subs:
		var snap2: Dictionary = g.snapshot()
		var v: float = await _ab_recurse(g, nxt, sc, leaf_eval, depth - 1, alpha, beta)
		g.restore(snap2)
		if maximizing:
			best_v = maxf(best_v, v)
			alpha = maxf(alpha, v)
		else:
			best_v = minf(best_v, v)
			beta = minf(beta, v)
		if beta <= alpha:
			break
	return best_v


static func top_k_const() -> int:
	return 6
