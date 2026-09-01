## repro_macro_loop.gd —— 复现队友 2026-09-01 报的「巨噬细胞可以无穷动」
##
## 跑：godot --headless --path game --script res://tests/repro_macro_loop.gd
extends SceneTree


func _initialize() -> void:
	_run()


func _run() -> void:
	for combo in [[], ["组织浸润"], ["LFA-1黏附"]]:
		for lv in [0, 2, 3]:
			_walk(combo, lv)
	quit(0)


## 让一个巨噬细胞沿着一条癌组织走廊一直走，看能量是涨是跌
func _walk(skills: Array, level_idx: int) -> void:
	var g := CWGame.new()
	g.init([CWData.Faction.IMMUNE, CWData.Faction.CANCER], 1)
	g.setup.build_board()
	## 铺一条横穿棋盘的癌组织走廊
	for q in range(-6, 7):
		if g.tiles.has(Vector2i(q, 0)):
			g.tiles[Vector2i(q, 0)]["tissue"] = CWData.Tissue.CANCER
	var cell := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(-6, 0),
		CWData.ImmuneType.MACRO, -1)
	cell["equipped"] = skills.duplicate()
	cell["energy"] = 100
	g.cells.append(cell)
	## 免疫等级由抗原记忆决定，直接把记忆顶到该等级的门槛
	g.memory = CWData.LEVEL_MIN_MEMORY[level_idx]

	var start: int = cell["energy"]
	var steps := 0
	for q in range(-5, 7):
		var to := Vector2i(q, 0)
		var cost: int = g.actions._move_cost_mod(cell, to, g.actions._move_base_cost(cell, to))
		if not g.can_pay(cell, cost):
			break
		await g.actions._do_move(cell, to, cost)
		steps += 1
	print("等级 %s｜技能 %-12s｜走 %2d 格｜能量 %s → %s（%s）" % [
		["I", "II", "III", "X"][level_idx],
		"、".join(skills) if not skills.is_empty() else "无",
		steps, CWData.fmt(start), CWData.fmt(cell["energy"]),
		"每格净赚 %s ⚠ 无穷动" % CWData.fmt((cell["energy"] - start) / maxi(steps, 1))
			if cell["energy"] >= start else
			"每格净花 %s" % CWData.fmt((start - cell["energy"]) / maxi(steps, 1))])
	g.dispose()
