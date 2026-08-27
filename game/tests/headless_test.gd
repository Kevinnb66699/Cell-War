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
	await t_full_game_2p()
	await t_full_game_4p()
	await t_determinism()
	t_board_view()
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
func make_game(n_players: int, seed_value: int) -> CWGame:
	var g := CWGame.new()
	g.init(CWData.FACTION_ORDER[n_players], seed_value)
	for pid in g.order:
		var b := CWHeuristicBridge.new()
		b.game = g
		g.bridges[pid] = b
	return g


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
	await g.setup.run()
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


# ---- 攻击伤害结算顺序：基础 → 标记×2 → 免疫逃逸-0.5 ----
func t_hit_order() -> void:
	print("[伤害结算]")
	var g := make_game(2, 1)
	await g.setup.run()
	var target: Dictionary = g.living_cells(CWData.Faction.CANCER)[0]
	var attacker: Dictionary = g.living_cells(CWData.Faction.IMMUNE)[0]
	target["ctype"] = CWData.CancerType.ESCAPE
	target["marked"] = true
	target["escape_used"] = false
	target["energy"] = 50
	attacker["itype"] = CWData.ImmuneType.MACRO
	var before_atk: int = attacker["energy"]
	var dmg := g.immune_hit(target, 10, attacker)
	check(dmg == 15, "1.0 ×2(标记) -0.5(逃逸) = 1.5")
	check(target["energy"] == 35, "目标余 3.5")
	check(attacker["energy"] == before_atk + 5, "巨噬吞噬 +0.5")
	check(not target["marked"], "标记已消耗")
	var dmg2 := g.immune_hit(target, 10, attacker)
	check(dmg2 == 10, "逃逸每世界回合仅一次，第二击不减免")
	g.dispose()


# ---- 无氧呼吸向下取整 ----
func t_anaerobic_floor() -> void:
	print("[无氧呼吸]")
	var g := make_game(2, 1)
	g.setup.build_board()
	# 连通块：3 癌 + 1 固化 = 0.2×3 + 0.5 = 1.1 → 2 个细胞各得 0.5（向下取整）
	var coords := [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0)]
	for c in coords:
		g.tiles[c]["tissue"] = CWData.Tissue.CANCER
	g.tiles[Vector2i(3, 0)]["tissue"] = CWData.Tissue.SOLID
	for i in 2:
		var cell := CWSetup.make_cell(i, i, CWData.Faction.CANCER, coords[i], -1, 0)
		cell["energy"] = 0
		g.cells.append(cell)
	g.world._anaerobic()
	check(g.cells[0]["energy"] == 5 and g.cells[1]["energy"] == 5,
		"池 1.1 / 2 细胞 = 各 0.5（向下取整到 0.1）")
	g.dispose()


# ---- 固化与衰减 ----
func t_solidify_and_decay() -> void:
	print("[固化]")
	var g := make_game(2, 1)
	g.setup.build_board()
	var pos := Vector2i(1, 1)
	g.tiles[pos]["tissue"] = CWData.Tissue.CANCER
	var cell := CWSetup.make_cell(0, 0, CWData.Faction.CANCER, pos, -1, CWData.CancerType.BLAST)
	g.cells.append(cell)
	g.world._solidify()
	check(g.tiles[pos]["solid"] == 1, "停留 1 回合计数 1")
	g.world._solidify()
	check(g.tiles[pos]["tissue"] == CWData.Tissue.SOLID, "计数到 2 → 固化癌组织")
	# 衰减：无细胞停留的癌组织 -1；固着点不减
	var d1 := Vector2i(-1, 0)
	g.tiles[d1]["tissue"] = CWData.Tissue.CANCER
	g.tiles[d1]["solid"] = 1
	g.world._decay()
	check(g.tiles[d1]["solid"] == 0, "无人停留 → 计数 -1")
	g.tiles[d1]["solid"] = 1
	g.tiles[d1]["sticky"] = 1
	g.world._decay()
	check(g.tiles[d1]["solid"] == 1, "固着点不自然衰减")
	# 新生癌组织当回合不可固化
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
	g.check_cancer_s_win()
	check(g.winner < 0, "加权 %d < %d → 未获胜" % [need - 1, need])
	g.tiles[coords[need - 1]]["tissue"] = CWData.Tissue.CANCER
	g.check_cancer_s_win()
	check(g.winner == CWData.Faction.CANCER, "加权 %d → 癌症胜利" % need)
	g.dispose()


# ---- 免疫细胞死亡 → 罚停 → 随机健康组织复活 ----
func t_immune_respawn() -> void:
	print("[免疫罚停复活]")
	var g := make_game(4, 11)
	await g.setup.run()
	var imm: Dictionary = g.living_cells(CWData.Faction.IMMUNE)[0]
	g.round_no = 3
	g.kill(imm)
	check(not imm["alive"], "免疫细胞死亡")
	check(imm["respawn_round"] == 5, "罚停 1 回合：死于第 3 → 第 5 回合复活")
	# 第 4 回合：仍在罚停
	g.round_no = 4
	g.world._immune_respawn()
	check(not imm["alive"], "第 4 回合仍未复活（缺席一整回合）")
	# 第 5 回合：复活于健康组织
	g.round_no = 5
	g.world._immune_respawn()
	check(imm["alive"], "第 5 回合复活")
	check(g.tile(imm["pos"])["tissue"] == CWData.Tissue.HEALTHY, "复活点是健康组织")
	check(imm["energy"] == CWData.IMMUNE_RESPAWN_ENERGY, "复活获得 2.0 能量")
	check(imm["respawn_round"] == -1, "复活后清除罚停标记")
	# 关掉复活开关 → 永久死亡（规则原文语义）
	g.tune.immune_respawn_delay = -1
	var imm2: Dictionary = g.living_cells(CWData.Faction.IMMUNE)[0]
	g.kill(imm2)
	g.world._immune_respawn()
	check(not imm2["alive"], "旋钮关掉后免疫永久死亡")
	g.dispose()


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
	var board = load("res://scenes/Board.tscn").instantiate()
	board._ready()   # 不入场景树，直接触发生成

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
