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
	t_anaerobic_round()
	await t_card_events()
	await t_card_events_cancer()
	await t_card_instants()
	await t_card_choices()
	await t_card_mods()
	await t_settle_order_rulings()
	await t_card_perms()
	await t_world_events_draw()
	t_ev_attack_mods()
	await t_ev_attack_flow()
	await t_ev_costs()
	await t_ev_suppressor()
	await t_ev_supply()
	t_ev_solidify_accel()
	await t_ev_chaos()
	await t_ev_chaos_simul()
	t_ev_memory()
	t_ev_proliferate()
	await t_ev_double()
	await t_ev_double_instant()
	await t_ev_lifecycle()
	t_breath_sheets()
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
	await t_ai_cards()
	await t_ai_eval()
	await t_ai_mc()
	await t_config_panel()
	await t_hover_info()
	await t_log_panel()
	await t_rules_page()
	await t_save_load()
	await t_settings()
	t_board_view()
	t_hex_pick()
	await t_ui_bridge()
	await t_human_ask()
	await t_hand_play()
	t_match_panel()
	await t_settle_screen()
	await t_opening()
	await t_pause_and_teardown()
	t_hand()
	await t_hand_limit()
	t_card_pool()
	t_font_coverage()
	t_card_name_fit()
	t_view_blend()
	await t_announce()
	t_action_bar_width()
	await t_buttons_dim()
	await t_enter_not_skipped()
	t_main_menu()
	await t_quit_confirm()
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
		var req: Dictionary = await g.pending()
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


# ---- 无氧呼吸：0.4/格 + 固化 1.0/格，块内均分，四舍五入到十分位；小细胞肺癌 110% ----
func t_anaerobic_round() -> void:
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
	## 除不尽时四舍五入（定案 #43）：2.2 / 4 = 0.55 → 0.6（向下取整会给 0.5）
	g.cells[0]["ctype"] = CWData.CancerType.MELANOMA
	for i in [2, 3]:
		var extra := CWSetup.make_cell(i, i, CWData.Faction.CANCER, coords[i], -1,
			CWData.CancerType.MELANOMA)
		extra["energy"] = 0
		g.cells.append(extra)
	for cell in g.cells:
		cell["energy"] = 0
	g.world._anaerobic()
	check(g.cells[0]["energy"] == 6, "池 2.2 / 4 细胞 = 0.55 → 四舍五入 0.6")
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
	await g.world.revive_immune(pid, m)
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


## 让 cell 的桥对当前行动栏做一次决策，返回所选选项的 data
func _ai_pick(g: CWGame, cell: Dictionary) -> Dictionary:
	var opts: Array = g.actions.build_options(cell)
	var b: CWBridge = g.bridges[cell["pid"]]
	var idx: int = await b.ask({ "kind": "action", "pid": cell["pid"],
		"options": opts, "prompt": "" })
	return opts[idx]["data"]


# ---- AI 会用卡：装备/攻击增益的时机/防御卡的时机/抽卡/代谢耦联与选格子询问 ----
func t_ai_cards() -> void:
	print("[AI·会用卡]")
	var g := make_game(2, 9)
	await run_setup(g)
	for c in g.tiles.keys():
		g.tiles[c]["tissue"] = CWData.Tissue.HEALTHY
		g.tiles[c]["solid"] = 0
		g.tiles[c]["newborn"] = false
	var imm: Dictionary = g.living_cells(CWData.Faction.IMMUNE)[0]
	var can: Dictionary = g.living_cells(CWData.Faction.CANCER)[0]
	imm["pos"] = Vector2i(0, 0)
	can["pos"] = Vector2i(0, 6)
	imm["energy"] = 60
	can["energy"] = 60

	## ① 永久技能到手就装
	imm["hand"] = ["组织驻留"]
	var d: Dictionary = await _ai_pick(g, imm)
	check(d.get("act", "") == "play" and d.get("card", "") == "组织驻留",
		"永久技能到手就装（选了 %s）" % str(d))
	imm["hand"] = []

	## ② 攻击增益：敌人贴脸时先打增益、下一手就是攻击
	can["pos"] = Vector2i(1, 0)
	imm["hand"] = ["补体调理"]
	d = await _ai_pick(g, imm)
	check(d.get("act", "") == "play" and d.get("card", "") == "补体调理",
		"贴脸时先打【补体调理】")
	await g.actions.execute(imm, d)
	d = await _ai_pick(g, imm)
	check(d.get("act", "") == "move" and d.get("to", Vector2i.MAX) == can["pos"],
		"增益打完下一手就是攻击（选了 %s）" % str(d))

	## ③ 攻击增益不空放：没仗可打时压在手里
	can["pos"] = Vector2i(0, 6)
	imm["hand"] = ["穿孔素-颗粒酶"]
	imm["mods"] = []
	d = await _ai_pick(g, imm)
	check(d.get("act", "") != "play", "没仗可打时不空放攻击增益（选了 %s）" % str(d.get("act")))
	imm["hand"] = []

	## ④ 防御卡：敌人近了才亮
	can["hand"] = ["PD-L1表达"]
	imm["pos"] = Vector2i(1, 6)   ## 贴脸
	d = await _ai_pick(g, can)
	check(d.get("act", "") == "play" and d.get("card", "") == "PD-L1表达",
		"敌人贴脸时癌细胞打出【PD-L1表达】")
	imm["pos"] = Vector2i(0, 0)   ## 拉远
	d = await _ai_pick(g, can)
	check(d.get("act", "") != "play", "敌人远时防御卡压在手里（选了 %s）" % str(d.get("act")))
	can["hand"] = []

	## ⑤ 抽卡：能量宽裕才抽
	d = await _ai_pick(g, imm)
	check(d.get("act", "") == "draw", "免疫能量 6.0 且无事可做 → 抽卡（选了 %s）" % str(d.get("act")))
	imm["energy"] = 22
	d = await _ai_pick(g, imm)
	check(d.get("act", "") != "draw", "免疫能量 2.2 → 不抽卡（选了 %s）" % str(d.get("act")))
	imm["energy"] = 60

	## ⑥ 【代谢耦联】两连问：方向选富济贫，数额拉满
	var bi: CWBridge = g.bridges[imm["pid"]]
	can["energy"] = 30
	var dirs := [
		{ "label": "", "data": { "from": can["id"], "to_cid": imm["id"] } },
		{ "label": "", "data": { "from": imm["id"], "to_cid": can["id"] } },
	]
	var di: int = await bi.ask({ "kind": "pick", "tag": "代谢耦联",
		"pid": imm["pid"], "options": dirs, "prompt": "" })
	check(di == 1, "代谢耦联方向：转出方选能量高的一侧（选了 %d）" % di)
	var tiers := [
		{ "label": "", "data": { "pay": 10, "get": 12 } },
		{ "label": "", "data": { "pay": 15, "get": 20 } },
		{ "label": "", "data": { "pay": 20, "get": 25 } },
	]
	var ti: int = await bi.ask({ "kind": "pick", "tag": "代谢耦联",
		"pid": imm["pid"], "options": tiers, "prompt": "" })
	check(ti == 2, "代谢耦联数额：拉满（选了 %d）" % ti)

	## ⑦ 「选一格」子询问：不选停止，挑癌性邻格多的
	for n in CWData.neighbors(Vector2i(-2, 0)):
		g.tiles[n]["tissue"] = CWData.Tissue.CANCER
	var tile_opts := [
		{ "label": "", "data": { "stop": true } },
		{ "label": "", "data": { "to": Vector2i(3, 0) } },
		{ "label": "", "data": { "to": Vector2i(-2, 0) } },
	]
	var pt: int = await bi.ask({ "kind": "pick_tile", "tag": "基质重塑",
		"pid": imm["pid"], "options": tile_opts, "prompt": "" })
	check(pt == 2, "选格子：不停止、挑癌性邻格最多的（选了 %d）" % pt)
	g.dispose()

	## ⑧ 完整对局里卡真的在流动（抽了、也打/装了）
	var g2 := make_game(4, 123)
	var w: int = await g2.run_game()
	check(w >= 0, "有卡版完整对局分出胜负（%s）" % g2.win_reason)
	var drew := false
	var played := false
	for line in g2.logs:
		if line.contains("」抽到"):
			drew = true
		if line.contains("打出【") or line.contains("装备至角色面板"):
			played = true
	check(drew, "完整对局里 AI 抽过卡")
	check(played, "完整对局里 AI 打出/装备过卡")
	g2.dispose()


func _immune_pid(g: CWGame) -> int:
	for pid in g.order:
		if g.player(pid)["faction"] == CWData.Faction.IMMUNE:
			return pid
	return -1


# ---- AI·静态估值：方向对、零和、终局压倒一切 ----
func t_ai_eval() -> void:
	print("[AI·静态估值]")
	var g := make_game(2, 11)
	await run_setup(g)
	var sc := CWEval.score(g, CWData.Faction.CANCER)
	var si := CWEval.score(g, CWData.Faction.IMMUNE)
	check(sc == -si, "双方视角零和（%d / %d）" % [sc, si])
	var flip := Vector2i.MAX
	for c in g.tiles.keys():
		if g.tiles[c]["tissue"] == CWData.Tissue.HEALTHY:
			flip = c
			break
	g.tiles[flip]["tissue"] = CWData.Tissue.CANCER
	var sc2 := CWEval.score(g, CWData.Faction.CANCER)
	check(sc2 > sc, "多一格癌组织，癌方分上涨（%d → %d）" % [sc, sc2])
	g.tiles[flip]["tissue"] = CWData.Tissue.HEALTHY
	g.memory += 3
	check(CWEval.score(g, CWData.Faction.IMMUNE) > si, "记忆 +3，免疫分上涨")
	g.memory -= 3
	g.winner = CWData.Faction.IMMUNE
	check(CWEval.score(g, CWData.Faction.CANCER) <= -CWEval.WIN, "输掉的终局压倒性为负")
	g.winner = -1
	g.dispose()


# ---- AI·扁平蒙特卡洛：零污染、确定性、拿得下白送的击杀、整局能跑 ----
func t_ai_mc() -> void:
	print("[AI·扁平蒙特卡洛]")
	## ① 主线零污染 + 同局面同答案
	var g := make_game(2, 33)
	var ip := _immune_pid(g)
	var mc := CWMonteCarloBridge.new()
	mc.game = g
	mc.rollouts = 1
	mc.horizon = 8
	g.bridges[ip] = mc
	await run_setup(g)
	var req: Dictionary = {}
	while true:
		req = await g.pending()
		if req.is_empty() or (req["kind"] == "action" and req["pid"] == ip):
			break
		await g.step(await g.ask(req["pid"], req))
	check(not req.is_empty(), "推进到了免疫的行动决策点")
	var h0 := g.state_hash()
	var n0 := g.logs.size()
	var a1: int = await mc.ask(req)
	check(g.state_hash() == h0, "蒙特卡洛评估完，主线状态逐位不变")
	check(g.logs.size() == n0, "推演没有留下日志")
	check(not g.sim_quiet, "评估完静音已关（真日志照常记录）")
	var a2: int = await mc.ask(req)
	check(a1 == a2, "同局面两次评估答案一致（确定性）")
	g.dispose()

	## ② 白送的击杀要拿：残血癌细胞贴脸、无处可逃（截断内它还会占地），
	## 评出来的应是攻击那一步。先推进到免疫的行动询问再摆场景，
	## 然后就地重摊选项 —— 蒙特卡洛只在 pending 边界上快照，req 必须就是 _pending
	var g2 := make_game(2, 55)
	var ip2 := _immune_pid(g2)
	var mc2 := CWMonteCarloBridge.new()
	mc2.game = g2
	mc2.rollouts = 3
	mc2.horizon = 12
	g2.bridges[ip2] = mc2
	await run_setup(g2)
	while true:
		req = await g2.pending()
		if req.is_empty() or (req["kind"] == "action" and req["pid"] == ip2):
			break
		await g2.step(await g2.ask(req["pid"], req))
	for c in g2.tiles.keys():
		g2.tiles[c]["tissue"] = CWData.Tissue.HEALTHY
		g2.tiles[c]["solid"] = 0
		g2.tiles[c]["newborn"] = false
	var imm: Dictionary = g2.cell_of(ip2)
	var can: Dictionary = g2.living_cells(CWData.Faction.CANCER)[0]
	imm["pos"] = Vector2i(0, 0)
	imm["energy"] = 80
	imm["hand"] = []
	can["pos"] = Vector2i(1, 0)
	can["energy"] = 5
	can["hand"] = []
	req["options"] = g2.actions.build_options(imm)
	var pick: int = await mc2.ask(req)
	var pd: Dictionary = req["options"][pick]["data"]
	check(pd.get("act", "") == "move" and pd.get("to", Vector2i.MAX) == Vector2i(1, 0),
		"残血癌细胞贴脸 → 蒙特卡洛选择攻击（选了 %s）" % str(pd))
	g2.dispose()

	## ③ 整局跑完 + 确定性：蒙特卡洛桥当免疫方，同种子两局同哈希
	var hs: Array[String] = []
	var ws: Array[int] = []
	for k in 2:
		var g3 := make_game(2, 44)
		var mc3 := CWMonteCarloBridge.new()
		mc3.game = g3
		mc3.rollouts = 1
		mc3.horizon = 6
		g3.bridges[_immune_pid(g3)] = mc3
		ws.append(await g3.run_game())
		hs.append(g3.state_hash())
		g3.dispose()
	check(ws[0] >= 0, "蒙特卡洛桥整局跑完并分出胜负")
	check(hs[0] == hs[1] and ws[0] == ws[1], "同种子两局哈希与胜者一致")


# ---- 对局配置面板：默认值 / 拨值 / 座位规则 / AI 强度接线 ----
func t_config_panel() -> void:
	print("[对局配置面板]")
	var p := CWConfigPanel.new()
	root.add_child(p)
	await process_frame   ## _ready（面板搭建）在入树后的下一帧才跑
	var cfg := p.config()
	check(cfg["players"] == 4 and cfg["faction"] == CWData.Faction.IMMUNE \
		and cfg["smart"] == false, "默认配置：4 人 · 免疫细胞 · 普通 AI")
	check(int(cfg["seed"]) >= 10000000, "随机种子开局就有一枚（8 位）")
	## 打开时焦点在第一行：回车是拨值不是开局（Kevin 8-29：停在按钮上
	## 玩家会以为配置改不了）
	var got: Array = []
	p.confirmed.connect(func(c: Dictionary) -> void: got.append(c))
	p.open()
	check(p.visible, "open() 后面板可见")
	var accept := InputEventAction.new()
	accept.action = "ui_accept"
	accept.pressed = true
	p.handle_input(accept)
	check(got.is_empty() and p.config()["players"] == 6 and p.visible,
		"焦点默认在第一行：回车 = 拨值（人数 4 → 6），不会误开局")
	var down := InputEventAction.new()
	down.action = "ui_down"
	down.pressed = true
	for i in 4:
		p.handle_input(down)   ## 人数 → 阵营 → AI → 种子 → 进入棋盘
	p.handle_input(accept)
	check(got.size() == 1 and not p.visible, "走到「进入棋盘」回车才开局")
	## 键盘拨值：人数成环；阵营环到观战；AI → 较强；种子拨一下换一枚
	p.open()
	var right := InputEventAction.new()
	right.action = "ui_right"
	right.pressed = true
	p.handle_input(right)
	check(p.config()["players"] == 2, "人数 6 再往右回到 2（取值成环）")
	p.handle_input(down)        ## → 我的阵营
	p.handle_input(right)
	check(p.config()["faction"] == CWData.Faction.CANCER, "阵营 → 癌细胞")
	p.handle_input(right)
	check(p.config()["faction"] == -1, "再拨 → 观战")
	p.handle_input(down)        ## → AI 强度
	p.handle_input(right)
	check(p.config()["smart"] == true, "AI 强度 → 较强")
	p.handle_input(down)        ## → 随机种子
	var seed0: int = p.config()["seed"]
	p.handle_input(right)
	check(p.config()["seed"] != seed0, "种子行拨一下 = 换一枚")
	## Esc 收面板发 cancelled（菜单靠它把自己淡回来），不开局；取值局间保留
	var cancels: Array = []
	p.cancelled.connect(func() -> void: cancels.append(1))
	var esc := InputEventAction.new()
	esc.action = "ui_cancel"
	esc.pressed = true
	p.handle_input(esc)
	check(not p.visible and got.size() == 1 and cancels.size() == 1,
		"Esc 收面板并发 cancelled，不开局")
	p.open()
	check(p.config()["players"] == 2 and p.config()["smart"] == true \
		and p.config()["faction"] == -1, "再次打开保留上次取值")
	## 箭头定位固定；按钮变白按「最后动的设备」裁决（Kevin 8-30 终稿）：
	## 键盘选到按钮=白；鼠标一旦介入按悬停算，直到下一次键盘按键夺回
	check(p._arrows[0][1].position.x == CWConfigPanel.ARROW_R_X, "右箭头在固定位置")
	p.handle_input(right)   ## 换一档，值文案长度变了
	check(p._arrows[0][1].position.x == CWConfigPanel.ARROW_R_X, "换档后右箭头不挪窝")
	for k in 4:
		p.handle_input(down)
	check(p._btn.get_theme_stylebox("panel") == p._btn_hot, "键盘走到「进入棋盘」变白")
	p._btn_hover = false     ## 鼠标划过按钮又移开（exited 把焦点权抢给鼠标）
	p._mouse_led = true
	p._repaint()
	check(p._btn.get_theme_stylebox("panel") == p._btn_rest,
		"鼠标介入后按悬停算：没悬停就回蓝，哪怕键盘焦点还停在按钮上")
	p._btn_hover = true
	p._repaint()
	check(p._btn.get_theme_stylebox("panel") == p._btn_hot, "悬停中 = 白")
	var up := InputEventAction.new()
	up.action = "ui_up"
	up.pressed = true
	p.handle_input(up)       ## 键盘再动：夺回焦点权，焦点走到种子行
	check(p._btn.get_theme_stylebox("panel") == p._btn_rest,
		"键盘一动夺回焦点权：焦点离开按钮，按钮回蓝（悬停不再算数）")
	p.handle_input(down)
	check(p._btn.get_theme_stylebox("panel") == p._btn_hot, "键盘再走到按钮又变白")
	p._btn_hover = false
	root.remove_child(p)
	p.free()

	## 座位规则：人类坐所选阵营在行动顺序里的第一个位置；观战不占座
	check(CWConfigPanel.human_seat(2, CWData.Faction.IMMUNE) == 0
		and CWConfigPanel.human_seat(2, CWData.Faction.CANCER) == 1
		and CWConfigPanel.human_seat(4, CWData.Faction.CANCER) == 1
		and CWConfigPanel.human_seat(6, CWData.Faction.IMMUNE) == 0
		and CWConfigPanel.human_seat(6, CWData.Faction.CANCER) == 1,
		"座位 = 该阵营在行动顺序里的第一个位置")
	check(CWConfigPanel.human_seat(4, -1) == -1, "观战不占座位")

	## AI 强度接线：UI 桥默认普通（关推演），纯蒙特卡洛桥默认开
	check(CWUIBridge.new().enabled == false, "UI 桥默认普通 AI")
	check(CWMonteCarloBridge.new().enabled == true, "蒙特卡洛桥默认开推演")


# ---- 悬停格子详情 + 被动技能悬浮框 ----
func t_hover_info() -> void:
	print("[悬停详情与技能悬浮框]")
	var g := _fx_game(2)
	var c: Vector2i = CWData.CORES[0]
	g.tiles[c]["tissue"] = CWData.Tissue.CANCER
	g.tiles[c]["solid"] = 2
	g.tiles[c]["store"] = 10
	## cells 的下标就是 pid（cell_of 按下标取），追加顺序必须和玩家顺序一致
	var imm := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(5, 0),
		CWData.ImmuneType.BASIC, -1)
	g.cells.append(imm)
	var can := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, c, -1, CWData.CancerType.MELANOMA)
	can["energy"] = 38
	can["marked"] = true
	can["mark_left"] = 1
	g.cells.append(can)

	## describe 是纯函数：直接核对文案
	var all := ""
	for r in CWTileInfo.describe(g, c):
		all += r["text"] + "|"
	check(all.contains("癌组织") and all.contains("固化 2 / %d" % g.tune.solidify_threshold),
		"详情：组织与固化进度")
	check(all.contains("代谢核心 · 储量 1.0"), "详情：核心储量")
	check(all.contains("恶性黑色素瘤") and all.contains("能量 3.8") and all.contains("标记 ×1"),
		"详情：占据者、能量与标记")
	check(CWTileInfo.describe(g, Vector2i(0, 0)).size() == 1, "健康空格只有一行")

	## 宽度按最长行实测撑开：核心储量行装不进 208（试玩第一轮的出框），短内容保底 208
	var wide := CWTileInfo.width_for(CWTileInfo.describe(g, c))
	var row_w: float = CWStyle.FONT.get_string_size("代谢核心 · 储量 1.0",
		HORIZONTAL_ALIGNMENT_LEFT, -1, CWStyle.SIZE_BODY).x
	check(wide >= row_w + 24.0 and wide > 208.0, "核心储量行超 208：卡片实测加宽到 %d" % int(wide))
	check(CWTileInfo.width_for(CWTileInfo.describe(g, Vector2i(0, 0))) == 208.0,
		"短内容仍用最小宽 208")

	## place 也是纯函数：贴右栏翻左、上下钳进画布
	var screen := CWView.screen_size()
	var box := Vector2(208, 120)
	var pr := CWTileInfo.place(Vector2(650, 270), box, screen)
	check(pr.x + box.x < 650.0, "贴右栏的格子翻到左侧")
	check(CWTileInfo.place(Vector2(100, 10), box, screen).y >= 8.0, "顶边不越界")
	check(CWTileInfo.place(Vector2(100, 530), box, screen).y + box.y <= screen.y - 7.9,
		"底边不越界")

	## 延迟与开关：0.25s 前不浮、换格重计时、演出期间不浮、出棋盘即收
	var board := make_board()
	var cam := Camera2D.new()
	CWView.apply(cam, board, CWView.GAME_ZOOM, CWView.GAME_LOOK_AT, CWView.GAME_ANCHOR)
	var info := CWTileInfo.new()
	root.add_child(info)
	await process_frame
	info.on_hover(c)
	info.sync(0.1, g, board, cam, false)
	check(not info.visible, "悬停 0.1s：还没浮出")
	info.sync(0.2, g, board, cam, false)
	check(info.visible, "悬停满 0.25s：浮出")
	info.on_hover(Vector2i(0, 1))
	check(not info.visible, "换格子先收起重新计时")
	info.sync(0.3, g, board, cam, false)
	check(info.visible, "新格子计时满再浮出")
	info.sync(0.3, g, board, cam, true)
	check(not info.visible, "开场/返场演出期间不浮")
	info.on_hover(Vector2i(99, 99))
	info.sync(0.3, g, board, cam, false)
	check(not info.visible, "移出棋盘收起")
	root.remove_child(info)
	info.free()
	board.free()
	cam.free()

	## 技能悬浮框：无装备不浮、装备变化重搭、reset 清干净
	var panel := CWMatchPanel.new()
	root.add_child(panel)
	await process_frame
	panel.refresh(g)     ## 第一遍先按人数把行建出来（_build 会重置悬停状态）
	panel._tip_pid = 1
	panel.refresh(g)
	check(panel._tip == null or not panel._tip.visible, "没装备不浮框")
	can["equipped"] = ["组织驻留", "LFA-1黏附"]
	panel.refresh(g)
	check(panel._tip != null and panel._tip.visible, "有装备才浮出")
	check(panel._tip.get_child_count() == 4, "清单 = 底板 + 标题 + 两条")
	can["equipped"].append("免疫突触成熟")
	panel.refresh(g)
	check(panel._tip.get_child_count() == 5, "装备变化悬浮框跟着重搭")
	panel._tip_pid = -1
	panel.refresh(g)
	check(not panel._tip.visible, "移开行即收起")
	panel.reset()
	check(panel._tip == null, "reset 清掉悬浮框")
	root.remove_child(panel)
	panel.free()
	g.dispose()


# ---- 对局日志面板：窗口/着色是纯函数，开关与滚动走真节点 ----
func t_log_panel() -> void:
	print("[对局日志面板]")
	check(CWLogPanel.first_line(100, 20, 0) == 80, "窗口贴底")
	check(CWLogPanel.first_line(100, 20, 30) == 50, "上翻 30 行")
	check(CWLogPanel.first_line(10, 20, 0) == 0, "不足一屏从头显示")
	check(CWLogPanel.line_color("▶ 玩家1 的回合") == CWStyle.TEXT_HI
		and CWLogPanel.line_color("★ 免疫等级升至 II 级") == CWStyle.IMMUNE
		and CWLogPanel.line_color("☠ 谁 死亡") == CWStyle.CANCER
		and CWLogPanel.line_color("　细节行") == CWStyle.TEXT_DIM,
		"行着色跟着日志前缀语法")

	var g := _fx_game(2)
	for i in 40:
		g.log_msg("行 %d" % i)
	var p := CWLogPanel.new()
	root.add_child(p)
	await process_frame
	var lkey := InputEventKey.new()
	lkey.keycode = KEY_L
	lkey.pressed = true
	p._unhandled_input(lkey)
	check(not p.visible, "对局外不响应 L")
	p.active = true
	p._unhandled_input(lkey)
	check(p.visible, "对局中 L 打开面板")
	## 标题行右侧的 L 是键帽（试玩二轮改定：和行动栏快捷键数字同款灰底垫块）
	var cap: Panel = p.get_node("KeyCap")
	var capbox := cap.get_theme_stylebox("panel") as StyleBoxFlat
	var cl := cap.get_child(0) as Label
	check(cl.text == "L" and capbox.bg_color == Color(CWStyle.TEXT_DIM, 0.25) \
		and capbox.border_width_top == 0,
		"面板标题行的 L 用行动栏同款灰底垫块（CWStyle.keycap）")
	## 点阵行框虚高（ascent 11/descent 3），键帽按 10px 字形带手工对中：
	## 带的顶行 = label_y + (ascent-10)，应落在 (14-10)/2 = 2
	check(cap.size == Vector2(11, 14) \
		and is_equal_approx(cl.position.y + CWStyle.FONT.get_ascent(CWStyle.SIZE_LABEL) - 10.0, 2.0),
		"键帽定尺寸、字形带对中（行框居中不可信）")
	p.refresh(g)
	var last: String = g.logs[g.logs.size() - 1]
	check(p._lines[p._visible_n - 1].text == last, "默认跟到最新一行")
	p._scroll(5)
	p.refresh(g)
	check(p._lines[p._visible_n - 1].text != last, "上翻后不再贴底")
	p._scroll(-999)
	p.refresh(g)
	check(p._lines[p._visible_n - 1].text == last, "滚回底部继续跟随")
	p._scroll(99999)
	p.refresh(g)
	check(p._lines[0].text == g.logs[0], "翻到顶被钳在第一行")
	p._unhandled_input(lkey)
	check(not p.visible, "再按 L 收起")
	p._scroll(5)
	p.toggle()
	check(p.visible and p._offset == 0, "开合走 toggle：重新贴底跟随最新行")
	p.toggle()
	root.remove_child(p)
	p.free()
	g.dispose()

	## 左上角入口提示（定案A·2026-08-30）：钉在面板将来展开的那个角上，点击 = 按 L
	var chip := CWLogHint.new()
	root.add_child(chip)
	await process_frame
	check(chip.position == CWLogPanel.RECT.position and chip.size == CWLogHint.SIZE,
		"提示钉在面板展开的角上（%s）" % str(CWLogPanel.RECT.position))
	var hits := [0]
	chip.pressed.connect(func() -> void: hits[0] += 1)
	var mev := InputEventMouseButton.new()
	mev.pressed = true
	mev.button_index = MOUSE_BUTTON_LEFT
	chip.gui_input.emit(mev)
	check(hits[0] == 1, "点提示发出开关手势")
	root.remove_child(chip)
	chip.free()


# ---- 规则速查：数字必须现读常量/旋钮，不许抄第二份 ----
func t_rules_page() -> void:
	print("[规则速查]")
	var all := ""
	for s in CWRulesPage.sections():
		all += s["title"] + "|"
		for line in s["lines"]:
			all += line + "|"
	var tune := CWTuning.new()
	check(all.contains("加权占地达到 %d" % tune.cancer_win_weighted), "胜利线跟着旋钮走")
	check(all.contains("上限 %d 个世界回合" % CWData.LIMIT_ROUND), "回合上限跟着常量走")
	check(all.contains("-%s" % CWData.fmt(tune.attack_dmg_success))
		and all.contains("-%s" % CWData.fmt(tune.attack_dmg_crit)), "攻击伤害跟着旋钮走")
	check(not all.contains("受反击"), "规则原文反弹无伤害 → 默认不显示反击那半句")
	check(all.contains("上限 %d 张" % CWData.HAND_MAX)
		and all.contains("每回合至多 %d 次" % CWData.DRAW_MAX_PER_TURN), "手牌与抽卡上限")
	check(all.contains("蹲满 %d 回合" % tune.solidify_threshold), "固化门槛跟着旋钮走")
	## 反击旋钮开了，那半句要跟着出现（平衡实验档）
	## sections() 用的是默认 CWTuning，这里只验固定文案的另一半确实受控于旋钮：
	## 直接构造开旋钮的行文对比不可行（sections 内建 tune），改为验默认关。见上一条。

	## 页面开关
	var page := CWRulesPage.new()
	root.add_child(page)
	await process_frame
	page.open()
	check(page.visible, "打开规则速查")
	var esc := InputEventAction.new()
	esc.action = "ui_cancel"
	esc.pressed = true
	page.handle_input(esc)
	check(not page.visible, "Esc 关闭")
	root.remove_child(page)
	page.free()


# ---- 存档读档：快照落盘、恢复逐位一致、继续走同一步仍一致 ----
func t_save_load() -> void:
	print("[存档读档]")
	CWSave.clear()
	check(not CWSave.exists(), "起手无档")
	var g := make_game(2, 88)
	check(not CWSave.write(g, [0], false), "还没到 pending 边界：拒写")
	await run_setup(g)
	for i in 30:
		if (await g.pending()).is_empty():
			break
		await g.step(g.rng.randi_range(0, 3))
	var req: Dictionary = await g.pending()
	check(not req.is_empty(), "停在一个待决询问上")
	check(CWSave.write(g, [0], true), "pending 边界：写档成功")
	check(CWSave.exists(), "档落在盘上")
	var h0 := g.state_hash()

	var data := CWSave.read()
	check(data["players"] == 2 and data["smart"] == true and int(data["human"][0]) == 0,
		"配置字段原样读回")
	var g2 := make_game(int(data["players"]), 1)   ## 种子无所谓：restore 会盖掉 rng
	g2.restore(data["snap"])
	check(g2.state_hash() == h0, "恢复后的局面逐位一致")
	var r1: Dictionary = await g.pending()
	var r2: Dictionary = await g2.pending()
	check(r2["prompt"] == r1["prompt"] and r2["options"].size() == r1["options"].size(),
		"存档那一刻待决的询问原样回来")
	await g.step(1)
	await g2.step(1)
	check(g2.state_hash() == g.state_hash(), "两边各走同一步，仍逐位一致")
	g.dispose()
	g2.dispose()

	## 暂停菜单：「保存并退出」按 can_save 亮灭（不真开菜单，别把测试树暂停了）
	var pm := CWPauseMenu.new()
	root.add_child(pm)
	await process_frame
	pm.can_save = func() -> bool: return false
	pm._show_page("")
	var save_item := {}
	for it in pm._list:
		if it["id"] == "save_quit":
			save_item = it
	check(not save_item.is_empty() and not pm._enabled(save_item),
		"不能存时「保存并退出」灰着")
	pm.can_save = func() -> bool: return true
	check(pm._enabled(save_item), "能存时亮起")
	root.remove_child(pm)
	pm.free()
	CWSave.clear()
	check(not CWSave.exists(), "清档干净（不污染下一次测试）")


# ---- 设置：两项偏好即改即存，读回一致；收尾必须还原默认（掷骰演出测试在后面）----
func t_settings() -> void:
	print("[设置]")
	check(CWSettings.ai_delay_ms == 220 and CWSettings.dice_anim, "默认：标准节奏 + 演出")
	var page := CWSettingsPage.new()
	root.add_child(page)
	await process_frame
	page.open()
	## 2026-08-30 与配置面板对齐：箭头钉在固定位、只在焦点行亮，标题辉光跟焦点走
	check(page._arrows[0][0].position.x == CWSettingsPage.ARROW_L_X \
		and page._arrows[1][1].position.x == CWSettingsPage.ARROW_R_X,
		"两行箭头都钉在固定位置（不随值字宽跑）")
	check(page._arrows[0][0].visible and not page._arrows[1][0].visible,
		"箭头只在焦点行亮出来")
	check((page._glow.get_child(0) as Label).text == "AI 节奏", "标题辉光落在焦点行")
	page._hot_arrow = page._arrows[0][1]
	page._repaint()
	check(page._arrows[0][1].get_theme_constant("outline_size") == 8, "悬停的箭头亮起白光")
	page._hot_arrow = null
	var right := InputEventAction.new()
	right.action = "ui_right"
	right.pressed = true
	var down := InputEventAction.new()
	down.action = "ui_down"
	down.pressed = true
	page.handle_input(right)                 ## 标准 → 慢
	check(CWSettings.ai_delay_ms == CWSettings.AI_DELAYS[2], "AI 节奏拨到慢（即时生效）")
	page.handle_input(down)
	check(not page._arrows[0][0].visible and page._arrows[1][0].visible \
		and (page._glow.get_child(0) as Label).text == "掷骰动画",
		"焦点下移：箭头与辉光一起跟过去")
	page.handle_input(right)                 ## 演出 → 跳过
	check(not CWSettings.dice_anim, "掷骰动画拨到跳过")
	check(FileAccess.file_exists(CWSettings.PATH), "改动已落盘")
	## 读回：把内存值打乱再 load，应恢复成盘上的（慢 + 跳过）
	CWSettings.ai_delay_ms = 220
	CWSettings.dice_anim = true
	CWSettings._loaded = false
	CWSettings.load_prefs()
	check(CWSettings.ai_delay_ms == CWSettings.AI_DELAYS[2] and not CWSettings.dice_anim,
		"重新载入读回盘上的偏好")
	root.remove_child(page)
	page.free()
	## 还原默认并清盘：dice_anim=false 会让后面的掷骰演出测试整段空转
	CWSettings.ai_delay_ms = 220
	CWSettings.dice_anim = true
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CWSettings.PATH))
	check(not FileAccess.file_exists(CWSettings.PATH), "测试收尾清掉偏好文件")


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

# ---- 结算屏 ----
## 团队 2026-08-28 从四个方向里选的「丁」。这里盯四件事：
##   ① 演出**能自己演完** —— tween 里任何一段 delay 算错，内容会永远停在透明，
##      而这种 bug 在跑一局才看得到的界面上极难发现
##   ② 中途跳过要真的跳到底（团队定的规矩：过场随时可跳）
##   ③ 屏上的数字确实来自引擎，不是写死的
##   ④ **中途放弃不弹结算屏** —— aborted 时 run_game 照样返回，但 winner 仍是 -1
func t_settle_screen() -> void:
	print("[结算屏]")
	## 造一个「已经分出胜负」的局面。不必真跑完一局 ——
	## 结算屏只读 winner / win_kind / round_no / tune 和三个数格子的函数。
	var g := make_game(4, 7)
	g.setup.build_board()
	g.winner = CWData.Faction.CANCER
	g.win_kind = "cancer_weighted"
	g.round_no = 12
	## 手摆一个像样的终局：光 build_board() 是 127 格全健康，
	## 加权 0、刻度落在条的最右端，好几条断言等于没测。
	var coords := CWData.all_coords()
	for k in 70:
		g.tiles[coords[k]]["tissue"] = CWData.Tissue.CANCER
	for k in range(70, 75):
		g.tiles[coords[k]]["tissue"] = CWData.Tissue.SOLID
	for k in range(75, 78):
		g.tiles[coords[k]]["necrosis"] = 2
	var healthy: int = g.count_tissue(CWData.Tissue.HEALTHY)
	var weighted: int = g.count_tissue(CWData.Tissue.CANCER) 		+ 2 * g.count_tissue(CWData.Tissue.SOLID)

	var s := CWSettleScreen.new()
	root.add_child(s)
	await process_frame
	check(not s.visible, "没开局时结算屏是收着的")

	s.show_result(g)
	check(s.visible and s._playing, "开演")
	check(s._clip.size.y < 1.0, "第一帧横幅高度还是 0（从中线拉开）")
	check(s._rows[0].modulate.a < 0.01, "第一帧内容还是透明的")
	check(s._stat_num[0].text == "0", "四个数从 0 滚起")

	## ② 跳过：一下到底
	s.skip()
	check(not s._playing, "跳过后演出结束")
	check(is_equal_approx(s._clip.size.y, CWSettleScreen.BANNER_H),
		"跳过后横幅到位（%d）" % int(s._clip.size.y))
	var all_shown := true
	for row in s._rows:
		if not is_equal_approx(row.modulate.a, 1.0) 				or not is_equal_approx(row.position.y, row.get_meta("y")):
			all_shown = false
	check(all_shown, "跳过后四块内容都到位、都不透明")

	## ③ 数字来自引擎
	check(s._stat_num[0].text == str(healthy), "健康格数 %s 来自 count_tissue" % healthy)
	check(s._stat_num[3].text == str(g.count_necrosis()),
		"坏死格数走的是 count_necrosis（它不是第四种组织）")
	check(s._w_num.text == str(weighted), "加权 %d = 癌 + 2×固化" % weighted)
	check(s._reason.text.contains(">="), "胜因用 ASCII 的 >=（字体里没有 U+2265）")
	check(s._meta.text.contains("第 12 回合"), "回合数来自引擎")

	## 胜利线刻度：加权超过阈值时条填满，刻度按比例落在条内
	check(s._bar_tick.position.x > 0.0 and s._bar_tick.position.x <= CWSettleScreen.BAR_W,
		"胜利线刻度落在条上（x=%d / %d）" % [int(s._bar_tick.position.x), CWSettleScreen.BAR_W])

	## 四种结局各有各的标签，判定那两种不能写得像击溃
	var chips := true
	for kind in ["immune_clear", "cancer_weighted", "limit_immune", "limit_cancer"]:
		if not CWSettleScreen.KIND_CHIP.has(kind):
			chips = false
	check(chips, "四种 win_kind 都有结局标签")
	check(CWSettleScreen.KIND_CHIP["limit_immune"] == "限时判定"
		and CWSettleScreen.KIND_CHIP["immune_clear"] == "清场",
		"限时判定和清场分开说")

	## 按钮：默认停在「再来一局」，左右键切换，两个出口都通
	check(s._btns.size() == 2, "两个按钮")
	check(s._sel == 1, "默认停在「再来一局」")
	var got := []
	s.chose.connect(func(a: String) -> void: got.append(a))
	s._activate(0)
	s._activate(1)
	check(got == ["menu", "restart"], "两个出口分别是 menu / restart（%s）" % str(got))

	## ① 不跳过也能自己演完
	s.show_result(g)
	check(s._playing, "重开一次演出")
	await create_timer(2.0).timeout
	check(not s._playing, "不跳过也能自己演完（没有卡在半路）")
	check(s._stat_num[0].text == str(healthy), "自己演完后数字也到位")

	## ④ 中途放弃不该弹结算屏
	s.reset()
	check(not s.visible, "reset 之后收起来")
	var main_scene: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main_scene)
	await process_frame
	main_scene._on_match_finished(-1)
	check(not main_scene.settle.visible,
		"winner = -1（中途放弃）不弹结算屏 —— 那条路是返场，不是结算")

	## 「再来一局」要真的能开出新局。这条路串了 fade_out → 等淡完 → teardown →
	## 重新开局，中间全是 await —— **断一环的表现是永远停在黑屏上**，
	## 而且只有玩到分出胜负才碰得到，肉眼几乎不可能发现。
	main_scene.match_node.start()
	await process_frame
	var first: CWGame = main_scene.match_node.game
	main_scene._on_settle_chose("restart")
	await create_timer(2.4).timeout   ## T_RESTART 0.85 + 绽开 0.75 + 余量
	check(main_scene.match_node.game != null and main_scene.match_node.game != first,
		"再来一局：开出了新的一局")
	check(not main_scene.settle.visible, "新局开始时结算屏收起来了")
	check(main_scene.pause.active, "新局里暂停菜单又能用了")

	main_scene.queue_free()
	s.queue_free()
	g.dispose()


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

	# ①c 暂停菜单里的规则速查/设置（2026-08-30 接入）：页压页、树保持冻结
	pm.open()
	var rules_at := -1
	var settings_at := -1
	for i in CWPauseMenu.ITEMS.size():
		match CWPauseMenu.ITEMS[i]["id"]:
			"rules": rules_at = i
			"settings": settings_at = i
	check(pm._enabled(CWPauseMenu.ITEMS[rules_at]) \
		and pm._enabled(CWPauseMenu.ITEMS[settings_at]), "规则速查与设置不再灰着")
	pm._activate(rules_at)
	check(pm._rules.visible and pm.visible and pm.get_tree().paused \
		and not pm._panel.visible, "打开规则速查：页压页、树保持冻结、列表让位")
	check(fired.size() == 1, "子页入口不发 chose（在菜单内部消化）")
	pm._unhandled_input(esc)
	check(not pm._rules.visible and pm._panel.visible and pm.get_tree().paused,
		"规则页上 Esc：只关子页，暂停不解除")
	pm._activate(settings_at)
	check(pm._settings.visible, "打开设置页")
	var sright := InputEventAction.new()
	sright.action = "ui_right"
	sright.pressed = true
	pm._unhandled_input(sright)          ## 路由给设置页第一行：标准 → 慢
	check(CWSettings.ai_delay_ms == CWSettings.AI_DELAYS[2], "键盘路由到设置页：拨值即时生效")
	pm._unhandled_input(esc)
	check(not pm._settings.visible and pm._panel.visible, "设置页上 Esc 退回暂停列表")
	pm._unhandled_input(esc)
	check(not pm.visible and not pm.get_tree().paused, "再按 Esc 才关掉暂停菜单")
	CWSettings.ai_delay_ms = 220         ## 拨值动了真设置，还原并清盘
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CWSettings.PATH))
	pm.active = false

	# ② 拆局：棋盘要擦回开局前
	## 交给 AI 打（不然 start() 会停在「请玩家落子」那一问上，一个细胞都还没有，
	## 「细胞节点清干净了」就成了一句空话）
	m.human_players = []
	CWSettings.ai_delay_ms = 0   ## AI 停顿归设置管了；测试要跑得快，完事还原默认
	m.start()
	await process_frame          ## 细胞节点是 _process 里按 game.cells 建的，得让它跑一帧
	check(m.game.count_tissue(CWData.Tissue.CANCER) > 0, "开局铺了癌组织")
	check(m.ui.visible and pm.active, "开局后 HUD 出现、暂停菜单启用")
	## 左上角入口提示的显隐链（定案A）：开局亮 → 面板开着让位 → 收起回来
	check(m._log_hint != null and m._log_hint.visible, "「对局日志 L」入口提示亮着")
	m._log_panel.toggle()
	await process_frame
	check(m._log_panel.visible and not m._log_hint.visible, "面板开着时提示让位（同一个角）")
	m._log_panel.toggle()
	await process_frame
	check(m._log_hint.visible, "面板收起提示回来")
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
	check(not m._log_hint.visible, "拆局后入口提示收起")

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
	CWSettings.ai_delay_ms = 220   ## 还原默认，别影响别的测试

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
			## 费用行 = [快捷键数字（CWStyle.keycap 灰底垫块）] + [费用文字]
			var line: Node = c.get_child(0).get_child(1)
			var cap0: Control = line.get_child(0)
			plated = cap0 is Panel and \
				(cap0.get_theme_stylebox("panel") as StyleBoxFlat).bg_color \
					== Color(CWStyle.TEXT_DIM, 0.25)
			if plated:
				badge = (cap0.get_child(0) as Label).text
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

	main_scene._begin({ "players": 4, "faction": CWData.Faction.IMMUNE, "smart": false })
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

	# 键盘上下必须跳过灰掉的项。mask 由 enabled_mask() 现算（「继续对局」随存档
	# 有无变化），这里直接摆两种局面验静态跳转规则。
	var last: int = menu_script.ITEMS.size() - 1
	var no_save := [true, false, true, true, true]
	check(menu_script.next_enabled(0, 1, no_save) == 2, "无档：往下跳过「继续对局」落到规则速查")
	check(menu_script.next_enabled(2, 1, no_save) == 3, "规则速查再往下是设置")
	check(menu_script.next_enabled(last, -1, no_save) == 3, "键盘往上一步到设置")
	check(menu_script.next_enabled(0, -1, no_save) == 0, "到顶了就停在原地，不绕回")
	var with_save := [true, true, true, true, true]
	check(menu_script.next_enabled(0, 1, with_save) == 1, "有档：往下落到「继续对局」")

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
		if (await g.pending()).is_empty():
			break
		await g.step(g.rng.randi_range(0, 3))
	var h0 := g.state_hash()
	var snap := g.snapshot()
	## 拿它乱走一通
	for i in 30:
		if (await g.pending()).is_empty():
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
		if (await control.pending()).is_empty() or (await probe.pending()).is_empty():
			break
		## 实验组：快照 → 乱跑 → 回滚，重复 5 次
		for r in 5:
			var snap := probe.snapshot()
			for k in 8:
				if (await probe.pending()).is_empty():
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
	await g.actions.collect_special(cell, m)
	check(g.tiles[m]["cards"] == 1 and cell["hand"].size() == 8,
		"手牌满时踩骨髓：卡留在骨髓里，没被浪费")
	cell["hand"].resize(7)
	await g.actions.collect_special(cell, m)
	check(g.tiles[m]["cards"] == 0, "空出位置后骨髓就把卡给出去了")
	## 兜底：直接调 draw() 也撑不爆
	cell["hand"].resize(8)
	await g.cards.draw(cell, "测试")
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
	## 判定不用 has_char：整套 UI 测试跑过之后它会经由字体回退链把系统字也算进来，
	## 于是「字库里没有」的字形照样放行（≥ − ‹ › 就是这样漏上屏的，2026-08-29 实锤：
	## 同一段扫描单独跑能抓到、套件里跑抓不到）。get_supported_chars 只报**这份字库
	## 自己**有什么，拿它建一次成员表，不受运行顺序影响。
	var chars := CWStyle.FONT.get_supported_chars()
	var supported := {}
	for k in chars.length():
		supported[chars.unicode_at(k)] = true
	check(not supported.has(0x2265) and supported.has(0x00B7),
		"判定器自检：≥ 该缺、· 该有（防这个测试再次哑火）")
	## 扫描器自检：注释行之后的字面量必须抠得出来，LF 和 CRLF 行尾都得行。
	## 2026-08-30 实锤过一次「com 粘死」：CRLF 下换行比对失败，# 之后全被跳过，
	## 扫描空转、检查空心绿——「−1.5」就是这么溜上屏的。
	check(_string_literals("# 注释\nvar s := \"甲\"\n") == ["甲"] \
		and _string_literals("# 注释\r\nvar s := \"乙\"\r\n") == ["乙"],
		"扫描器自检：LF/CRLF 下注释后的字符串都抠得出")
	var bad := {}
	var files: Array[String] = []
	_collect_gd("res://scripts", files)
	check(files.size() > 10, "扫到了 %d 个脚本" % files.size())
	for path in files:
		for s in _string_literals(FileAccess.get_file_as_string(path)):
			for k in s.length():
				var code: int = s.unicode_at(k)
				if code > 0x7F and not supported.has(code):
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
		## 换行必须写成 \n 转义并连 \r 一起认：上一版把**真实换行**写进字面量，
		## 本文件被 git 换成 CRLF 行尾后字面量成了两个字符，单字符永远比不上，
		## 于是第一个 # 之后 com 永远为真 → 整个扫描空转、检查空心绿
		## （2026-08-30 「−1.5」上屏成豆腐块才揭穿；08-29 记的「套件里抓不到」真凶是它）
		if ch == "\n" or ch == "\r":
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


# ---- 主菜单的「退出游戏」要过一道确认（团队 2026-08-28）----
func t_quit_confirm() -> void:
	print("[退出确认]")
	var menu: Node2D = load("res://scenes/MainMenu.tscn").instantiate()
	var root := Node2D.new()
	get_root().add_child(root)
	var board := make_board()
	board.name = "Board"
	root.add_child(board)
	var cam := Camera2D.new()
	cam.name = "Camera2D"
	root.add_child(cam)
	root.add_child(menu)
	await process_frame
	## 「退出游戏」是最后一项
	var quit_i: int = menu.ITEMS.size() - 1
	check(menu.ITEMS[quit_i]["node"] == "Quit", "最后一项是退出游戏")
	menu._activate(quit_i)
	await process_frame
	check(menu._confirm != null and menu._confirm.visible,
		"点退出弹出确认层，而不是直接退出")
	check(menu._confirm_sel == 1, "默认停在「取消」，回车不会顺手就退了")
	check(menu.CONFIRM_ITEMS[1] == "取消", "第二项确实是取消")
	## 方向键在两项之间来回
	var down := InputEventAction.new()
	down.action = "ui_down"
	down.pressed = true
	menu._confirm_input(down)
	check(menu._confirm_sel == 0, "方向键切到「确定」")
	menu._confirm_input(down)
	check(menu._confirm_sel == 1, "再按一下切回「取消」")
	## 辉光跟着选中项走
	check(menu._confirm_glow.position == menu._confirm_labels[1].position,
		"辉光跟到了选中项上")
	## 「取消」关掉确认层，游戏不退
	menu._pick_confirm(1)
	check(not menu._confirm.visible, "取消 → 收起确认层")
	## 确认层收起后，方向键重新归主菜单管
	menu._selected = 0
	menu._unhandled_input(down)
	check(menu._selected != 0, "确认层关掉后方向键回到主菜单（跳到了第 %d 项）" % menu._selected)
	root.queue_free()


# ---- 卡牌效果（CWCardFx）：全场铺健康再手搭场景，别依赖开局癌区 ----
func _fx_game(n_players := 2) -> CWGame:
	var g := make_game(n_players, 1)
	g.setup.build_board()
	for c in g.tiles.keys():
		g.tiles[c]["tissue"] = CWData.Tissue.HEALTHY
		g.tiles[c]["solid"] = 0
		g.tiles[c]["newborn"] = false
	return g


func t_card_events() -> void:
	print("[卡牌·免疫事件]")
	var g := _fx_game(4)
	var imm := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.BASIC, -1)
	imm["energy"] = 0
	g.cells.append(imm)
	await g.card_fx.resolve_event(imm, "急性炎症反应")
	check(imm["energy"] == 15, "急性炎症反应：+1.5 能量")
	await g.card_fx.resolve_event(imm, "抗原摄取")
	check(g.memory == 1, "抗原摄取：不邻癌性组织 +1 记忆")
	g.tiles[Vector2i(1, 0)]["tissue"] = CWData.Tissue.CANCER
	await g.card_fx.resolve_event(imm, "抗原摄取")
	check(g.memory == 3, "抗原摄取：邻癌性组织改为 +2 记忆")
	await g.card_fx.resolve_event(imm, "抗原呈递增强")
	check(g.memory == 6, "抗原呈递增强：+3 记忆")
	await g.card_fx.resolve_event(imm, "局部吞噬")
	check(g.tiles[Vector2i(1, 0)]["tissue"] == CWData.Tissue.HEALTHY and g.memory == 7,
		"局部吞噬：转化唯一相邻癌组织并 +1 记忆")
	var imm2 := CWSetup.make_cell(1, 1, CWData.Faction.IMMUNE, Vector2i(0, 6), CWData.ImmuneType.BASIC, -1)
	imm2["energy"] = 0
	g.cells.append(imm2)
	imm["energy"] = 0
	await g.card_fx.resolve_event(imm, "克隆扩增")
	check(imm["energy"] == 15 and imm2["energy"] == 10, "克隆扩增：全体 +1.0、抽卡者共 +1.5")
	var m: Vector2i = CWData.MARROWS[0]
	g.tiles[m]["cards"] = 0
	await g.card_fx.resolve_event(imm, "骨髓动员")
	check(imm["energy"] == 20 and g.tiles[m]["cards"] == 1, "骨髓动员：全体 +0.5 且空仓骨髓立即产卡")
	var foe := CWSetup.make_cell(2, 2, CWData.Faction.CANCER, Vector2i(2, 0), -1, CWData.CancerType.MELANOMA)
	foe["energy"] = 30
	g.cells.append(foe)
	g.tiles[Vector2i(2, 0)]["tissue"] = CWData.Tissue.CANCER
	g.tiles[Vector2i(0, 1)]["tissue"] = CWData.Tissue.CANCER
	g.tiles[Vector2i(0, 1)]["solid"] = 20
	await g.card_fx.resolve_event(imm, "IFN-γ释放")
	check(foe["energy"] == 20 and g.tiles[Vector2i(0, 1)]["solid"] == 10,
		"IFN-γ释放：2 格内癌细胞 −1.0、固化计数 −1.0")
	## 全身性免疫清除：12 个孤立候选，随机清 10
	for c in g.tiles.keys():
		g.tiles[c]["tissue"] = CWData.Tissue.HEALTHY
		g.tiles[c]["solid"] = 0
	var spots: Array[Vector2i] = [
		Vector2i(-4, -2), Vector2i(-2, -2), Vector2i(0, -2), Vector2i(2, -2),
		Vector2i(4, -2), Vector2i(-4, 2), Vector2i(-2, 2), Vector2i(0, 2),
		Vector2i(2, 2), Vector2i(4, 2), Vector2i(-6, 3), Vector2i(6, -3),
	]
	for c in spots:
		g.tiles[c]["tissue"] = CWData.Tissue.CANCER
	await g.card_fx.resolve_event(imm, "全身性免疫清除")
	var left := 0
	for c in spots:
		if g.tiles[c]["tissue"] == CWData.Tissue.CANCER:
			left += 1
	check(left == 2, "全身性免疫清除：12 个候选随机清掉 10 个")
	g.dispose()


func t_card_events_cancer() -> void:
	print("[卡牌·癌症事件]")
	var g := _fx_game()
	var a := CWSetup.make_cell(0, 0, CWData.Faction.CANCER, Vector2i(0, 0), -1, CWData.CancerType.MELANOMA)
	var b := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(5, -5), -1, CWData.CancerType.MELANOMA)
	a["energy"] = 0
	b["energy"] = 0
	g.cells.append(a)
	g.cells.append(b)
	g.round_no = 12
	await g.card_fx.resolve_event(a, "肿瘤血管生成")
	check(a["energy"] == 25 and b["energy"] == 20, "肿瘤血管生成：中期全体 +2.0、抽卡者 +2.5")
	g.round_no = 1
	await g.card_fx.resolve_event(a, "克隆增殖")
	var newborns := 0
	for n in CWData.neighbors(Vector2i(0, 0)):
		if g.tiles[n]["tissue"] == CWData.Tissue.CANCER:
			newborns += 1
	check(newborns == 1, "克隆增殖：前期恰好转化 1 格")
	## 糖酵解爆发：块 2.2 / 1 细胞 → +2.2，口径与 E 阶段一致
	for c in g.tiles.keys():
		g.tiles[c]["tissue"] = CWData.Tissue.HEALTHY
	for c in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)]:
		g.tiles[c]["tissue"] = CWData.Tissue.CANCER
	g.tiles[Vector2i(3, 0)]["tissue"] = CWData.Tissue.SOLID
	a["energy"] = 0
	await g.card_fx.resolve_event(a, "糖酵解爆发")
	check(a["energy"] == 22, "糖酵解爆发：立刻结算一次无氧呼吸（2.2）")
	g.dispose()


func t_card_instants() -> void:
	print("[卡牌·即时技能]")
	var g := _fx_game(6)
	var t_cell := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.T_CELL, -1)
	g.cells.append(t_cell)
	g.tiles[Vector2i(1, 0)]["tissue"] = CWData.Tissue.SOLID
	g.tiles[Vector2i(1, 0)]["solid"] = 30
	t_cell["hand"] = ["基质降解"]
	var opts: Array = []
	g.card_fx.hand_options(t_cell, opts)
	check(opts.size() == 1 and opts[0]["data"]["act"] == "play", "手牌摊平：一目标一选项")
	await g.card_fx.play(t_cell, opts[0]["data"])
	check(g.tiles[Vector2i(1, 0)]["tissue"] == CWData.Tissue.CANCER \
		and g.tiles[Vector2i(1, 0)]["solid"] == 0 and t_cell["hand"].is_empty(),
		"基质降解：固化转癌、计数清零、结算后弃置")
	var b := CWSetup.make_cell(1, 1, CWData.Faction.IMMUNE, Vector2i(0, 2), CWData.ImmuneType.B_CELL, -1)
	g.cells.append(b)
	var foe := CWSetup.make_cell(2, 2, CWData.Faction.CANCER, Vector2i(1, 2), -1, CWData.CancerType.OSTEO)
	foe["energy"] = 30
	g.cells.append(foe)
	b["hand"] = ["抗体依赖细胞毒作用"]
	await g.card_fx.play(b, { "act": "play", "card": "抗体依赖细胞毒作用", "cid": 2 })
	check(foe["energy"] == 15, "抗体依赖细胞毒作用：B 细胞造成 1.5（卡牌伤害不吃树突/巨噬）")
	b["hand"] = ["交叉呈递"]
	await g.card_fx.play(b, { "act": "play", "card": "交叉呈递", "cid": 2 })
	check(foe["marked"], "交叉呈递：目标获得【标记】")
	var lac := CWSetup.make_cell(3, 3, CWData.Faction.CANCER, Vector2i(3, 0), -1, CWData.CancerType.SIGNET)
	g.cells.append(lac)
	var vic := CWSetup.make_cell(4, 4, CWData.Faction.IMMUNE, Vector2i(3, 1), CWData.ImmuneType.BASIC, -1)
	vic["energy"] = 30
	g.cells.append(vic)
	g.round_no = 1
	lac["hand"] = ["乳酸酸化"]
	await g.card_fx.play(lac, { "act": "play", "card": "乳酸酸化", "cid": 4 })
	check(vic["energy"] == 22, "乳酸酸化：前期 0.8")
	for n in [Vector2i(3, 0), Vector2i(4, 0), Vector2i(2, 2)]:
		g.tiles[n]["tissue"] = CWData.Tissue.CANCER
	lac["hand"] = ["乳酸酸化"]
	await g.card_fx.play(lac, { "act": "play", "card": "乳酸酸化", "cid": 4 })
	check(vic["energy"] == 9, "乳酸酸化：目标邻 ≥3 格癌性组织额外 +0.5")
	g.round_no = 25
	g.tiles[Vector2i(3, 0)]["solid"] = 15
	lac["hand"] = ["基质硬化"]
	await g.card_fx.play(lac, { "act": "play", "card": "基质硬化", "to": Vector2i(3, 0) })
	check(g.tiles[Vector2i(3, 0)]["tissue"] == CWData.Tissue.SOLID,
		"基质硬化：1.5 + 后期 2.0 达阈值，立即转固化")
	var mac := CWSetup.make_cell(5, 5, CWData.Faction.IMMUNE, Vector2i(-3, 0), CWData.ImmuneType.MACRO, -1)
	mac["energy"] = 0
	g.cells.append(mac)
	for n in CWData.neighbors(Vector2i(-3, 0)):
		g.tiles[n]["tissue"] = CWData.Tissue.CANCER
	mac["hand"] = ["溶酶体强化"]
	await g.card_fx.play(mac, { "act": "play", "card": "溶酶体强化" })
	var left := 0
	for n in CWData.neighbors(Vector2i(-3, 0)):
		if g.tiles[n]["tissue"] == CWData.Tissue.CANCER:
			left += 1
	check(left == 2 and mac["energy"] == 12, "溶酶体强化：转化 4 格、巨噬回 1.2")
	mac["hand"] = ["免疫增援"]
	await g.card_fx.play(mac, { "act": "play", "card": "免疫增援", "cid": 0 })
	check(CWData.hex_dist(mac["pos"], t_cell["pos"]) <= 2 and mac["pos"] != Vector2i(-3, 0),
		"免疫增援：传送到所选队友 2 格内的健康组织")
	g.round_no = 1
	var rec := CWSetup.make_cell(6, 5, CWData.Faction.CANCER, Vector2i(5, 0), -1, CWData.CancerType.SCLC)
	g.cells.append(rec)
	lac["hand"] = ["肿瘤细胞募集"]
	await g.card_fx.play(lac, { "act": "play", "card": "肿瘤细胞募集", "cid": 6 })
	check(CWData.hex_dist(rec["pos"], lac["pos"]) <= 2 and g.is_cancerous(rec["pos"]),
		"肿瘤细胞募集：目标落到自身 2 格内的癌性组织")
	lac["hand"] = ["乳酸酸化"]
	g.actions._do_discard(lac, "乳酸酸化")
	check(lac["hand"].is_empty(), "弃牌：随时可弃")
	g.dispose()


## 脚本桥：按队列作答（int=下标；Callable=f(req)->int 按内容找下标），
## 并记录收到的询问与通报 —— 「需中途选择」批的测试全用它驱动
class CWScriptBridge:
	extends CWBridge
	var answers: Array = []
	var asked: Array = []
	var toasts: Array = []
	func ask(req: Dictionary) -> int:
		asked.append(req)
		if answers.is_empty():
			return 0
		var a: Variant = answers.pop_front()
		if a is Callable:
			return a.call(req)
		return a
	func show_result(text: String, _at: Vector2i) -> void:
		toasts.append(text)


## 建一局全健康棋盘 + 脚本桥（所有玩家共用一个桥对象）
func _choice_game() -> Array:
	var g := _fx_game(4)
	var b := CWScriptBridge.new()
	b.game = g
	for pid in g.order:
		g.bridges[pid] = b
	return [g, b]


## 在 options 里找 data[key] == want 的下标（找不到返回 0 = 停止/放弃）
static func _pick_by(key: String, want: Variant) -> Callable:
	return func(req: Dictionary) -> int:
		var options: Array = req["options"]
		for i in options.size():
			if options[i]["data"].get(key) == want:
				return i
		return 0


func t_card_choices() -> void:
	print("[卡牌·需中途选择]")
	## ① 趋化募集：两步免费走位，只进健康组织，踩核心照常收取
	var pack := _choice_game()
	var g: CWGame = pack[0]
	var b: CWScriptBridge = pack[1]
	var imm := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, -1), CWData.ImmuneType.BASIC, -1)
	imm["energy"] = 10
	g.cells.append(imm)
	var core: Vector2i = CWData.CORES[0]   ## (0,-3)：从 (0,-1) 两步可达
	g.tiles[core]["store"] = 10
	g.tiles[Vector2i(1, -1)]["tissue"] = CWData.Tissue.CANCER   ## 趋化募集不许进的格
	b.answers = [_pick_by("to", Vector2i(0, -2)), _pick_by("to", core)]
	await g.card_fx.resolve_event(imm, "趋化募集")
	check(imm["pos"] == core and imm["energy"] == 20,
		"趋化募集：两步走上代谢核心，免费且照常收取 1.0")
	check(b.asked.size() == 2 and b.asked[0]["kind"] == "free_move"
		and b.asked[0]["options"][0]["data"].get("stop", false),
		"趋化募集：逐步询问 free_move，下标 0 恒为停止")
	var offered_cancer := false
	for o in b.asked[0]["options"]:
		if o["data"].get("to") == Vector2i(1, -1):
			offered_cancer = true
	check(not offered_cancer, "趋化募集：癌组织不在候选里（只进健康组织）")
	check("事件【趋化募集】免费移动最多 2 步" in b.toasts, "事件通报带效果说明（试玩第五轮要求）")
	imm["energy"] = 0
	await g.card_fx.resolve_event(imm, "克隆扩增")
	check("事件【克隆扩增】全体免疫 +1.0 · 自身另 +0.5" in b.toasts, "即时结算的事件通报实际数值")
	g.dispose()

	## ② 效应细胞浸润：可进癌组织并触发净化
	pack = _choice_game()
	g = pack[0]
	b = pack[1]
	var inf := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(2, 0), CWData.ImmuneType.BASIC, -1)
	inf["energy"] = 10
	g.cells.append(inf)
	g.tiles[Vector2i(3, 0)]["tissue"] = CWData.Tissue.CANCER
	b.answers = [_pick_by("to", Vector2i(3, 0)), 0]   ## 第二步主动停
	var mem0: int = g.memory
	await g.card_fx.resolve_event(inf, "效应细胞浸润")
	check(inf["pos"] == Vector2i(3, 0) and g.tiles[Vector2i(3, 0)]["tissue"] == CWData.Tissue.HEALTHY
		and g.memory == mem0 + 1, "效应细胞浸润：进癌组织触发净化（+1 记忆）")
	check(b.asked.size() == 2, "第二步问过并被主动停止")
	g.dispose()

	## ③ 炎症风暴：选人 → 邻格净化 + 邻敌 −0.5（有癌细胞站着的格不转化）
	pack = _choice_game()
	g = pack[0]
	b = pack[1]
	var a1 := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.BASIC, -1)
	a1["energy"] = 10
	g.cells.append(a1)
	var a2 := CWSetup.make_cell(1, 1, CWData.Faction.IMMUNE, Vector2i(4, 0), CWData.ImmuneType.BASIC, -1)
	a2["energy"] = 10
	g.cells.append(a2)
	var foe := CWSetup.make_cell(2, 2, CWData.Faction.CANCER, Vector2i(4, 1), -1, CWData.CancerType.MELANOMA)
	foe["energy"] = 30
	g.cells.append(foe)
	g.tiles[Vector2i(5, 0)]["tissue"] = CWData.Tissue.CANCER
	g.tiles[Vector2i(4, 1)]["tissue"] = CWData.Tissue.CANCER
	b.answers = [_pick_by("cid", 1)]
	await g.card_fx.resolve_event(a1, "炎症风暴")
	check(b.asked[0]["kind"] == "pick_cell", "炎症风暴：选人走 pick_cell")
	check(g.tiles[Vector2i(5, 0)]["tissue"] == CWData.Tissue.HEALTHY, "炎症风暴：邻格空癌组织转健康")
	check(g.tiles[Vector2i(4, 1)]["tissue"] == CWData.Tissue.CANCER, "炎症风暴：有癌细胞站着的格不转化")
	check(foe["energy"] == 25, "炎症风暴：邻接癌细胞 −0.5")
	g.dispose()

	## ④ 免疫风暴：2 格内敌 −1.0 + 无癌细胞占据的癌组织转健康
	pack = _choice_game()
	g = pack[0]
	b = pack[1]
	var st := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.BASIC, -1)
	st["energy"] = 10
	g.cells.append(st)
	## 靶子避开印戒——【囊性护甲】会按口径①减免卡牌伤害，这里只想验风暴本身
	var foe2 := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(2, 0), -1, CWData.CancerType.MELANOMA)
	foe2["energy"] = 30
	g.cells.append(foe2)
	g.tiles[Vector2i(2, 0)]["tissue"] = CWData.Tissue.CANCER
	g.tiles[Vector2i(1, 1)]["tissue"] = CWData.Tissue.CANCER
	b.answers = [_pick_by("cid", 0)]
	await g.card_fx.resolve_event(st, "免疫风暴")
	check(foe2["energy"] == 20, "免疫风暴：2 格内癌细胞 −1.0")
	check(g.tiles[Vector2i(1, 1)]["tissue"] == CWData.Tissue.HEALTHY
		and g.tiles[Vector2i(2, 0)]["tissue"] == CWData.Tissue.CANCER,
		"免疫风暴：空癌组织转健康，有癌细胞的不转")
	g.dispose()

	## ⑤ 全身免疫动员：全体 +1.5，逐个细胞问「迁移一次/放弃」，费用照付
	pack = _choice_game()
	g = pack[0]
	b = pack[1]
	var m1 := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.BASIC, -1)
	m1["energy"] = 2
	g.cells.append(m1)
	var m2 := CWSetup.make_cell(1, 1, CWData.Faction.IMMUNE, Vector2i(0, 3), CWData.ImmuneType.BASIC, -1)
	m2["energy"] = 2
	g.cells.append(m2)
	b.answers = [_pick_by("to", Vector2i(1, 0)), 0]   ## m1 迁移一步，m2 放弃
	await g.card_fx.resolve_event(m1, "全身免疫动员")
	check(m1["pos"] == Vector2i(1, 0) and m1["energy"] == 2 + 15 - g.tune.immune_move_healthy[0],
		"全身免疫动员：+1.5 后迁移一步，费用照付（对照 §六 口径）")
	check(m2["pos"] == Vector2i(0, 3) and m2["energy"] == 17, "放弃迁移的原地不动、只拿 +1.5")
	check(b.asked.size() == 2, "每个免疫细胞各问一次")
	g.dispose()

	## ⑥ 基因组不稳定：免费突变不计次数；第 20 回合起两掷二选一
	pack = _choice_game()
	g = pack[0]
	b = pack[1]
	var mut := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(3, 3), -1, CWData.CancerType.MELANOMA)
	mut["energy"] = 30
	g.cells.append(mut)
	g.round_no = 5
	_rig_roll(g, 3, [1])   ## 单掷必出「无事发生」
	await g.card_fx.resolve_event(mut, "基因组不稳定")
	check(not mut["mutate_used"] and mut["energy"] == 30,
		"基因组不稳定：免费（不扣 0.5）也不占每回合的突变次数")
	check(b.asked.is_empty(), "第 20 回合前单掷，不发问")
	g.round_no = 25
	_rig_roll(g, 3, [1, 2])   ## 两掷不同 → 触发二选一
	b.answers = [_pick_by("r", 1)]   ## 挑「无事发生」
	var h0: int = mut["hand"].size()
	await g.card_fx.resolve_event(mut, "基因组不稳定")
	check(b.asked.size() == 1 and b.asked[0]["kind"] == "pick"
		and b.asked[0]["options"].size() == 2, "第 20 回合起：两掷不同时二选一")
	check(mut["hand"].size() == h0 and mut["energy"] == 30, "挑了「无事发生」→ 什么都没发生")
	g.dispose()

	## ⑦ 炎症性趋化：每步 0.2、逐步追问、进癌组织触发净化、固化不在候选
	pack = _choice_game()
	g = pack[0]
	b = pack[1]
	var chx := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.BASIC, -1)
	chx["energy"] = 30
	chx["hand"] = ["炎症性趋化"]
	g.cells.append(chx)
	g.tiles[Vector2i(1, 0)]["tissue"] = CWData.Tissue.CANCER
	g.tiles[Vector2i(-1, 0)]["tissue"] = CWData.Tissue.SOLID
	var copts: Array = []
	g.card_fx.hand_options(chx, copts)
	var has_solid := false
	var first := {}
	for o in copts:
		if o["data"].get("to") == Vector2i(-1, 0):
			has_solid = true
		if o["data"].get("to") == Vector2i(1, 0):
			first = o["data"]
	check(copts.size() == 5 and not has_solid and first["cost"] == CWData.CHEMOTAX_STEP_COST,
		"炎症性趋化：第一步摊成手牌选项（健康/癌组织各一，固化除外，每步 0.2）")
	var cm0: int = g.memory
	b.answers = [0]   ## 第 2 步就停
	await g.card_fx.play(chx, first)
	check(chx["pos"] == Vector2i(1, 0) and g.tiles[Vector2i(1, 0)]["tissue"] == CWData.Tissue.HEALTHY
		and g.memory == cm0 + 1, "第一步进癌组织触发净化")
	check(chx["energy"] == 28 and chx["hand"].is_empty(), "只走一步只扣 0.2，结算后弃置")
	g.dispose()

	## ⑧ 代谢耦联：方向唯一时不问方向，只问数额
	pack = _choice_game()
	g = pack[0]
	b = pack[1]
	var cp1 := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.BASIC, -1)
	cp1["energy"] = 30
	cp1["hand"] = ["代谢耦联"]
	g.cells.append(cp1)
	var cp2 := CWSetup.make_cell(1, 1, CWData.Faction.IMMUNE, Vector2i(0, 3), CWData.ImmuneType.BASIC, -1)
	cp2["energy"] = 8   ## 付不起最低一档 1.0 → 「索取」方向不存在
	g.cells.append(cp2)
	var kopts: Array = []
	g.card_fx.hand_options(cp1, kopts)
	check(kopts.size() == 1 and kopts[0]["data"]["cid"] == 1, "代谢耦联：一个队友一个选项")
	b.answers = [1]   ## 三档里挑 1.5 → 2.0
	await g.card_fx.play(cp1, kopts[0]["data"])
	check(b.asked.size() == 1, "方向唯一（对方付不起）→ 只问数额")
	check(cp1["energy"] == 15 and cp2["energy"] == 28, "转出 1.5、接收方得 2.0")
	g.dispose()

	## ⑨ 基质重塑：拆两格固化 → 从拆过的格及其邻格挑两格转健康
	pack = _choice_game()
	g = pack[0]
	b = pack[1]
	var rm := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.BASIC, -1)
	rm["energy"] = 30
	rm["hand"] = ["基质重塑"]
	g.cells.append(rm)
	g.tiles[Vector2i(1, 0)]["tissue"] = CWData.Tissue.SOLID
	g.tiles[Vector2i(1, 0)]["solid"] = 30
	g.tiles[Vector2i(0, 2)]["tissue"] = CWData.Tissue.SOLID
	g.tiles[Vector2i(0, 2)]["solid"] = 30
	g.tiles[Vector2i(2, 0)]["tissue"] = CWData.Tissue.CANCER
	var ropts: Array = []
	g.card_fx.hand_options(rm, ropts)
	check(ropts.size() == 2, "基质重塑：2 格内每格固化一个选项")
	b.answers = [_pick_by("to", Vector2i(0, 2)), _pick_by("to", Vector2i(2, 0)), _pick_by("to", Vector2i(1, 0))]
	await g.card_fx.play(rm, { "act": "play", "card": "基质重塑", "to": Vector2i(1, 0) })
	check(g.tiles[Vector2i(1, 0)]["tissue"] == CWData.Tissue.HEALTHY
		and g.tiles[Vector2i(2, 0)]["tissue"] == CWData.Tissue.HEALTHY,
		"基质重塑：拆过的格自身与邻格都能转健康")
	check(g.tiles[Vector2i(0, 2)]["tissue"] == CWData.Tissue.CANCER
		and g.tiles[Vector2i(0, 2)]["solid"] == 0, "第二格拆成普通癌组织（没被选去转健康）")
	check(b.asked.size() == 3 and rm["hand"].is_empty(), "追问三次（再拆一格 + 两次转健康）")
	g.dispose()

	## ⑩ 放疗：随机连通 15 格，区域内癌性组织清光、整片坏死 5 轮
	pack = _choice_game()
	g = pack[0]
	b = pack[1]
	var rd := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(-5, 0), CWData.ImmuneType.BASIC, -1)
	rd["energy"] = 30
	rd["hand"] = ["放疗"]
	g.cells.append(rd)
	var blob := 0
	for c in g.tiles.keys():
		if CWData.hex_dist(c, Vector2i(3, 0)) <= 2:
			g.tiles[c]["tissue"] = CWData.Tissue.CANCER
			blob += 1
	g.tiles[Vector2i(3, 0)]["tissue"] = CWData.Tissue.SOLID   ## 固化也算癌性组织
	var dopts: Array = []
	g.card_fx.hand_options(rd, dopts)
	check(dopts.size() == blob, "放疗：全图每格癌性组织一个选项（%d）" % blob)
	await g.card_fx.play(rd, { "act": "play", "card": "放疗", "to": Vector2i(3, 0) })
	check(g.count_necrosis() == CWData.RADIO_REGION, "放疗：恰好 15 格进入坏死")
	check(g.tiles[Vector2i(3, 0)]["tissue"] == CWData.Tissue.HEALTHY
		and g.tiles[Vector2i(3, 0)]["necrosis"] == CWData.NECROSIS_RADIO,
		"起点固化癌组织转健康并坏死 5 轮")
	var necro_pred := func(c: Vector2i) -> bool:
		return g.tiles[c]["necrosis"] > 0
	check(g.blocks_of(necro_pred).size() == 1, "放疗：坏死区域是一整块连通区域")
	var dirty := false
	for c in g.tiles.keys():
		if g.tiles[c]["necrosis"] > 0 and g.is_cancerous(c):
			dirty = true
	check(not dirty, "放疗：区域内没有残留的癌性组织")
	check(rd["hand"].is_empty(), "结算后弃置")
	g.dispose()


func t_card_perms() -> void:
	print("[卡牌·永久技能]")
	## ① 装备流程：打出即装备、进「技 N」、装备后不再进抽卡候选
	var g := _fx_game(4)
	var imm := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.BASIC, -1)
	imm["energy"] = 100
	g.cells.append(imm)
	imm["hand"] = ["组织驻留"]
	var eopts: Array = []
	g.card_fx.hand_options(imm, eopts)
	check(eopts.size() == 1 and eopts[0]["label"].contains("装备"), "永久技能：无目标的「装备」选项")
	await g.card_fx.play(imm, eopts[0]["data"])
	check(imm["hand"].is_empty() and imm["equipped"] == ["组织驻留"], "打出即装备至角色面板")
	check(not g.cards.is_legal(imm, "组织驻留"), "已装备的同名永久技能不再进抽卡候选")
	## ② 组织驻留：每行动回合首次向健康组织迁移免费
	var base_h: int = g.tune.immune_move_healthy[0]
	check(g.actions._move_cost_mod(imm, Vector2i(0, 1), base_h) == 0, "组织驻留：首次向健康组织迁移标价 0")
	await g.actions._do_move(imm, Vector2i(0, 1), 0)
	check(imm["energy"] == 100, "免费移动没扣钱")
	check(g.actions._move_cost_mod(imm, Vector2i(0, 2), base_h) == base_h, "本回合第二次恢复原价")
	g.turn.begin_turn(0, imm)
	check(g.actions._move_cost_mod(imm, Vector2i(0, 2), base_h) == 0, "新行动回合重新免费")
	## ③ LFA-1黏附 + 组织浸润：向癌性组织的减免叠加，首移后只剩浸润
	imm["equipped"] = ["LFA-1黏附", "组织浸润"]
	imm["fx_turn"] = {}
	g.tiles[Vector2i(1, 1)]["tissue"] = CWData.Tissue.CANCER
	var base_c: int = g.tune.immune_move_cancerous[0]
	check(g.actions._move_cost_mod(imm, Vector2i(1, 1), base_c)
		== maxi(base_c - CWData.LFA1_CUT - CWData.INFILTRATE_CUT, CWData.MOVE_CUT_MIN),
		"LFA-1黏附 + 组织浸润：首移 −0.4−0.3")
	await g.actions._do_move(imm, Vector2i(1, 1),
		g.actions._move_cost_mod(imm, Vector2i(1, 1), base_c))
	g.tiles[Vector2i(1, 2)]["tissue"] = CWData.Tissue.CANCER
	check(g.actions._move_cost_mod(imm, Vector2i(1, 2), base_c)
		== maxi(base_c - CWData.INFILTRATE_CUT, CWData.MOVE_CUT_MIN),
		"首移之后 LFA 闸门烧掉，只剩浸润的 −0.3")
	## ④ 组织巡航：首移免费（任何目的地），此后每次 −0.2
	imm["equipped"] = ["组织巡航"]
	imm["fx_turn"] = {}
	check(g.actions._move_cost_mod(imm, Vector2i(2, 2), base_h) == 0, "组织巡航：首移免费")
	await g.actions._do_move(imm, Vector2i(2, 2), 0)
	check(g.actions._move_cost_mod(imm, Vector2i(2, 3), base_h)
		== maxi(base_h - CWData.CRUISE_CUT, CWData.MOVE_CUT_MIN), "此后每次迁移 −0.2")
	g.dispose()

	## ⑤ 代谢适应 / 自分泌生存信号：有氧额外 +0.5/+0.8；GLUT1：无氧额外（分期）
	g = _fx_game(4)
	var ae := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.BASIC, -1)
	ae["energy"] = 0
	ae["equipped"] = ["代谢适应", "自分泌生存信号"]
	g.cells.append(ae)
	g.world.aerobic()
	check(ae["energy"] == 30 + CWData.AEROBIC_ADAPT + CWData.AEROBIC_AUTOCRINE,
		"有氧 3.0 + 代谢适应 0.5 + 自分泌 0.8")
	var gl := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(5, 0), -1, CWData.CancerType.MELANOMA)
	gl["energy"] = 0
	gl["equipped"] = ["GLUT1高表达"]
	g.cells.append(gl)
	g.tiles[Vector2i(5, 0)]["tissue"] = CWData.Tissue.CANCER
	g.round_no = 12
	check(g.world.anaerobic_gain_for(gl) == 4 + CWData.GLUT1_BONUS[1],
		"GLUT1：单格块无氧 0.4 + 中期 0.8（糖酵解爆发同口径）")
	g.world._anaerobic()
	check(gl["energy"] == 4 + CWData.GLUT1_BONUS[1], "E 阶段无氧同样加成")
	g.dispose()

	## ⑥ 净化连锁：模式识别增强 + 效应记忆形成（每世界回合一次）；免疫记忆库免费抽
	g = _fx_game(4)
	var pu := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.BASIC, -1)
	pu["energy"] = 0
	pu["equipped"] = ["模式识别增强", "效应记忆形成"]
	g.cells.append(pu)
	g.tiles[Vector2i(1, 0)]["tissue"] = CWData.Tissue.CANCER
	g.tiles[Vector2i(2, 0)]["tissue"] = CWData.Tissue.CANCER
	await g.actions.enter_tile(pu, Vector2i(1, 0))
	check(pu["energy"] == CWData.SKILL_HEAL * 2 and g.memory == 2,
		"首次净化：两技能各回 0.5，记忆 +1（净化）+1（效应记忆）")
	await g.actions.enter_tile(pu, Vector2i(2, 0))
	check(pu["energy"] == CWData.SKILL_HEAL * 2 and g.memory == 3,
		"同世界回合第二次净化：技能不再触发，只有净化本身 +1 记忆")
	pu["equipped"] = ["免疫记忆库"]
	pu["fx_round"] = {}
	g.tiles[Vector2i(3, 0)]["tissue"] = CWData.Tissue.CANCER
	var log0: int = g.logs.size()
	await g.actions.enter_tile(pu, Vector2i(3, 0))
	var drew_log := false
	for i in range(log0, g.logs.size()):
		if g.logs[i].contains("免疫记忆库"):
			drew_log = true
	check(drew_log and pu["fx_round"].has("免疫记忆库"), "免疫记忆库：首次净化免费抽 1 张")
	g.dispose()

	## ⑦ 免疫突触成熟：判定分布 1 失败 / 2~4 成功 / 5~6 大成功
	g = _fx_game(2)
	var sy := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.BASIC, -1)
	sy["equipped"] = ["免疫突触成熟"]
	g.cells.append(sy)
	check(g.actions.attack_outcome(2, sy) == "success" and g.actions.attack_outcome(5, sy) == "crit"
		and g.actions.attack_outcome(1, sy) == "fail", "免疫突触成熟：1/6 失败、1/2 成功、1/3 大成功")
	check(g.actions.attack_outcome(2) == "fail" and g.actions.attack_outcome(5) == "success",
		"不带技能仍是 1~2 失败 / 6 大成功")
	g.dispose()

	## ⑧ 细胞因子网络：装备者打完即时卡上膛，下一名免疫细胞的即时卡结算完 +0.5
	g = _fx_game(4)
	var na := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.BASIC, -1)
	na["energy"] = 100
	na["equipped"] = ["细胞因子网络"]
	g.cells.append(na)
	var nb := CWSetup.make_cell(1, 1, CWData.Faction.IMMUNE, Vector2i(0, 3), CWData.ImmuneType.BASIC, -1)
	nb["energy"] = 100
	g.cells.append(nb)
	na["hand"] = ["细胞膜修复"]
	await g.card_fx.play(na, { "act": "play", "card": "细胞膜修复" })
	check(g.mods_of(na, "细胞因子网络·待发").size() == 1, "打完即时卡：网络上膛")
	na["hand"] = ["细胞膜修复"]
	await g.card_fx.play(na, { "act": "play", "card": "细胞膜修复" })
	check(g.mods_of(na, "细胞因子网络·待发").size() == 1 and na["energy"] == 100,
		"自己连打不触发自己的网络（「下一名」），也不重复上膛")
	nb["hand"] = ["细胞膜修复"]
	await g.card_fx.play(nb, { "act": "play", "card": "细胞膜修复" })
	check(nb["energy"] == 100 + CWData.SKILL_HEAL and g.mods_of(na, "细胞因子网络·待发").is_empty(),
		"下一名免疫细胞结算完即时卡：+0.5，网络消耗")
	g.dispose()

	## ⑨ 免疫监视：3 格范围内不做增生判定
	g = _fx_game(4)
	var wt := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.BASIC, -1)
	wt["equipped"] = ["免疫监视"]
	g.cells.append(wt)
	g.tune.proliferate_per_adjacent = 1000   ## 必中，隔离概率因素
	g.tiles[Vector2i(1, 0)]["tissue"] = CWData.Tissue.CANCER    ## 全在守护圈内
	g.tiles[Vector2i(5, 0)]["tissue"] = CWData.Tissue.CANCER    ## 圈外
	g.world._proliferate()
	check(g.tiles[Vector2i(2, 0)]["tissue"] == CWData.Tissue.HEALTHY,
		"守护圈内的健康组织不做增生判定")
	check(g.tiles[Vector2i(6, 0)]["tissue"] == CWData.Tissue.CANCER,
		"圈外照常增生（(6,0) 距离 6 > 3）")
	check(g.world._watched(Vector2i(3, 0)) and not g.world._watched(Vector2i(4, 0)),
		"守护半径恰为 3（⏳ #66 的读法）")
	g.dispose()

	## ⑩ 耗竭抵抗：每世界回合首次损失 −1.0；微环境压迫额外 −0.5
	g = _fx_game(4)
	var ex := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.BASIC, -1)
	ex["energy"] = 100
	ex["equipped"] = ["耗竭抵抗"]
	g.cells.append(ex)
	for n in [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 1)]:
		g.tiles[n]["tissue"] = CWData.Tissue.CANCER
	g.world._pressure()
	check(ex["energy"] == 100, "压迫 0.5 被「首次 −1.0 + 压迫 −0.5」整个吃掉")
	g.cancer_hit(ex, 20, "测试")
	check(ex["energy"] == 80, "首次闸门已烧，第二次损失全额")
	g.dispose()

	## ⑪ 抗原呈递强化：每世界回合首次攻击未标记者 → 施加标记；树突的标记翻倍两次
	g = _fx_game(4)
	var pr := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.BASIC, -1)
	pr["energy"] = 100
	pr["equipped"] = ["抗原呈递强化"]
	g.cells.append(pr)
	var pf := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(1, 0), -1, CWData.CancerType.MELANOMA)
	pf["energy"] = 500
	g.cells.append(pf)
	_rig_roll(g, 6, [3])
	await g.actions._do_move(pr, Vector2i(1, 0), 0)
	check(pf["marked"] and pf["mark_left"] == 1, "普通细胞攻击后施加标记（1 次翻倍）")
	var dd := CWSetup.make_cell(2, 2, CWData.Faction.IMMUNE, Vector2i(5, -5), CWData.ImmuneType.DENDRITIC, -1)
	dd["equipped"] = ["抗原呈递强化"]
	g.cells.append(dd)
	var pf2 := CWSetup.make_cell(3, 3, CWData.Faction.CANCER, Vector2i(-3, 0), -1, CWData.CancerType.MELANOMA)
	pf2["energy"] = 500
	g.cells.append(pf2)
	g.apply_mark(pf2, dd)
	check(pf2["mark_left"] == 2, "呈递强化树突施加的标记有两次翻倍")
	var d1 := g.immune_hit(pf2, 10, pr, false)
	var d2 := g.immune_hit(pf2, 10, pr, false)
	var d3 := g.immune_hit(pf2, 10, pr, false)
	check(d1 == 20 and d2 == 20 and d3 == 10, "翻倍两次后标记才移除")
	g.dispose()

	## ⑫ 抗体亲和力成熟：B 抗体 0.5 费 / 1.5 伤；每行动回合首次攻击邻健康的目标 +0.5
	g = _fx_game(4)
	var bm := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.B_CELL, -1)
	bm["energy"] = 100
	bm["equipped"] = ["抗体亲和力成熟"]
	g.cells.append(bm)
	var bt := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(1, 0), -1, CWData.CancerType.MELANOMA)
	bt["energy"] = 500
	g.cells.append(bt)
	check(g.actions.antibody_cost(bm) == CWData.MATURED_ANTIBODY_COST, "抗体费 1.0 → 0.5")
	await g.actions._do_antibody(bm)
	check(bm["energy"] == 100 - CWData.MATURED_ANTIBODY_COST
		and bt["energy"] == 500 - CWData.MATURED_ANTIBODY_DMG, "抗体伤害 1.0 → 1.5")
	var bt0: int = bt["energy"]
	_rig_roll(g, 6, [3])
	await g.actions._do_move(bm, Vector2i(1, 0), 0)
	check(bt["energy"] == bt0 - g.tune.attack_dmg_success - CWData.MATURED_ATTACK_EXTRA,
		"首次攻击邻健康的癌细胞 +0.5")
	g.dispose()

	## ⑬ 吞噬体成熟：打剩 ≤0.5 直接死；巨噬阈值 1.5 并回 0.5
	g = _fx_game(4)
	var ph := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.MACRO, -1)
	ph["energy"] = 100
	ph["equipped"] = ["吞噬体成熟"]
	g.cells.append(ph)
	var pv := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(1, 0), -1, CWData.CancerType.MELANOMA)
	pv["energy"] = g.tune.attack_dmg_success + 12   ## 打完剩 1.2 ≤ 巨噬阈值 1.5
	g.cells.append(pv)
	var ph0: int = ph["energy"]
	_rig_roll(g, 6, [3])
	await g.actions._do_move(ph, Vector2i(1, 0), 0)
	check(not pv["alive"], "吞噬体成熟：目标剩 1.2 ≤ 1.5，直接死亡")
	check(ph["energy"] == ph0 + 10 + CWData.SKILL_HEAL,
		"巨噬吸血 1.0（⌈2.0/2⌉）+ 吞噬体回 0.5")
	g.dispose()

	## ⑭ 细胞毒性增强：T 细胞每次成功 +1.0 且无视减伤（囊性护甲拦不住那 1.0）
	g = _fx_game(4)
	var ct := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.T_CELL, -1)
	ct["energy"] = 100
	ct["equipped"] = ["细胞毒性增强"]
	g.cells.append(ct)
	var cv := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(1, 0), -1, CWData.CancerType.SIGNET)
	cv["energy"] = 500
	g.cells.append(cv)
	_rig_roll(g, 6, [3])
	await g.actions._do_move(ct, Vector2i(1, 0), 0)
	check(cv["energy"] == 500 - (g.tune.attack_dmg_success - CWData.ARMOR_REDUCTION)
		- CWData.CYTOTOX_EXTRA,
		"主伤害吃囊性护甲减免，额外的 1.0 直接扣（无视减伤）")
	g.dispose()

	## ⑮ RAS持续激活：每行动回合首次移动定殖 → 恢复（分期）
	g = _fx_game(4)
	var ra := CWSetup.make_cell(0, 0, CWData.Faction.CANCER, Vector2i(0, 0), -1, CWData.CancerType.MELANOMA)
	ra["energy"] = 100
	ra["equipped"] = ["RAS持续激活"]
	g.cells.append(ra)
	g.round_no = 1
	await g.actions._do_move(ra, Vector2i(1, 0), 0)
	check(ra["energy"] == 100 + CWData.RAS_HEAL[0], "首次定殖 +0.3（前期）")
	await g.actions._do_move(ra, Vector2i(2, 0), 0)
	check(ra["energy"] == 100 + CWData.RAS_HEAL[0], "同回合第二次定殖不再触发")
	g.dispose()

	## ⑯ BCL-2抗凋亡：致死损失改为存活（分期能量），本牌弃置可重抽
	g = _fx_game(4)
	var bc := CWSetup.make_cell(0, 0, CWData.Faction.CANCER, Vector2i(0, 0), -1, CWData.CancerType.MELANOMA)
	bc["energy"] = 10
	bc["equipped"] = ["BCL-2抗凋亡"]
	g.cells.append(bc)
	g.round_no = 1
	g.cancer_hit(bc, 99, "测试")
	check(bc["alive"] and bc["energy"] == CWData.BCL2_ENERGY[0] and bc["equipped"].is_empty(),
		"免死：能量改为 0.5，本牌弃置")
	check(g.cards.is_legal(bc, "BCL-2抗凋亡"), "弃置后可重新抽取")
	g.cancer_hit(bc, 99, "测试")
	check(not bc["alive"], "没有第二张 BCL-2 就真死了")
	g.dispose()

	## ⑰ 癌症干性：复活能量提高（分期），本世界回合向癌性组织移动免费
	g = _fx_game(4)
	var s0 := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(-5, 0), CWData.ImmuneType.BASIC, -1)
	g.cells.append(s0)
	var sc := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(5, 5), -1, CWData.CancerType.MELANOMA)
	sc["energy"] = 10
	sc["equipped"] = ["癌症干性"]
	g.cells.append(sc)
	g.round_no = 5
	g.kill(sc)
	g.tiles[Vector2i(3, 0)]["tissue"] = CWData.Tissue.SOLID
	await g.world.revive_cancer(1, { "to": Vector2i(3, 0) })
	check(sc["alive"] and sc["energy"] == CWData.STEMNESS_ENERGY[0],
		"干性复活：能量 2.0 → 2.5（前期）")
	g.tiles[Vector2i(4, 0)]["tissue"] = CWData.Tissue.CANCER
	check(g.actions._move_cost_mod(sc, Vector2i(4, 0), CWData.CANCER_MOVE_CANCEROUS) == 0,
		"本世界回合向癌性组织移动免费")
	await g.actions._do_move(sc, Vector2i(4, 0), 0)
	g.tiles[Vector2i(5, 0)]["tissue"] = CWData.Tissue.CANCER
	check(g.actions._move_cost_mod(sc, Vector2i(5, 0), CWData.CANCER_MOVE_CANCEROUS)
		== CWData.CANCER_MOVE_CANCEROUS, "前期只有 1 次额度，用完恢复原价")
	g.dispose()


## 把 rng 拨到「接下来 sides 面骰会依次掷出 want 序列」的状态上（穷举附近状态，必然找得到）
func _rig_roll(g: CWGame, sides: int, want: Array) -> void:
	while true:
		var probe: int = g.rng.state
		var hit := true
		for w in want:
			if g.rng.randi_range(1, sides) != w:
				hit = false
				break
		if hit:
			g.rng.state = probe
			return


func t_card_mods() -> void:
	print("[卡牌·修饰批]")
	## ① 移动费修饰：炎症趋化 0.5 覆盖 / CXCR3 每份 −0.5 最低 0.2 / 叠加 / 用后消耗
	var g := _fx_game(4)
	var imm := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.BASIC, -1)
	imm["energy"] = 100
	g.cells.append(imm)
	g.tiles[Vector2i(1, 0)]["tissue"] = CWData.Tissue.CANCER
	var base_c: int = g.tune.immune_move_cancerous[0]
	imm["hand"] = ["炎症趋化"]
	await g.card_fx.play(imm, { "act": "play", "card": "炎症趋化" })
	check(g.actions._move_cost_mod(imm, Vector2i(1, 0), base_c) == CWData.INFLAM_CHEMO_COST,
		"炎症趋化：向癌性组织的迁移费定为 0.5")
	check(g.actions._move_cost_mod(imm, Vector2i(0, 1), g.tune.immune_move_healthy[0])
		== g.tune.immune_move_healthy[0], "炎症趋化：向健康组织不受影响")
	imm["hand"] = ["CXCR3趋化"]
	await g.card_fx.play(imm, { "act": "play", "card": "CXCR3趋化" })
	check(g.actions._move_cost_mod(imm, Vector2i(1, 0), base_c) == CWData.MOVE_CUT_MIN,
		"叠加：0.5 再 −0.5 踩到 CXCR3 的下限 0.2")
	var e0: int = imm["energy"]
	await g.actions._do_move(imm, Vector2i(1, 0), 2)
	check(imm["energy"] == e0 - 2 + 0, "按 0.2 付费移动（净化不给能量）")
	check(g.mods_of(imm, "炎症趋化").is_empty(), "炎症趋化：用一次就消耗")
	check(g.mods_of(imm, "CXCR3趋化").size() == 1, "CXCR3：还剩 1 次")
	g.tiles[Vector2i(2, 0)]["tissue"] = CWData.Tissue.CANCER
	check(g.actions._move_cost_mod(imm, Vector2i(2, 0), base_c) == maxi(base_c - CWData.CXCR3_CUT, CWData.MOVE_CUT_MIN),
		"只剩 CXCR3 时按 −0.5 计")
	await g.actions._do_move(imm, Vector2i(2, 0), g.actions._move_cost_mod(imm, Vector2i(2, 0), base_c))
	check(g.mods_of(imm, "CXCR3趋化").is_empty(), "CXCR3：两次用尽")
	## 回合结束清「本回合」修饰
	imm["hand"] = ["炎症趋化"]
	await g.card_fx.play(imm, { "act": "play", "card": "炎症趋化" })
	g.turn.end_turn(0, imm)
	check(g.mods_of(imm, "炎症趋化").is_empty(), "「本回合」修饰随 end_turn 过期")
	g.dispose()

	## ①b 结算顺序按打出先后（PRD 通则，团队 2026-08-30 定案）——同样两张卡，
	## 换个出牌顺序结果不同：先覆盖后减免能吃到减免，反过来减免被覆盖冲掉。
	for order in [["炎症趋化", "CXCR3趋化"], ["CXCR3趋化", "炎症趋化"]]:
		g = _fx_game(4)
		var o := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0),
			CWData.ImmuneType.BASIC, -1)
		o["energy"] = 100
		g.cells.append(o)
		g.tiles[Vector2i(1, 0)]["tissue"] = CWData.Tissue.CANCER
		for card in order:
			o["hand"] = [card]
			await g.card_fx.play(o, { "act": "play", "card": card })
		var got: int = g.actions._move_cost_mod(o, Vector2i(1, 0), g.tune.immune_move_cancerous[0])
		if order[0] == "炎症趋化":
			check(got == CWData.MOVE_CUT_MIN, "先覆盖后减免：0.5 − 0.5 → 下限 0.2")
		else:
			check(got == CWData.INFLAM_CHEMO_COST, "先减免后覆盖：减免被冲掉，回到 0.5")
		g.dispose()

	## ①c 减免只降不升：已经免费的价钱不会被减免卡抬回 0.2。
	## 【组织驻留】先装备（首次向健康组织免费），之后打【CXCR3趋化】——
	## 没有这条规则的话就是 0 − 0.5 钳成 0.2，一张打折卡把免费变成了收费。
	g = _fx_game(4)
	var free_cell := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0),
		CWData.ImmuneType.BASIC, -1)
	free_cell["energy"] = 100
	g.cells.append(free_cell)
	free_cell["hand"] = ["组织驻留"]
	await g.card_fx.play(free_cell, { "act": "play", "card": "组织驻留" })
	free_cell["hand"] = ["CXCR3趋化"]
	await g.card_fx.play(free_cell, { "act": "play", "card": "CXCR3趋化" })
	check(free_cell["equip_seq"]["组织驻留"] < g.mods_of(free_cell, "CXCR3趋化")[0]["seq"],
		"永久技能与即时卡盖在同一把尺上（装备在前）")
	check(g.actions._move_cost_mod(free_cell, Vector2i(0, 1), g.tune.immune_move_healthy[0]) == 0,
		"先免费后减免：仍然免费，不被抬回 0.2")
	g.dispose()

	## ①d 世界事件排在所有卡牌之后：【基质阻隔】翻倍作用在卡牌算完的价上
	g = _fx_game(4)
	var bar := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0),
		CWData.ImmuneType.BASIC, -1)
	bar["energy"] = 100
	g.cells.append(bar)
	g.tiles[Vector2i(1, 0)]["tissue"] = CWData.Tissue.CANCER
	bar["hand"] = ["炎症趋化"]
	await g.card_fx.play(bar, { "act": "play", "card": "炎症趋化" })
	g.events["active"].append({ "name": "基质阻隔", "left": 2, "stacks": 1, "data": {} })
	check(g.actions._move_cost_mod(bar, Vector2i(1, 0), g.tune.immune_move_cancerous[0])
		== CWData.INFLAM_CHEMO_COST * 2,
		"基质阻隔在最后翻倍：0.5 → 1.0（不是先翻倍再被覆盖成 0.5）")
	g.dispose()

	## ② 上皮—间质转化（癌方）：向健康组织移动 0.2，前期 1 次
	g = _fx_game(4)
	var can := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(0, 0), -1, CWData.CancerType.MELANOMA)
	can["energy"] = 100
	g.cells.append(can)
	g.round_no = 1
	can["hand"] = ["上皮—间质转化"]
	await g.card_fx.play(can, { "act": "play", "card": "上皮—间质转化" })
	check(g.actions._move_cost_mod(can, Vector2i(1, 0), CWData.CANCER_MOVE_HEALTHY) == CWData.EMT_MOVE_COST,
		"上皮—间质转化：向健康组织移动费 0.2")
	await g.actions._do_move(can, Vector2i(1, 0), CWData.EMT_MOVE_COST)
	check(g.mods_of(can, "上皮—间质转化").is_empty(), "前期只有 1 次，用后消耗")
	g.dispose()

	## ③ 护盾类：细胞膜修复 −1.5 / I型干扰素事件全体 −1.0 / 同时生效各消耗（定案 #57）
	g = _fx_game(4)
	var s1 := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.BASIC, -1)
	s1["energy"] = 100
	g.cells.append(s1)
	var s2 := CWSetup.make_cell(1, 1, CWData.Faction.IMMUNE, Vector2i(0, 3), CWData.ImmuneType.BASIC, -1)
	s2["energy"] = 100
	g.cells.append(s2)
	await g.card_fx.resolve_event(s1, "I型干扰素")
	check(g.mods_of(s2, "I型干扰素").size() == 1, "I型干扰素：事件给每个免疫细胞发盾")
	s1["hand"] = ["细胞膜修复"]
	await g.card_fx.play(s1, { "act": "play", "card": "细胞膜修复" })
	g.cancer_hit(s1, 30, "测试")
	check(s1["energy"] == 100 - (30 - 15 - 10), "两面盾同时生效：3.0 − 1.5 − 1.0 = 0.5")
	check(g.mods_of(s1, "细胞膜修复").is_empty() and g.mods_of(s1, "I型干扰素").is_empty(),
		"同一次损失把两面盾都消耗掉")
	g.cancer_hit(s1, 10, "测试")
	check(s1["energy"] == 100 - 5 - 10, "第二次损失不再减免")
	await g.world_fx.round_end()
	check(g.mods_of(s2, "I型干扰素").is_empty(), "干扰素盾随世界回合结束过期（没用上也作废）")
	g.dispose()

	## ④ 缺氧适应（2026-08-30 卡面重写）：一面一次性护盾，
	## 「下一次【微环境压迫】或癌细胞技能造成的能量损失 -1.0」。世界事件不算。
	g = _fx_game(4)
	var hyp := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.BASIC, -1)
	hyp["energy"] = 100
	g.cells.append(hyp)
	hyp["hand"] = ["缺氧适应"]
	await g.card_fx.play(hyp, { "act": "play", "card": "缺氧适应" })
	g.cancer_hit(hyp, 10, "增殖抑制")
	check(hyp["energy"] == 90, "世界事件的损失既不是技能也不是压迫，不减免")
	check(not g.mods_of(hyp, "缺氧适应").is_empty(), "不合条件的损失也不会白白吃掉盾")
	g.cancer_hit(hyp, 15, "乳酸酸化", true)
	check(hyp["energy"] == 90 - 5, "癌细胞技能的损失 -1.0")
	check(g.mods_of(hyp, "缺氧适应").is_empty(), "护盾一次性消耗")
	g.dispose()

	## ④b 压迫侧：同一面盾也挡【微环境压迫】（不再是「免疫压迫」而是走管线减 1.0），
	## 且写的是「下一次」→ 跨世界回合等着，不随回合作废。
	g = _fx_game(4)
	var hyp2 := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0),
		CWData.ImmuneType.BASIC, -1)
	hyp2["energy"] = 100
	g.cells.append(hyp2)
	for n in [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 1)]:
		g.tiles[n]["tissue"] = CWData.Tissue.CANCER
	hyp2["hand"] = ["缺氧适应"]
	await g.card_fx.play(hyp2, { "act": "play", "card": "缺氧适应" })
	await g.world_fx.round_end()
	check(not g.mods_of(hyp2, "缺氧适应").is_empty(),
		"护盾跨世界回合仍在（卡面写的是「下一次」）")
	g.world._pressure()
	check(hyp2["energy"] == 100, "压迫 0.5 被 -1.0 完全吸收（钳在 0）")
	check(g.mods_of(hyp2, "缺氧适应").is_empty(), "压迫吃掉了这面盾")
	g.world._pressure()
	check(hyp2["energy"] == 95, "盾没了，下一轮压迫照常掉 0.5")
	g.dispose()

	## ⑤ DNA损伤修复：挡事件/技能，不挡普通攻击（定案 #62）
	g = _fx_game(4)
	var atk := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.BASIC, -1)
	atk["energy"] = 100
	g.cells.append(atk)
	var dna := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(1, 0), -1, CWData.CancerType.MELANOMA)
	dna["energy"] = 100
	g.cells.append(dna)
	g.round_no = 1
	dna["hand"] = ["DNA损伤修复"]
	await g.card_fx.play(dna, { "act": "play", "card": "DNA损伤修复" })
	_rig_roll(g, 6, [4])
	await g.actions._do_move(atk, Vector2i(1, 0), 0)
	check(dna["energy"] == 100 - g.tune.attack_dmg_success, "普通攻击不被 DNA损伤修复 减免")
	check(g.mods_of(dna, "DNA损伤修复").size() == 1, "普通攻击也不消耗它")
	g.immune_hit(dna, 10, atk, false)
	check(dna["energy"] == 100 - g.tune.attack_dmg_success, "技能伤害被减免 1.0（前期档）→ 0")
	check(g.mods_of(dna, "DNA损伤修复").is_empty(), "挡过一次即消耗")
	g.dispose()

	## ⑥ PD-L1表达：判定下降一级（大成功→成功、成功→失败）
	g = _fx_game(4)
	var pk := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.BASIC, -1)
	pk["energy"] = 100
	g.cells.append(pk)
	var pd := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(1, 0), -1, CWData.CancerType.MELANOMA)
	pd["energy"] = 100
	g.cells.append(pd)
	pd["hand"] = ["PD-L1表达"]
	await g.card_fx.play(pd, { "act": "play", "card": "PD-L1表达" })
	_rig_roll(g, 6, [6])
	await g.actions._do_move(pk, Vector2i(1, 0), 0)
	check(pd["energy"] == 100 - g.tune.attack_dmg_success,
		"PD-L1：大成功压成普通成功（伤害按成功档）")
	check(g.mods_of(pd, "PD-L1表达").is_empty(), "受一次攻击即消耗")
	pd["hand"] = ["PD-L1表达"]
	await g.card_fx.play(pd, { "act": "play", "card": "PD-L1表达" })
	var pd_e: int = pd["energy"]
	_rig_roll(g, 6, [4])
	pk["pos"] = Vector2i(0, 0)
	await g.actions._do_move(pk, Vector2i(1, 0), 0)
	check(pd["energy"] == pd_e and pk["pos"] == Vector2i(0, 0),
		"PD-L1：成功压成失败，攻击者被反弹")
	g.dispose()

	## ⑦ 高亲和力克隆：不掷骰直接大成功 +1.0；补体调理：失败重掷 + 命中 +0.5
	g = _fx_game(4)
	var aff := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.BASIC, -1)
	aff["energy"] = 100
	g.cells.append(aff)
	var sack := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(1, 0), -1, CWData.CancerType.MELANOMA)
	sack["energy"] = 500
	g.cells.append(sack)
	aff["hand"] = ["高亲和力克隆"]
	await g.card_fx.play(aff, { "act": "play", "card": "高亲和力克隆" })
	var rng_before: int = g.rng.state
	await g.actions._do_move(aff, Vector2i(1, 0), 0)
	check(g.rng.state == rng_before, "高亲和力克隆：完全不消耗随机数（不掷骰）")
	check(sack["energy"] == 500 - g.tune.attack_dmg_crit - CWData.AFFINITY_EXTRA,
		"直接大成功并额外 +1.0")
	check(g.mods_of(aff, "高亲和力克隆").is_empty(), "用后消耗")
	var s0: int = sack["energy"]
	aff["hand"] = ["补体调理"]
	await g.card_fx.play(aff, { "act": "play", "card": "补体调理" })
	_rig_roll(g, 6, [1, 5])
	await g.actions._do_move(aff, Vector2i(1, 0), 0)
	check(sack["energy"] == s0 - g.tune.attack_dmg_success - CWData.OPSONIN_EXTRA,
		"补体调理：首掷失败自动重掷成功，额外 +0.5")
	check(g.mods_of(aff, "补体调理").is_empty(), "骑在下一次攻击上，无论结果都消耗")
	g.dispose()

	## ⑧ 穿孔素-颗粒酶（T 细胞 +2.0）与补体级联（成功后转 2 格）
	g = _fx_game(4)
	var tc := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.T_CELL, -1)
	tc["energy"] = 100
	g.cells.append(tc)
	var vic2 := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(1, 0), -1, CWData.CancerType.MELANOMA)
	vic2["energy"] = 500
	g.cells.append(vic2)
	g.tiles[Vector2i(2, 0)]["tissue"] = CWData.Tissue.CANCER
	g.tiles[Vector2i(2, -1)]["tissue"] = CWData.Tissue.CANCER
	tc["hand"] = ["穿孔素-颗粒酶"]
	await g.card_fx.play(tc, { "act": "play", "card": "穿孔素-颗粒酶" })
	tc["hand"] = ["补体级联"]
	await g.card_fx.play(tc, { "act": "play", "card": "补体级联" })
	_rig_roll(g, 6, [4])
	await g.actions._do_move(tc, Vector2i(1, 0), 0)
	check(vic2["energy"] == 500 - g.tune.attack_dmg_success - CWData.PERFORIN_EXTRA_T,
		"穿孔素：T 细胞攻击成功额外 +2.0")
	check(g.tiles[Vector2i(2, 0)]["tissue"] == CWData.Tissue.HEALTHY
		and g.tiles[Vector2i(2, -1)]["tissue"] == CWData.Tissue.HEALTHY,
		"补体级联：目标相邻 2 格癌组织转健康")
	check(g.mods_of(tc, "穿孔素-颗粒酶").is_empty() and g.mods_of(tc, "补体级联").is_empty(),
		"两张都在成功后消耗")
	g.dispose()

	## ⑨ TNF-α局部炎症：范围伤害 + 固化 −1.0 + 本回合冻结固化计数
	g = _fx_game(4)
	var tn := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.BASIC, -1)
	tn["energy"] = 100
	g.cells.append(tn)
	var fz := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(1, 0), -1, CWData.CancerType.MELANOMA)
	fz["energy"] = 100
	g.cells.append(fz)
	g.tiles[Vector2i(1, 0)]["tissue"] = CWData.Tissue.CANCER
	g.tiles[Vector2i(1, 0)]["solid"] = 15
	g.tiles[Vector2i(0, 1)]["tissue"] = CWData.Tissue.CANCER
	g.tiles[Vector2i(0, 1)]["solid"] = 10
	tn["hand"] = ["TNF-α局部炎症"]
	var topts: Array = []
	g.card_fx.hand_options(tn, topts)
	check(topts.size() == 1, "TNF：范围内有目标才可打")
	await g.card_fx.play(tn, topts[0]["data"])
	check(fz["energy"] == 90 and g.tiles[Vector2i(1, 0)]["solid"] == 5
		and g.tiles[Vector2i(0, 1)]["solid"] == 0, "TNF：癌细胞 −1.0、固化计数 −1.0")
	g.raise_solid(Vector2i(0, 1), 10)
	check(g.tiles[Vector2i(0, 1)]["solid"] == 0, "冻结：本世界回合不能增加固化计数")
	await g.world_fx.round_end()
	g.raise_solid(Vector2i(0, 1), 10)
	check(g.tiles[Vector2i(0, 1)]["solid"] == 10, "回合末解冻，固化恢复正常")
	g.dispose()

	## ⑩ 基质稳定：本回合固化不衰减；TGF-β：下次有氧逐份 −20% 且结算即消耗
	g = _fx_game(4)
	var dr := CWSetup.make_cell(0, 0, CWData.Faction.CANCER, Vector2i(5, 5), -1, CWData.CancerType.MELANOMA)
	dr["energy"] = 100
	g.cells.append(dr)
	g.tiles[Vector2i(3, 0)]["tissue"] = CWData.Tissue.CANCER
	g.tiles[Vector2i(3, 0)]["solid"] = 10
	await g.card_fx.resolve_event(dr, "基质稳定")
	g.world._decay()
	check(g.tiles[Vector2i(3, 0)]["solid"] == 10, "基质稳定：本回合固化计数不衰减")
	await g.world_fx.round_end()
	g.world._decay()
	check(g.tiles[Vector2i(3, 0)]["solid"] == 5, "事件到期后衰减恢复")
	var iw := CWSetup.make_cell(1, 1, CWData.Faction.IMMUNE, Vector2i(-5, 0), CWData.ImmuneType.BASIC, -1)
	iw["energy"] = 0
	g.cells.append(iw)
	await g.card_fx.resolve_event(dr, "TGF-β释放")
	await g.card_fx.resolve_event(dr, "TGF-β释放")
	g.world.aerobic()
	## 全场 127 格健康 − 2 格癌性：基准 (125×3/127 四舍五入)=3.0 → 30；两份 −20%：30→24→19
	check(iw["energy"] == 19, "TGF-β 两份叠加：3.0 → 逐份 ×80% 向下取整 = 1.9")
	check(g.event_stacks("TGF-β释放") == 0, "结算一次即整体消耗")
	iw["energy"] = 0
	g.world.aerobic()
	check(iw["energy"] == 30, "下一次有氧恢复原额")
	g.dispose()

	## ⑪ 修饰条目计入 state_hash（快照/复现的地基）
	g = _fx_game(2)
	var hs := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.BASIC, -1)
	g.cells.append(hs)
	var h0 := g.state_hash()
	g.add_mod(hs, "细胞膜修复", 1, "")
	check(g.state_hash() != h0, "挂上修饰后 state_hash 变化")
	g.spend_mods(hs, "细胞膜修复")
	check(g.state_hash() == h0, "消耗后还原")
	g.dispose()
# ---- 世界事件 ----

## 手动挂一个事件条目（绕过抽取；left/stacks 可指定），返回条目供操作簿记
func _install(g: CWGame, ev_name: String, stacks := 1, left := 1) -> Dictionary:
	var e := { "name": ev_name, "left": left, "stacks": stacks, "data": {} }
	g.events["active"].append(e)
	return e


func _find_act(opts: Array, act: String) -> Dictionary:
	for o in opts:
		if o["data"].get("act", "") == act:
			return o
	return {}


func t_world_events_draw() -> void:
	print("[世界事件·抽取]")
	var g := _fx_game(2)
	check(g.events["pool"].size() == 18, "开局事件池 18 个")
	for i in 7:
		await g.world_fx.trigger()
	check(g.events["pool"].size() == 11, "7 次触发后事件池剩 11（同局不重复，定案 #42）")
	var g2 := _fx_game(2)
	for i in 7:
		await g2.world_fx.trigger()
	check(g2.events["pool"] == g.events["pool"], "同种子抽取顺序一致（走 game.rng）")
	var snap := g.snapshot()
	var h := g.state_hash()
	await g.world_fx.trigger()
	check(g.state_hash() != h, "事件状态计入 state_hash")
	g.restore(snap)
	check(g.state_hash() == h, "快照带事件状态，restore 可复原")


func t_ev_attack_mods() -> void:
	print("[世界事件·攻击判定]")
	var g := _fx_game(2)
	check(g.actions.attack_outcome(1) == "fail" and g.actions.attack_outcome(3) == "success" \
		and g.actions.attack_outcome(6) == "crit", "基础判定：1~2 失败 / 3~5 成功 / 6 大成功")
	_install(g, "细胞毒", 1, 2)
	check(g.actions.attack_outcome(1) == "success" and g.actions.attack_outcome(2) == "success",
		"细胞毒：失败概率并给成功（定案 W3）")
	check(g.actions.attack_outcome(6) == "crit", "细胞毒：大成功不受影响")
	g.events["active"].clear()
	_install(g, "免疫伪装", 1, 2)
	check(g.actions.attack_outcome(6) == "success", "免疫伪装：大成功并给成功（PRD：1/3 失败、2/3 成功）")
	check(g.actions.attack_outcome(1) == "fail", "免疫伪装：失败概率不变")
	check(g.actions.attack_outcome(4) == "success", "免疫伪装：普通成功不受影响")


func t_ev_attack_flow() -> void:
	print("[世界事件·攻击流程]")
	var g := _fx_game(2)
	var imm := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.BASIC, -1)
	imm["energy"] = 500
	g.cells.append(imm)
	var can := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(1, 0), -1, CWData.CancerType.MELANOMA)
	can["energy"] = 500
	g.cells.append(can)
	## 抗原丢失：攻击不造成能量损失（细胞毒保证判定必然非失败）
	_install(g, "抗原丢失")
	_install(g, "细胞毒", 1, 2)
	var e0: int = can["energy"]
	await g.actions._do_move(imm, Vector2i(1, 0), 0)
	check(can["energy"] == e0, "抗原丢失：攻击无法使癌细胞损失能量")
	check(imm["pos"] == Vector2i(0, 0), "目标未死 → 攻击者返回原格")
	## 抗原变异：失败/大成功触发抽牌（多打几次总会掷出）
	g.events["active"].clear()
	_install(g, "抗原变异", 1, 2)
	var drew := false
	for i in 20:
		imm["pos"] = Vector2i(0, 0)
		var n0 := g.logs.size()
		await g.actions._do_move(imm, Vector2i(1, 0), 0)
		for j in range(n0, g.logs.size()):
			if g.logs[j].contains("抗原变异"):
				drew = true
		if drew or not can["alive"]:
			break
	check(drew, "抗原变异：攻击失败/大成功触发抽牌")


func t_ev_costs() -> void:
	print("[世界事件·费用修正]")
	var g := _fx_game(2)
	var imm := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.BASIC, -1)
	imm["energy"] = 100
	g.cells.append(imm)
	## 基质阻隔：移动费翻倍（免疫移动 + 癌症技能移动）
	_install(g, "基质阻隔", 1, 2)
	var opts: Array = []
	g.actions._immune_options(imm, opts)
	check(_find_act(opts, "move")["data"]["cost"] == g.tune.immune_move_healthy[0] * 2,
		"基质阻隔：免疫移动费翻倍")
	## 免疫伪装：癌细胞移动 +0.2
	g.events["active"].clear()
	_install(g, "免疫伪装", 1, 2)
	var can := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(0, 3), -1, CWData.CancerType.MELANOMA)
	can["energy"] = 100
	g.cells.append(can)
	g.tiles[Vector2i(0, 2)]["tissue"] = CWData.Tissue.CANCER
	opts = []
	g.actions._cancer_options(can, opts)
	var mv := {}
	for o in opts:
		if o["data"].get("act", "") == "move" and o["data"]["to"] == Vector2i(0, 2):
			mv = o
	check(mv["data"]["cost"] == CWData.CANCER_MOVE_CANCEROUS + 2, "免疫伪装：癌细胞移动 +0.2")
	## 迁移激活：免疫每回合首次移动免费，用掉恢复原价，新回合重置
	g.events["active"].clear()
	_install(g, "迁移激活", 1, 2)
	opts = []
	g.actions._immune_options(imm, opts)
	var first := _find_act(opts, "move")
	check(first["data"]["cost"] == 0, "迁移激活：首次移动费用 0")
	await g.actions.execute(imm, first["data"])
	opts = []
	g.actions._immune_options(imm, opts)
	check(_find_act(opts, "move")["data"]["cost"] == g.tune.immune_move_healthy[0],
		"迁移激活：第二次移动恢复原价")
	await g.world_fx.on_round_start()
	opts = []
	g.actions._immune_options(imm, opts)
	check(_find_act(opts, "move")["data"]["cost"] == 0, "迁移激活：新回合重置")
	## 细胞应激：打牌收费（付不起 → 无选项；付得起 → 打出时扣费）
	g.events["active"].clear()
	_install(g, "细胞应激")
	g.tiles[Vector2i(0, 2)]["tissue"] = CWData.Tissue.HEALTHY
	var target := CWSetup.make_cell(2, 1, CWData.Faction.CANCER, imm["pos"] + Vector2i(1, 0), -1, CWData.CancerType.MELANOMA)
	target["energy"] = 100
	g.cells.append(target)
	imm["hand"] = ["交叉呈递"]
	imm["energy"] = 3
	opts = []
	g.card_fx.hand_options(imm, opts)
	check(opts.is_empty(), "细胞应激：付不起 0.5 就打不出")
	imm["energy"] = 100
	opts = []
	g.card_fx.hand_options(imm, opts)
	check(not opts.is_empty(), "细胞应激：付得起时选项照常")
	await g.card_fx.play(imm, opts[0]["data"])
	check(imm["energy"] == 95, "细胞应激：打出时支付 0.5")


func t_ev_suppressor() -> void:
	print("[世界事件·免疫抑制因子]")
	var g := _fx_game(2)
	var imm := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.BASIC, -1)
	imm["energy"] = 100
	imm["hand"] = ["测试卡A", "测试卡B"]
	g.cells.append(imm)
	g.tiles[Vector2i(1, 0)]["tissue"] = CWData.Tissue.CANCER
	var e := _install(g, "免疫抑制因子")
	var opts: Array = []
	g.actions._immune_options(imm, opts)
	var mv := {}
	for o in opts:
		if o["data"].get("act", "") == "move" and o["data"]["to"] == Vector2i(1, 0):
			mv = o
	check(mv["data"]["cost"] == g.tune.immune_move_cancerous[0] + 2, "净化移动加价 0.2（定案 W5）")
	var mem0: int = g.memory
	await g.actions.enter_tile(imm, Vector2i(1, 0))
	check(g.tiles[Vector2i(1, 0)]["tissue"] == CWData.Tissue.HEALTHY and g.memory == mem0,
		"净化照常发生但不获得抗原记忆（定案 W5）")
	var can := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(0, 3), -1, CWData.CancerType.MELANOMA)
	can["energy"] = 20
	g.cells.append(can)
	await g.world_fx._resolve(e)
	check(can["energy"] == 15, "一次性部分：所有癌细胞失去 0.5")
	check(imm["hand"].size() == 1, "一次性部分：所有免疫随机弃 1 张（定案 W6）")


func t_ev_supply() -> void:
	print("[世界事件·补给类]")
	var g := _fx_game(2)
	## 营养输送：首次通过血管 +2.0 并抽 1，第二次不再奖励
	var imm := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, CWData.VESSELS[0], CWData.ImmuneType.BASIC, -1)
	imm["energy"] = 10
	g.cells.append(imm)
	var e := _install(g, "营养输送", 1, 2)
	await g.world._vessel_teleport()
	check(imm["pos"] == CWData.VESSELS[1], "血管传送照常")
	check(e["data"].has(imm["id"]), "营养输送：登记首次通过")
	check(imm["energy"] >= 30, "营养输送：+2.0 能量（抽到的事件卡可能另有增益）")
	var after: int = imm["energy"]
	var hand_after: int = imm["hand"].size()
	await g.world._vessel_teleport()
	check(imm["energy"] == after and imm["hand"].size() == hand_after,
		"营养输送：同一细胞第二次通过不再奖励")
	## 代谢加速：收取代谢核心翻倍
	g.events["active"].clear()
	_install(g, "代谢加速", 1, 2)
	var core: Vector2i = CWData.CORES[0]
	g.tiles[core]["store"] = 10
	var e1: int = imm["energy"]
	await g.actions.collect_special(imm, core)
	check(imm["energy"] == e1 + 20, "代谢加速：收取 1.0 变 2.0")
	## 营养缺乏：清空并本回合不产出
	g.events["active"].clear()
	var lack := _install(g, "营养缺乏")
	g.tiles[core]["store"] = 10
	g.tiles[CWData.MARROWS[0]]["cards"] = 1
	await g.world_fx._resolve(lack)
	check(g.tiles[core]["store"] == 0 and g.tiles[CWData.MARROWS[0]]["cards"] == 0,
		"营养缺乏：代谢核心与骨髓清空")
	var prod0: int = g.tiles[core]["prod"]
	await g.world._tissue_production()
	check(g.tiles[core]["store"] == 0 and g.tiles[core]["prod"] == prod0,
		"营养缺乏：本回合不产出")


func t_ev_solidify_accel() -> void:
	print("[世界事件·固化加速]")
	var g := _fx_game(2)
	var pos := Vector2i(2, 2)
	g.tiles[pos]["tissue"] = CWData.Tissue.CANCER
	g.tiles[pos]["solid"] = 15
	_install(g, "固化加速")
	g.raise_solid(pos, 10)
	check(g.tiles[pos]["tissue"] == CWData.Tissue.SOLID,
		"固化加速：从 <2.0 涨到 ≥2.0 立即转化（定案 W4，1.5+1.0 含骨样硬化口径）")
	var p2 := Vector2i(3, 2)
	g.tiles[p2]["tissue"] = CWData.Tissue.CANCER
	g.tiles[p2]["solid"] = 20
	g.raise_solid(p2, 5)
	check(g.tiles[p2]["tissue"] == CWData.Tissue.CANCER, "触发时已 ≥2.0 的格不追溯转化（W4 保守读法）")
	g.events["active"].clear()
	g.raise_solid(p2, 5)
	check(g.tiles[p2]["tissue"] == CWData.Tissue.SOLID, "无事件时仍按 3.0 正常转化")


func t_ev_chaos() -> void:
	print("[世界事件·紊乱]")
	var g := _fx_game(2)
	var imm := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.BASIC, -1)
	imm["energy"] = 50
	g.cells.append(imm)
	var can := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(0, 6), -1, CWData.CancerType.MELANOMA)
	can["energy"] = 50
	g.cells.append(can)
	g.tiles[Vector2i(0, 6)]["tissue"] = CWData.Tissue.CANCER
	g.tiles[Vector2i(0, 5)]["tissue"] = CWData.Tissue.CANCER   ## 癌方唯一空余癌组织
	var e := _install(g, "紊乱")
	await g.world_fx._chaos(e)
	check(imm["pos"] != Vector2i(0, 0) and g.tiles[imm["pos"]]["tissue"] == CWData.Tissue.HEALTHY,
		"紊乱：免疫传送到健康组织")
	check(g.tile(imm["pos"])["special"] != CWData.Special.VESSEL, "紊乱：不落在血管格（定案 W2）")
	check(can["pos"] == Vector2i(0, 5), "紊乱：癌细胞传送到己方组织（唯一候选）")
	check(e["data"][imm["id"]] == Vector2i(0, 0) and e["data"][can["id"]] == Vector2i(0, 6),
		"紊乱：原位已记录")
	await g.world_fx._chaos_return(e)
	check(imm["pos"] == Vector2i(0, 0) and can["pos"] == Vector2i(0, 6), "紊乱：回合结束返回原位")
	## 原位被占则留在原地（W2③ 未定案，保守假设）
	await g.world_fx._chaos(e)
	var blocker := CWSetup.make_cell(2, 1, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.BASIC, -1)
	blocker["energy"] = 50
	g.cells.append(blocker)
	await g.world_fx._chaos_return(e)
	check(imm["pos"] != Vector2i(0, 0), "紊乱：原位被占时留在原地")


func t_ev_memory() -> void:
	print("[世界事件·抗原暴露]")
	var g := _fx_game(2)
	_install(g, "抗原暴露", 1, 2)
	g.gain_memory(1)
	check(g.memory == 2, "抗原暴露：每次获得记忆额外 +1")
	g.gain_memory(2)
	check(g.memory == 5, "抗原暴露：按次数不按点数（+2 变 +3）")


func t_ev_proliferate() -> void:
	print("[世界事件·增生类]")
	var g := _fx_game(2)
	g.tune.proliferate_per_adjacent = 1000   ## 必中，隔离概率因素
	g.tiles[Vector2i(0, 0)]["tissue"] = CWData.Tissue.CANCER
	_install(g, "增殖抑制")
	g.world._proliferate()
	var converted := 0
	for c in CWData.neighbors(Vector2i(0, 0)):
		if g.tiles[c]["tissue"] == CWData.Tissue.CANCER:
			converted += 1
	check(converted == 0, "增殖抑制：本回合组织无法增生")
	g.events["active"].clear()
	g.world._proliferate()
	converted = 0
	for c in CWData.neighbors(Vector2i(0, 0)):
		if g.tiles[c]["tissue"] == CWData.Tissue.CANCER:
			converted += 1
	check(converted == 6, "解除后增生恢复（必中六邻全转）")
	## 异常增殖：概率翻倍（50% 翻成 100% 验证）
	var g2 := _fx_game(2)
	g2.tune.proliferate_per_adjacent = 500
	g2.tiles[Vector2i(0, 0)]["tissue"] = CWData.Tissue.CANCER
	_install(g2, "异常增殖", 1, 2)
	g2.world._proliferate()
	var all6 := true
	for c in CWData.neighbors(Vector2i(0, 0)):
		if g2.tiles[c]["tissue"] != CWData.Tissue.CANCER:
			all6 = false
	check(all6, "异常增殖：增生概率翻倍（单邻 50% → 100% 必中）")


func t_ev_double() -> void:
	print("[世界事件·双重触发]")
	var g := _fx_game(2)
	g.events["double_next"] = true
	g.events["pool"] = ["信号放大"]
	await g.world_fx.trigger()
	check(g.event_stacks("信号放大") == 2 and g.events["active"][0]["left"] == 2,
		"可叠事件：触发两次（stacks=2，仍持续 2 回合）")
	g.events["active"].clear()
	g.events["double_next"] = true
	g.events["pool"] = ["细胞毒"]
	await g.world_fx.trigger()
	check(g.event_stacks("细胞毒") == 1 and g.events["active"][0]["left"] == 4,
		"开关类持续事件：一份强度接力 4 回合（定案 #49 修订版）")
	check(not g.events["double_next"], "双重触发：标记已消耗")


func t_ev_lifecycle() -> void:
	print("[世界事件·生命周期]")
	var g := _fx_game(2)
	_install(g, "细胞毒", 1, 2)
	_install(g, "抗原丢失", 1, 1)
	await g.world_fx.round_end()
	check(g.event_stacks("细胞毒") == 1 and g.event_stacks("抗原丢失") == 0,
		"回合末：本回合事件到期，持续事件余 1 回合")
	await g.world_fx.round_end()
	check(g.events["active"].is_empty(), "第二个回合末全部到期")
func t_ev_chaos_simul() -> void:
	print("[世界事件·紊乱同时返回]")
	var g := _fx_game(2)
	var a := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(5, 0), CWData.ImmuneType.BASIC, -1)
	a["energy"] = 50
	g.cells.append(a)
	var b := CWSetup.make_cell(1, 1, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.BASIC, -1)
	b["energy"] = 50
	g.cells.append(b)
	## 模拟传送后的局面：a 原位 (0,0) 正被 b 站着（b 自己也是返回者，原位 (0,1)）
	var e := _install(g, "紊乱")
	e["data"][a["id"]] = Vector2i(0, 0)
	e["data"][b["id"]] = Vector2i(0, 1)
	await g.world_fx._chaos_return(e)
	check(a["pos"] == Vector2i(0, 0) and b["pos"] == Vector2i(0, 1),
		"方案A：原位被另一个返回者占着不算挡，两个都归位")


func t_ev_double_instant() -> void:
	print("[世界事件·双重触发×本回合类]")
	var g := _fx_game(2)
	var imm := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.BASIC, -1)
	imm["energy"] = 100
	g.cells.append(imm)
	g.events["double_next"] = true
	g.events["pool"] = ["增殖抑制"]
	await g.world_fx.trigger()
	var e: Dictionary = g.events["active"][0]
	check(e["left"] == 2 and e["stacks"] == 1, "本回合类加倍：连续两回合各生效一遍（定案 #49 修订版）")
	check(imm["energy"] == 95, "第一回合结算一遍（免疫 −0.5）")
	await g.world_fx.round_end()
	check(g.event_stacks("增殖抑制") == 1, "回合末仍在场（余 1 回合）")
	await g.world_fx.on_round_start()
	check(imm["energy"] == 90, "第二回合开头完整重演（再 −0.5）")
	await g.world_fx.round_end()
	check(g.events["active"].is_empty(), "第二回合末到期")
func t_breath_sheets() -> void:
	print("[细胞呼吸动画]")
	var M = load("res://scripts/ui/match.gd")
	var arts: Array = []
	arts.append_array(M.IMMUNE_ART.values())
	arts.append_array(M.CANCER_ART.values())
	check(arts.size() == 9, "九种细胞都有呼吸表")
	var ok := true
	for tex in arts:
		var w: int = tex.get_width()
		if w % M.BREATH_FRAMES != 0 or not (w / M.BREATH_FRAMES) in [16, 32] 				or not tex.get_height() in [18, 32, 34]:
			ok = false
	check(ok, "每张都是横排 6 帧、帧宽 16/32、帧高 18/32/34")
## 打牌交互（方案甲，团队 2026-08-29 定）：点手牌 → 棋盘选目标。
## 和 t_human_ask 一样用合成信号驱动，逐步核对**下标映射**。
func t_hand_play() -> void:
	print("[打牌交互·方案甲]")
	var board := make_board()
	root.add_child(board)
	var bar := CWActionBar.new()
	root.add_child(bar)
	var hand := CWHand.new()
	root.add_child(hand)

	var g := CWGame.new()
	g.init(CWData.FACTION_ORDER[2], 11)
	var ai := CWHeuristicBridge.new()
	ai.game = g
	for pid in g.order:
		g.bridges[pid] = ai
	await run_setup(g)

	var b := CWUIBridge.new()
	b.game = g
	b.board = board
	b.bar = bar
	b.hand = hand
	b.human_pids = [0]
	for pid in g.order:
		g.bridges[pid] = b

	hand.sync(3, Vector2.INF, PackedStringArray(["交叉呈递", "乳酸酸化", "免疫增援"]))
	var tpos: Vector2i = g.cells[1]["pos"]
	var areq := { "kind": "action", "pid": 0, "prompt": "", "options": [
		{ "label": "", "data": { "act": "move", "to": Vector2i(1, 0), "cost": 5 } },
		{ "label": "", "data": { "act": "play", "card": "交叉呈递", "cid": 1 } },
		{ "label": "", "data": { "act": "play", "card": "溶酶体强化" } },
		{ "label": "", "data": { "act": "discard", "card": "交叉呈递" } },
		{ "label": "", "data": { "act": "discard", "card": "乳酸酸化" } },
		{ "label": "", "data": { "act": "discard", "card": "永久样例" } },
		{ "label": "", "data": { "act": "end" } }] }

	# ① 点卡 → 高亮目标细胞所在格 → 点格 → 还原为对应选项下标
	var r1 := [-99]
	var run1 := func() -> void: r1[0] = await b.ask(areq)
	run1.call()
	hand.card_clicked.emit("交叉呈递")
	await process_frame
	check(b.marks.size() == 1 and b.marks.has(tpos), "点卡后高亮目标细胞所在格")
	check(hand._selected == 0, "被点的卡进入选中态（半抬）")
	var pad: Control = bar._row.get_child(0)
	check(not (pad is PanelContainer) and pad.custom_minimum_size.x == CWHand.LEFT + CWHand.SPAN,
		"底条给手牌区让位 312px（标题不会被抬起的卡压住）")
	board.tile_clicked.emit(Vector2i(9, 9))
	check(r1[0] == -99, "点非目标格无效")
	board.tile_clicked.emit(tpos)
	await process_frame
	check(r1[0] == 1, "点目标格 → 还原成那张卡对那个目标的选项下标")
	check(hand._selected == -1, "答完选中态清除")

	# ② 目标态中途改点另一张卡 → 换卡；无目标卡走「确认打出」一拍（定案③）
	var r2 := [-99]
	var run2 := func() -> void: r2[0] = await b.ask(areq)
	run2.call()
	hand.card_clicked.emit("交叉呈递")
	await process_frame
	hand.card_clicked.emit("溶酶体强化")
	await process_frame
	check(b.marks.is_empty(), "换到无目标卡：不再高亮格子")
	bar.chosen.emit(0)                        ## 「确认打出」
	await process_frame
	check(r2[0] == 2, "确认打出 → 无目标卡的选项下标")

	# ③ 右键 → 弃置确认（定案②）
	var r3 := [-99]
	var run3 := func() -> void: r3[0] = await b.ask(areq)
	run3.call()
	hand.card_right_clicked.emit("乳酸酸化")
	await process_frame
	bar.chosen.emit(0)                        ## 「确认弃置」
	await process_frame
	check(r3[0] == 4, "确认弃置 → 那张卡的弃置选项下标")

	# ④ 打不出的卡：给解释，可就地弃置
	var r4 := [-99]
	var run4 := func() -> void: r4[0] = await b.ask(areq)
	run4.call()
	hand.card_clicked.emit("永久样例")
	await process_frame
	await process_frame
	var last: Control = bar._row.get_child(bar._row.get_child_count() - 1)
	check(last.position.x + last.size.x <= 674.0,
		"让位形态下按钮不越过底条右缘（不会藏进右侧竖条底下）")
	bar.chosen.emit(0)                        ## 「弃置它」→ 先进弃置确认（试玩第四轮）
	await process_frame
	check(r4[0] == -99, "「弃置它」不直接弃：先进确认条")
	bar.chosen.emit(0)                        ## 「确认弃置」
	await process_frame
	check(r4[0] == 5, "确认后才真的弃置")

	# ⑤ 取消回按钮栏，这一问还没答；手牌手势只在行动询问期间生效
	var r5 := [-99]
	var run5 := func() -> void: r5[0] = await b.ask(areq)
	run5.call()
	hand.card_clicked.emit("交叉呈递")
	await process_frame
	bar.chosen.emit(0)                        ## 「取消」
	await process_frame
	check(r5[0] == -99 and b.marks.is_empty(), "取消后回到按钮栏，这一问还没答")
	bar.chosen.emit(_buttons(bar) - 1)        ## 结束回合（纯行动栏形态占最后一格）
	await process_frame
	check(r5[0] == 6, "结束回合仍然可用")

	# ⑤b 子问句里右键点在卡上也等于「取消」，不是弃那张卡（试玩第三轮报的）
	var r5b := [-99]
	var run5b := func() -> void: r5b[0] = await b.ask(areq)
	run5b.call()
	hand.card_clicked.emit("交叉呈递")
	await process_frame
	hand.card_right_clicked.emit("乳酸酸化")
	await process_frame
	check(r5b[0] == -99 and b.marks.is_empty(), "目标态里右键点卡 = 取消，回到按钮栏")
	bar.chosen.emit(_buttons(bar) - 1)
	await process_frame
	check(r5b[0] == 6, "取消后仍能正常结束回合")

	# ⑦ 双击无目标卡 → 免确认直接打出（2026-08-30 对局内试玩追加）
	var r7 := [-99]
	var run7 := func() -> void: r7[0] = await b.ask(areq)
	run7.call()
	hand.card_double_clicked.emit("溶酶体强化")
	await process_frame
	check(r7[0] == 2, "双击无目标卡：跳过「确认打出」直接打")

	# ⑧ 双击有目标的卡：目标没法替玩家选，照旧进选目标态
	var r8 := [-99]
	var run8 := func() -> void: r8[0] = await b.ask(areq)
	run8.call()
	hand.card_double_clicked.emit("交叉呈递")
	await process_frame
	check(r8[0] == -99 and b.marks.has(tpos), "双击有目标卡：仍要在棋盘上选")
	board.tile_clicked.emit(tpos)
	await process_frame
	check(r8[0] == 1, "选完目标正常还原下标")

	# ⑥ 卡控件的鼠标事件真的接到了信号上（左键/右键/双击各一发）
	var seen: Array = []
	hand.card_clicked.connect(func(n: String) -> void: seen.append(["L", n]))
	hand.card_right_clicked.connect(func(n: String) -> void: seen.append(["R", n]))
	hand.card_double_clicked.connect(func(n: String) -> void: seen.append(["D", n]))
	var ev := InputEventMouseButton.new()
	ev.pressed = true
	ev.button_index = MOUSE_BUTTON_LEFT
	hand._cards[0].gui_input.emit(ev)
	var ev2 := InputEventMouseButton.new()
	ev2.pressed = true
	ev2.button_index = MOUSE_BUTTON_RIGHT
	hand._cards[1].gui_input.emit(ev2)
	## 双击的第二下：double_click=true，只发双击信号、不再发一次单击
	var ev3 := InputEventMouseButton.new()
	ev3.pressed = true
	ev3.button_index = MOUSE_BUTTON_LEFT
	ev3.double_click = true
	hand._cards[0].gui_input.emit(ev3)
	check(seen == [["L", "交叉呈递"], ["R", "乳酸酸化"], ["D", "交叉呈递"]],
		"卡上的左右键与双击事件映射到手势信号")

	g.dispose()
	hand.free()
	bar.free()
	board.free()


# ---- 2026-08-30 审查后的四条定案（A/B/C/D）----
## 这一组盯的是**结算顺序**本身，而不是单张卡的数值。审查那天 683 项全绿却漏掉了
## 全部六个问题，原因就是没有人从「两张卡先后顺序不同会怎样」这个角度写过断言。
func t_settle_order_rulings() -> void:
	print("[结算顺序定案 A/B/C/D]")
	_t_ruling_a_rewrite()
	await _t_ruling_d_keep_allowance()
	_t_ruling_b_armor()
	await _t_ruling_c_presentation()


## 建一个只有棋盘的空对局（不落子），方便手工摆细胞
func bare_game() -> CWGame:
	var g := CWGame.new()
	g.init(CWData.FACTION_ORDER[2], 1)
	g.setup.build_board()
	return g


func put_immune(g: CWGame, at: Vector2i) -> Dictionary:
	var c := CWSetup.make_cell(g.cells.size(), 0, CWData.Faction.IMMUNE, at,
		CWData.ImmuneType.BASIC, -1, 200)
	g.cells.append(c)
	return c


## 装备一个永久技能并盖上打出先后的戳（和 CWCardFx.play 的装备分支同口径）
func put_skill(cell: Dictionary, skill: String) -> void:
	cell["equipped"].append(skill)
	cell["play_n"] += 1
	cell["equip_seq"][skill] = cell["play_n"]


## 定案 A：【炎症趋化】是「**改为** 0.5」而不是「降为」——它会把更便宜的价钱抬回 0.5。
## 抬价本身是有意的（打出顺序要玩家权衡），所以这里钉的是「确实会抬」而不是「不许抬」。
func _t_ruling_a_rewrite() -> void:
	var canc := Vector2i(1, 0)
	var g := bare_game()
	g.tiles[canc]["tissue"] = CWData.Tissue.CANCER
	var cell := put_immune(g, Vector2i.ZERO)
	put_skill(cell, "组织巡航")
	check(g.actions._move_cost_mod(cell, canc, 10) == 0, "只有【组织巡航】：首移免费")
	g.add_mod(cell, "炎症趋化", 1, "turn")
	check(g.actions._move_cost_mod(cell, canc, 10) == CWData.INFLAM_CHEMO_COST,
		"A：后打的【炎症趋化】把 0 改写成 0.5（改为，不是降为）")
	g.dispose()

	## 反过来打就不会被抬——同两张卡、只差顺序，结果不同
	var g2 := bare_game()
	g2.tiles[canc]["tissue"] = CWData.Tissue.CANCER
	var c2 := put_immune(g2, Vector2i.ZERO)
	g2.add_mod(c2, "炎症趋化", 1, "turn")
	put_skill(c2, "组织巡航")
	check(g2.actions._move_cost_mod(c2, canc, 10) == 0,
		"A：先打【炎症趋化】再装【组织巡航】则仍是 0（顺序决定结果）")
	g2.dispose()


## 定案 D：不改变费用的条目不结算、也不消耗额度。
func _t_ruling_d_keep_allowance() -> void:
	## D-1：两个「本回合首次免费」，一次移动只该用掉一个
	var g := bare_game()
	var cell := put_immune(g, Vector2i.ZERO)
	put_skill(cell, "组织巡航")
	put_skill(cell, "组织驻留")
	var base_h: int = g.tune.immune_move_healthy[0]
	check(g.actions._move_cost_mod(cell, Vector2i(1, 0), base_h) == 0, "D：首移→健康免费")
	await g.actions._do_move(cell, Vector2i(1, 0), 0)
	check(cell["fx_turn"].has("组织巡航"), "D：【组织巡航】的首移额度用掉了")
	check(not cell["fx_turn"].has("组织驻留"),
		"D：【组织驻留】没起作用，额度留着（旧版会一起烧掉）")
	check(g.actions._move_cost_mod(cell, Vector2i(2, 0), base_h) == 0,
		"D：同回合第二次→健康，靠【组织驻留】仍免费")
	await g.actions._do_move(cell, Vector2i(2, 0), 0)
	check(cell["fx_turn"].has("组织驻留"), "D：这一次才轮到【组织驻留】")
	check(g.actions._move_cost_mod(cell, Vector2i(3, 0), base_h)
		== maxi(base_h - CWData.CRUISE_CUT, CWData.MOVE_CUT_MIN),
		"D：两个额度用尽后只剩【组织巡航】的 -0.2")
	g.dispose()

	## D-2：限次折扣卡在价钱已经到底时不该被扣次数
	var canc := Vector2i(1, 0)
	var g2 := bare_game()
	g2.immune_level = 3                       ## X 级基准 0.5
	g2.tiles[canc]["tissue"] = CWData.Tissue.CANCER
	var c2 := put_immune(g2, Vector2i.ZERO)
	put_skill(c2, "组织浸润")                   ## -0.3 → 0.2，已到 MOVE_CUT_MIN
	g2.add_mod(c2, "CXCR3趋化", 2, "turn")
	var quote: int = g2.actions._move_cost_mod(c2, canc, g2.actions._move_base_cost(c2, canc))
	check(quote == CWData.MOVE_CUT_MIN, "D：0.5 −0.3 已踩到下限 0.2")
	await g2.actions._do_move(c2, canc, quote)
	var left: Array = g2.mods_of(c2, "CXCR3趋化")
	check(left.size() == 1 and left[0]["uses"] == 2,
		"D：【CXCR3趋化】这一次没减到钱，两次额度都留着")
	g2.dispose()

	## D-3：【迁移激活】的每回合免费额度同理
	var g3 := bare_game()
	var c3 := put_immune(g3, Vector2i.ZERO)
	put_skill(c3, "组织巡航")
	g3.events["active"].append({ "name": "迁移激活", "left": 2, "stacks": 1, "data": {} })
	check(g3.actions._move_cost_mod(c3, Vector2i(1, 0), g3.tune.immune_move_healthy[0]) == 0,
		"D：巡航已经把首移变免费")
	await g3.actions._do_move(c3, Vector2i(1, 0), 0)
	check(g3.world_fx.free_move_available(c3),
		"D：【迁移激活】的免费额度没被白烧")
	g3.dispose()


## 定案 B：【囊性护甲】= 每世界回合第一次能量损失 -0.5，**不限来源**。
## 旧实现只挂在 immune_hit 上，世界事件那条管线整个绕过去了。
func _t_ruling_b_armor() -> void:
	var g := bare_game()
	var sig := CWSetup.make_cell(0, 0, CWData.Faction.CANCER, Vector2i(2, 0),
		-1, CWData.CancerType.SIGNET, 100)
	g.cells.append(sig)
	var atk := CWSetup.make_cell(1, 1, CWData.Faction.IMMUNE, Vector2i(3, 0),
		CWData.ImmuneType.BASIC, -1, 100)
	g.cells.append(atk)
	check(g.cancer_hit(sig, 5, "免疫抑制因子") == 0,
		"B：世界事件的 0.5 被【囊性护甲】完全挡下（旧版挡不住）")
	check(sig["armor_used"], "B：这一轮的护甲额度已用掉")
	check(g.immune_hit(sig, 10, atk, false) == 10,
		"B：同一世界回合内不再减免，两条管线共用同一个额度")
	g.world._reset_round_flags()
	check(g.immune_hit(sig, 10, atk, false) == 5, "B：新世界回合护甲恢复")
	g.dispose()


## 定案 C：【抗原呈递强化】按口径 #70「攻击发动即算攻过」——把目标当场打死，
## 本世界回合的施加额度照样用掉。审查前这是 and 求值顺序的副产品，现在是明写的选择，
## 而且必须有一句日志，否则玩家看不出额度没了。
func _t_ruling_c_presentation() -> void:
	var canc := Vector2i(1, 0)
	var g := bare_game()
	g.tiles[canc]["tissue"] = CWData.Tissue.CANCER
	var dc := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i.ZERO,
		CWData.ImmuneType.DENDRITIC, -1, 200)
	put_skill(dc, "抗原呈递强化")
	g.cells.append(dc)
	var victim := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, canc,
		-1, CWData.CancerType.SCLC, 5)
	g.cells.append(victim)
	g.tune.attack_dmg_success = 200   ## 保证一击必杀，把「目标已死」这条路走到
	var n0: int = g.logs.size()
	await g.actions._do_move(dc, canc, 0)
	check(not victim["alive"], "C：目标被一击打死")
	check(dc["fx_round"].has("抗原呈递强化"),
		"C：按口径 #70，打死目标也算攻过，本世界回合额度用掉")
	var told := false
	for i in range(n0, g.logs.size()):
		if "抗原呈递强化" in g.logs[i] and "已死亡" in g.logs[i]:
			told = true
	check(told, "C：日志要说清额度是怎么没的（旧版零反馈）")
	g.dispose()
