extends SceneTree
## 复现：【基质硬化】对脚下的格子使用无效（团队 2026-09-05 实测报告）
## 合成的最简场景是**正常**的，所以逐个试真实局面里脚下那格可能处于的状态。
##   godot --headless --path game --script res://tests/repro_stroma.gd

var _g: CWGame


func _make(setup: Callable) -> Array:
	_g = CWGame.new()
	_g.init(CWData.FACTION_ORDER[2], 1)
	_g.setup.build_board()
	var here := Vector2i(0, 0)
	_g.tiles[here]["tissue"] = CWData.Tissue.CANCER
	for d in CWData.DIRS:
		_g.tiles[here + d]["tissue"] = CWData.Tissue.CANCER
	var cell := CWSetup.make_cell(0, 0, CWData.Faction.CANCER, here, -1,
		CWData.CancerType.MELANOMA)
	cell["energy"] = 500
	cell["hand"] = ["基质硬化"]
	_g.cells.append(cell)
	setup.call(_g, cell, here)
	var opts: Array = []
	_g.card_fx.hand_options(cell, opts)
	var own := false
	for o in opts:
		if o["data"].get("to") == here:
			own = true
	return [cell, here, own, opts.size()]


func _report(name: String, r: Array) -> void:
	var here: Vector2i = r[1]
	print("【%s】脚下选项：%s（共 %d 个目标） tissue=%d newborn=%s solid=%d" % [
		name, "有" if r[2] else "★没有★", r[3], _g.tiles[here]["tissue"],
		str(_g.tiles[here]["newborn"]), _g.tiles[here]["solid"]])


func _initialize() -> void:
	var r := _make(func(_g2, _c, _h) -> void: pass)
	_report("基准：脚下普通癌组织", r)
	var before: int = _g.tiles[r[1]]["solid"]
	await _g.card_fx.play(r[0], { "act": "play", "card": "基质硬化", "to": r[1] })
	print("      结算后 solid %d → %d" % [before, _g.tiles[r[1]]["solid"]])
	_g.dispose()

	_report("脚下已是固化癌组织", _make(func(g, _c, h) -> void:
		g.tiles[h]["tissue"] = CWData.Tissue.SOLID))
	_g.dispose()

	_report("脚下是「新生」（刚定殖）", _make(func(g, _c, h) -> void:
		g.tiles[h]["newborn"] = true))
	_g.dispose()

	_report("脚下被 TNF-α 冻结", _make(func(g, _c, h) -> void:
		g.events["active"].append({ "name": "TNF-α局部炎症", "stacks": 1,
			"left": 1, "data": { h: true } })))
	var r4 := _make(func(g, _c, h) -> void:
		g.events["active"].append({ "name": "TNF-α局部炎症", "stacks": 1,
			"left": 1, "data": { h: true } }))
	var b4: int = _g.tiles[r4[1]]["solid"]
	await _g.card_fx.play(r4[0], { "act": "play", "card": "基质硬化", "to": r4[1] })
	print("      冻结时结算后 solid %d → %d" % [b4, _g.tiles[r4[1]]["solid"]])
	_g.dispose()

	## 计数已经很高：+1.0 一步跨过阈值 → 当场转固化，玩家可能以为「没生效」
	var r5 := _make(func(g, _c, h) -> void:
		g.tiles[h]["solid"] = g.tune.solidify_threshold - 5)
	var b5: int = _g.tiles[r5[1]]["solid"]
	await _g.card_fx.play(r5[0], { "act": "play", "card": "基质硬化", "to": r5[1] })
	print("【差一点到阈值】solid %d → %d，tissue=%d（2=固化）" % [
		b5, _g.tiles[r5[1]]["solid"], _g.tiles[r5[1]]["tissue"]])
	_g.dispose()

	quit(0)
