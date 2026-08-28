## elm_migrate_test.gd —— 迁移验证：cw_setup（真实） vs ElmSetup（迁移版）行为等价
##
## 方法：同种子 12345、4 人局、同一决策（DummyBridge 恒返回 0），
## 真实 g.setup.run() 与迁移版 ElmShell.run_to_setup() 各自跑完，
## 逐项对比 tiles / cells / players.cancer_type / rng_state。
## 若全等 → 迁移版与真实逻辑等价（rng 复刻 + 纯函数化成立）。
extends SceneTree


class DummyBridge:
	extends CWBridge

	func ask(_req: Dictionary) -> int:
		return 0


func _init():
	print("========================================")
	print("  迁移验证 1：cw_setup -> ElmSetup 行为等价")
	print("========================================")
	await _run()
	quit()


func _run() -> void:
	var seed_value := 12345
	var faction_list: Array = CWData.FACTION_ORDER[4]

	# ---- 真实基准（返回 0 的桥，隔离桥差异，只比逻辑）----
	var g := CWGame.new()
	g.init(faction_list, seed_value)
	for pid in g.order:
		g.bridges[pid] = DummyBridge.new()
	await g.setup.run()

	# ---- 迁移版 ----
	var shell := ElmShell.new()
	shell.bridge = DummyBridge.new()
	var mr := shell.run_to_setup(seed_value, faction_list, CWTuning.new())
	var s: Dictionary = mr["state"]

	var ok := true
	var why := ""

	# 1) rng_state
	var rng_ok: bool = int(g.rng.state) == int(s["rng_state"])
	if not rng_ok:
		ok = false
		why = "rng_state: %d vs %d" % [g.rng.state, s["rng_state"]]
	print("  1) rng_state 一致: %s (%d)" % [rng_ok, s["rng_state"]])

	# 2) tiles 逐格
	var tile_mismatch := 0
	for c in g.tiles:
		var a: Dictionary = g.tiles[c]
		var b: Dictionary = s["tiles"][c]
		if a["tissue"] != b["tissue"] or a["solid"] != b["solid"] or a["sticky"] != b["sticky"] \
				or a["newborn"] != b["newborn"] or a["store"] != b["store"] \
				or a["cards"] != b["cards"] or a["prod"] != b["prod"] or a["special"] != b["special"]:
			tile_mismatch += 1
			if tile_mismatch <= 3:
				why = "tile %s: %s vs %s" % [str(c), a, b]
	if tile_mismatch > 0:
		ok = false
	print("  2) tiles 逐格一致: %s (%d 格不匹配)" % [tile_mismatch == 0, tile_mismatch])

	# 3) cells 逐 cell
	var cell_mismatch := 0
	if g.cells.size() != s["cells"].size():
		ok = false
		why = "cells 数量: %d vs %d" % [g.cells.size(), s["cells"].size()]
		print("  3) cells 数量一致: false (%d vs %d)" % [g.cells.size(), s["cells"].size()])
	else:
		for i in g.cells.size():
			var a: Dictionary = g.cells[i]
			var b: Dictionary = s["cells"][i]
			if a["pid"] != b["pid"] or a["faction"] != b["faction"] or a["pos"] != b["pos"] \
					or a["itype"] != b["itype"] or a["ctype"] != b["ctype"] \
					or a["energy"] != b["energy"] or a["alive"] != b["alive"] \
					or a["marked"] != b["marked"]:
				cell_mismatch += 1
				if cell_mismatch <= 3:
					why = "cell %d: %s vs %s" % [i, a, b]
		if cell_mismatch > 0:
			ok = false
		print("  3) cells 逐格一致: %s (%d 不匹配)" % [cell_mismatch == 0, cell_mismatch])

	# 4) players.cancer_type
	var pt_mismatch := 0
	for i in g.players.size():
		var a: int = g.players[i].get("cancer_type", -1)
		var b: int = s["players"][i].get("cancer_type", -1)
		if a != b:
			pt_mismatch += 1
	if pt_mismatch > 0:
		ok = false
	print("  4) players cancer_type 一致: %s" % [pt_mismatch == 0])

	# 5) 收尾
	print("  5) cells=%d steps=%d pc=%s（应 SETUP_DONE）" % [s["cells"].size(), mr["steps"], s["pc"]])

	print("")
	print("  行为等价: " + ("✓ 通过" if ok else "✗ 失败 — " + why))
	g.dispose()
