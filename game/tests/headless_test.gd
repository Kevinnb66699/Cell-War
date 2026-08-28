## headless_test.gd —— 无头单元/回归测试
##
## 运行：godot --headless --path game --script res://tests/headless_test.gd
## 注意：新增 class_name 脚本后必须先 `--import`，否则报 "Identifier not declared"。
extends SceneTree

var fails := 0
var checks := 0


func _initialize() -> void:
	_run_all()


func _run_all() -> void:
	t_board()
	t_pay_rule()
	await t_setup()
	await t_hit_order()
	t_anaerobic_floor()
	t_solidify_and_decay()
	t_erosion()
	t_immune_win()
	t_cancer_s_win()
	await t_immune_respawn()
	t_pressure()
	t_necrosis()
	t_one_cell_per_tile()
	t_phase_order()
	t_event_rounds()
	t_draw_limit()
	await t_snapshot()
	await t_rollout_isolation()
	await t_step_atomic()
	await t_full_game_2p()
	await t_full_game_4p()
	await t_determinism()
	t_board_view()
	t_hex_pick()
	await t_ui_bridge()
	await t_human_ask()
	t_match_panel()
	await t_opening()
	await t_pause_and_teardown()
	t_hand()
	t_hand_limit()
	t_card_pool()
	t_font_coverage()
	t_card_name_fit()
	t_view_blend()
	await t_announce()
	t_action_bar_width()
	await t_buttons_dim()
	await t_enter_not_skipped()
	t_main_menu()
	await t_roll_hook()
	t_dice()
	print("")
	if fails == 0:
		print("✔ 全部测试通过（%d 项检查）" % checks)
		quit(0)
	else:
		print("✘ %d 项检查失败（共 %d 项）" % [fails, checks])
		quit(1)


func check(cond: bool, name: String) -> void:
	checks += 1
	if cond:
		print("  ok  %s" % name)
	else:
		fails += 1
		print("  FAIL %s" % name)


## 建一个带 AI 桥的对局（不跑流程）
## 把对局推到「开局落子完毕、世界回合尚未开始」为止。
## 相当于旧的 setup.run() —— 流程改成状态机之后，开局落子也是一串正常的决策了。
func run_setup(g: CWGame) -> void:
	g.stop_at = "round_start"
	while true:
		var req := g.pending()
		if req.is_empty():
			break
		await g.step(0)
	g.stop_at = ""


func make_game(n_players: int, seed_value: int) -> CWGame:
	var g := CWGame.new()
	g.init(CWData.FACTION_ORDER[n_players], seed_value)
	for pid in g.order:
		var b := CWHeuristicBridge.new()
		b.game = g
		g.bridges[pid] = b
	return g


## 建一块棋盘并立刻生成格子（不入场景树，直接触发 _ready）。
## 一定要走这里，别自己 instantiate —— 脚本解析失败时 Godot 只打印错误、
## 照样返回一个光秃秃的 Node2D，之后每个 check 都不会执行，而 fails 仍是 0，
## 于是测试**假装通过**（2026-08-27 真踩到了：board.gd 一处类型推断写错，
## 报「全部测试通过（61 项）」，实际有两个测试整个没跑）。
## 判据只能用 has_method()：脚本解析失败时 Godot 会挂一个 MissingResource 占位，
## get_script() 照样非空 —— 问它等于没问（这一条也是当场试出来的）。
func make_board() -> Node2D:
	var board: Node2D = load("res://scenes/Board.tscn").instantiate()
	check(board.has_method("hex_at"), "Board.tscn 的脚本解析通过")
	if not board.has_method("hex_at"):
		return board       ## 脚本没挂上，_ready() 只会再刷一屏错误
	board._ready()
	return board


# ---- 棋盘 ----
func t_board() -> void:
	print("[棋盘]")
	var g := make_game(2, 1)
	g.setup.build_board()
	check(g.tiles.size() == CWData.TOTAL_TILES, "%d 格" % CWData.TOTAL_TILES)
	var specials := 0
	for t in g.tiles.values():
		if t["special"] != CWData.Special.NONE:
			specials += 1
	var want_specials: int = CWData.CORES.size() + CWData.MARROWS.size() + CWData.VESSELS.size()
	check(specials == want_specials, "特殊组织 %d 格（%d 核心+%d 骨髓+%d 血管）" % [
		want_specials, CWData.CORES.size(), CWData.MARROWS.size(), CWData.VESSELS.size()])
	# 中央格必须是普通格：规则要求初始癌组织「必须包含中央格」且「不得与特殊组织重合」，
	# 中央格一旦是特殊组织，这两条就无法同时成立（说明 #34，2026-08-27 已按此移走中央骨髓）。
	check(g.tiles[Vector2i.ZERO]["special"] == CWData.Special.NONE, "中央格不是特殊组织")
	check(CWData.hex_dist(CWData.VESSELS[0], CWData.VESSELS[1]) == CWData.BOARD_RADIUS * 2,
		"血管两端是棋盘对角（相距 %d 格）" % (CWData.BOARD_RADIUS * 2))
	g.dispose()


# ---- 费用规则：支付不能使能量降至 0 ----
func t_pay_rule() -> void:
	print("[费用]")
	var g := make_game(2, 1)
	var cell := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i.ZERO,
		CWData.ImmuneType.BASIC, -1)
	cell["energy"] = 10
	check(not g.pay(cell, 10), "1.0 能量付 1.0 → 拒绝（会降至 0）")
	check(g.pay(cell, 9), "1.0 能量付 0.9 → 允许")
	check(cell["energy"] == 1, "余 0.1")
	g.dispose()


# ---- 开局 ----
func t_setup() -> void:
	print("[开局]")
	var g := make_game(4, 7)
	await run_setup(g)
	var cancerous := g.count_tissue(CWData.Tissue.CANCER) + g.count_tissue(CWData.Tissue.SOLID)
	check(cancerous == CWData.INIT_CANCER_TILES,
		"初始 %d 格癌性组织" % CWData.INIT_CANCER_TILES)
	check(g.is_cancerous(Vector2i.ZERO), "含中央格")
	check(g.cells.size() == 4, "4 个细胞落子")
	# 原发灶：每个癌症玩家的出生格开局即为固化癌组织
	var cancer_cells := g.living_cells(CWData.Faction.CANCER)
	var spawns := {}
	for c in cancer_cells:
		spawns[c["pos"]] = true
	check(g.count_tissue(CWData.Tissue.SOLID) == spawns.size(),
		"原发灶数 = 癌细胞出生格数（%d）" % spawns.size())
	var all_solid := true
	for pos in spawns.keys():
		if g.tile(pos)["tissue"] != CWData.Tissue.SOLID:
			all_solid = false
	check(all_solid, "原发灶都位于癌细胞出生格")
	# 落子时癌细胞必须在癌组织上；之后原发灶会把出生格升级为固化癌组织，故这里用 is_cancerous
	var legal := true
	for c in g.cells:
		if c["faction"] == CWData.Faction.CANCER and not g.is_cancerous(c["pos"]):
			legal = false
		if c["faction"] == CWData.Faction.IMMUNE \
				and g.tile(c["pos"])["tissue"] != CWData.Tissue.HEALTHY:
			legal = false
	check(legal, "落子位置合法（癌在癌性组织，免疫在健康组织）")
	var types := {}
	for p in g.players:
		if p["faction"] == CWData.Faction.CANCER:
			types[p["cancer_type"]] = true
	check(types.size() == 2, "两个癌症玩家种类不重复")
	g.dispose()


# ---- 能量损失五步管线：基础 → 固定增加 → 倍增 → 倍减 → 固定减免 ----
func t_hit_order() -> void:
	print("[伤害结算]")
	# 先单测纯函数，把顺序钉死：先减免再倍增会得到 (10-5)*2 = 10，是错的
	check(CWGame.settle_loss(10, 0, 2, 1, 5) == 15, "1.0 ×2 −0.5 = 1.5（倍增在减免之前）")
	check(CWGame.settle_loss(10, 0, 2, 2, 0) == 10, "×2 再 ÷2 = 原值")
	check(CWGame.settle_loss(10, 0, 1, 2, 0) == 5, "÷2 向下取整到十分位")
	check(CWGame.settle_loss(5, 0, 1, 1, 10) == 0, "减免不会减成负数")
	var g := make_game(2, 1)
	await run_setup(g)
	var target: Dictionary = g.living_cells(CWData.Faction.CANCER)[0]
	var attacker: Dictionary = g.living_cells(CWData.Faction.IMMUNE)[0]
	target["ctype"] = CWData.CancerType.SIGNET   ## 【囊性护甲】−0.5
	target["marked"] = true                      ## 树突【标记】×2
	target["armor_used"] = false
	target["energy"] = 50
	attacker["itype"] = CWData.ImmuneType.MACRO
	var before_atk: int = attacker["energy"]
	var dmg := g.immune_hit(target, 10, attacker)
	check(dmg == 15, "1.0 ×2(标记) −0.5(囊性护甲) = 1.5")
	check(target["energy"] == 35, "目标余 3.5")
	## 巨噬【吞噬】= ⌈受击方损失 ÷ 2⌉，取整符号外没写「到十分位」→ 按整数能量
	check(attacker["energy"] == before_atk + 10, "巨噬吞噬 ⌈1.5÷2⌉ = 1.0")
	check(not target["marked"], "标记已消耗")
	var dmg2 := g.immune_hit(target, 10, attacker)
	check(dmg2 == 10, "囊性护甲每世界回合仅一次，第二击不减免")
	## 【I-各司其职】：树突状细胞攻击只造成 1/2
	attacker["itype"] = CWData.ImmuneType.DENDRITIC
	target["marked"] = false
	check(g.immune_hit(target, 10, attacker) == 5, "树突攻击 1.0 → 0.5")
	g.dispose()


# ---- 无氧呼吸：0.4/格 + 固化 1.0/格，块内均分，向下取整；小细胞肺癌 110% ----
func t_anaerobic_floor() -> void:
	print("[无氧呼吸]")
	var g := make_game(2, 1)
	g.setup.build_board()
	# 连通块：3 癌 + 1 固化 = 0.4×3 + 1.0 = 2.2 → 2 个细胞各得 1.1
	var coords := [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0)]
	for c in coords:
		g.tiles[c]["tissue"] = CWData.Tissue.CANCER
	g.tiles[Vector2i(3, 0)]["tissue"] = CWData.Tissue.SOLID
	for i in 2:
		var cell := CWSetup.make_cell(i, i, CWData.Faction.CANCER, coords[i], -1,
			CWData.CancerType.MELANOMA)
		cell["energy"] = 0
		g.cells.append(cell)
	g.world._anaerobic()
	check(g.cells[0]["energy"] == 11 and g.cells[1]["energy"] == 11,
		"池 2.2 / 2 细胞 = 各 1.1")
	## 【瓦伯格超速糖酵解】：110%，向上取整到十分位 → 1.1 × 1.1 = 1.21 → 1.3
	g.cells[0]["ctype"] = CWData.CancerType.SCLC
	g.cells[0]["energy"] = 0
	g.cells[1]["energy"] = 0
	g.world._anaerobic()
	check(g.cells[0]["energy"] == 13, "小细胞肺癌 1.1 → 1.3（110% 向上取整）")
	check(g.cells[1]["energy"] == 11, "同块的其他癌细胞不受影响")
	g.dispose()


# ---- 固化：计数用十分整数，阈值 3.0、衰减 −0.5、骨肉瘤 +1.5 ----
func t_solidify_and_decay() -> void:
	print("[固化]")
	var g := make_game(2, 1)
	g.setup.build_board()
	var pos := Vector2i(1, 1)
	g.tiles[pos]["tissue"] = CWData.Tissue.CANCER
	var cell := CWSetup.make_cell(0, 0, CWData.Faction.CANCER, pos, -1,
		CWData.CancerType.MELANOMA)
	g.cells.append(cell)
	g.world._solidify()
	check(g.tiles[pos]["solid"] == 10, "停留 1 回合 → 计数 1.0")
	g.world._solidify()
	check(g.tiles[pos]["tissue"] == CWData.Tissue.CANCER, "计数 2.0 还没到阈值")
	g.world._solidify()
	check(g.tiles[pos]["tissue"] == CWData.Tissue.SOLID, "计数到 3.0 → 固化癌组织")
	## 骨肉瘤【骨样硬化】：同样的停留只要两回合就够 3.0
	var op := Vector2i(-2, 1)
	g.tiles[op]["tissue"] = CWData.Tissue.CANCER
	cell["ctype"] = CWData.CancerType.OSTEO
	cell["pos"] = op
	g.world._solidify()
	check(g.tiles[op]["solid"] == 15, "骨肉瘤停留 → 计数 +1.5")
	g.world._solidify()
	check(g.tiles[op]["tissue"] == CWData.Tissue.SOLID, "两回合即固化")
	## 衰减：无细胞停留的癌组织每世界回合 −0.5
	var d1 := Vector2i(-1, 0)
	g.tiles[d1]["tissue"] = CWData.Tissue.CANCER
	g.tiles[d1]["solid"] = 10
	g.world._decay()
	check(g.tiles[d1]["solid"] == 5, "无人停留 → 计数 −0.5")
	g.world._decay()
	check(g.tiles[d1]["solid"] == 0, "再减一次归零，不会变负")
	g.world._decay()
	check(g.tiles[d1]["solid"] == 0, "已经是 0 就不再减")
	## 新生癌组织当回合不可固化
	var nb := Vector2i(0, 1)
	g.tiles[nb]["tissue"] = CWData.Tissue.CANCER
	g.tiles[nb]["newborn"] = true
	cell["pos"] = nb
	g.world._solidify()
	check(g.tiles[nb]["solid"] == 0, "新生癌组织当回合不固化")
	g.dispose()


# ---- 侵蚀 ----
func t_erosion() -> void:
	print("[侵蚀]")
	var g := make_game(2, 5)
	g.setup.build_board()
	# 全盘设为癌组织，只留 (0,0) (1,0) 两格健康 → 被完全包围且不接外缘
	for c in g.tiles.keys():
		g.tiles[c]["tissue"] = CWData.Tissue.CANCER
	g.tiles[Vector2i(0, 0)]["tissue"] = CWData.Tissue.HEALTHY
	g.tiles[Vector2i(1, 0)]["tissue"] = CWData.Tissue.HEALTHY
	# 免疫细胞站 (0,0) → 只有 (1,0) 可被侵蚀
	var imm := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0),
		CWData.ImmuneType.BASIC, -1)
	g.cells.append(imm)
	g.world._erosion()
	check(g.tiles[Vector2i(0, 0)]["tissue"] == CWData.Tissue.HEALTHY, "免疫所在格不可被侵蚀")
	check(g.tiles[Vector2i(1, 0)]["tissue"] == CWData.Tissue.CANCER, "被包围块的邻癌格被侵蚀")
	check(g.tiles[Vector2i(1, 0)]["newborn"], "侵蚀所得为新生癌组织")
	# 接外缘的健康块不侵蚀
	var g2 := make_game(2, 5)
	g2.setup.build_board()
	g2.tiles[Vector2i.ZERO]["tissue"] = CWData.Tissue.CANCER
	g2.world._erosion()
	var healthy := g2.count_tissue(CWData.Tissue.HEALTHY)
	check(healthy == CWData.TOTAL_TILES - 1, "与外缘连通的健康块不受侵蚀")
	g.dispose()
	g2.dispose()


# ---- 免疫胜利（占格封复活）----
func t_immune_win() -> void:
	print("[免疫胜利]")
	var g := make_game(2, 1)
	g.setup.build_board()
	var solid := Vector2i(2, 2)
	g.tiles[solid]["tissue"] = CWData.Tissue.SOLID
	var imm := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i.ZERO,
		CWData.ImmuneType.BASIC, -1)
	g.cells.append(imm)
	g.check_immune_win()
	check(g.winner < 0, "有未被占据的固化格 → 未获胜")
	imm["pos"] = solid
	g.check_immune_win()
	check(g.winner == CWData.Faction.IMMUNE, "占住全部固化格且无癌细胞 → 立即获胜")
	g.dispose()


# ---- 癌症加权胜利 ----
func t_cancer_s_win() -> void:
	print("[癌症胜利]")
	var g := make_game(2, 1)
	g.setup.build_board()
	var coords: Array = g.tiles.keys()
	var need: int = CWData.CANCER_WIN_WEIGHTED
	for i in need - 1:
		g.tiles[coords[i]]["tissue"] = CWData.Tissue.CANCER
	g.check_cancer_win()
	check(g.winner < 0, "加权 %d < %d → 未获胜" % [need - 1, need])
	g.tiles[coords[need - 1]]["tissue"] = CWData.Tissue.CANCER
	g.check_cancer_win()
	check(g.winner == CWData.Faction.CANCER, "加权 %d → 癌症胜利" % need)
	g.dispose()


# ---- 免疫【S-复活】：下一个 S 阶段在健康骨髓格复活，1.0 能量 ----
func t_immune_respawn() -> void:
	print("[免疫复活]")
	var g := make_game(4, 11)
	await run_setup(g)
	var imm: Dictionary = g.living_cells(CWData.Faction.IMMUNE)[0]
	var pid: int = imm["pid"]
	g.round_no = 3
	g.kill(imm)
	check(not imm["alive"], "免疫细胞死亡")
	## PRD 没有罚停条款：下一个世界回合的 S 阶段就复活
	check(imm["respawn_round"] == 4, "死于第 3 回合 → 第 4 回合复活")
	## 骨髓全被癌化 → 无处可复活
	for c in CWData.MARROWS:
		g.tiles[c]["tissue"] = CWData.Tissue.CANCER
	g.round_no = 4
	check(g.world.revive_options_immune(pid).is_empty(), "骨髓全被癌化 → 没有落点")
	## 放开一个健康骨髓格
	var m: Vector2i = CWData.MARROWS[0]
	g.tiles[m]["tissue"] = CWData.Tissue.HEALTHY
	var opts: Array = g.world.revive_options_immune(pid)
	check(opts.size() == 1 and opts[0]["data"]["to"] == m, "落点正是那个健康骨髓格")
	g.world.revive_immune(pid, m)
	check(imm["alive"] and imm["pos"] == m, "在骨髓复活")
	check(imm["energy"] == 10, "复活获得 1.0 能量（癌细胞是 2.0）")
	check(imm["respawn_round"] == -1, "复活后清除标记")
	## 骨髓被别的细胞占着也不行
	var imm2: Dictionary = g.living_cells(CWData.Faction.IMMUNE)[1]
	g.round_no = 5
	g.kill(imm2)
	g.round_no = 6
	check(g.world.revive_options_immune(imm2["pid"]).is_empty(),
		"唯一的健康骨髓被队友占着 → 没有落点")
	## 旋钮关掉 → 永久死亡
	g.tune.immune_respawn_delay = -1
	g.kill(imm)
	check(imm["respawn_round"] == -1, "旋钮关掉后不再排队复活")
	g.dispose()


# ---- 【E-微环境压迫】：相邻癌性组织 > 2 格时按超出格数扣能量 ----
func t_pressure() -> void:
	print("[微环境压迫]")
	var g := make_game(2, 1)
	g.setup.build_board()
	var pos := Vector2i.ZERO
	var cell := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, pos,
		CWData.ImmuneType.BASIC, -1)
	cell["energy"] = 50
	g.cells.append(cell)
	var nb := CWData.neighbors(pos)
	for k in 2:
		g.tiles[nb[k]]["tissue"] = CWData.Tissue.CANCER
	g.world._pressure()
	check(cell["energy"] == 50, "相邻 2 格不造成损失")
	g.tiles[nb[2]]["tissue"] = CWData.Tissue.CANCER
	g.world._pressure()
	check(cell["energy"] == 45, "相邻 3 格 → (3−2)×0.5 = 0.5")
	for k in range(3, 6):
		g.tiles[nb[k]]["tissue"] = CWData.Tissue.SOLID
	cell["energy"] = 50
	g.world._pressure()
	check(cell["energy"] == 30, "相邻 6 格（含固化）→ (6−2)×0.5 = 2.0")
	## 这是癌方第一个能真正打死免疫细胞的手段
	cell["energy"] = 15
	g.world._pressure()
	check(not cell["alive"], "压迫可以致死")
	g.dispose()


# ---- 「坏死」：不为有氧呼吸供能，按世界回合倒计时 ----
func t_necrosis() -> void:
	print("[坏死]")
	var g := make_game(2, 1)
	g.setup.build_board()
	var cell := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i.ZERO,
		CWData.ImmuneType.BASIC, -1)
	cell["energy"] = 0
	g.cells.append(cell)
	g.world._aerobic()
	## 全盘 127 格健康：127 × 3 ÷ 127 = 3.0
	check(cell["energy"] == 30, "满盘健康 → 3.0")
	## 抠掉 20 格坏死：(127−20) × 3 ÷ 127 = 2.527 → 四舍五入 2.5
	var n := 0
	for c in g.tiles.keys():
		if n >= 20:
			break
		g.tiles[c]["necrosis"] = CWData.NECROSIS_TOXIN
		n += 1
	cell["energy"] = 0
	g.world._aerobic()
	check(cell["energy"] == 25, "坏死 20 格 → 2.5（四舍五入到十分位）")
	## 倒计时：两个世界回合后恢复
	g.world._tick_necrosis()
	g.world._tick_necrosis()
	cell["energy"] = 0
	g.world._aerobic()
	check(cell["energy"] == 30, "坏死到期后重新供能")
	g.dispose()


# ---- 一格一细胞 + 骨肉瘤【刚性屏障】 ----
func t_one_cell_per_tile() -> void:
	print("[一格一细胞]")
	var g := make_game(2, 1)
	g.setup.build_board()
	var a := Vector2i.ZERO
	var b: Vector2i = CWData.neighbors(a)[0]
	var mine := CWSetup.make_cell(0, 0, CWData.Faction.CANCER, a, -1,
		CWData.CancerType.MELANOMA)
	var mate := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, b, -1,
		CWData.CancerType.SCLC)
	g.cells.append(mine)
	g.cells.append(mate)
	var opts: Array = g.actions.build_options(mine)
	var can_go := false
	for o in opts:
		if o["data"].get("to", Vector2i.MAX) == b:
			can_go = true
	check(not can_go, "己方细胞占着的格也不能进（不再是「同阵营可叠」）")
	## 骨肉瘤站在固化癌组织上时不可被攻击
	var imm := CWSetup.make_cell(2, 0, CWData.Faction.IMMUNE, a,
		CWData.ImmuneType.BASIC, -1)
	g.cells.clear()
	mate["ctype"] = CWData.CancerType.OSTEO
	mate["pos"] = b
	imm["pos"] = a
	imm["energy"] = 50
	g.cells.append(mate)
	g.cells.append(imm)
	g.tiles[b]["tissue"] = CWData.Tissue.SOLID
	check(not g.actions._attackable(mate), "固化癌组织上的骨肉瘤不可攻击")
	g.tiles[b]["tissue"] = CWData.Tissue.CANCER
	check(g.actions._attackable(mate), "破除固化后就能打了")
	g.dispose()


# ---- E 阶段顺序：增生必须排在侵蚀之前 ----
func t_phase_order() -> void:
	print("[阶段顺序]")
	var src := FileAccess.get_file_as_string("res://scripts/core/cw_world.gd")
	var body := src.substr(src.find("func e_phase"))
	body = body.substr(0, body.find("# ---- S 阶段"))
	var seq: Array[String] = []
	for name in ["_pressure", "_proliferate", "_erosion", "_anaerobic",
			"_solidify", "_decay", "_tick_necrosis", "_clear_newborn"]:
		seq.append(name)
	var last := -1
	var ordered := true
	for name in seq:
		var at: int = body.find(name + "()")
		if at < 0 or at < last:
			ordered = false
		last = at
	check(ordered, "E 阶段八步都在、且顺序和 PRD 一致")
	## 单独把最容易搞反的一对钉死：增生会改变「完全包围」的判定结果
	check(body.find("_proliferate()") < body.find("_erosion()"),
		"【增生】排在【侵蚀】之前")


# ---- 世界事件回合表：3/6/10/15/20/25/30，到 30 为止 ----
func t_event_rounds() -> void:
	print("[世界事件回合]")
	var hit: Array[int] = []
	for r in range(1, 41):
		if CWData.is_world_event_round(r):
			hit.append(r)
	check(hit == [3, 6, 10, 15, 20, 25, 30], "触发回合正是 PRD 那七个（%s）" % str(hit))
	check(not CWData.is_world_event_round(35), "30 之后不再触发")


# ---- 【基因表达】每行动回合 3 次 ----
func t_draw_limit() -> void:
	print("[抽卡上限]")
	var g := make_game(2, 1)
	g.setup.build_board()
	var cell := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i.ZERO,
		CWData.ImmuneType.BASIC, -1)
	cell["energy"] = 100
	g.cells.append(cell)
	for i in CWData.DRAW_MAX_PER_TURN:
		check(_has_act(g.actions.build_options(cell), "draw"), "第 %d 次抽卡还在菜单里" % (i + 1))
		g.actions.execute(cell, { "act": "draw" })
	check(not _has_act(g.actions.build_options(cell), "draw"),
		"抽满 3 次后菜单里没有抽卡了")
	check(cell["draws_used"] == 3, "计数是 3")
	## 抽到的**不一定**进手牌：【事件】立即结算并弃置，不占手牌
	check(cell["hand"].size() <= 3, "进手牌的不会超过抽的次数")
	g.dispose()




func _has_act(opts: Array, act: String) -> bool:
	for o in opts:
		if o["data"].get("act", "") == act:
			return true
	return false


# ---- 完整对局 ----
func t_full_game_2p() -> void:
	print("[完整对局 2 人]")
	var g := make_game(2, 42)
	var w: int = await g.run_game()
	check(w == CWData.Faction.IMMUNE or w == CWData.Faction.CANCER, "分出胜负（%s）" % g.win_reason)
	check(g.round_no <= CWData.LIMIT_ROUND, "不超过回合上限（%d）" % CWData.LIMIT_ROUND)
	g.dispose()


func t_full_game_4p() -> void:
	print("[完整对局 4 人]")
	var g := make_game(4, 7)
	var w: int = await g.run_game()
	check(w == CWData.Faction.IMMUNE or w == CWData.Faction.CANCER, "分出胜负（%s）" % g.win_reason)
	g.dispose()


# ---- 确定性：同种子两局哈希一致（联机/回放的前提）----
func t_determinism() -> void:
	print("[确定性]")
	var hashes: Array[String] = []
	var winners: Array[int] = []
	var log_counts: Array[int] = []
	for i in 2:
		var g := make_game(4, 20260826)
		var w: int = await g.run_game()
		hashes.append(g.state_hash())
		winners.append(w)
		log_counts.append(g.logs.size())
		g.dispose()
	check(hashes[0] == hashes[1], "同种子两局最终状态哈希一致")
	check(winners[0] == winners[1] and log_counts[0] == log_counts[1], "胜者与日志长度一致")


# ---- 棋盘渲染：画出来的格子必须和 CWData 的轴坐标一一对应 ----
# 渲染层用「行,列」下标，规则层用轴坐标 (q,r)，两套坐标必须描述同一个棋盘。
# 2026-08-27 之前渲染层自己抄了一份特殊组织下标，地图改版后没跟上——这组检查就是防这个。
func t_board_view() -> void:
	print("[棋盘渲染]")
	var board := make_board()

	check(board.map.size() == CWData.TOTAL_TILES, "渲染出 %d 格" % CWData.TOTAL_TILES)

	# axial_to_rc 必须是双射：127 个轴坐标恰好盖满 127 个已渲染的格子
	var mapped := {}
	for c in CWData.all_coords():
		mapped[board.axial_to_rc(c)] = true
	check(mapped.size() == CWData.TOTAL_TILES and mapped.size() == board.map.size(),
		"轴坐标 → 行列下标是双射")
	var all_hit := true
	for rc in mapped:
		if not board.map.has(rc):
			all_hit = false
	check(all_hit, "每个轴坐标都落在已渲染的格子上")

	# 特殊组织的贴图数量必须等于 CWData 里声明的数量
	var tex_count := {}
	for k in board.map:
		var f: String = board.map[k]["instance"].texture.resource_path.get_file()
		tex_count[f] = tex_count.get(f, 0) + 1
	check(tex_count.get("vessel.png", 0) == CWData.VESSELS.size(),
		"血管贴图 %d 处" % CWData.VESSELS.size())
	check(tex_count.get("energy_normal.png", 0) == CWData.CORES.size(),
		"代谢核心贴图 %d 处" % CWData.CORES.size())
	check(tex_count.get("marrow_normal.png", 0) == CWData.MARROWS.size(),
		"骨髓贴图 %d 处" % CWData.MARROWS.size())

	board.free()


# ---- 棋盘点选 ----
# hex_at() 是 tile_center() 的逆。两者一旦对不上，点哪儿都是错的格子，
# 而且错得很隐蔽（只差一格、还跟着鼠标位置变），所以这里逐格核对，不抽样。
func t_hex_pick() -> void:
	print("[棋盘点选]")
	var board := make_board()

	# ① 每一格的顶面中心都得点回它自己
	var exact := 0
	for c in CWData.all_coords():
		if board.hex_at(board.tile_center(c)) == c:
			exact += 1
	check(exact == CWData.TOTAL_TILES,
		"127 格的中心都点回自己（%d/%d）" % [exact, CWData.TOTAL_TILES])

	# ② 格内抖动仍要命中同一格。这几个偏移都在压扁六边形的内部
	#    （横向内切半径 18，正上方的顶点在 36/√3/1.559 ≈ 13.3）。
	var jitter := [Vector2(15, 0), Vector2(-15, 0), Vector2(0, 12), Vector2(0, -12),
		Vector2(10, 5), Vector2(-10, -5)]
	var ok_jitter := true
	for c in CWData.all_coords():
		for d in jitter:
			if board.hex_at(board.tile_center(c) + d) != c:
				ok_jitter = false
	check(ok_jitter, "格内抖动 %d 个方向仍命中同一格" % jitter.size())

	# ③ 相邻两格的中点必须落在这两格之一。若有第三格来抢，说明纵向校正系数算错了
	#    —— 这正是「压扁网格直接套六边形公式」会犯的错。
	var ok_mid := true
	for c in CWData.all_coords():
		for n in CWData.neighbors(c):
			var mid: Vector2 = (board.tile_center(c) + board.tile_center(n)) / 2.0
			var hit: Vector2i = board.hex_at(mid)
			if hit != c and hit != n:
				ok_mid = false
	check(ok_mid, "相邻格中点只会命中这两格之一")

	# ④ 棋盘之外必须判为没点中，否则外缘格会把整个屏幕外侧都吸进来
	var outside := [Vector2(0, -400), Vector2(0, 400), Vector2(-900, 0), Vector2(900, 0),
		board.tile_center(Vector2i(0, 6)) + Vector2(0, 60)]
	var ok_out := true
	for pt in outside:
		if board.hex_at(pt) != board.NO_TILE:
			ok_out = false
	check(ok_out, "棋盘外的 %d 个点都返回 NO_TILE" % outside.size())

	# ⑤ 高亮层：整体替换语义 + 清空
	## 查的是**目标集合**而不是节点数 —— 高亮是淡入淡出的，
	## 撤掉的那一格要等淡完才真的删掉，节点会滞留一小会儿。
	board.set_marks({ Vector2i(0, 0): board.MARK_MOVE, Vector2i(1, 0): board.MARK_ATTACK })
	check(board._mark_target.size() == 2, "设置 2 格高亮")
	check(board._mark_nodes[Vector2i(0, 0)].modulate.a < board.MARK_MOVE.a,
		"新出现的高亮从透明淡进来，不是「啪」地出现")
	var first_node: Node = board._mark_nodes[Vector2i(0, 0)]
	board.set_marks({ Vector2i(0, 0): board.MARK_HOVER, Vector2i(3, -1): board.MARK_MOVE })
	check(board._mark_target.size() == 2 and board._mark_target.has(Vector2i(3, -1))
		and not board._mark_target.has(Vector2i(1, 0)), "再次设置是整体替换而非追加")
	check(board._mark_nodes[Vector2i(0, 0)] == first_node,
		"还在的那一格复用同一个节点（不然补间每帧都会被重建打断）")
	board.set_marks({})
	check(board._mark_target.is_empty(), "空字典清空高亮")

	# ⑥ 高亮按同心圆由内向外亮起：圆心取这批格子的**重心**，
	#    所以「整张棋盘」和「细胞周围六格」两种情况用同一条规则都对。
	var whole := CWData.all_coords()
	var d_all: Dictionary = board.ring_delays(whole, 1.0)
	check(is_zero_approx(d_all[Vector2i(0, 0)]), "整张棋盘时中央格最先亮")
	check(is_equal_approx(d_all[Vector2i(6, 0)], 6.0)
		and is_equal_approx(d_all[Vector2i(0, -3)], 3.0), "外圈按环号依次排队")
	var around: Array = CWData.neighbors(Vector2i(2, -2))
	var d_ring: Dictionary = board.ring_delays(around, 1.0)
	var same := true
	for c: Vector2i in around:
		if not is_equal_approx(d_ring[c], 1.0):
			same = false
	check(same, "只有邻格时重心落在那个细胞上，六格同时亮（都是第 1 环）")
	check(board.ring_delays([], 1.0).is_empty(), "空集合不报错")

	board.free()

# ---- 演出桥 ----
## 只记账、不真播动画的骰子。真播一次要 1.9 秒，而这里要验的不是动画本身
## （那是 t_dice 的活），是**桥有没有把骰子摆到引擎指定的那一格**——
## 摆错格子肉眼很难发现：骰子照样会掉下来，只是掉在别处。
class StubDice:
	extends CWDice
	var played: Array = []
	func play(value: int, sides: int, fast := false) -> void:
		played.append({ "value": value, "sides": sides, "fast": fast })


func t_ui_bridge() -> void:
	print("[演出桥]")
	var board := make_board()
	var g := CWGame.new()
	g.init(CWData.FACTION_ORDER[2], 7)
	var b := CWUIBridge.new()
	b.game = g
	b.board = board
	var stub := StubDice.new()
	stub._ready()
	b.dice = stub
	b.human_pids = [0]

	var at := Vector2i(2, -3)
	await b.show_roll("攻击", 5, 6, 1, at)
	check(stub.played.size() == 1, "show_roll 真的演了一次（不是死代码）")
	check(stub.played[0]["value"] == 5 and stub.played[0]["sides"] == 6,
		"点数与面数原样传给演出（表现层无权改结果）")
	check(stub._ground == board.tile_center(at), "骰子落在引擎指定的那一格")
	await b.show_roll("攻击", 3, 6, 0, at)
	check(not stub.played[0]["fast"] and not stub.played[1]["fast"],
		"AI 和人类同一档速度（团队 2026-08-27 定：两种节奏反而显得乱）")

	# 人类以外的位置退回启发式 AI —— 界面能一种一种做，对局始终跑得通
	var idx: int = await b.ask({ "kind": "confirm", "tag": "lyse_purge", "pid": 1,
		"prompt": "", "options": [{ "label": "净化", "data": {} }, { "label": "暂不", "data": {} }] })
	check(idx == 0, "非人类玩家的询问退回启发式 AI")
	check(b.marks.is_empty(), "桥默认不请求任何高亮")

	# 高亮色要能逐像素还原设计稿：健康组织主色 #2E4A41 叠一层 MARK_MOVE 之后
	# 必须变成 board_pick.png 里的 #2F8491。这条守的是设计还原度，
	# 着色器本身对不对只能靠截图看（见 silhouette.gdshader 的注释）。
	var base := Color8(0x2E, 0x4A, 0x41)
	var mv: Color = board.MARK_MOVE
	var got := base.lerp(Color(mv.r, mv.g, mv.b), mv.a)
	var want := Color8(0x2F, 0x84, 0x91)
	check(abs(got.r - want.r) < 0.006 and abs(got.g - want.g) < 0.006
			and abs(got.b - want.b) < 0.006, "候选格高亮叠色后与设计稿一致")

	g.dispose()
	board.free()
	stub.free()

# ---- 人类询问界面 ----
## 记录一整局里实际出现过的 act，用来核对行动栏有没有漏登记技能名。
class ActRecorder:
	extends CWHeuristicBridge
	var seen := {}
	func ask(req: Dictionary) -> int:
		if req["kind"] == "action":
			for o in req["options"]:
				seen[o["data"]["act"]] = true
		return await super.ask(req)


func _buttons(bar: CWActionBar) -> int:
	var n := 0
	for c in bar._row.get_children():
		if c is PanelContainer:
			n += 1
	return n


## 用合成事件把「点技能 → 点格子 / 取消」整条路走一遍。
## 这条路上最容易错的是**下标映射**：引擎给的每个相邻格是一个独立选项，
## 而行动栏把它们合成一个「迁移」按钮，选完格子还要还原成对应的那个下标。
## 错了不会报错，只会走到别的格子去——所以这里逐步核对返回的下标。
func t_human_ask() -> void:
	print("[人类询问界面]")
	var board := make_board()
	root.add_child(board)
	var bar := CWActionBar.new()
	root.add_child(bar)

	var g := CWGame.new()
	g.init(CWData.FACTION_ORDER[2], 11)
	var ai := CWHeuristicBridge.new()
	ai.game = g
	for pid in g.order:
		g.bridges[pid] = ai
	await run_setup(g)          ## 先把细胞摆好，后面才有 cell_of()

	var b := CWUIBridge.new()
	b.game = g
	b.board = board
	b.bar = bar
	b.human_pids = [0]
	for pid in g.order:
		g.bridges[pid] = b

	# ① 纯棋盘点选（setup_place / revive / remodel_target 都是这一类）
	var r1 := [-99]
	var req := { "kind": "setup_place", "pid": 0, "prompt": "选位置", "options": [
		{ "label": "a", "data": { "to": Vector2i(1, 0) } },
		{ "label": "b", "data": { "to": Vector2i(2, 0) } },
		{ "label": "c", "data": { "to": Vector2i(3, 0) } }] }
	var run1 := func() -> void: r1[0] = await b.ask(req)
	run1.call()
	check(b.marks.size() == 3, "三个候选格都高亮了")
	check(bar.visible, "提示栏出现")
	board.tile_clicked.emit(Vector2i(9, 9))   ## 不在候选里
	check(r1[0] == -99, "点非候选格无效")
	board.tile_clicked.emit(Vector2i(2, 0))
	await process_frame
	check(r1[0] == 1, "点第二格 → 返回第二个选项")
	check(b.marks.is_empty(), "答完后高亮清空")
	check(not bar.visible, "答完后提示栏收起")

	# ② 行动栏两段式：迁移合成一个按钮，点了才选格子
	var areq := { "kind": "action", "pid": 0, "prompt": "选择行动", "options": [
		{ "label": "", "data": { "act": "move", "to": Vector2i(1, 0), "cost": 5 } },
		{ "label": "", "data": { "act": "move", "to": Vector2i(0, 1), "cost": 10 } },
		{ "label": "", "data": { "act": "draw" } },
		{ "label": "", "data": { "act": "end" } }] }
	var r2 := [-99]
	var run2 := func() -> void: r2[0] = await b.ask(areq)
	run2.call()
	check(_buttons(bar) == 3,
		"未分化免疫细胞的完整按钮集合 = 迁移/基因表达 + 结束回合")
	check(b.marks.is_empty(), "按钮栏阶段不高亮格子")
	bar.chosen.emit(0)                        ## 点「迁移」
	await process_frame
	check(b.marks.size() == 2, "点迁移后高亮 2 格可达")
	board.tile_clicked.emit(Vector2i(0, 1))
	await process_frame
	check(r2[0] == 1, "选中的格子还原成了对应的那个选项下标")

	# ③ 「迁移」是切换式的：**走完一步继续停在选目标格上**，不必每步都重点一次按钮。
	#    上一段刚走完一步，所以这一问应当直接进目标选择态。
	var r3 := [-99]
	var run3 := func() -> void: r3[0] = await b.ask(areq)
	run3.call()
	check(_buttons(bar) == 1 and b.marks.size() == 2,
		"上一步走的是迁移 → 这一问直接回到选目标格，不再经过按钮栏")
	bar.chosen.emit(0)                        ## 「结束迁移」
	await process_frame
	check(r3[0] == -99 and _buttons(bar) == 3, "退出迁移后回到按钮栏，这一问还没答")
	check(not b._sticky_move, "退出后开关关掉了")
	bar.chosen.emit(2)                        ## 结束回合
	await process_frame
	check(r3[0] == 3, "结束回合映射到最后一个选项")

	# ③a 新的世界回合也要作废 —— 一个人每回合只行动一次，
	#     不清的话新回合一开始就直接进了选目标格（团队反馈）
	b._sticky_move = true
	b._sticky_pid = 0
	b._sticky_round = g.round_no
	g.round_no += 1
	var r3a := [-99]
	var run3a := func() -> void: r3a[0] = await b.ask(areq)
	run3a.call()
	check(not b._sticky_move and b.marks.is_empty(), "新世界回合从按钮栏重新开始")
	bar.chosen.emit(_buttons(bar) - 1)
	await process_frame
	g.round_no -= 1

	# ③b 换人时开关必须作废，不然轮到下一个人会莫名其妙直接进选目标格
	b._sticky_move = true
	b._sticky_pid = 0
	var r3b := [-99]
	var areq1 := areq.duplicate()
	areq1["pid"] = 1
	b.human_pids = [0, 1]
	var run3b := func() -> void: r3b[0] = await b.ask(areq1)
	run3b.call()
	check(not b._sticky_move and b.marks.is_empty(),
		"换人后从按钮栏重新开始（癌细胞的按钮集合和免疫不同，所以只查是否回到按钮栏）")
	bar.chosen.emit(_buttons(bar) - 1)   ## 最后一个按钮是「结束回合」
	await process_frame
	b.human_pids = [0]

	# ④ 有右侧竖条时，「结束回合」搬去面板底部，不再占行动栏
	var panel := CWMatchPanel.new()
	root.add_child(panel)
	b.panel = panel
	var r5 := [-99]
	var run5 := func() -> void: r5[0] = await b.ask(areq)
	run5.call()
	check(_buttons(bar) == 2, "有面板时行动栏只剩迁移和基因表达")
	check(panel._end != null and panel._end.visible, "面板底部的结束回合亮起来了")
	panel.end_turn_pressed.emit()
	await process_frame
	check(r5[0] == 3, "按面板上的结束回合 → 仍映射到引擎的最后一个选项")
	check(not panel._end.visible, "答完后结束回合收起")
	b.panel = null
	panel.queue_free()

	# ⑤ 非人类玩家不该弹界面
	var r4 := [-99]
	var run4 := func() -> void: r4[0] = await b.ask({ "kind": "confirm", "tag": "lyse_purge",
		"pid": 1, "prompt": "", "options": [{ "label": "净化", "data": {} },
		{ "label": "暂不", "data": {} }] })
	run4.call()
	await process_frame
	check(r4[0] == 0 and not bar.visible, "轮到 AI 时不弹界面，直接由 AI 作答")

	# ⑥ 新增主动技能却忘了在行动栏登记 → 按钮会显示成 act 的英文名。
	#    跑一整局把实际出现过的 act 收齐，逐个核对。
	var g2 := CWGame.new()
	g2.init(CWData.FACTION_ORDER[4], 99)
	var rec := ActRecorder.new()
	rec.game = g2
	for pid in g2.order:
		g2.bridges[pid] = rec
	await g2.run_game()
	var missing: PackedStringArray = []
	for act in rec.seen:
		if not CWUIBridge.ACT_TITLE.has(act):
			missing.append(act)
	check(missing.is_empty(), "一局里出现的 %d 种行动在行动栏都有名字%s"
		% [rec.seen.size(), "" if missing.is_empty() else "（缺 %s）" % ", ".join(missing)])

	g.dispose()
	g2.dispose()
	board.queue_free()
	bar.queue_free()

# ---- 右侧竖条 ----
## 这块的高度是按**最挤的 6 人局**配平的：五块加起来 530，只余 10px。
## 随手把哪一块调高一点，4 人局完全看不出问题，只有 6 人局会溢出到屏幕外——
## 所以这里专门盯 6 人局。
func t_match_panel() -> void:
	print("[右侧竖条]")
	var p := CWMatchPanel.new()
	root.add_child(p)

	p._build(6)
	var end_top: float = p._end.position.y
	check(p._level_y + CWMatchPanel.LEVEL_H <= end_top,
		"6 人局：免疫等级块（底 %d）不和结束回合（顶 %d）打架"
		% [p._level_y + CWMatchPanel.LEVEL_H, end_top])
	check(end_top + CWMatchPanel.END_H + CWMatchPanel.PAD == CWMatchPanel.RECT.size.y,
		"结束回合钉在底部，下面正好留出 %d 内边距" % CWMatchPanel.PAD)
	check(not p._end.visible, "默认不显示结束回合（轮到别人时整条行动入口都收掉）")

	## 面板宽度必须和对局机位让出的那一条严丝合缝，否则棋盘要么被压要么留缝
	check(int(CWMatchPanel.RECT.size.x) == CWView.PANEL_WIDTH
		and CWMatchPanel.RECT.position.x == 960 - CWView.PANEL_WIDTH,
		"竖条宽度与对局机位让出的 %d px 一致" % CWView.PANEL_WIDTH)

	## 「下一次世界事件在第几回合」：第 3、6、10、15，之后每 5 个
	var ev := true
	for pair in [[1, 3], [3, 3], [4, 6], [7, 10], [11, 15], [16, 20], [21, 25]]:
		if p._next_event_round(pair[0]) != pair[1]:
			ev = false
	check(ev, "世界事件回合表：3 / 6 / 10 / 15 之后每 5 个")

	p.queue_free()

# ---- 开场三拍 ----
## 盯的是开发日志记过的那个坑：相机和绽开是**前后相接的两段计时动画**，
## 一旦挂到同一条时间轴上，相机走完那一帧的进度 1 会被当成「绽开也走完了」，
## 于是 7 格癌组织一次全出、绽开整个被跳过。表现是「地图停稳的瞬间癌组织突然显示」——
## 肉眼只看得出「有点怪」，说不清哪儿怪，所以这里用状态断言钉死。
## 另外盯第三拍：绽开没演完不能把控制权交给玩家。
func t_opening() -> void:
	print("[开场三拍]")
	var main_scene: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main_scene)
	await process_frame
	var m: CWMatch = main_scene.get_node("Match")

	main_scene.menu.dismiss(0.05, 4.0)   ## 走一遍菜单退场，顺带查它有没有停止吃鼠标
	m.start_with_bloom(0.3)          ## 不 await：要在演的中途查状态
	var hidden: int = m._bloom.size()
	check(hidden >= CWData.INIT_CANCER_TILES - 1,
		"绽开刚开始时还有 %d 格没揭开（不是一次全出）" % hidden)
	check(m.bridge.opening, "绽开期间桥被闸住，落子提示不弹出来")
	check(m.game.count_tissue(CWData.Tissue.CANCER) == CWData.INIT_CANCER_TILES,
		"引擎那边 %d 格初始癌组织其实早就就位了（藏起来的只是画面）"
		% CWData.INIT_CANCER_TILES)

	await create_timer(0.6).timeout
	check(m._bloom.is_empty(), "演完后全部揭开")
	check(not m.bridge.opening, "演完才把控制权交还玩家（第三拍）")

	## 菜单淡出后必须**停止吃鼠标**：Control 的 modulate 归零只是看不见，
	## 照样挡点击，而「开始对局」那一行正压在棋盘上方。
	var menu: Node = main_scene.get_node("MainMenu")
	var eats := false
	for label in _all_labels(menu):
		if label.mouse_filter != Control.MOUSE_FILTER_IGNORE:
			eats = true
	check(not eats, "菜单退场后不再挡住棋盘的点击")
	check(not menu.get_node("UI").visible, "菜单的 CanvasLayer 也关掉了（它不跟随父节点）")

	main_scene.queue_free()

# ---- 暂停菜单 / 返回主菜单 ----
## 返回主菜单最容易漏的是**擦棋盘**：棋盘和相机是和主菜单共用的同一份，
## 不擦干净的话上一局的癌组织会留在菜单背景里 —— 而这只有真的退回去看一眼才发现。
## Esc 的归属也在这里钉住：选目标格时它是「取消」，不是「打开菜单」。
func t_pause_and_teardown() -> void:
	print("[暂停菜单 / 返回主菜单]")
	var main_scene: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main_scene)
	await process_frame
	var m: CWMatch = main_scene.get_node("Match")
	var pm: CWPauseMenu = main_scene.get_node("Match/UI/Pause")
	var bar: CWActionBar = main_scene.get_node("Match/UI/ActionBar")

	# ① Esc 的归属
	var esc := InputEventAction.new()
	esc.action = "ui_cancel"
	esc.pressed = true
	pm.active = false
	pm._unhandled_input(esc)
	check(not pm.visible, "主菜单状态下 Esc 不弹暂停菜单")
	pm.active = true
	bar.show_bar("选择要迁移到的组织", "", [{ "title": "取消", "cost": "" }], 0)
	check(bar.can_cancel(), "目标选择态可以取消")
	pm._unhandled_input(esc)
	check(not pm.visible, "选目标格时 Esc 归行动栏的「取消」，不开菜单")
	bar.clear()
	pm._unhandled_input(esc)
	check(pm.visible and pm.get_tree().paused, "非选目标时 Esc 打开菜单并真的暂停")
	pm._unhandled_input(esc)
	check(not pm.visible and not pm.get_tree().paused, "再按一次关掉并解除暂停")

	# ①b 「返回主菜单 / 退出游戏」要先过一道确认（团队 2026-08-27 要求：两项都不可撤销）
	var fired: Array = []
	pm.chose.connect(func(a: String) -> void: fired.append(a))
	pm.open()
	check(pm._glow.visible and pm._glow.get_child_count() == CWPauseMenu.GLOW.size(),
		"选中项有辉光（%d 层，和主菜单同一套）" % CWPauseMenu.GLOW.size())
	check((pm._glow.get_child(0) as Label).text == pm._list[pm._selected]["text"],
		"辉光跟着选中项走")
	var back_at := -1
	for i in CWPauseMenu.ITEMS.size():
		if CWPauseMenu.ITEMS[i]["id"] == "menu":
			back_at = i
	pm._activate(back_at)
	check(fired.is_empty(), "点「返回主菜单」不直接执行")
	check(pm._confirming == "menu" and pm._list.size() == 2, "先进确认页")
	check(pm._list[pm._selected]["id"] == "no", "确认页默认停在「取消」上，回车不会顺手确认")
	pm._unhandled_input(esc)
	check(pm._confirming == "" and pm.visible, "确认页上按 Esc 退回上一层，不是关掉整个菜单")
	pm._activate(back_at)
	pm._activate(1)                      ## 「取消」
	check(fired.is_empty() and pm._confirming == "", "选「取消」退回主列表，什么都没执行")
	pm._activate(back_at)
	pm._activate(0)                      ## 「确定」
	check(fired.size() == 1 and fired[0] == "menu", "确认之后才真的执行")
	check(not pm.visible and not pm.get_tree().paused, "执行时菜单收起并解除暂停")
	pm.active = false

	# ② 拆局：棋盘要擦回开局前
	## 交给 AI 打（不然 start() 会停在「请玩家落子」那一问上，一个细胞都还没有，
	## 「细胞节点清干净了」就成了一句空话）
	m.human_players = []
	m.ai_delay_ms = 0
	m.start()
	await process_frame          ## 细胞节点是 _process 里按 game.cells 建的，得让它跑一帧
	check(m.game.count_tissue(CWData.Tissue.CANCER) > 0, "开局铺了癌组织")
	check(m.ui.visible and pm.active, "开局后 HUD 出现、暂停菜单启用")
	var n_cells: int = m._cell_nodes.size()
	m.teardown()
	check(m.game == null, "对局已释放")
	check(m._cell_nodes.is_empty(), "细胞节点清干净（原有 %d 个）" % n_cells)
	var dirty := 0
	for c in CWData.all_coords():
		var tex: String = m.board.map[m.board.axial_to_rc(c)]["instance"].texture.resource_path.get_file()
		if "cancer" in tex:
			dirty += 1
	check(dirty == 0, "棋盘擦回开局前，没有残留的癌性贴图（剩 %d 格）" % dirty)
	check(not m.ui.visible and not pm.active, "HUD 收起、暂停菜单停用")

	# ③ 拆完还能再开一局（人数可能变，面板要按新人数重建）
	m.start()
	check(m.game != null and m.game.count_tissue(CWData.Tissue.CANCER) > 0, "拆完还能再开一局")
	m.teardown()

	# ④ 卡在「等玩家点格子」时拆局，信号必须断干净
	## 不断的话，对局释放之后鼠标往棋盘上一动，那个还挂着的处理函数就去调用
	## 已经置空的 game —— **debug 模式下 Godot 直接断在调试器里，表现就是「卡死」**。
	## 2026-08-27 团队试玩报的「返回主菜单后游戏卡死」就是这条。
	m.human_players = [0]
	m.start()
	check(not m.board.tile_hovered.get_connections().is_empty(),
		"询问期间棋盘悬停有接收方（说明确实连上了）")
	m.teardown()
	check(m.board.tile_hovered.get_connections().is_empty(), "拆局后悬停信号断干净")
	check(m.board.tile_clicked.get_connections().is_empty(), "拆局后点击信号断干净")
	check(m.bridge == null, "桥也放掉了")

	main_scene.queue_free()

# ---- 手牌抽屉 ----
## 手牌上限规则**还没定**，所以张数多了必须自己压缩间距 ——
## 按设计稿那个 52 的固定间距，第 6 张就开始盖到右下角的行动栏上。
## 这种越界只在手牌攒多了才出现，正常试玩很可能一直撞不到。
func t_hand() -> void:
	print("[手牌抽屉]")
	var h := CWHand.new()
	root.add_child(h)

	h.sync(5)
	check(h._cards.size() == 5, "手牌 5 张")
	check(is_equal_approx(h._stagger(), CWHand.STAGGER), "5 张以内用设计稿的间距 52")

	var overflow := 0
	for n in [1, 5, 6, 8, 12, 20]:
		h.sync(n)
		if h._slot(n - 1).x + CWHand.CARD.x > CWActionBar.BAR_RECT.position.x:
			overflow += 1
	check(overflow == 0, "1..20 张都没越过行动栏左缘 %d" % int(CWActionBar.BAR_RECT.position.x))

	## 抬起 86px 之后整张卡正好落在画布内（顶 428、底 540）——
	## 86 这个数就是这么定的，改高度或改 top 都得跟着重算
	check(CWHand.REST_TOP - CWHand.LIFT + CWHand.CARD.y == CWView.screen_size().y,
		"悬停抬起后整张卡刚好铺到画布底边")
	check(CWHand.CARD.x - CWHand.STAGGER == CWHand.PUSH,
		"推开量正好等于重叠量 %d（推完两边就不再压着抬起的那张）"
		% int(CWHand.CARD.x - CWHand.STAGGER))

	h.sync(0)
	check(h._cards.is_empty(), "手牌清空")
	h.queue_free()

# ---- 开场推进的机位插值 ----
## 这一条盯的是「两端都对、中间不对」——最难查的那类动画错。
## 直接插相机的 position 和 zoom，起点终点都严丝合缝，唯独途中取景会游走；
## 而这只有真的盯着动画看才觉得「不好看」，说不清哪儿不对（团队试玩报的就是这个）。
func t_view_blend() -> void:
	print("[开场机位插值]")
	var board := make_board()
	var cam := Camera2D.new()

	# ① 两端必须和各自的机位严格一致
	CWView.apply(cam, board, CWView.MENU_ZOOM, CWView.MENU_LOOK_AT, CWView.MENU_ANCHOR)
	var at_menu := cam.position
	CWView.apply(cam, board, CWView.GAME_ZOOM, CWView.GAME_LOOK_AT, CWView.GAME_ANCHOR)
	var at_game := cam.position
	CWView.blend(cam, board, 0.0)
	check(cam.position.is_equal_approx(at_menu)
		and is_equal_approx(cam.zoom.x, CWView.MENU_ZOOM), "k=0 就是菜单机位")
	CWView.blend(cam, board, 1.0)
	check(cam.position.is_equal_approx(at_game)
		and is_equal_approx(cam.zoom.x, CWView.GAME_ZOOM), "k=1 就是对局机位")

	# ② 途中：棋盘中心的横移速度要基本均匀
	var origin_x: float = CWView.board_origin(board).x
	var half: float = CWView.screen_size().x / 2.0
	var xs: Array[float] = []
	for i in 41:
		CWView.blend(cam, board, i / 40.0)
		xs.append(half + (origin_x - cam.position.x) * cam.zoom.x)
	var peak := 0.0
	var total := 0.0
	for i in 40:
		var d: float = absf(xs[i + 1] - xs[i])
		peak = maxf(peak, d)
		total += d
	var ratio: float = peak / (total / 40.0)
	check(ratio < 1.4,
		"棋盘横移基本匀速（最快/平均 = %.2f；直接插 position 会到 1.76）" % ratio)

	# ③ zoom 走几何插值：视觉缩放速度取决于每帧的**倍率**，倍率恒定才匀
	var first := 0.0
	var geometric := true
	for i in 40:
		CWView.blend(cam, board, i / 40.0)
		var a: float = cam.zoom.x
		CWView.blend(cam, board, (i + 1) / 40.0)
		var r: float = cam.zoom.x / a
		if i == 0:
			first = r
		elif not is_equal_approx(r, first):
			geometric = false
	check(geometric, "zoom 是几何插值（每帧倍率恒定 %.4f）" % first)

	cam.free()
	board.free()

# ---- 掷骰结算说明 ----
## 记下引擎通报过的每一句话
class ResultRecorder:
	extends CWHeuristicBridge
	var said: Array = []
	var where: Array = []
	func show_result(text: String, at: Vector2i) -> void:
		said.append(text)
		where.append(at)


## 「攻击成功」这类结算说明**必须由引擎给**：点数怎么判读是规则，
## 表现层照着点数自己再判一遍等于把规则抄了第二份，改一处就会对不上。
func t_announce() -> void:
	print("[掷骰结算说明]")
	var g := CWGame.new()
	g.init(CWData.FACTION_ORDER[2], 5)
	var rec := ResultRecorder.new()
	rec.game = g
	g.bridges[0] = rec
	g.bridges[1] = rec            ## 同一个对象注册给两个玩家（热座）
	g.announce("攻击大成功", Vector2i(1, 2))
	check(rec.said.size() == 1, "通报按对象去重，只报一次")
	check(rec.said[0] == "攻击大成功" and rec.where[0] == Vector2i(1, 2),
		"文字和格子原样传到表现层")
	g.dispose()

	## 真跑一局：攻击/突变/抗体三处掷骰都要报出来
	var g2 := CWGame.new()
	g2.init(CWData.FACTION_ORDER[4], 99)
	var rec2 := ResultRecorder.new()
	rec2.game = g2
	for pid in g2.order:
		g2.bridges[pid] = rec2
	await g2.run_game()
	var kinds := {}
	for t: String in rec2.said:
		kinds[t.split("：")[0].substr(0, 2)] = true
	check(not rec2.said.is_empty(), "一局里报出了 %d 条结算说明" % rec2.said.size())
	check(kinds.has("攻击"), "攻击的判定结果有通报")
	var blank := false
	for t: String in rec2.said:
		if t.strip_edges().is_empty():
			blank = true
	check(not blank, "没有空白通报")
	g2.dispose()

	## 提示不能压在骰面上。锚点必须是骰子的**外框**：
	## 骰子在屏幕上有一百多像素高，拿格子中心当锚点提示就正好落在骰面上
	## （2026-08-28 团队截图报的）。这类错只有截图才看得出来，所以把摆位抽出来直接测。
	var screen := CWView.screen_size()
	var box := Vector2(120, 40)
	var mid := Rect2(Vector2(400, 200), Vector2(104, 104))
	var at_mid := CWToast.place(box, mid, screen)
	check(at_mid.y + box.y <= mid.position.y, "提示浮在骰子上方，底边不越过骰子顶边")
	check(is_equal_approx(at_mid.x + box.x / 2.0, mid.get_center().x), "横向对齐骰子中线")

	var high := Rect2(Vector2(400, 4), Vector2(104, 104))
	var at_high := CWToast.place(box, high, screen)
	check(at_high.y >= high.end.y, "骰子贴着画布顶边时，提示翻到它下面而不是压上去")

	var edge := Rect2(Vector2(screen.x - 20, 200), Vector2(104, 104))
	var at_edge := CWToast.place(box, edge, screen)
	check(at_edge.x + box.x <= screen.x, "贴右边缘时提示收得回画布内")


# ---- 行动栏宽度 ----
## 最挤的情况是 T细胞的四个技能。快捷键数字标在费用行前面，只有「迁移」会因此变宽
## （它标题最短、费用最长）。放不下的话整条会顶出画布右缘 ——
## 而这**只有轮到 T细胞 时才看得见**，平时试玩撞不到。
func t_action_bar_width() -> void:
	print("[行动栏宽度]")
	var bar := CWActionBar.new()
	root.add_child(bar)
	bar.show_bar("", "", [
		{ "title": "迁移", "cost": "0.5 / 1.0" },
		{ "title": "基因表达", "cost": "0.5 抽卡" },
		{ "title": "细胞毒素", "cost": "1.0" },
		{ "title": "裂解", "cost": "1.0" }])
	var total := 0.0
	var n := 0
	var badge := ""
	var plated := false
	for c in bar._row.get_children():
		if not (c is PanelContainer):
			continue
		total += (c as Control).get_combined_minimum_size().x
		if n == 0:
			## 费用行 = [快捷键数字（垫灰底）] + [费用文字]
			var line: Node = c.get_child(0).get_child(1)
			plated = line.get_child(0) is PanelContainer
			if plated:
				badge = (line.get_child(0).get_child(0) as Label).text
		n += 1
	total += CWActionBar.GAP * maxi(n - 1, 0)
	check(n == 4, "四个技能按钮")
	check(total <= CWActionBar.BAR_RECT.size.x,
		"T细胞四技能合计 %d px，放得进 %d px" % [int(total), int(CWActionBar.BAR_RECT.size.x)])
	check(plated and badge == "1", "第一个按钮的快捷键数字垫了灰底（%s）" % badge)
	bar.queue_free()

# ---- 开场过场不能被启动它的那一下点击跳掉 ----
## Control 的 `gui_input` **不会自动吃掉事件**。不显式标记已处理的话，
## 点「开始对局」那一下会继续传到 main.gd 的 `_unhandled_input`，
## 在那儿被「过场中点一下跳过」当成跳过指令 —— 于是过场从来没播出来过，
## 表现是「地图瞬间就位」（团队反馈「开局动画不好看」的真正原因，2026-08-27 查到）。
##
## 真实点击那条路 `--headless` 下测不了（没有显示服务，GUI 输入进不了管线），
## 所以这里测的是那道**时间闸**：过场刚起步的一小段里，点击一律不算跳过。
## 菜单侧的 `set_input_as_handled()` 才是正解，这道闸是第二层保险 ——
## 「事件被谁消费」在加新界面时最容易被破坏，而破坏的表现是过场整个消失。
func t_enter_not_skipped() -> void:
	print("[开场过场不被自己的点击跳掉]")
	var main_scene: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main_scene)
	await process_frame
	var cam: Camera2D = main_scene.get_node("Camera2D")
	check(is_equal_approx(cam.zoom.x, CWView.MENU_ZOOM), "起手停在菜单机位")

	main_scene._begin()
	check(main_scene._tween != null and main_scene._tween.is_running(), "过场起步了")

	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	main_scene._unhandled_input(press)
	check(main_scene._tween.is_running(),
		"刚起步时漏下来的那一下点击不算跳过（防的就是启动它的那一下）")
	check(cam.zoom.x > CWView.GAME_ZOOM, "镜头没有一步跳到对局机位")

	(main_scene.get_node("Match") as CWMatch).teardown()
	main_scene.queue_free()


# ---- 主菜单：三条会被「别处改动」悄悄弄坏的约束 ----
# ① 装饰细胞踩的那五格，得真的在棋盘上。地图改版时最容易漏掉的就是这种硬写的坐标。
# ② 机位换算得可逆：把相机摆到算出来的位置，看点必须正好落在设计稿标的锚点上。
# ③ 字号必须是点阵网格的整数倍 —— 中文 10 的倍数、Logo 用的 Silkscreen 8 的倍数。
#    这条最容易在「随手调一下大小」时破掉，破掉之后字会被重采样磨出灰边，
#    但只在特定字号下明显，肉眼未必当场看得出来。
func t_main_menu() -> void:
	print("[主菜单]")
	var menu_script := load("res://scripts/ui/main_menu.gd")
	var board := make_board()

	var all_on := true
	var all_rendered := true
	for at: Vector2i in menu_script.DECOR:
		if not CWData.is_on_board(at):
			all_on = false
		if board.tile_center(at) == Vector2.ZERO:      # 没画出来的格子会返回零向量
			all_rendered = false
	check(all_on, "%d 个装饰细胞的坐标都在棋盘范围内" % menu_script.DECOR.size())
	check(all_rendered, "每个装饰细胞脚下都有一块真实存在的组织")

	# 机位：把相机摆到算出来的位置后，看点应当正好投影到锚点上
	var screen := Vector2(960, 540)
	var look_at := Vector2(123, -45)
	var anchor := CWView.MENU_ANCHOR
	var zoom := CWView.MENU_ZOOM
	var cam := CWView.camera_pos_for(look_at, anchor, zoom, screen)
	var projected: Vector2 = screen / 2.0 + (look_at - cam) * zoom
	check(projected.distance_to(anchor) < 0.001, "机位换算可逆（看点落在锚点 %s 上）" % anchor)

	# 菜单场景里的节点名、字号
	var scene = load("res://scenes/MainMenu.tscn").instantiate()
	var items: Control = scene.get_node("UI/Screen/Items")
	var names_ok := true
	for item in menu_script.ITEMS:
		if not items.has_node(item["node"]):
			names_ok = false
	check(names_ok, "ITEMS 里的 %d 个节点名在场景里都存在" % menu_script.ITEMS.size())

	# 键盘上下必须跳过灰掉的项。现在中间三项都没实现，从第 0 项往下应直接落到最后一项。
	var last: int = menu_script.ITEMS.size() - 1
	check(menu_script.next_enabled(0, 1) == last, "键盘往下跳过了灰掉的项")
	check(menu_script.next_enabled(last, -1) == 0, "键盘往上跳过了灰掉的项")
	check(menu_script.next_enabled(0, -1) == 0, "到顶了就停在原地，不绕回")

	var grid_ok := true
	var bad := ""
	for label in _all_labels(scene):
		var size: int = label.get_theme_font_size("font_size")   ## 主题项叫 font_size，不是 font
		var grid := 8 if label.get_theme_font("font").resource_path.contains("silkscreen") else 10
		if size % grid != 0:
			grid_ok = false
			bad = "%s=%dpx（要 %d 的倍数）" % [label.name, size, grid]
	check(grid_ok, "所有字号都落在点阵网格上" if grid_ok else "字号脱离点阵网格：%s" % bad)

	scene.free()
	board.free()


func _all_labels(node: Node) -> Array[Label]:
	var out: Array[Label] = []
	if node is Label:
		out.append(node)
	for child in node.get_children():
		out.append_array(_all_labels(child))
	return out


# ---- 掷骰演出钩子：送给表现层的点数，必须就是引擎结算用的那个点数 ----
# D 方案（着色器骰子）靠 CWBridge.show_roll() 把结果送到表现层。
# 最关键的不变量是「演出落在哪一面 == 规则算出来的结果」—— 若两者脱钩，
# 骰子会停在一个和实际结算不符的点数上，这是掷骰动画最经典也最难查的 bug。
# 这里拿钩子收到的值和日志里实际结算用的值逐次交叉核对。
#
# 注意本组**不**负责证明「演出不会扰动 rng」：roll_shown 与 roll_d6 消耗的
# rng 完全相同，且任何扰动只要是确定性的就仍然可复现（由 t_determinism 覆盖）。
func t_roll_hook() -> void:
	print("[掷骰演出钩子]")

	var g := CWGame.new()
	g.init(CWData.FACTION_ORDER[4], 99)
	var spies: Array = []
	for pid in g.order:
		var b := CWRollSpy.new()
		b.game = g
		g.bridges[pid] = b
		spies.append(b)
	var _w: int = await g.run_game()

	var rolls: Array = spies[0].rolls          # 广播的，每个桥收到的是同一份
	check(rolls.size() > 0, "钩子被调用了 %d 次（不是死代码）" % rolls.size())

	var in_range := true
	var reasons := {}
	for r in rolls:
		if r["value"] < 1 or r["value"] > r["sides"]:
			in_range = false
		reasons[r["reason"]] = true
	check(in_range, "每次掷骰的点数都落在 1..面数 之内")
	check(reasons.has("攻击"), "攻击掷骰走了演出钩子")

	var all_same := true
	for b in spies:
		if b.rolls.size() != rolls.size():
			all_same = false
	check(all_same, "掷骰广播给了全部 %d 个桥（AI 掷的骰旁观者也看得见）" % spies.size())

	# ── 核心检查：逐次核对「演出收到的点数」与「引擎写进日志的结算点数」 ──
	# 日志格式见 CWActions._do_attack()：「攻击掷骰 N：…」
	var shown: Array[int] = []
	for r in rolls:
		if r["reason"] == "攻击":
			shown.append(r["value"])
	var logged: Array[int] = []
	for line in g.logs:
		var i: int = line.find("攻击掷骰 ")
		if i >= 0:
			logged.append(int(line.substr(i + 5)))
	check(logged.size() == shown.size() and logged == shown,
		"演出收到的点数 == 引擎结算用的点数（逐次核对 %d 次攻击）" % shown.size())

	# 骰-1 决定骰子落在棋盘格上，所以每次掷骰都必须指向一个真实存在的格
	var coords_ok := true
	for r in rolls:
		if not CWData.is_on_board(r["at"]):
			coords_ok = false
	check(coords_ok, "每次掷骰都指向棋盘上真实存在的一格（骰子要落在那里）")

	g.dispose()


## 只记录、不干预的测试用桥：ask 沿用启发式 AI，show_roll 把参数存下来。
class CWRollSpy extends CWHeuristicBridge:
	var rolls: Array = []

	func show_roll(reason: String, value: int, sides: int, pid: int, at: Vector2i) -> void:
		rolls.append({ "reason": reason, "value": value, "sides": sides, "pid": pid, "at": at })


# ---- 骰子（方案 D）：着色器要能编译，静止姿态要真的把那一面转到朝上 ----
# REST 表若写错，骰子会停在与结算结果不符的面上 —— 而这种错只有肉眼能发现，
# 所以这里用矩阵直接验：把该面的法线按静止姿态转一下，必须指向正上方。
func t_dice() -> void:
	print("[骰子·方案D]")

	var sh := load("res://assets/shaders/dice.gdshader")
	check(sh != null, "着色器资源能加载")

	var d: CWDice = CWDice.new()
	d._ready()                       # 不入场景树，直接建材质（着色器编译失败会在这里报错）
	check(d.material != null and d.material.shader == sh, "骰子节点挂上了这个着色器")

	# 各面法线（本地空间）。**必须和着色器里 face_val() 的约定一致**：
	# +Z=1 −Z=6 +X=2 −X=5 +Y=3 −Y=4，对面点数和为 7。
	# 跨语言（GDScript / GLSL）没法共享常量，这组检查就是那道防线。
	var face_n := {
		1: Vector3(0, 0, 1),  6: Vector3(0, 0, -1),
		2: Vector3(1, 0, 0),  5: Vector3(-1, 0, 0),
		3: Vector3(0, 1, 0),  4: Vector3(0, -1, 0),
	}
	var all_up := true
	var opposite_ok := true
	for v in range(1, 7):
		var up: Vector3 = CWDice.euler_basis(CWDice.REST[v]) * face_n[v]
		if up.distance_to(Vector3.UP) > 0.001:
			all_up = false
		if face_n[v].dot(face_n[7 - v]) > -0.999:
			opposite_ok = false
	check(all_up, "六种静止姿态都把对应点数转到了正上方")
	check(opposite_ok, "对面点数和为 7（法线互为反向）")

	# d3 借同一颗 d6 演，三个结果要落进 1-2 / 3-4 / 5-6 三个不同色区
	var zones := {}
	for v in range(1, 4):
		zones[_zone_of(d._face_for(v, 3))] = true
	check(zones.size() == 3, "d3 的三个结果落在三个不同色区")
	check(d._face_for(4, 6) == 4, "d6 直接用原点数")

	# 落点几何：接地点由着色器的相机参数反推，必须落在方块内且位于中心偏下
	# （立方体是俯视看的，底面中心自然比方块中心低）。
	var cy := CWDice.contact_y(d.size.y)
	check(cy > d.size.y * 0.5 and cy < d.size.y,
		"底面接地点在方块中心偏下、且没跑出方块（%.1f / %.0f）" % [cy, d.size.y])

	# 摆位：底面中心要对准落点
	d.place_at(Vector2(300, 180), 0)
	check(absf(d.position.x + d.size.x * 0.5 - 300.0) < 0.01
		and absf(d.position.y + cy - 180.0) < 0.01, "骰子底面中心对准了落点")

	# 深度：骰子必须**压在自己那格上面**、又被前一排盖住。
	# 上一版这条是拿 place_at 自己算出来的 z 跟自己比，等于什么都没验 ——
	# 实际骰子的 z 比自己那格低 4（tile_center 给的是顶面中心，比贴图中心高 4px），
	# 于是被脚下的组织盖住，看起来像"掉到棋盘下面"。团队试玩时才发现。
	var bd := make_board()
	var depth_ok := true
	var layered := true
	for c in [Vector2i(0, 0), Vector2i(-2, 3), Vector2i(4, -1), Vector2i(0, 6)]:
		var tile: Sprite2D = bd.map[bd.axial_to_rc(c)]["instance"]
		d.place_at(bd.tile_center(c), bd.tile_z(c, bd.Z_DICE))
		if d.z_index <= tile.z_index or d.z_index >= tile.z_index + bd.distance_y:
			depth_ok = false
		# 三层的先后：高亮 < 细胞 < 骰子，且都夹在自己那格和前一排之间
		if not (bd.tile_z(c, bd.Z_MARK) < bd.tile_z(c, bd.Z_CELL)
				and bd.tile_z(c, bd.Z_CELL) < bd.tile_z(c, bd.Z_DICE)):
			layered = false
	check(depth_ok, "骰子压在自己那格上面、又低于前一排（不会掉到棋盘后面）")
	check(layered, "站在格子上的三层顺序：高亮 < 细胞 < 骰子")
	check(bd.Z_DICE < bd.distance_y, "最上面那层仍低于前一排的 +%d" % bd.distance_y)

	bd.free()
	d.free()


## 点数 → 色区档位，和着色器里 face_color() 的分档一致
func _zone_of(face: int) -> int:
	if face <= 2:
		return 0
	elif face <= 5:
		return 1
	return 2



# ---- 快照 / 回滚：AI 推演的地基 ----
func t_snapshot() -> void:
	print("[快照回滚]")
	var g := make_game(4, 31)
	await run_setup(g)
	## 先往前跑几十步，到一个「中局」局面
	for i in 40:
		if g.pending().is_empty():
			break
		await g.step(g.rng.randi_range(0, 3))
	var h0 := g.state_hash()
	var snap := g.snapshot()
	## 拿它乱走一通
	for i in 30:
		if g.pending().is_empty():
			break
		await g.step(g.rng.randi_range(0, 5))
	check(g.state_hash() != h0, "推演确实改变了局面")
	g.restore(snap)
	check(g.state_hash() == h0, "restore() 之后局面逐位还原")
	## 随机数发生器也得还原 —— 否则同一步走两遍会掷出不同的骰子
	var a := g.rng.randi()
	g.restore(snap)
	check(g.rng.randi() == a, "rng 状态也在快照里")
	g.dispose()


# ---- 推演不能污染主线：这是「AI 能自己往前推」的验收条件 ----
func t_rollout_isolation() -> void:
	print("[推演隔离]")
	## 两局同种子。对照组一路走到底；实验组每走一步之前先做 5 次推演再回滚。
	var control := make_game(4, 77)
	var probe := make_game(4, 77)
	await run_setup(control)
	await run_setup(probe)
	for turn_i in 25:
		if control.pending().is_empty() or probe.pending().is_empty():
			break
		## 实验组：快照 → 乱跑 → 回滚，重复 5 次
		for r in 5:
			var snap := probe.snapshot()
			for k in 8:
				if probe.pending().is_empty():
					break
				await probe.step(probe.rng.randi_range(0, 4))
			probe.restore(snap)
		## 两边走同一步
		await control.step(turn_i % 3)
		await probe.step(turn_i % 3)
	check(control.state_hash() == probe.state_hash(),
		"做过 125 次推演的那一局，主线状态和没推演过的完全一致")
	control.dispose()
	probe.dispose()


# ---- step() 必须是原子的：一个行动不能在中途再问一次 ----
func t_step_atomic() -> void:
	print("[行动原子性]")
	## 分化、裂解、血行转移、跃进 这四个原来都是「先选行动、再问一次细节」。
	## 埋在 execute() 里的询问会让 AI 没法把一个行动当成原子来推演，
	## 所以它们都被摊成了顶层选项 —— 这里逐个核对选项自带全部参数。
	var g := make_game(4, 5)
	await run_setup(g)
	var imm: Dictionary = g.living_cells(CWData.Faction.IMMUNE)[0]
	g.immune_level = 2
	var opts: Array = g.actions.build_options(imm)
	var diff := []
	for o in opts:
		if o["data"].get("act", "") == "differentiate":
			diff.append(o["data"])
	check(diff.size() == 4, "四种分化各是一个顶层选项（%d）" % diff.size())
	var typed := true
	for d in diff:
		if not d.has("type"):
			typed = false
	check(typed, "每个分化选项自带 type，execute() 不必再问")
	## 裂解：找一格空地，手动造成固化癌组织再站上去
	var solid := Vector2i.MAX
	for c in g.tiles.keys():
		if g.cells_at(c).is_empty():
			solid = c
			break
	check(solid != Vector2i.MAX, "找得到一格空地")
	g.tiles[solid]["tissue"] = CWData.Tissue.SOLID
	imm["itype"] = CWData.ImmuneType.T_CELL
	imm["pos"] = solid
	imm["energy"] = 50
	var lyse := []
	for o in g.actions.build_options(imm):
		if o["data"].get("act", "") == "lyse":
			lyse.append(o["data"]["purge"])
	check(lyse.size() == 2 and (true in lyse) and (false in lyse),
		"裂解摊成「并净化 / 暂不」两个顶层选项")
	## 整份行动表里不该再有任何需要二次询问的项
	var need_more := false
	for o in g.actions.build_options(imm):
		var d: Dictionary = o["data"]
		if d.get("act", "") in ["differentiate", "lyse", "homing", "jump"] \
			and d.size() < 2:
			need_more = true
	check(not need_more, "没有「选了还要再问一次」的行动")
	g.dispose()


# ---- 手牌上限 8：抽卡选项消失、骨髓不发卡、卡名按露出宽度截断 ----
func t_hand_limit() -> void:
	print("[手牌上限]")
	check(CWData.HAND_MAX == 8, "上限是 8（团队 2026-08-28 定，PRD 没有这条）")
	var g := make_game(2, 3)
	g.setup.build_board()
	var cell := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i.ZERO,
		CWData.ImmuneType.BASIC, -1)
	cell["energy"] = 500
	g.cells.append(cell)
	## 直接塞满 —— 靠抽是塞不满的（见下面 t_card_pool 的「I 级最多 6 张」）
	for name in CWCardData.CARDS:
		if cell["hand"].size() >= CWData.HAND_MAX:
			break
		if CWCardData.CARDS[name]["kind"] != CWCardData.Kind.EVENT:
			cell["hand"].append(name)
	check(cell["hand"].size() == 8, "手上 8 张")
	cell["draws_used"] = 0
	check(not _has_act(g.actions.build_options(cell), "draw"),
		"满 8 张 → 抽卡选项直接不出现")
	## 骨髓：手牌满时不发卡，**卡留着**
	var m: Vector2i = CWData.MARROWS[0]
	g.tiles[m]["cards"] = 1
	g.actions.collect_special(cell, m)
	check(g.tiles[m]["cards"] == 1 and cell["hand"].size() == 8,
		"手牌满时踩骨髓：卡留在骨髓里，没被浪费")
	cell["hand"].resize(7)
	g.actions.collect_special(cell, m)
	check(g.tiles[m]["cards"] == 0, "空出位置后骨髓就把卡给出去了")
	## 兜底：直接调 draw() 也撑不爆
	cell["hand"].resize(8)
	g.cards.draw(cell, "测试")
	check(cell["hand"].size() == 8, "draw() 自己也守着上限")
	g.dispose()


# ---- 卡池：身份表 + 抽卡合法性（效果尚未实现）----
func t_card_pool() -> void:
	print("[卡池]")
	check(CWCardData.CARDS.size() == 66, "66 张唯一卡（%d）" % CWCardData.CARDS.size())
	## 四个免疫池 + 癌症三期的张数，逐个对照 PRD
	var want := [11, 14, 17, 22]
	for lv in 4:
		var n: int = CWCardData.pool_of(CWData.Faction.IMMUNE, lv, 1).size()
		check(n == want[lv], "免疫 %s 级池 %d 张" % [CWData.LEVEL_NAMES[lv], n])
	for r in [1, 10, 20]:
		var n: int = CWCardData.pool_of(CWData.Faction.CANCER, 0, r).size()
		check(n == 17, "癌症池第 %d 回合 %d 张（不分等级）" % [r, n])
	check(CWCardData.cancer_phase(9) == 0 and CWCardData.cancer_phase(10) == 1 \
		and CWCardData.cancer_phase(19) == 1 and CWCardData.cancer_phase(20) == 2,
		"癌症卡分期切在第 10 / 20 回合")
	## 同种子必须抽出同一张
	var g := make_game(2, 1)
	g.setup.build_board()
	var cell := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i.ZERO,
		CWData.ImmuneType.BASIC, -1)
	g.cells.append(cell)
	g.rng.seed = 12345
	var a := g.cards.pick(cell)
	g.rng.seed = 12345
	check(g.cards.pick(cell) == a, "同种子抽出同一张（%s）" % a)
	## 同名【技能】在手 → 从候选剔除；【事件】不受这条限制
	cell["hand"] = ["补体调理"]
	check(not g.cards.is_legal(cell, "补体调理"), "手上已有同名技能 → 抽不到")
	check(g.cards.is_legal(cell, "急性炎症反应"), "事件卡不受同名限制")
	cell["hand"] = []
	cell["equipped"] = ["组织驻留"]
	check(not g.cards.is_legal(cell, "组织驻留"), "已装备的同名永久技能 → 抽不到")
	## I 级池只有 6 张技能（另外 5 张是事件），所以 I 级手牌最多 6 张 —— 碰不到 8 的上限
	cell["equipped"] = []
	var skills := 0
	for c in CWCardData.pool_of(CWData.Faction.IMMUNE, 0, 1):
		if CWCardData.CARDS[c["name"]]["kind"] != CWCardData.Kind.EVENT:
			skills += 1
	check(skills == 6, "I 级池只有 %d 张技能 → I 级手牌上限实际是 6" % skills)
	## 候选被抽干之后就抽不出来了
	var all_skills: Array = []
	for c in CWCardData.pool_of(CWData.Faction.IMMUNE, 0, 1):
		if CWCardData.CARDS[c["name"]]["kind"] != CWCardData.Kind.EVENT:
			all_skills.append(c["name"])
	cell["hand"] = all_skills
	var only_events := true
	for i in 20:
		var got := g.cards.pick(cell)
		if got != "" and CWCardData.CARDS[got]["kind"] != CWCardData.Kind.EVENT:
			only_events = false
	check(only_events, "技能抽干后只剩事件卡")
	g.dispose()




# ---- 卡名：写全名不加省略号，靠 clip_contents + 后一张卡遮挡 ----
func t_card_name_fit() -> void:
	print("[卡名显示]")
	var hand := CWHand.new()
	hand._ready()
	hand.sync(3, Vector2.INF, PackedStringArray(
		["补体级联", "抗体依赖细胞毒作用", "缺氧适应"]))
	var full := true
	var clipped := true
	for c in hand._cards:
		if not c.clip_contents:
			clipped = false
	check(clipped, "每张卡都开了 clip_contents —— 最后一张没有邻居遮挡，不裁会溢到棋盘上")
	var texts: Array[String] = []
	for c in hand._cards:
		texts.append((c.get_node("Name") as Label).text)
	check(texts == ["补体级联", "抗体依赖细胞毒作用", "缺氧适应"],
		"名字一律写全，不加省略号（%s）" % str(texts))
	## 露出宽度：前面的被压成 _stagger()，最后一张露整卡宽
	check(hand.exposed_width(2) == CWHand.CARD.x, "最后一张露出整卡宽 72")
	check(hand.exposed_width(0) == CWHand.STAGGER, "3 张时前面的各露 52")
	## 满编 8 张会压到 (300-72)/7 ≈ 32.6
	hand.sync(CWData.HAND_MAX)
	check(hand.exposed_width(0) < 34.0,
		"8 张时每张只露 %.1fpx（约 3 个字）" % hand.exposed_width(0))
	hand.free()


# ---- 按钮不消失、只变暗（团队 2026-08-28）----
func t_buttons_dim() -> void:
	print("[按钮变暗]")
	var g := make_game(4, 5)
	await run_setup(g)
	var imm: Dictionary = g.living_cells(CWData.Faction.IMMUNE)[0]
	## 按钮集合只看种类和等级，不看能量 —— 这正是「宽度不会跳」的依据
	imm["itype"] = CWData.ImmuneType.T_CELL
	var rich: Array[String] = g.actions.action_kinds(imm)
	imm["energy"] = 1
	var poor: Array[String] = g.actions.action_kinds(imm)
	check(rich == poor, "能量掉光了按钮集合也不变（%s）" % str(rich))
	check(rich == ["move", "draw", "toxin", "lyse"], "T 细胞四个按钮")
	## 分化用掉之后按钮才真的消失（那是一次性事件，不是每步都变）
	g.immune_level = 2
	imm["itype"] = CWData.ImmuneType.BASIC
	imm["differentiated"] = false
	check("differentiate" in g.actions.action_kinds(imm), "III 级未分化 → 有分化按钮")
	imm["differentiated"] = true
	check(not ("differentiate" in g.actions.action_kinds(imm)), "分化过了 → 按钮收掉")
	## 四种癌细胞各自的第四个按钮
	var can: Dictionary = g.living_cells(CWData.Faction.CANCER)[0]
	for pair in [[CWData.CancerType.MELANOMA, "homing"],
			[CWData.CancerType.SIGNET, "mucus"],
			[CWData.CancerType.SCLC, "jump"],
			[CWData.CancerType.OSTEO, ""]]:
		can["ctype"] = pair[0]
		var kinds: Array[String] = g.actions.action_kinds(can)
		check(kinds.size() == (4 if pair[1] != "" else 3) and (pair[1] == "" or pair[1] in kinds),
			"%s 的按钮集合 %s" % [CWData.CANCER_TYPE_NAMES[pair[0]], str(kinds)])
	## 行动栏：灰按钮照样占位，数字键点不动它
	var bar := CWActionBar.new()
	get_root().add_child(bar)
	await process_frame
	bar.show_bar("", "", [
		{ "title": "迁移", "cost": "1 0.5" },
		{ "title": "基因表达", "cost": "2 0.5", "disabled": true },
		{ "title": "细胞毒素", "cost": "3 1.0" }])
	await process_frame
	check(bar._count() == 3, "灰掉的按钮照样占位（否则宽度会跳、快捷键编号也会变）")
	check(bar._is_disabled(1) and not bar._is_disabled(0), "第二个是灰的")
	## 光「点不动」不够 —— 得**看着也是灰的**。
	## 上一版 show_bar 末尾调的是 _set_hot(-1)，而 _hot 本来就是 -1、那函数开头就 return，
	## 于是灰按钮点不动却画得和正常按钮一样（2026-08-28 团队试玩报的）。
	var btns: Array = []
	for c in bar._row.get_children():
		if c is PanelContainer:
			btns.append(c)
	var title_of := func(p: PanelContainer) -> Color:
		return (p.get_child(0).get_child(0) as Label).get_theme_color("font_color")
	check(title_of.call(btns[1]) == CWStyle.TEXT_OFF,
		"灰按钮的标题真的画成了暗色")
	check(title_of.call(btns[0]) != CWStyle.TEXT_OFF, "正常按钮不受影响")
	var hits: Array[int] = []
	bar.chosen.connect(func(i: int) -> void: hits.append(i))
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.keycode = KEY_2
	bar._unhandled_key_input(ev)
	check(hits.is_empty(), "数字键 2 点不动灰按钮")
	ev.keycode = KEY_3
	bar._unhandled_key_input(ev)
	check(hits == [2], "数字键 3 仍然有效 —— 编号不因为有灰按钮而错位")
	bar.free()
	g.dispose()


# ---- 字形覆盖：会上屏的字符串里不能出现字库没有的字 ----
##
## 起因：突变的提示里用了 U+2212（−，MINUS SIGN），点阵字库没有这个字形，
## 玩家看到的是一个方框里写着「2212」（2026-08-28 团队试玩时报的）。
## 这种错**只有在那条分支真的触发时才看得见**，靠人眼盯不住，所以做成自动检查。
##
## 扫的是**字符串字面量**，注释不算（注释不上屏，里面写 ≥ ⌈⌉ 没关系）。
func t_font_coverage() -> void:
	print("[字形覆盖]")
	var font: Font = CWStyle.FONT
	var bad := {}
	var files: Array[String] = []
	_collect_gd("res://scripts", files)
	check(files.size() > 10, "扫到了 %d 个脚本" % files.size())
	for path in files:
		for s in _string_literals(FileAccess.get_file_as_string(path)):
			for k in s.length():
				var code: int = s.unicode_at(k)
				if code > 0x7F and not font.has_char(code):
					bad["U+%04X %s" % [code, s[k]]] = path.get_file()
	var msg := ""
	for k in bad:
		msg += "%s（%s）" % [k, bad[k]]
	check(bad.is_empty(), "所有会上屏的字符字库里都有%s" % ("" if bad.is_empty() else "；缺：" + msg))


func _collect_gd(dir_path: String, out: Array[String]) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if d.current_is_dir():
			_collect_gd(dir_path + "/" + n, out)
		elif n.ends_with(".gd"):
			out.append(dir_path + "/" + n)
		n = d.get_next()
	d.list_dir_end()


## 从源码里抠出所有字符串字面量的内容。跳过 # 注释，处理反斜杠转义。
func _string_literals(src: String) -> Array[String]:
	var out: Array[String] = []
	var buf := ""
	var ins := false
	var esc := false
	var com := false
	for i in src.length():
		var ch := src[i]
		if ch == "
":
			com = false
			continue
		if com:
			continue
		if esc:
			esc = false
			continue
		if ins:
			if ch == "\\":
				esc = true
			elif ch == "\"":
				ins = false
				out.append(buf)
				buf = ""
			else:
				buf += ch
			continue
		if ch == "\"":
			ins = true
		elif ch == "#":
			com = true
	return out