## repro_revive.gd —— 复现「癌细胞原地固化 → 被打死 → 再也不复活」
##
## 队友 2026-08-31 报的现象：癌细胞一直待在一格不动（按规则那格会固化），
## 结果它死掉之后一直没有复活。
##
## 跑：godot --headless --path game --script res://tests/repro_revive.gd
extends SceneTree


func _initialize() -> void:
	_run()


func _run() -> void:
	var g := CWGame.new()
	g.init([CWData.Faction.IMMUNE, CWData.Faction.CANCER], 20260901)
	for pid in g.order:
		var b := CWHeuristicBridge.new()
		b.game = g
		g.bridges[pid] = b
	g.setup.begin()

	## 摆一个最小局面：癌细胞待在中央那格不动，免疫细胞就在隔壁
	var lair := Vector2i(0, 0)
	var next_to := Vector2i(1, 0)
	g.setup.place(0, next_to)      # 免疫
	g.setup.place(1, lair)         # 癌症
	g.setup.finish()
	var immune: Dictionary = g.cell_of(0)
	var cancer: Dictionary = g.cell_of(1)
	print("开局：免疫 @%s，癌症 @%s（%s）" % [
		str(immune["pos"]), str(cancer["pos"]),
		CWData.TISSUE_NAMES[g.tile(lair)["tissue"]]])

	## ① 原地不动，等它固化。固化是 E 阶段结算的，一格每回合 +1.0，门槛 3.0。
	## 免疫先灌满能量：它贴在癌组织堆里，不然三个回合的【微环境压迫】就把它压死了，
	## 攻击那一步根本走不到（第一版脚本就是这么翻车的）。
	immune["energy"] = 9999
	for i in 4:
		await g.world.e_phase()
		print("  第 %d 次 E 阶段后：%s 固化计数 %s，组织 %s" % [
			i + 1, str(lair), CWData.fmt(g.tile(lair)["solid"]),
			CWData.TISSUE_NAMES[g.tile(lair)["tissue"]]])
		if g.tile(lair)["tissue"] == CWData.Tissue.SOLID:
			break
	var solidified: bool = g.tile(lair)["tissue"] == CWData.Tissue.SOLID
	print("① 固化成功？ %s" % ("是" if solidified else "否"))

	## ② 免疫攻过去把它打死。能量压到 0.1，一次成功就够；掷骰不确定，所以循环到死为止。
	cancer["energy"] = 1
	var tries := 0
	while cancer["alive"] and tries < 30:
		tries += 1
		await g.actions.execute(immune, { "act": "move", "to": lair, "cost": 0 })
	for line in g.logs.slice(maxi(g.logs.size() - 12, 0)):
		print("   log| " + line)
	print("② 癌细胞死了？ %s（打了 %d 次）｜免疫现在站在 %s｜%s 现在是 %s" % [
		"是" if not cancer["alive"] else "否", tries, str(immune["pos"]),
		str(lair), CWData.TISSUE_NAMES[g.tile(lair)["tissue"]]])

	## ③ 下一个世界回合的 S 阶段，问它复活落点 —— 这才是队友看到的那一步
	var opts: Array = g.world.revive_options_cancer(1)
	print("③ 复活选项 %d 个：%s" % [opts.size(), str(opts)])
	if opts.is_empty():
		print("   ⇒ 复现了：没有任何复活落点，流程会**静默跳过**这个玩家")
		var solid_tiles: Array = []
		for c in g.tiles:
			if g.tiles[c]["tissue"] == CWData.Tissue.SOLID:
				solid_tiles.append("%s（占据者：%s）" % [str(c),
					"无" if g.cells_at(c).is_empty() else g.cell_name(g.cells_at(c)[0])])
		print("   场上固化癌组织：%s" % ("无" if solid_tiles.is_empty() else ", ".join(solid_tiles)))

	## ④ 把免疫挪开，看是不是就能复活了 —— 用来确认「挡路」就是原因
	await g.actions.enter_tile(immune, Vector2i(2, 0))
	var opts2: Array = g.world.revive_options_cancer(1)
	print("④ 免疫让开之后，复活选项 %d 个" % opts2.size())

	g.dispose()
	quit(0)
