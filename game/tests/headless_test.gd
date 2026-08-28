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
	t_hex_pick()
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
	board.set_marks({ Vector2i(0, 0): board.MARK_MOVE, Vector2i(1, 0): board.MARK_ATTACK })
	check(board._marks.get_child_count() == 2, "设置 2 格高亮")
	board.set_marks({ Vector2i(3, -1): board.MARK_HOVER })
	check(board._marks.get_child_count() == 1, "再次设置是整体替换而非追加")
	board.set_marks({})
	check(board._marks.get_child_count() == 0, "空字典清空高亮")

	board.free()

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
	var anchor: Vector2 = menu_script.MENU_ANCHOR
	var zoom: float = menu_script.MENU_ZOOM
	var cam: Vector2 = menu_script.camera_pos_for(look_at, anchor, zoom, screen)
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
	g.init(CWData.FACTION_ORDER[4], 20260827)
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

	# 摆位：骰子按落地点的 y 参与深度排序，和组织块同一套规则
	d.place_at(Vector2(300, 180))
	check(d.z_index == 180, "骰子按落地点的 y 做深度排序")
	check(absf(d.position.x + d.size.x * 0.5 - 300.0) < 0.01
		and absf(d.position.y + cy - 180.0) < 0.01, "骰子底面中心对准了落点")

	d.free()


## 点数 → 色区档位，和着色器里 face_color() 的分档一致
func _zone_of(face: int) -> int:
	if face <= 2:
		return 0
	elif face <= 5:
		return 1
	return 2
