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
func evaluate_path(g: CWGame, pid: int, path: Array) -> Dictionary:
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
	var metrics := _read_metrics(g, pid)
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
func _read_metrics(g: CWGame, pid: int) -> Dictionary:
	var faction: int = g.player(pid)["faction"]
	var ct: int = g.count_tissue(CWData.Tissue.CANCER)
	var st: int = g.count_tissue(CWData.Tissue.SOLID)
	var imm_energy := 0
	var can_energy := 0
	for c in g.living_cells(CWData.Faction.IMMUNE):
		imm_energy += int(c["energy"])
	for c in g.living_cells(CWData.Faction.CANCER):
		can_energy += int(c["energy"])
	return {
		"faction": faction, "round_no": g.round_no,
		"cancer_supply": MechValue.total_supply(g),
		"cancer_tiles": ct, "solid_tiles": st,
		"win_progress": ct + 2 * st,
		"immune_level": g.immune_level, "memory": g.memory,
		"immune_energy": imm_energy, "cancer_energy": can_energy,
		"state_hash": g.state_hash(),
	}
