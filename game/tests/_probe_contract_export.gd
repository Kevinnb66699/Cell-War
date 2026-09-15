## 临时探针：导出「契约表」金标向量（纯函数级，不含 RNG / 不含流程）
## 运行：godot --headless --path game --script res://tests/_probe_contract_export.gd
extends SceneTree

const OUT := "user://contract_gd.json"


func _initialize() -> void:
	var g := CWGame.new()
	g.tune = CWTuning.new()
	g.init(CWData.FACTION_ORDER[4], 4242)

	var out := {}

	# 1) 攻击判定：骰面 × 装备 → 判词（纯函数，C# 侧是 RulePolicies.AttackOutcome）
	var cell: Dictionary = g.cells[0]
	var rows: Array = []
	for synapse in [false, true]:
		cell["equipped"] = ["免疫突触成熟"] if synapse else []
		for r in range(0, 8):
			rows.append({"roll": r, "synapse": synapse, "verdict": g.actions.base_verdict(r, cell)})
	cell["equipped"] = []
	out["attack_verdict"] = rows

	# 2) 按人数分档的数值表
	var by_players: Array = []
	for n in [2, 4, 6]:
		by_players.append({
			"n": n,
			"init_cancer_tiles": CWData.init_cancer_tiles(n),
			"level_min_memory": CWData.level_min_memory(n),
			"aerobic_level_base": CWData.aerobic_level_base(n),
			"anaerobic_block_coef": CWData.anaerobic_block_coef(n),
			"anaerobic_block_exp": CWData.anaerobic_block_exp(n),
		})
	out["by_players"] = by_players

	# 3) 连通块人数系数
	var k: Array = []
	for n in range(1, 6):
		k.append({"cells": n, "k_percent": CWData.anaerobic_cells_k(n)})
	out["anaerobic_cells_k"] = k

	# 4) 抗体递减（C# 侧 RulePolicies.AntibodyDamage）
	var ab: Array = []
	for used in range(0, 5):
		ab.append({"used": used, "tenths": CWData.ANTIBODY_DAMAGE >> used})
	out["antibody_damage"] = ab

	# 5) 取整口径（C# 侧 Settlement.RoundTenth）
	var rt: Array = []
	for pair in [[5, 2], [7, 2], [-5, 2], [1, 3], [2, 3], [100, 7], [0, 3], [15, 4]]:
		rt.append({"num": pair[0], "den": pair[1], "out": CWData.round_tenth(pair[0], pair[1])})
	out["round_tenth"] = rt

	# 6) 棋盘布局契约：127 格 → 特殊格类型
	var board: Array = []
	for c in CWData.all_coords():
		board.append({"q": c.x, "r": c.y, "special": int(CWData.special_of(c))})
	out["board_special"] = board

	# 7) 环大小 / 距离
	var ring: Array = []
	for n in range(0, 4):
		ring.append({"n": n, "size": CWData.ring(Vector2i(0, 0), n).size()})
	out["ring_size"] = ring

	# 8) 世界事件回合
	var we: Array = []
	for r in range(1, 16):
		we.append({"round": r, "is_event": CWData.is_world_event_round(r)})
	out["world_event_round"] = we

	var f := FileAccess.open(OUT, FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "  "))
	f.close()
	print("written: ", ProjectSettings.globalize_path(OUT))
	g.dispose()
	quit(0)
