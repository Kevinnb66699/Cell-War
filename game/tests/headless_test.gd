## headless_test.gd —— 无头单元/回归测试
##
## 运行：godot --headless --path game --script res://tests/headless_test.gd
## 分片并行（Kevin 2026-09-05 提的：套件 2.5 分钟一跑，Godot 无头是单线程，开两个进程各跑一半）：
##   ... --script res://tests/headless_test.gd -- --shard=0/2   （另一个进程 --shard=1/2）
## 谁归哪片按耗时权重贪心均衡（WEIGHTS / _assign）；tools/run_tests.sh / .ps1 默认就这么开两片再汇总。
## `-- --timing` 会在末尾列出最慢的几个测试（分片不均衡时看这个调）。
## 每个进程的 user:// 都改到自己的 CellWar-tests/shard<i>（见 _isolate_user_dir）：两片同时读写同一份
## 存档 / 设置文件会互相踩，顺便也让测试**再也碰不到玩家真实的 user://**。
## 注意：新增 class_name 脚本后必须先 `--import`，否则报 "Identifier not declared"。
extends SceneTree

var fails := 0
var checks := 0
var _shard := 0        ## 本进程跑第几片（0 起）
var _shards := 1       ## 一共几片；1 = 不分片
var _timing := false   ## 末尾列最慢的测试
## 看门狗（2026-09-07）：**测试进程必须自己走掉**。见 _process() 的注释。
## `-- --timeout=秒` 改单个测试的上限；0 = 关掉看门狗。
var _watchdog_floor_ms := 120000
var _cur_test := ""           ## 此刻在跑哪个测试（看门狗报错时要说出名字）
var _cur_started := 0          ## 它是什么时候开始的；协程一死这个数就不动了
var _durations: Array = []   ## [毫秒, 测试名]
## 各测试的耗时权重（秒，2026-09-05 `--timing` 实测；没列的按 0.1）。分片按「最重优先」贪心：先排最重的，
## 每个放到此刻最轻的那一片。靠下标取模的话 t_net_game 一个就 79 s、落在哪片哪片就是 100 s，另一片 9 s 就跑完了。
## 加了明显变慢的测试就把它填进来（跑一次 `-- --timing` 看末尾那张表）
const WEIGHTS := {
	"t_net_game": 79.0, "t_ai_mc": 7.4, "t_ai_mcts": 0.7, "t_settle_screen": 4.6, "t_net_reconnect": 3.5,
	"t_net_timeout": 3.0, "t_net_drain": 1.3, "t_net_lobby": 1.0, "t_hotseat": 0.8,
	"t_teleport_fx": 0.7, "t_opening": 0.6,
}


func _initialize() -> void:
	_parse_args()
	_isolate_user_dir()
	_run_all()


## 每个测试归哪一片：按权重从重到轻（同重按原顺序）依次放到此刻最轻的片；不分片时全归 0
func _assign(tests: Array[Callable]) -> Array[int]:
	var owner: Array[int] = []
	owner.resize(tests.size())
	owner.fill(0)
	if _shards <= 1:
		return owner
	var order: Array = range(tests.size())
	order.sort_custom(func(a: int, b: int) -> bool:
		var wa := _weight(tests[a])
		var wb := _weight(tests[b])
		return wa > wb if wa != wb else a < b)
	var load: Array[float] = []
	load.resize(_shards)
	load.fill(0.0)
	for i in order:
		var s := 0
		for k in range(1, _shards):
			if load[k] < load[s]:
				s = k
		owner[i] = s
		load[s] += _weight(tests[i])
	return owner


func _weight(t: Callable) -> float:
	return float(WEIGHTS.get(t.get_method(), 0.1))


## `--` 之后的参数：--shard=i/n、--timing
func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shard="):
			var parts := a.substr(8).split("/")
			if parts.size() == 2 and int(parts[1]) > 0:
				_shards = int(parts[1])
				_shard = clampi(int(parts[0]), 0, _shards - 1)
		elif a == "--timing":
			_timing = true
		elif a.begins_with("--timeout="):
			_watchdog_floor_ms = maxi(int(a.substr(10)), 0) * 1000


## 把 user:// 改到测试自己的目录（%APPDATA%/CellWar-tests/shard<i>），运行时改工程设置即可生效，
## 目录要自己建（引擎只在启动时建默认的那一个）。不分片时也隔离：存档 / 设置 / 引导进度都不再碰玩家的真实文件
func _isolate_user_dir() -> void:
	ProjectSettings.set_setting("application/config/use_custom_user_dir", true)
	ProjectSettings.set_setting("application/config/custom_user_dir_name", "CellWar-tests/shard%d" % _shard)
	DirAccess.make_dir_recursive_absolute(OS.get_user_data_dir())
	print("user:// -> %s" % OS.get_user_data_dir())


func _run_all() -> void:
	## 顺序即原来一条条 await 的顺序；分片只决定谁归哪片（_assign），每片内部仍按这个顺序跑
	var tests: Array[Callable] = [
		t_board, t_pay_rule, t_setup, t_hit_order,
		t_anaerobic_round, t_balance_candidates, t_cancer_win_hold, t_storm_preview,
		t_card_events, t_card_events_cancer, t_card_instants, t_card_choices,
		t_card_mods, t_settle_order_rulings, t_review_fixes, t_review_0831,
		t_attack_cap, t_pass_through_ally, t_batch_death_and_triggers, t_design_required_checks,
		t_damage_pipeline, t_card_perms, t_world_events_draw, t_ev_attack_mods,
		t_ev_attack_flow, t_ev_costs, t_ev_supply,
		t_solidify_threshold, t_ev_chaos, t_ev_chaos_simul, t_ev_memory,
		t_ev_proliferate, t_ev_double, t_ev_double_instant, t_ev_lifecycle,
		t_breath_sheets, t_solidify_and_decay, t_vessel_no_solid, t_erosion, t_macro_purify_heal,
		t_cancer_lineup, t_antibody_cap, t_antibody_halve, t_anaerobic_sqrt,
		t_jump_cap, t_heur_lifecare, t_heur_no_squat_on_fresh, t_plan_path, t_plan_core_gain,
		t_dendritic_rework, t_mark_range, t_prd_online_0907, t_eval_features, t_feed_log, t_proliferate_tiers, t_effector_responses, t_ossify_mark, t_chemo_blink, t_solidify_roundtrip, t_pass_through_chain, t_eval_solid_monotone,
		t_immune_win, t_surrender, t_cancer_revive_blocked, t_cancer_revive_ring, t_cancer_s_win, t_immune_respawn,
		t_pressure, t_necrosis, t_erosion_fx, t_spread_fx, t_teleport_fx,
		t_hotseat, t_tutorial, t_stroma_targets, t_batch2_rules,
		t_immune_level_rules, t_tissue_transitions, t_one_cell_per_tile, t_phase_order,
		t_event_rounds, t_draw_limit, t_snapshot, t_state_codec,
		t_rollout_isolation, t_step_atomic, t_full_game_2p, t_full_game_4p,
		t_determinism, t_ai_cards, t_ai_eval, t_ai_mc,
		t_mc_budget, t_ai_mcts, t_config_panel, t_config_custom, t_hover_info, t_chemo_info,
		t_log_panel, t_rules_page, t_production_row, t_mucus_row, t_skill_info,
		t_hot_patch, t_save_load, t_settings, t_board_view, t_store_ring, t_solid_tissue_art, t_ring_and_toxin, t_world_events_off, t_doubled_marker, t_skill_move_price_tag, t_pressure_doom, t_mark_aura, t_mutation_faces, t_no_auto_end_turn, t_shader_no_return, t_hex_pick, t_hover_layer,
		t_ui_bridge, t_human_ask, t_hand_play, t_hand_exit,
		t_hand_index_after_exit, t_card_info, t_tier_highlight, t_match_panel, t_card_history, t_event_strip, t_card_draw_fx, t_net_ping, t_draw_purify_memory, t_ossify_cost_and_pin, t_income_display, t_mods_tip, t_move_hand, t_settle_screen,
		t_opening, t_pause_and_teardown, t_hand, t_hand_limit,
		t_hand_long_name, t_diff_info, t_card_pool, t_font_coverage,
		t_card_name_fit, t_view_blend, t_announce, t_action_bar_width,
		t_buttons_dim, t_enter_not_skipped, t_main_menu, t_guide_data,
		t_codex, t_guide_bridge, t_guide_spotlight, t_quit_confirm,
		t_tutorial_pick, t_roll_hook, t_dice, t_net_protocol,
		t_net_lobby, t_net_game, t_net_reconnect, t_net_timeout,
		t_net_surrender, t_surrender_seats, t_net_drain, t_online_panel, t_online_glow, t_match_online,
	]
	var owner := _assign(tests)
	var mine := 0
	for i in tests.size():
		if owner[i] != _shard:
			continue
		mine += 1
		var t0 := Time.get_ticks_msec()
		_cur_test = tests[i].get_method()   ## 看门狗要用：卡住时说得出是哪个
		_cur_started = t0
		await tests[i].call()
		_durations.append([Time.get_ticks_msec() - t0, tests[i].get_method()])
	print("")
	if _timing:
		_durations.sort_custom(func(x: Array, y: Array) -> bool: return x[0] > y[0])
		var total := 0
		for d in _durations:
			total += int(d[0])
		print("耗时 %.1fs，最慢：" % (total / 1000.0))
		for d in _durations.slice(0, 8):
			print("  %6.1fs  %s" % [d[0] / 1000.0, d[1]])
	_cur_started = 0   ## 跑完了，关掉看门狗（下面就 quit）
	var tag := "" if _shards == 1 else "分片 %d/%d " % [_shard + 1, _shards]
	if fails == 0:
		print("✔ %s全部测试通过（%d 项检查，%d 个测试）" % [tag, checks, mine])
		quit(0)
	else:
		print("✘ %s%d 项检查失败（共 %d 项，%d 个测试）" % [tag, fails, checks, mine])
		quit(1)


## 看门狗：**测试进程必须自己走掉，不能挂着**（Kevin 2026-09-07 报「报错后直接卡住」）。
##
## 挂住的成因是 GDScript 的协程语义：`_run_all()` 是 fire-and-forget 的协程，
## 它里头任何一次 `await` **之后**出运行时错误，协程就地中止 —— 末尾那句 `quit()` 永远执行不到，
## 而 SceneTree 还在空转，于是进程既不报错也不退出，CI 和人都只能干等。
##
## 判据是「当前这个测试跑了多久」：协程一死，`_cur_started` 就再也不动了。
## 上限取 `WEIGHTS` 里那条实测耗时的 4 倍，再兜一个下限（默认 120 s）——
## 最慢的 t_net_game 实测 79 s，快测试则在两分钟内就能被抓住。
##
## ⚠ **救不了单帧内的死循环**：那种情况 `_process` 根本轮不到（2026-09-07 的
## `_next_event_round` 无上界 while 就是这种）。那一层由 `tools/run_tests.sh` 的 `timeout` 兜底。
func _process(_delta: float) -> bool:
	if _cur_started <= 0 or _watchdog_floor_ms <= 0:
		return false
	var limit: int = maxi(int(float(WEIGHTS.get(_cur_test, 0.1)) * 4000.0), _watchdog_floor_ms)
	var spent: int = Time.get_ticks_msec() - _cur_started
	if spent < limit:
		return false
	print("")
	print("✘ 看门狗：%s 跑了 %.0f 秒还没结束（上限 %.0f 秒），判定为挂死"
		% [_cur_test, spent / 1000.0, limit / 1000.0])
	print("  多半是它内部出了运行时错误（往上翻 SCRIPT ERROR）：协程被打断 → quit() 执行不到。")
	quit(1)
	return true


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
	check(cancerous == CWData.init_cancer_tiles(4),
		"初始 %d 格癌性组织（4 人局）" % CWData.init_cancer_tiles(4))
	## 初始癌组织按人数分档（口径 #82）：6 人局要多铺，补免疫方随人数线性增长的收入。
	## 这两条一起钉的是「分档真的生效」——只查 4 人局的话，把表换成定值也照样绿。
	check(CWData.init_cancer_tiles(6) > CWData.init_cancer_tiles(4),
		"6 人局初始癌组织（%d）多于 4 人局（%d）" % [
			CWData.init_cancer_tiles(6), CWData.init_cancer_tiles(4)])
	var g6 := make_game(6, 7)
	await run_setup(g6)
	check(g6.count_tissue(CWData.Tissue.CANCER) + g6.count_tissue(CWData.Tissue.SOLID)
		== CWData.init_cancer_tiles(6),
		"初始 %d 格癌性组织（6 人局）" % CWData.init_cancer_tiles(6))
	g6.dispose()
	check(g.is_cancerous(Vector2i.ZERO), "含中央格")
	check(g.cells.size() == 4, "4 个细胞落子")
	## PRD「游戏开始」6．「所有癌组织固化计数初始为 0」——
	## 原发灶 2026-08-31 取消（口径 #85），开局不该有任何固化癌组织
	check(g.count_tissue(CWData.Tissue.SOLID) == 0, "开局没有固化癌组织（原发灶已取消）")
	var solid_ct := 0
	for c in g.tiles.keys():
		if g.tiles[c]["solid"] > 0:
			solid_ct += 1
	check(solid_ct == 0, "开局所有癌组织的固化计数为 0")

	## 机制本身没删，只是默认关：开旋钮要能照旧生效——
	## 否则哪天平衡实验想把它开回来，会发现代码早就烂了而测试全绿
	var tl := CWTuning.new()
	tl.solid_at_cancer_spawn = true
	var gl := make_game(4, 7)
	gl.tune = tl
	await run_setup(gl)
	var spawns := {}
	for c in gl.living_cells(CWData.Faction.CANCER):
		spawns[c["pos"]] = true
	check(gl.count_tissue(CWData.Tissue.SOLID) == spawns.size(),
		"旋钮打开时原发灶数 = 癌细胞出生格数（%d）" % spawns.size())
	var all_solid := true
	for pos in spawns.keys():
		if gl.tile(pos)["tissue"] != CWData.Tissue.SOLID:
			all_solid = false
	check(all_solid, "旋钮打开时原发灶都位于癌细胞出生格")
	gl.dispose()

	# 落子时癌细胞必须在癌组织上（原发灶关掉后出生格就是普通癌组织）
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
	## 【I-各司其职】2026-09-04 换了机制：不再是伤害减半，而是**根本不能移向癌细胞占据的格**。
	## 所以伤害管线里不该再有树突那一层 —— 卡牌/毒素这类非攻击伤害此前也被它误减半
	attacker["itype"] = CWData.ImmuneType.DENDRITIC
	target["marked"] = false
	check(g.immune_hit(target, 10, attacker) == 10, "树突不再减半伤害（旧【各司其职】已撤）")
	g.dispose()


# ---- 无氧呼吸：0.4/格 + 固化 1.0/格，块内均分，四舍五入到十分位；小细胞肺癌 110% ----

## 四条平衡候选旋钮（团队 2026-09-01）。**四条刻意不并存**，这里只逐条验证「旋钮真的接上了」。
##
## 为什么必须有这组断言：本项目 8-31 出过「参数收下了、_tune() 里没赋值，
## 整张网格跑出来一模一样」的事故 —— **旋钮静默失效比没有旋钮更坏**，
## 因为你会拿着一堆看似有效的数据下结论。每一条都钉两头：关着时恒等、开着时确实改变。

## 两个风暴的「选目标预览」与真正结算共用同一份判据。
##
## 为什么要钉：这两张牌的最优选择完全取决于「哪个免疫细胞旁边能净化几格」，
## 而选择界面原本只列细胞名字。2026-09-01 手打时数了盘面那次清 6 格、
## 凭印象那次清 0 格 —— 整张牌白费。
## 现在标签会带上预览，**但预览与结算必须永远相等**，否则界面就在骗人。
func t_storm_preview() -> void:
	print("[风暴预览]")
	var g := _fx_game(2)
	var mid := Vector2i(0, 0)
	var nbs: Array = CWData.neighbors(mid)
	var me := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, mid,
		CWData.ImmuneType.BASIC, -1)
	g.cells.append(me)
	var fx: CWCardFx = g.card_fx

	check(fx.storm_inflammation_tiles(mid).is_empty(), "炎症风暴：周围全健康 → 预览 0 格")
	for n in nbs:
		g.tiles[n]["tissue"] = CWData.Tissue.CANCER
	check(fx.storm_inflammation_tiles(mid).size() == 6, "炎症风暴：六面皆癌 → 预览 6 格")

	## 有细胞占据的格子**不算** —— 这正是判据里最容易抄错的一条
	var squatter := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, nbs[0], -1,
		CWData.CancerType.MELANOMA)
	g.cells.append(squatter)
	check(fx.storm_inflammation_tiles(mid).size() == 5,
		"炎症风暴：被细胞占据的格子不计入")
	## 固化癌组织也不算（判据写的是 Tissue.CANCER，不是 is_cancerous）
	g.tiles[nbs[1]]["tissue"] = CWData.Tissue.SOLID
	check(fx.storm_inflammation_tiles(mid).size() == 4,
		"炎症风暴：固化癌组织不计入（判据是普通癌组织）")

	## **同源性**：预览给的格数，必须正好是结算真正转掉的格数。
	var before: int = g.count_tissue(CWData.Tissue.CANCER)
	var predicted: int = fx.storm_inflammation_tiles(mid).size()
	for n in fx.storm_inflammation_tiles(mid):
		g.tiles[n]["tissue"] = CWData.Tissue.HEALTHY
	check(before - g.count_tissue(CWData.Tissue.CANCER) == predicted,
		"炎症风暴：预览的格数 = 结算真正转掉的格数")

	## 免疫风暴的判据**不一样**：半径 2，且只排除**癌细胞**占据（免疫站着的照转）
	var g2 := _fx_game(2)
	var m2 := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, mid,
		CWData.ImmuneType.BASIC, -1)
	g2.cells.append(m2)
	var fx2: CWCardFx = g2.card_fx
	## ⚠ 只铺 6 个直接邻格是**测不出半径差别的**（两者都会是 6）——
	## 半径 2 的外圈也得铺上，第一版就是这么写错的。
	for c2 in fx2._tiles_in_range(mid, 2):
		g2.tiles[c2]["tissue"] = CWData.Tissue.CANCER
	var r1: int = fx2.storm_inflammation_tiles(mid).size()
	var r2: int = fx2.storm_immune_tiles(mid).size()
	check(r2 > r1, "免疫风暴半径 2 覆盖的格子多于炎症风暴的相邻 1 格（%d > %d）" % [r2, r1])
	## 两者对**中心格**的处理不同，这是判据差异的第二处，别顺手「统一」掉：
	## 炎症风暴走 CWData.neighbors()（不含中心）；免疫风暴走 _tiles_in_range()（含中心），
	## 而它只排除**癌细胞**占据 —— 所以免疫自己站的那格若是癌组织，会被自己净化掉。
	check(not fx2.storm_inflammation_tiles(mid).has(mid),
		"炎症风暴：不含中心格（走 neighbors）")
	check(fx2.storm_immune_tiles(mid).has(mid),
		"免疫风暴：**含**中心格（走 _tiles_in_range，且只排除癌细胞占据）")

## ---- 提案 B（团队 2026-09-01）：癌方占地胜利要**连续 N 个回合末**达标 ----
## 旋钮 cancer_win_hold_rounds 默认 1 = 达标即胜（现行）。N=2 时第一次达标只拉警报，
## 免疫方有一个完整回合回应；中途回落归零。计数进快照与哈希 —— 推演里达标一次不能污染主线。
func t_cancer_win_hold() -> void:
	print("[占地胜利·连续达标]")
	check(CWTuning.new().cancer_win_hold_rounds == 2 and CWData.CANCER_WIN_HOLD_ROUNDS == 2,
		"默认 2 = 连续两个世界回合末达标（团队 2026-09-01 定案 B）")
	var need := CWTuning.new().cancer_win_weighted
	var g := _flat_board_with_cancer(7, need)
	g.tune.cancer_win_hold_rounds = 1
	g.check_cancer_win()
	check(g.winner == CWData.Faction.CANCER and g.win_kind == "cancer_weighted", "hold=1（旧规则）：第一次达标就判胜")
	g.dispose()

	var g2 := _flat_board_with_cancer(7, need)
	g2.tune.cancer_win_hold_rounds = 2
	var coords: Array = g2.tiles.keys()
	var n0 := g2.logs.size()
	g2.check_cancer_win()
	check(g2.winner < 0 and g2.cancer_win_streak == 1, "hold=2：第一次达标不判胜，计数 1")
	check(g2.logs.size() > n0 and g2.logs[-1].contains("1/2"), "达标那一刻记一条警报日志（连续第 1/2）")
	var snap := g2.snapshot()
	g2.check_cancer_win()
	check(g2.winner == CWData.Faction.CANCER, "hold=2：连续第二个回合末仍达标 → 判胜")
	g2.restore(snap)
	check(g2.winner < 0 and g2.cancer_win_streak == 1, "restore 把计数和胜负一起放回（推演不污染主线）")
	g2.tiles[coords[0]]["tissue"] = CWData.Tissue.HEALTHY
	g2.check_cancer_win()
	check(g2.winner < 0 and g2.cancer_win_streak == 0, "回落到线下：计数归零")
	g2.tiles[coords[0]]["tissue"] = CWData.Tissue.CANCER
	g2.check_cancer_win()
	check(g2.winner < 0 and g2.cancer_win_streak == 1, "再次达标要从 1 重新数，不能沿用旧计数")
	var h1 := g2.state_hash()
	g2.cancer_win_streak = 0
	check(g2.state_hash() != h1, "连续达标计数参与 state_hash（它决定下回合判不判胜）")
	g2.dispose()


## 全盘先铺成健康组织，再把前 n 格改成癌组织 —— 数量精确可控，
## 不受 build_board 自带的初始癌组织影响（那会让「回落一格」测不出来）。
func _flat_board_with_cancer(seed_value: int, n: int) -> CWGame:
	var g := make_game(2, seed_value)
	g.setup.build_board()
	for c in g.tiles.keys():
		g.tiles[c]["tissue"] = CWData.Tissue.HEALTHY
		g.tiles[c]["solid"] = 0
	var coords: Array = g.tiles.keys()
	for i in n:
		g.tiles[coords[i]]["tissue"] = CWData.Tissue.CANCER
	return g

func t_balance_candidates() -> void:
	print("[平衡候选旋钮]")
	var t := CWTuning.new()

	## ---- 候选①：有氧系数随回合增长 ----
	check(t.aerobic_mult_growth == 0 and t.cancer_upkeep_pct == 0
		and t.immune_attack_pct_growth == 0 and t.immune_attack_pct_per_memory == 0,
		"四条候选默认全关（默认值必须 = 现行行为）")
	check(t.aerobic_mult_at(1) == t.aerobic_mult and t.aerobic_mult_at(30) == t.aerobic_mult,
		"①关着：任何回合都恒等于 aerobic_mult")
	t.aerobic_mult_growth = 10
	check(t.aerobic_mult_at(1) == t.aerobic_mult,
		"①第 1 回合仍等于基值（团队硬约束：叫「随回合增长」不叫「整体抬高」）")
	check(t.aerobic_mult_at(3) == t.aerobic_mult + 20, "①第 3 回合 = 基值 + 2 步")
	## 负系数（反方向：削免疫收入）是合法值，但系数不能为负 ——
	## 负分子会让 _aerobic() 那次整数除法从「向下取整」翻成「向零截断」。
	t.aerobic_mult_growth = -10
	check(t.aerobic_mult_at(1) == t.aerobic_mult, "①负系数下第 1 回合仍是基值")
	check(t.aerobic_mult_at(20) == 0, "①负系数压到 0 为止，不会变成负系数")
	t.aerobic_mult_growth = 10

	## ①的整体接线：同一盘面、不同回合，收入必须真的不同
	var g := make_game(2, 7)
	g.setup.build_board()
	var immune := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0),
		CWData.ImmuneType.T_CELL, -1)
	immune["energy"] = 0
	g.cells.append(immune)
	## 候选①（系数随回合涨）挂在**旧盘面公式**上，现行等级式根本不看 aerobic_mult ——
	## 要验这条杠杆就得先切回旧公式，否则三条断言会一起变成「恒等于 2.5」的空转
	g.tune.aerobic_level_base = 0
	g.round_no = 1
	g.world._aerobic()
	var at_r1: int = immune["energy"]
	immune["energy"] = 0
	g.round_no = 5
	g.world._aerobic()
	check(at_r1 == immune["energy"], "①关着时第 1 回合与第 5 回合收入相同")
	g.tune.aerobic_mult_growth = 10
	immune["energy"] = 0
	g.round_no = 1
	g.world._aerobic()
	var on_r1: int = immune["energy"]
	immune["energy"] = 0
	g.round_no = 5
	g.world._aerobic()
	check(on_r1 == at_r1, "①开着时第 1 回合收入不变")
	check(immune["energy"] > on_r1, "①开着时第 5 回合收入确实更高")

	## ---- 候选③：癌细胞每回合按比例损能 ----
	var g3 := make_game(2, 7)
	g3.setup.build_board()
	var rich := CWSetup.make_cell(0, 1, CWData.Faction.CANCER, Vector2i(0, 0), -1,
		CWData.CancerType.MELANOMA)
	rich["energy"] = 100
	var poor := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(2, 0), -1,
		CWData.CancerType.MELANOMA)
	poor["energy"] = 4
	var mine := CWSetup.make_cell(2, 0, CWData.Faction.IMMUNE, Vector2i(4, 0),
		CWData.ImmuneType.T_CELL, -1)
	mine["energy"] = 100
	g3.cells.append_array([rich, poor, mine])
	g3.world._cancer_upkeep()
	check(rich["energy"] == 100 and poor["energy"] == 4, "③关着：一分不扣")
	g3.tune.cancer_upkeep_pct = 20
	g3.world._cancer_upkeep()
	check(rich["energy"] == 80, "③10.0 能量扣 20% = 8.0")
	check(poor["energy"] == 4,
		"③0.4 能量扣 20% 得 0 —— **按比例扣杀不死细胞**，所以不需要死亡检查")
	check(mine["energy"] == 100, "③只扣癌细胞，免疫方不受影响")

	## ---- 候选②④：免疫普攻倍率 ----
	var t2 := CWTuning.new()
	check(t2.immune_attack_pct(1, 0) == 100 and t2.immune_attack_pct(30, 50) == 100,
		"②④关着：任何回合、任何记忆都是 100%")
	t2.immune_attack_pct_growth = 20
	check(t2.immune_attack_pct(1, 0) == 100, "②第 1 回合仍是 100%（团队硬约束）")
	check(t2.immune_attack_pct(3, 0) == 140, "②第 3 回合 = 100 + 2×20")
	var t4 := CWTuning.new()
	t4.immune_attack_pct_per_memory = 10
	check(t4.immune_attack_pct(1, 5) == 150, "④5 点记忆 = 100 + 5×10")
	t4.immune_attack_pct_memory_cap = 30
	check(t4.immune_attack_pct(1, 5) == 130, "④封顶把记忆加成压到 30 个百分点")

	## ②④ 的整体接线，外加**范围收窄的证明**：团队 2026-09-01 明确「暂时只关注普攻伤害」，
	## 所以非攻击来源（卡牌/技能伤害，tags 里没有 ATTACK）必须一点都不受影响。
	var g2 := make_game(2, 7)
	g2.setup.build_board()
	var atk := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0),
		CWData.ImmuneType.T_CELL, -1)
	var vic := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(5, 0), -1,
		CWData.CancerType.MELANOMA)
	g2.cells.append_array([atk, vic])
	vic["energy"] = 100
	check(g2.immune_hit(vic, 10, atk, true) == 10, "②④关着：普攻 1.0 就是 1.0")
	## per_memory=20 × memory=5 ⇒ 倍率 200%
	g2.tune.immune_attack_pct_per_memory = 20
	g2.memory = 5
	vic["energy"] = 100
	check(g2.immune_hit(vic, 10, atk, true) == 20, "④倍率 200% 时普攻 1.0 → 2.0")
	vic["energy"] = 100
	check(g2.immune_hit(vic, 10, atk, false) == 10,
		"**只作用于普攻**：非攻击来源（卡牌/技能）倍率不生效")

func t_anaerobic_round() -> void:
	print("[无氧呼吸]")
	var g := make_game(2, 1)
	g.setup.build_board()
	# 连通块：3 普通癌 + 1 固化。现行式（2026-09-07）：3^0.3 × 2 + 全图固化 1 格 × 1.0，2 个细胞均分
	var coords := [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0)]
	for c in coords:
		g.tiles[c]["tissue"] = CWData.Tissue.CANCER
	g.tiles[Vector2i(3, 0)]["tissue"] = CWData.Tissue.SOLID
	for i in 2:
		var cell := CWSetup.make_cell(i, i, CWData.Faction.CANCER, coords[i], -1,
			CWData.CancerType.MELANOMA)
		cell["energy"] = 0
		g.cells.append(cell)
	## 现行式：块里 3 格普通癌 + 全图 1 格固化，2 个细胞均分。**按常量算**，旋钮改了这里不用跟
	g.world._anaerobic()
	var each4: int = _share(_pool_of(3, 1), 2)
	check(g.cells[0]["energy"] == each4 and g.cells[1]["energy"] == each4,
		"3 普通癌 + 1 固化 = %.1f 十分 / 2 细胞 = 各 %s" % [_pool_of(3, 1), CWData.fmt(each4)])
	## 以下切回线性对照档（团队 2026-09-04 之前的规则）——
	## 那套的取整口径、固化双倍权重、瓦伯格 110% 都还得有测试盯着
	g.tune.anaerobic_block_coef = 0
	g.cells[0]["energy"] = 0
	g.cells[1]["energy"] = 0
	g.world._anaerobic()
	check(g.cells[0]["energy"] == 11 and g.cells[1]["energy"] == 11,
		"线性档：池 2.2 / 2 细胞 = 各 1.1")
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
	check(g.tiles[pos]["tissue"] == CWData.Tissue.CANCER, "计数 1.0 还没到阈值 %s" % CWData.fmt(CWData.SOLIDIFY_THRESHOLD))
	## 阈值跟常量走（2026-09-01 定案乙 3.0→2.0 时这里原本写死 3.0）：再蹲到刚好够数的那一回合
	for k in range(CWData.SOLIDIFY_THRESHOLD / CWData.SOLIDIFY_STEP - 1):
		g.world._solidify()
	check(g.tiles[pos]["tissue"] == CWData.Tissue.SOLID, "计数到 %s → 固化癌组织" % CWData.fmt(CWData.SOLIDIFY_THRESHOLD))
	## 骨肉瘤停留：2026-09-05 起与普通癌细胞同为 +1.0。旧版 +1.5 在阈值 2.0 之下一回合也没省
	## （1.0→2.0 与 1.5→3.0 都是第 2 回合跨线），【骨样硬化】已重做成主动技能，见 t_batch2_rules
	var op := Vector2i(-2, 1)
	g.tiles[op]["tissue"] = CWData.Tissue.CANCER
	cell["ctype"] = CWData.CancerType.OSTEO
	cell["pos"] = op
	g.world._solidify()
	check(g.tiles[op]["solid"] == 10 and g.tiles[op]["tissue"] == CWData.Tissue.CANCER, "骨肉瘤停留 → 计数 +1.0（不再 +1.5）")
	g.world._solidify()
	check(g.tiles[op]["tissue"] == CWData.Tissue.SOLID, "两回合固化，与其他癌种相同")
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
	## 「新生」保护是旋钮（2026-09-04 Kevin 拍板取消该机制，默认关）。**正反两个方向都钉**：
	## 只钉一边的话，把读取点删干净也照样绿，而旋钮拨回 true 就该逐位复现旧行为
	var nb := Vector2i(0, 1)
	g.tiles[nb]["tissue"] = CWData.Tissue.CANCER
	g.tiles[nb]["newborn"] = true
	cell["ctype"] = CWData.CancerType.MELANOMA   ## 骨肉瘤 +1.5，换回普通癌细胞看 +1.0
	cell["pos"] = nb
	check(not g.tune.newborn_protect, "默认：「新生」保护已取消（Kevin 2026-09-04 拍板）")
	g.world._solidify()
	check(g.tiles[nb]["solid"] == CWData.SOLIDIFY_STEP,
		"取消后：当回合新铺的癌组织当回合就累计固化（+%s）" % CWData.fmt(CWData.SOLIDIFY_STEP))
	g.tiles[nb]["solid"] = 0
	g.tune.newborn_protect = true
	g.world._solidify()
	check(g.tiles[nb]["solid"] == 0, "旋钮拨回 true：按 PRD 当回合不固化（旧行为）")
	g.tiles[nb]["newborn"] = false
	g.world._solidify()
	check(g.tiles[nb]["solid"] == CWData.SOLIDIFY_STEP, "保护只管「新生」那一格，旧组织照常累计")
	g.tune.newborn_protect = false
	g.dispose()


## 血管不可被固化（Kevin 2026-09-06）：三条固化入口（【E-固化】计数 / 卡【基质硬化】/ 骨肉瘤【骨样硬化】）、
## 【原发灶】旋钮与 AI 的蹲点判断都认 `CWTissue.solidifiable()`；格子详情写明「不可固化」
func t_vessel_no_solid() -> void:
	print("[血管不可固化]")
	var g := _fx_game(2)
	var v: Vector2i = CWData.VESSELS[0]
	var plain := v + Vector2i(-1, 0)     ## 血管旁边的普通格，作对照
	var ctrl := v + Vector2i(-1, 1)      ## 另一格对照
	check(not CWTissue.solidifiable(g.tile(v)) and CWTissue.solidifiable(g.tile(plain)),
		"solidifiable：血管 false、普通格 true")
	for c in [v, plain, ctrl]:
		g.tiles[c]["tissue"] = CWData.Tissue.CANCER
	var on_v := CWSetup.make_cell(g.cells.size(), 1, CWData.Faction.CANCER, v, -1, CWData.CancerType.MELANOMA)
	on_v["energy"] = 100
	g.cells.append(on_v)
	var on_p := CWSetup.make_cell(g.cells.size(), 1, CWData.Faction.CANCER, plain, -1, CWData.CancerType.MELANOMA)
	on_p["energy"] = 100
	g.cells.append(on_p)
	## ① 【E-固化】：蹲满阈值那么多回合，旁边的普通癌组织固化了，血管纹丝不动
	var n0: int = g.logs.size()
	for k in range(CWData.SOLIDIFY_THRESHOLD / CWData.SOLIDIFY_STEP):
		g.world._solidify()
	check(g.tiles[plain]["tissue"] == CWData.Tissue.SOLID, "对照：旁边的普通癌组织照常固化")
	check(g.tiles[v]["tissue"] == CWData.Tissue.CANCER and g.tiles[v]["solid"] == 0,
		"血管：蹲满回合也不累计、不固化")
	check("\n".join(g.logs.slice(n0)).contains("不可固化"), "日志说明血管不可固化（别让玩家以为是 bug）")
	## ② 直接一次加满阈值也一样（卡【基质硬化】走的就是这条路）
	g.raise_solid(v, CWData.SOLIDIFY_THRESHOLD)
	check(g.tiles[v]["tissue"] == CWData.Tissue.CANCER and g.tiles[v]["solid"] == 0,
		"raise_solid 一次加满：血管仍是普通癌组织、计数 0")
	## ③ 卡【基质硬化】选目标：脚下的血管不给选项，旁边的普通癌组织照给（同一把尺）
	on_v["hand"] = ["基质硬化"]
	var o: Array = []
	g.card_fx.hand_options(on_v, o)
	check(not _has_target(o, v) and _has_target(o, ctrl), "【基质硬化】：血管不是目标，旁边的普通癌组织是")
	## ④ AI 蹲点判断：场上没有据点时，普通格值得从头熬、血管不值得
	CWTissue.crack_to_cancer(g.tiles[plain])
	check(g.count_tissue(CWData.Tissue.SOLID) == 0, "场上没有固化据点（蹲点的触发条件）")
	var h := CWHeuristicBridge.new()
	h.game = g
	check(h._worth_solidifying(on_p) and not h._worth_solidifying(on_v), "AI：普通格值得蹲、血管不蹲（v11）")
	## ⑤ 骨肉瘤【骨样硬化】：站在血管上没有选项、硬发也不落标记；挪到普通格就能标
	on_v["ctype"] = CWData.CancerType.OSTEO
	check(not _has_act(g.actions.build_options(on_v), "ossify"), "【骨样硬化】：血管上没有选项")
	var e0: int = on_v["energy"]
	await g.actions.execute(on_v, { "act": "ossify" })
	check(int(g.tiles[v]["ossify_at"]) == 0 and on_v["energy"] == e0, "硬发也不落标记、不扣钱")
	on_v["pos"] = ctrl
	check(_has_act(g.actions.build_options(on_v), "ossify"), "挪到普通癌组织 → 选项回来")
	on_v["pos"] = v
	## ⑥ 【原发灶】旋钮开着：出生在血管上的那格也不转固化
	g.tune.solid_at_cancer_spawn = true
	g.setup._place_primary_lesions()
	check(g.tiles[plain]["tissue"] == CWData.Tissue.SOLID and g.tiles[v]["tissue"] == CWData.Tissue.CANCER,
		"【原发灶】：普通格转固化、血管不转")
	g.tune.solid_at_cancer_spawn = false
	## ⑦ 格子详情写明
	var rows := ""
	for r in CWTileInfo.describe(g, v):
		rows += r["text"] + "|"
	check(rows.contains("血管 · 不可固化"), "格子详情：血管 · 不可固化（%s）" % rows)
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


# ---- 投降（Kevin 2026-09-09）----
## 引擎只认定**结果**，投票在外面。这里守的是「结果对不对」和「投完不许再动」。
func t_surrender() -> void:
	print("[投降]")
	var g := make_game(2, 1)
	g.setup.build_board()
	## 阵营名指的是**胜方**：免疫投降 → 癌方胜 → surrender_cancer
	g.surrender(CWData.Faction.IMMUNE)
	check(g.winner == CWData.Faction.CANCER and g.win_kind == "surrender_cancer",
		"免疫投降 → 癌方胜，win_kind 记胜方（%s）" % g.win_kind)
	check(g.win_reason.contains("免疫方投降"), "结束语写清是谁投的（%s）" % g.win_reason)
	check(g.is_over(), "投降即终局")
	check(not g.aborted, "投降**不是**放弃对局：aborted 仍为 false（结算屏要靠它区分）")
	## 已经分出胜负之后再投不许翻盘 —— 联机里两边同时点会走到这条
	g.surrender(CWData.Faction.CANCER)
	check(g.winner == CWData.Faction.CANCER and g.win_kind == "surrender_cancer",
		"局已终结，第二次投降不改结果")
	g.dispose()

	var g2 := make_game(2, 1)
	g2.setup.build_board()
	g2.surrender(CWData.Faction.CANCER)
	check(g2.winner == CWData.Faction.IMMUNE and g2.win_kind == "surrender_immune",
		"癌方投降 → 免疫胜")
	g2.dispose()

	## 观战没有阵营，投不了降（-1 是 CWMatch.viewing_faction 的「没有阵营」值）
	var g3 := make_game(2, 1)
	g3.setup.build_board()
	g3.surrender(-1)
	check(g3.winner < 0 and g3.win_kind == "", "没有阵营（观战 / 热座换手中）投不了降")
	g3.dispose()

	## 结算屏认得这两种
	check(CWSettleScreen.KIND_CHIP.get("surrender_immune", "") == "投降"
		and CWSettleScreen.KIND_CHIP.get("surrender_cancer", "") == "投降",
		"结算屏两种投降都标「投降」")


# ---- 癌方复活被堵住时必须给出说明（口径 #93）----
##
## 免疫站在固化癌组织上把复活位占死是**有意的战术**（Kevin 2026-08-31 裁定「保留」），
## 但引擎此前是**静默**返回空数组、流程直接跳过，玩家看到的就是「我死了，然后没有然后了」。
## 这个测试盯的不是「能不能复活」（那条 t_immune_win 已经在管），是**有没有把原因说出来**。
func t_cancer_revive_blocked() -> void:
	print("[癌方复活反馈]")
	var g := make_game(2, 1)
	g.setup.build_board()
	## make_game 只建棋盘不建细胞，细胞得自己摆（同 t_immune_win）
	var imm := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(-3, 0),
		CWData.ImmuneType.BASIC, -1)
	var can := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(0, 0),
		-1, CWData.CancerType.MELANOMA)
	g.cells.append(imm)
	g.cells.append(can)
	can["alive"] = false

	## ① 场上一格固化都没有
	var n := g.logs.size()
	check(g.world.revive_options_cancer(1).is_empty(), "没有固化癌组织 → 没有落点")
	var said: String = "
".join(g.logs.slice(n))
	check(said.contains("无法复活") and said.contains("没有固化癌组织"),
		"→ 说明了「场上没有固化癌组织」")

	## ② 有固化格，但被免疫站着
	var solid := Vector2i(2, 2)
	g.tiles[solid]["tissue"] = CWData.Tissue.SOLID
	imm["pos"] = solid
	n = g.logs.size()
	check(g.world.revive_options_cancer(1).is_empty(), "固化格被占 → 没有落点")
	said = "
".join(g.logs.slice(n))
	check(said.contains("无法复活") and said.contains(str(solid))
			and said.contains(g.cell_name(imm)),
		"→ 说明了是哪一格、被谁占的")

	## ③ 免疫席位也会被 _ask_each 问到这一段：死了的免疫细胞不归这里管，
	## 既不能报「场上没有固化癌组织」（队友 2026-09-03 截图），也不能被当成癌细胞给「复活于固化格」
	imm["pos"] = Vector2i(-3, 0)
	imm["alive"] = false
	imm["respawn_round"] = g.round_no
	n = g.logs.size()
	check(g.world.revive_options_cancer(0).is_empty(), "死了的免疫细胞走癌方复活段：不给固化格落点（哪怕 %s 空着）" % str(solid))
	check(not "
".join(g.logs.slice(n)).contains("无法复活"), "→ 也不替它报「没有固化癌组织」")
	g.round_no = 5
	can["respawn_round"] = -1
	check(g.world.revive_options_immune(1).is_empty(), "死了的癌细胞走免疫复活段：同样直接放过")

	## ③ 免疫让开：既能复活，也**不该**再报「无法复活」
	imm["pos"] = Vector2i(-3, 0)
	n = g.logs.size()
	check(not g.world.revive_options_cancer(1).is_empty(), "让开后有落点")
	check(not "
".join(g.logs.slice(n)).contains("无法复活"), "→ 有落点时不再报「无法复活」")

	## ④ 活着的细胞不该被问、也不该被通报
	can["alive"] = true
	n = g.logs.size()
	check(g.world.revive_options_cancer(1).is_empty(), "活着 → 没有复活询问")
	check(g.logs.size() == n, "→ 活着时一句话都不说")
	g.dispose()


## 【S-复活】癌症的第二条路（PRD 2026-09-08）：固化格被**队友**占着时，
## 可以落在它相邻一圈里未被占据的**癌性组织**上；降级的是**依托格**，不是落点。
##
## 这组要钉四件事：谁能当依托、一圈里哪些格算落点、碎的是哪一格、免疫堵位仍然有效。
func t_cancer_revive_ring() -> void:
	print("[癌症复活·依托队友的固化格]")
	var g := make_game(2, 3)
	g.setup.build_board()
	var solid := Vector2i(2, 2)
	var nbs: Array = CWData.neighbors(solid)
	var mate := CWSetup.make_cell(0, 1, CWData.Faction.CANCER, solid, -1,
		CWData.CancerType.MELANOMA)
	var dead := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(0, 0), -1,
		CWData.CancerType.SIGNET)
	var imm := CWSetup.make_cell(2, 0, CWData.Faction.IMMUNE, Vector2i(-4, 0),
		CWData.ImmuneType.BASIC, -1)
	g.cells.append(mate)
	g.cells.append(dead)
	g.cells.append(imm)
	dead["alive"] = false
	g.tiles[solid]["tissue"] = CWData.Tissue.SOLID

	## 一圈布置：癌组织空着（可落）、健康组织空着（不可落）、癌组织被占（不可落）
	var ok_spot: Vector2i = nbs[0]
	var healthy: Vector2i = nbs[1]
	var occupied: Vector2i = nbs[2]
	g.tiles[ok_spot]["tissue"] = CWData.Tissue.CANCER
	g.tiles[healthy]["tissue"] = CWData.Tissue.HEALTHY
	g.tiles[occupied]["tissue"] = CWData.Tissue.CANCER
	imm["pos"] = occupied
	for i in range(3, nbs.size()):
		g.tiles[nbs[i]]["tissue"] = CWData.Tissue.HEALTHY

	var tos: Array = []
	for o in g.world.revive_options_cancer(1):
		if o["data"].has("to"):
			tos.append(o["data"]["to"])
	check(tos.has(ok_spot), "空着的癌组织进落点（%s）" % str(ok_spot))
	check(not tos.has(healthy), "健康组织不进落点（Kevin 2026-09-08：只能落在癌性组织）")
	check(not tos.has(occupied), "有细胞站着的癌组织不进落点")
	check(not tos.has(solid), "依托格自己不进落点（队友站着）")

	## 碎的是**依托格**，不是落点 —— 这条最容易写反
	var pick := {}
	for o in g.world.revive_options_cancer(1):
		if o["data"].get("to", Vector2i.MAX) == ok_spot:
			pick = o["data"]
	check(pick.get("anchor", Vector2i.MAX) == solid, "选项带上依托格 %s" % str(solid))
	await g.world.revive_cancer(1, pick)
	check(dead["alive"] and dead["pos"] == ok_spot, "复活在落点上")
	check(g.tile(solid)["tissue"] == CWData.Tissue.CANCER, "**依托格**降级为癌组织")
	check(g.tile(ok_spot)["tissue"] == CWData.Tissue.CANCER, "落点仍是癌组织，没被多碎一次")

	## 免疫踩着固化格：两条路都封死（Kevin 2026-08-31 裁定的战术要保住）
	var g2 := make_game(2, 4)
	g2.setup.build_board()
	var mate2 := CWSetup.make_cell(0, 1, CWData.Faction.CANCER, Vector2i(0, 0), -1,
		CWData.CancerType.MELANOMA)
	var dead2 := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(0, 0), -1,
		CWData.CancerType.SIGNET)
	var imm2 := CWSetup.make_cell(2, 0, CWData.Faction.IMMUNE, solid,
		CWData.ImmuneType.BASIC, -1)
	g2.cells.append(mate2)
	g2.cells.append(dead2)
	g2.cells.append(imm2)
	dead2["alive"] = false
	g2.tiles[solid]["tissue"] = CWData.Tissue.SOLID
	for c in CWData.neighbors(solid):
		g2.tiles[c]["tissue"] = CWData.Tissue.CANCER
	var n := g2.logs.size()
	check(g2.world.revive_options_cancer(1).is_empty(),
		"免疫踩着固化格 → 一圈也不开（堵位战术仍然有效）")
	check("|".join(g2.logs.slice(n)).contains("被免疫占着"),
		"→ 说明是被免疫占着，而不是「周围没空位」")
	g2.dispose()

	## 队友踩着、但一圈全是健康组织 → 说的是另一种原因，玩家该去腾地方而不是赶免疫
	var g3 := make_game(2, 5)
	g3.setup.build_board()
	var mate3 := CWSetup.make_cell(0, 1, CWData.Faction.CANCER, solid, -1,
		CWData.CancerType.MELANOMA)
	var dead3 := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(0, 0), -1,
		CWData.CancerType.SIGNET)
	g3.cells.append(mate3)
	g3.cells.append(dead3)
	dead3["alive"] = false
	g3.tiles[solid]["tissue"] = CWData.Tissue.SOLID
	n = g3.logs.size()
	check(g3.world.revive_options_cancer(1).is_empty(), "队友踩着但一圈没癌性组织 → 没落点")
	check("|".join(g3.logs.slice(n)).contains("周围没有空的癌性组织"),
		"→ 说明的是「周围没空位」，与被免疫堵住分开讲")
	g3.dispose()
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
	check(g.winner < 0 and g.cancer_win_streak == 1, "加权 %d 首次达标 → 只拉警报，不判胜（定案 B）" % need)
	g.check_cancer_win()
	check(g.winner == CWData.Faction.CANCER, "连续第二个回合末仍达标 → 癌症胜利")
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
	## PRD 没有罚停条款（下一个世界回合的 S 阶段就复活）；
	## 引擎 2026-09-07 起额外罚停 `immune_respawn_delay` 个回合（Kevin 定，默认 1）。
	## **现读旋钮**：写死回合数的话，旋钮一动测试就红，而这正是它该扫的东西。
	var back: int = 3 + 1 + g.tune.immune_respawn_delay
	check(imm["respawn_round"] == back, "死于第 3 回合 → 第 %d 回合复活（罚停 %d）"
		% [back, g.tune.immune_respawn_delay])
	## 骨髓全被癌化 → 无处可复活
	for c in CWData.MARROWS:
		g.tiles[c]["tissue"] = CWData.Tissue.CANCER
	g.round_no = back
	var n0: int = g.logs.size()
	check(g.world.revive_options_immune(pid).is_empty(), "骨髓全被癌化 → 没有落点")
	## 说不出原因等于没说 —— 六个骨髓里「被癌化」和「站了人」的应对完全不同
	## （前者要净化，后者只要等），所以必须分开报（与癌方 _report_no_revive 对称）
	var said: String = "
".join(g.logs.slice(n0))
	check(said.contains("无法复活") and said.contains("被癌化"), "→ 报出「被癌化」")
	check(said.contains(str(CWData.MARROWS[0])), "→ 报出是哪几格")
	## 还没到复活回合：那是「还没轮到」，不该报「无法复活」
	g.round_no = 3
	var n1: int = g.logs.size()
	check(g.world.revive_options_immune(pid).is_empty(), "没到复活回合 → 也没有落点")
	check(g.logs.size() == n1, "→ 但一句话都不说（不是被挡住）")
	g.round_no = back
	## 放开一个健康骨髓格
	var m: Vector2i = CWData.MARROWS[0]
	g.tiles[m]["tissue"] = CWData.Tissue.HEALTHY
	var opts: Array = g.world.revive_options_immune(pid)
	check(opts.size() == 1 and opts[0]["data"]["to"] == m, "落点正是那个健康骨髓格")
	await g.world.revive_immune(pid, m)
	check(imm["alive"] and imm["pos"] == m, "在骨髓复活")
	check(imm["energy"] == 10, "复活获得 1.0 能量（癌细胞是 2.0）")
	check(imm["respawn_round"] == -1, "复活后清除标记")
	## 有落点时不该再报「无法复活」
	var n2: int = g.logs.size()
	g.tiles[CWData.MARROWS[1]]["tissue"] = CWData.Tissue.HEALTHY   ## m 上站着刚复活的 imm
	var imm3: Dictionary = g.living_cells(CWData.Faction.IMMUNE)[1]
	imm3["alive"] = false
	imm3["respawn_round"] = back
	check(not g.world.revive_options_immune(imm3["pid"]).is_empty(), "有健康空骨髓 → 有落点")
	check(not "
".join(g.logs.slice(n2)).contains("无法复活"), "→ 有落点时不报「无法复活」")
	imm3["alive"] = true
	imm3["respawn_round"] = -1
	g.tiles[CWData.MARROWS[1]]["tissue"] = CWData.Tissue.CANCER   ## 还原，下面那段要「只剩一个健康骨髓」
	## 骨髓被别的细胞占着也不行
	var imm2: Dictionary = g.living_cells(CWData.Faction.IMMUNE)[1]
	g.round_no = 5
	g.kill(imm2)
	g.round_no = 6
	check(g.world.revive_options_immune(imm2["pid"]).is_empty(),
		"唯一的健康骨髓被队友占着 → 没有落点")
	## 旋钮 immune_respawn_delay=1（2026-09-02 后期引擎对比表杠杆④）：多罚停一个世界回合
	g.tune.immune_respawn_delay = 1
	g.round_no = 5
	g.kill(imm)
	check(imm["respawn_round"] == 7, "罚停 1：死于第 5 回合 → 第 7 回合才复活（默认是第 6）")
	imm["alive"] = true
	imm["respawn_round"] = -1
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
	check(cell["energy"] == 50, "二癌四健康 → 被健康组织抵消，不掉能量")
	g.tiles[nb[2]]["tissue"] = CWData.Tissue.CANCER
	g.world._pressure()
	check(cell["energy"] == 50, "三癌三健康 → 正好抵平，仍不掉（新式的分界线）")
	g.tiles[nb[3]]["tissue"] = CWData.Tissue.CANCER
	g.world._pressure()
	check(cell["energy"] == 45, "四癌两健康 → 1/4 ×（4 − 2）= 0.5")
	for k in range(3, 6):
		g.tiles[nb[k]]["tissue"] = CWData.Tissue.SOLID
	cell["energy"] = 50
	g.world._pressure()
	## 1/4 × 9 = 2.25 → **四舍五入到十分位 = 2.3**（PRD 2026-09-08 加的通用规则 1；
	## 09-08 上午曾按向下取整落成 2.2，总则写明后改过来）。
	## 这一条同时钉住取整口径：写 2.2 或 2.25 都是错的。
	check(cell["energy"] == 27, "三癌三固化 → 1/4 ×（3 + 3×2）= 2.3（四舍五入到十分位）")
	## 这是癌方第一个能真正打死免疫细胞的手段
	cell["energy"] = 15
	g.world._pressure()
	check(not cell["alive"], "压迫可以致死")
	g.dispose()


# ---- 免疫等级三件套（团队 2026-09-04 定案）：记忆门槛 10/20、有氧按等级、分化降到 II 级 ----
##
## 三条是**一套**：门槛抬高 → III 级来得更晚 → 分化再挂在 III 上就基本用不上，所以一起下调；
## 有氧改成挂等级之后，「主动净化」这件事第一次同时给了收入和等级两份回报。
func t_immune_level_rules() -> void:
	print("[免疫等级：门槛/有氧/分化]")
	var g := bare_game()
	g.setup.build_board()
	check(CWData.LEVEL_MIN_MEMORY == [0, 10, 20, 30], "记忆门槛 = 0 / 10 / 20 / 30")

	## 门槛边界：9 不升、10 升 II、19 不再升、20 升 III、29 不升、30 升 X
	## （X 从 31 改回 PRD 的 30，Kevin 2026-09-07：「30 及以上都归 X 级」）
	var want := [[9, 0], [10, 1], [19, 1], [20, 2], [29, 2], [30, 3]]
	for pair in want:
		var g2 := bare_game()
		g2.gain_memory(int(pair[0]))
		check(g2.immune_level == int(pair[1]),
			"记忆 %d → %s 级" % [pair[0], CWData.LEVEL_NAMES[int(pair[1])]])
		g2.dispose()

	## 有氧 = 基数 + 等级² × 0.5（Kevin 2026-09-07 换成平方式），与盘面无关
	var cell := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i.ZERO,
		CWData.ImmuneType.BASIC, -1)
	g.cells.append(cell)
	for lv in 4:
		g.immune_level = lv
		cell["energy"] = 0
		g.world._aerobic()
		var want_lv: int = CWData.AEROBIC_LEVEL_BASE + CWData.AEROBIC_LEVEL_STEP * lv * lv
		check(cell["energy"] == want_lv,
			"%s 级有氧 = %s" % [CWData.LEVEL_NAMES[lv], CWData.fmt(want_lv)])
	check(CWData.AEROBIC_LEVEL_BASE == 20 and CWData.AEROBIC_LEVEL_STEP == 5,
		"四档就是 2.0 / 2.5 / 4.0 / 6.5（Kevin 2026-09-07 给的图）")
	## 盘面被癌组织吃掉一半也不掉收入 —— 这正是换公式要解决的死亡螺旋
	var half := 0
	for c in g.tiles.keys():
		if half >= 60:
			break
		g.tiles[c]["tissue"] = CWData.Tissue.CANCER
		half += 1
	g.immune_level = 0
	cell["energy"] = 0
	g.world._aerobic()
	check(cell["energy"] == CWData.AEROBIC_LEVEL_BASE,
		"盘面被吃掉 60 格，有氧仍是 %s（收入不再被地盘反噬）" % CWData.fmt(CWData.AEROBIC_LEVEL_BASE))

	## 【分化】仍挂 III 级：09-04 曾定案下调到 II，09-05 团队复核撤回。
	## 注意门槛那条**没跟着撤**（仍是 10/20），所以 III 级比改动前晚到 —— 团队知情。
	check(g.tune.differentiate_min_level == 2, "分化门槛 = 2（III 级，PRD 原值）")
	g.immune_level = 1
	check("differentiate" not in g.actions.action_kinds(cell), "II 级：分化按钮还不出现")
	g.immune_level = 2
	check("differentiate" in g.actions.action_kinds(cell), "III 级：分化解锁")
	cell["differentiated"] = true
	check("differentiate" not in g.actions.action_kinds(cell), "已分化过：按钮不再占位")
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
	check(cell["energy"] == CWData.AEROBIC_LEVEL_BASE, "现行等级式：I 级 → %s" % CWData.fmt(CWData.AEROBIC_LEVEL_BASE))
	## 抠掉 20 格坏死
	var n := 0
	for c in g.tiles.keys():
		if n >= 20:
			break
		g.tiles[c]["necrosis"] = CWData.NECROSIS_TOXIN
		n += 1
	cell["energy"] = 0
	g.world._aerobic()
	## 团队 2026-09-04 换成等级式之后，PRD 原文「坏死不为有氧供能」那条**全局比例**失效了 ——
	## 有氧已经和盘面脱钩。09-05 补的新效果是**局部**的：只罚站在坏死格上的那一个（见 t_batch2_rules）。
	## 这里的细胞在 (0,0)，不在那 20 格里，所以照拿 2.5 —— 盯住的是「别处的坏死不影响我」。
	check(cell["energy"] == CWData.AEROBIC_LEVEL_BASE, "别处的坏死不再拉低全场有氧（09-04 换公式后的口径）")

	## 以下切回旧盘面公式的对照档，坏死的原口径还得有测试盯着
	g.tune.aerobic_level_base = 0
	cell["energy"] = 0
	g.world._aerobic()
	## 抠掉 20 格坏死：(127−20) × 3 ÷ 127 = 2.527 → 四舍五入 2.5
	check(cell["energy"] == 25, "盘面档：坏死 20 格 → 2.5（四舍五入到十分位）")
	## 倒计时：两个世界回合后恢复
	g.world._tick_necrosis()
	g.world._tick_necrosis()
	cell["energy"] = 0
	g.world._aerobic()
	check(cell["energy"] == 30, "盘面档：坏死到期后重新供能 → 满盘 127×3÷127 = 3.0")
	g.dispose()


# ---- 巨噬【I-吞噬】：由【迁移】触发的净化，回能不能把这一步走成免费 ----
##
## 队友 2026-09-01 报「巨噬细胞可以无穷动」。根因是两条各自都合 PRD 的规则撞在一起：
## 迁移减免的共同地板是 0.2（各卡面都写「最低 0.2」），而【I-吞噬】每次净化回 0.3。
## 回的比付的多 → 走一格净赚 0.1，巨噬能在癌组织上无限走并顺手净化。
## 现在回能封到「实付 − 0.1」，**一次迁移的净支出至少 0.1**。
func t_macro_purify_heal() -> void:
	print("[巨噬吞噬回能封顶]")
	check(CWData.MACRO_MOVE_NET_MIN == 1, "净支出下限 0.1")
	## 2026-09-04：团队覆盖 PRD 正本时把定案①② 换回了旧文案，Kevin 定「以最新版 PRD 为标准」
	## → 两个默认值回到 PRD 值，定案①② 的值只剩旋钮能扫回来（mheal=0 / mvx=7）
	check(CWData.MACRO_HEAL_PURIFY == 3 and CWTuning.new().macro_heal_purify == 3,
		"默认与 PRD 一致：吞噬每次净化回 0.3（定案① 的 0 用 mheal=0 扫回）")
	## 2026-09-09：III 级由 0.7 改 0.8；**X 级不再另有减免**（Kevin 确认「删了」）——
	## 等级只升不降、好处累加，所以 X 级沿用 III 级那档，两格同值。
	check(CWData.IMMUNE_MOVE_CANCEROUS == [10, 10, 8, 8] and CWTuning.new().immune_move_cancerous[3] == 8,
		"默认与 PRD 一致：III 与 X 级迁移到癌性组织同为 0.8（X 级的额外减免已删）")
	## 走一格癌组织，返回「这一步净花了多少」。封顶逻辑按 PRD 的 0.3 测 —— 定案 ① 后默认 0，得显式拨回
	var net := func(paid: int, skills: Array) -> int:
		var g := bare_game()
		g.tune.macro_heal_purify = 3
		var to := Vector2i(1, 0)
		g.tiles[to]["tissue"] = CWData.Tissue.CANCER
		var m := put_immune(g, Vector2i.ZERO)
		m["itype"] = CWData.ImmuneType.MACRO
		m["equipped"] = skills.duplicate()
		m["energy"] = 200
		var before: int = m["energy"]
		await g.actions.enter_tile(m, to, paid)
		if paid > 0:
			m["energy"] -= paid                   ## enter_tile 不扣费，费在 commit 里扣
		var out: int = before - m["energy"]
		g.dispose()
		return out
	check(await net.call(7, []) == 4, "实付 0.7：回满 0.3，净花 0.4")
	check(await net.call(5, []) == 2, "实付 0.5：回满 0.3，净花 0.2")
	check(await net.call(4, []) == 1, "实付 0.4：回满 0.3，净花 0.1（正好卡在下限）")
	check(await net.call(3, []) == 1, "实付 0.3：回能压到 0.2，净花 0.1")
	check(await net.call(2, []) == 1, "实付 0.2（减免地板）：回能压到 0.1，净花 0.1 —— 不再是 0")
	check(await net.call(1, []) == 1, "实付 0.1：一点都不回，净花 0.1")
	## **两个边界 2026-09-08 反过来了**（云端修订版写明「每通过【迁移】触发一次【净化】」，
	## 并单列「免费迁移触发净化时恢复 0.3」）：
	## 免费迁移原来被封顶压成 0，现在回满；传送/蹲守那类原来回满，现在一分不回。
	check(await net.call(0, []) == -3, "免费迁移：回满 0.3，净赚（PRD 单列的一条）")
	check(await net.call(-1, []) == 0,
		"paid=-1（传送 / 复活 / 血管 / 卡牌位移 / 蹲守净化）：不是【迁移】触发的，一分不回")
	## 旋钮 macro_heal_purify（2026-09-02 后期引擎对比表杠杆①）：0 = 吞噬回能不适用于净化
	var g0 := bare_game()
	g0.tune.macro_heal_purify = 0
	var to0 := Vector2i(1, 0)
	g0.tiles[to0]["tissue"] = CWData.Tissue.CANCER
	var m0 := put_immune(g0, Vector2i.ZERO)
	m0["itype"] = CWData.ImmuneType.MACRO
	await g0.actions.enter_tile(m0, to0, 7)
	check(m0["energy"] == 200, "旋钮 0：实付 0.7 也一点不回")
	check(g0.tiles[to0]["tissue"] == CWData.Tissue.HEALTHY, "→ 净化本身照常发生")
	g0.dispose()


# ---- 癌种钉死旋钮 tune.cancer_types（2026-09-03，专项测「黑色素瘤 + 小细胞肺癌」组合时加）----
##
## 默认空 = 每个癌席随机抽、同局不重复（说明 #12）。钉死按癌席出场顺序取；没钉到、或钉的种类已被
## 前一席占用的席位照常抽 —— 这样 `lineup=mel` 也能用（只钉第一席）。
func t_cancer_lineup() -> void:
	print("[癌种钉死]")
	var order := [CWData.Faction.IMMUNE, CWData.Faction.CANCER, CWData.Faction.IMMUNE, CWData.Faction.CANCER]
	var g := CWGame.new()
	g.tune.cancer_types = [CWData.CancerType.SCLC, CWData.CancerType.MELANOMA]
	g.init(order, 7)
	g.setup.begin()   ## 抽种类在开局无决策段（advance 的第一步），不在 init 里
	check(g.player(1)["cancer_type"] == CWData.CancerType.SCLC
		and g.player(3)["cancer_type"] == CWData.CancerType.MELANOMA, "按癌席出场顺序钉死")
	g.dispose()
	var seen := {}
	for s in 12:
		var g2 := CWGame.new()
		g2.tune.cancer_types = [CWData.CancerType.OSTEO]
		g2.init(order, 100 + s)
		g2.setup.begin()
		check(g2.player(1)["cancer_type"] == CWData.CancerType.OSTEO, "只钉首席（种子 %d）" % (100 + s))
		seen[g2.player(3)["cancer_type"]] = true
		g2.dispose()
	check(not seen.has(CWData.CancerType.OSTEO) and seen.size() >= 2, "没钉到的席位随机抽，且不与钉死的重复")
	var g3 := CWGame.new()
	g3.tune.cancer_types = [CWData.CancerType.SIGNET, CWData.CancerType.SIGNET]
	g3.init(order, 9)
	g3.setup.begin()
	check(g3.player(1)["cancer_type"] == CWData.CancerType.SIGNET
		and g3.player(3)["cancer_type"] != CWData.CancerType.SIGNET, "钉了重复种类：后一席退回随机、仍不重复")
	g3.dispose()
	var seen0 := {}
	for s in 12:
		var g0 := CWGame.new()
		g0.init(order, 200 + s)
		g0.setup.begin()
		seen0[g0.player(1)["cancer_type"]] = true
		g0.dispose()
	check(seen0.size() >= 3, "默认不钉：随机抽")


# ---- B 细胞【抗体】每世界回合上限旋钮（2026-09-02 后期引擎对比表杠杆③）----
##
## PRD 2026-09-01 删掉了「每世界回合最多 2 次」，现行 = 不限（旋钮 0）。手打 D 局里 MC 免疫一回合 7~10 发抗体
## 把所有暴露的癌细胞一次打光，是后期雪球的一根杠杆，所以把上限做回旋钮供扫描；默认值下行为逐位不变。
## 小细胞肺癌【转移】的费用 / 每世界回合上限旋钮（2026-09-03 晚，Kevin 问「黑 + 小同场怎么治」的候选杠杆；默认 = 现行 PRD）
func t_jump_cap() -> void:
	print("[小细胞【转移】次数 / 费用旋钮]")
	var g := bare_game()
	var c := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i.ZERO, -1, CWData.CancerType.SCLC)
	c["energy"] = 500
	g.cells.append(c)
	var jumps := func() -> Array:
		var out := []
		for o in g.actions.build_options(c):
			if o["data"].get("act", "") == "jump":
				out.append(o)
		return out
	## 2026-09-04 新 PRD 给【转移】加了每世界回合次数上限；当天下午那版又从 1 次改成 **2 次**
	check(g.tune.metastasis_max_per_round == 2 and g.tune.metastasis_cost == CWData.METASTASIS_COST,
		"默认与 PRD 一致：每世界回合 2 次、1.0 一次")
	var first: Array = jumps.call()
	check(not first.is_empty() and first[0]["label"].contains("1.0"), "默认：有跃进选项、标价 1.0")
	await g.actions.execute(c, first[0]["data"])
	check(c["jump_used"] == 1 and not jumps.call().is_empty(), "默认（上限 2）：跳完 1 次还能再跳")
	await g.actions.execute(c, jumps.call()[0]["data"])
	check(c["jump_used"] == 2 and jumps.call().is_empty(), "默认（上限 2）：跳满 2 次 → 选项消失")
	g.tune.metastasis_max_per_round = 0
	check(not jumps.call().is_empty(), "旋钮拨 0（不限次）→ 选项回来")
	g.tune.metastasis_max_per_round = 1
	check(jumps.call().is_empty(), "上限 1：本回合已跳过 → 选项消失")
	var to: Vector2i = g.actions._jump_targets(c)[0]
	check(not g.actions._is_jump_legal_now(c, to), "上限 1：提交时复验同样拒绝（选项与谓词共用一份）")
	g.world._reset_round_flags()
	check(c["jump_used"] == 0 and not jumps.call().is_empty(), "S 阶段重置 → 选项回来")
	g.tune.metastasis_cost = 15
	check(jumps.call()[0]["label"].contains("1.5"), "费用旋钮 1.5 进标价")
	## 计数随 cells 进快照：推演里跳过的回滚后不会漏回主线
	var snap := g.snapshot()
	await g.actions.execute(c, jumps.call()[0]["data"])
	check(c["jump_used"] == 1, "跳一次计数 1")
	g.restore(snap)
	check(g.cells[0]["jump_used"] == 0, "restore 回到 0（restore 换了 cells 数组，旧引用不算）")
	g.dispose()


## ---- B 细胞【抗体】同一世界回合内递减（团队 2026-09-04 定）----
##
## 2026-09-05 智能体对局里一个 B 细胞单回合连放 8 发，把骨肉瘤从 14.7 打到 2.7 ——
## 抗体是免疫方唯一「不掷骰、不限次、无射程」的输出。团队定的解法不是硬性次数上限，
## 而是**每多放一次减半**：第一次的强度一点没动，只是不能刷。
## 这里盯三件事：数列对不对、旋钮关掉能回到老行为、S 阶段能重置。
## ---- 【E-无氧呼吸】开方式（团队 2026-09-04 定案，默认开）----
##
## 旧式线性求和，「占得越多 → 越有钱 → 占得越快」没有刹车；开方之后前期几乎不变、后期腰斩。
## 这里只验算式本身（连通块的组装另有测试盯着）：默认值、系数对不对、后期真被压住、
## 单调不减、以及关掉能退回线性式。
func t_anaerobic_sqrt() -> void:
	print("[无氧公式]")
	var g := bare_game()
	g.setup.build_board()
	## 系数默认 **-1 = 按人数取**（Kevin 2026-09-07：四人 2.0 / 六人 2.8）；另两项仍是常量
	check(g.tune.anaerobic_block_coef == -1
		and CWData.anaerobic_block_coef(4) == 20 and CWData.anaerobic_block_coef(6) == 28
		and CWData.anaerobic_block_coef(5) == CWData.ANAEROBIC_BLOCK_COEF
		and g.tune.anaerobic_block_exp == CWData.ANAEROBIC_BLOCK_EXP
		and g.tune.anaerobic_solid_bonus == CWData.ANAEROBIC_SOLID_BONUS,
		"默认 = 常量：系数 %s / 指数 0.%d / 每格固化 %s" % [
			CWData.fmt(CWData.ANAEROBIC_BLOCK_COEF), CWData.ANAEROBIC_BLOCK_EXP,
			CWData.fmt(CWData.ANAEROBIC_SOLID_BONUS)])
	check(CWData.ANAEROBIC_BLOCK_EXP == 30 and CWData.ANAEROBIC_BLOCK_COEF == 28
		and CWData.ANAEROBIC_SOLID_BONUS == 10,
		"Kevin 2026-09-07 的公式：块内癌组织数^0.3 × 2.8 + 全图固化数 × 1.0")

	## 取一块普通癌组织，逐格核对指数项（全图没有固化时第二项为 0）
	var keys: Array = g.tiles.keys()
	var blk: Array = []
	for k in 24:
		blk.append(keys[k])
		g.tiles[keys[k]]["tissue"] = CWData.Tissue.CANCER
	for n in [1, 4, 10, 24]:
		var part: Array = blk.slice(0, n)
		check(is_equal_approx(g.world._anaerobic_pool(part), _pool_of(n, 0)),
			"%d 格：%.1f 十分能量" % [n, _pool_of(n, 0)])
	check(g.world._anaerobic_pool([]) == 0.0, "空块不炸")
	## 单调不减：格子多了收入不能反而变少
	var prev := -1.0
	var mono := true
	for n2 in range(1, 24):
		var cur: float = g.world._anaerobic_pool(blk.slice(0, n2))
		if cur < prev:
			mono = false
		prev = cur
	check(mono, "1~23 格单调不减")

	## 固化：**不进指数项、按全图线性加**。把块里一格改成固化 —— 指数项少一格，但全图多一格固化
	var before: float = g.world._anaerobic_pool(blk)
	g.tiles[blk[0]]["tissue"] = CWData.Tissue.SOLID
	check(is_equal_approx(g.world._anaerobic_pool(blk), _pool_of(23, 1)),
		"块里一格转固化：指数项按 23 格算，另加全图 1 格固化")
	check(g.world._anaerobic_pool(blk) > before, "固化比普通癌组织值钱（+1.0 对上 0.3 次方的那点边际）")
	## 全图固化对**别的块**也算数（这正是新公式的用意）
	var far: Array = [keys[80]]
	g.tiles[keys[80]]["tissue"] = CWData.Tissue.CANCER
	check(is_equal_approx(g.world._anaerobic_pool(far), _pool_of(1, 1)),
		"另一块只有 1 格，也吃到全图那 1 格固化的 +1.0")

	## 关掉（系数 0）→ 退回 09-04 之前的线性求和
	g.tune.anaerobic_block_coef = 0
	var lin: Array = [keys[0], keys[1], keys[2]]
	for c in lin:
		g.tiles[c]["tissue"] = CWData.Tissue.CANCER
	g.tiles[lin[0]]["tissue"] = CWData.Tissue.SOLID
	check(is_equal_approx(g.world._anaerobic_pool(lin),
			float(g.tune.anaerobic_per_solid + g.tune.anaerobic_per_cancer * 2)),
		"系数 0：退回线性求和（对照档）")
	g.dispose()


func t_antibody_halve() -> void:
	print("[抗体同回合递减]")
	var g := bare_game()
	var b := put_immune(g, Vector2i.ZERO)
	b["itype"] = CWData.ImmuneType.B_CELL
	b["energy"] = 500
	var foe := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(3, 0), -1,
		CWData.CancerType.MELANOMA)
	foe["energy"] = 500
	g.cells.append(foe)

	check(g.tune.antibody_halve, "默认开（团队 2026-09-04 定案：保留递减机制）")
	## 15 → 7 → 3 → 1 → 0：整数除法向下取整，自然衰减到 0 而不是永远留个尾巴
	var want := [15, 7, 3, 1, 0]
	for k in want.size():
		check(g.actions.antibody_damage(b) == want[k],
			"第 %d 发伤害 %s" % [k + 1, CWData.fmt(want[k])])
		var before: int = g.cells[1]["energy"]
		await g.actions.execute(b, { "act": "antibody" })
		check(g.cells[1]["energy"] == before - want[k],
			"第 %d 发实扣 %s" % [k + 1, CWData.fmt(want[k])])

	## 选项标签要把「这一次打多少」写出来 —— 不写玩家会白花 1.0 能量打 0 伤害
	var label := ""
	for o in g.actions.build_options(b):
		if o["data"].get("act", "") == "antibody":
			label = o["label"]
	check(label.contains("伤害"), "选项标签带上本次伤害：%s" % label)

	g.world._reset_round_flags()
	check(g.actions.antibody_damage(b) == 15, "S 阶段重置 → 伤害回到满值")

	g.tune.antibody_halve = false
	for k in 3:
		await g.actions.execute(b, { "act": "antibody" })
	check(g.actions.antibody_damage(b) == 15, "旋钮关掉 = 老行为，放几次都打满")

func t_antibody_cap() -> void:
	print("[抗体次数上限旋钮]")
	var g := bare_game()
	var b := put_immune(g, Vector2i.ZERO)
	b["itype"] = CWData.ImmuneType.B_CELL
	## 一个与健康组织相邻的癌细胞 = 抗体有目标；血厚到打不死
	var foe := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(3, 0), -1,
		CWData.CancerType.MELANOMA)
	foe["energy"] = 500
	g.cells.append(foe)
	var has_ab := func() -> bool:
		for o in g.actions.build_options(b):
			if o["data"].get("act", "") == "antibody":
				return true
		return false
	check(g.tune.antibody_max_per_round == 0, "默认 0 = 不限（现行 PRD）")
	for k in 3:
		check(has_ab.call(), "默认：第 %d 发前选项在" % (k + 1))
		await g.actions.execute(b, { "act": "antibody" })
	check(b["antibody_used"] == 3, "计数跟着走（3）")
	check(has_ab.call(), "默认：打了 3 发选项仍在")
	g.tune.antibody_max_per_round = 2
	check(not has_ab.call(), "上限 2：本回合已用 3 → 选项消失")
	g.world._reset_round_flags()
	check(b["antibody_used"] == 0 and has_ab.call(), "S 阶段重置 → 选项回来")
	await g.actions.execute(b, { "act": "antibody" })
	await g.actions.execute(b, { "act": "antibody" })
	check(not has_ab.call(), "上限 2：第 3 发不给选")
	## 计数随 cells 进快照：MC 推演里打过的抗体回滚后不会漏回主线，主线打过的推演里也不会凭空多出额度
	var snap := g.snapshot()
	g.world._reset_round_flags()
	check(g.cell_of(0)["antibody_used"] == 0, "重置后计数 0")
	g.restore(snap)
	check(g.cell_of(0)["antibody_used"] == 2, "restore 回到 2")
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
	## 骨肉瘤【刚性屏障】：PRD 2026-09-01 由「不可被攻击」改为「受到的能量损失为 40%」。
	## 所以这里查两件事：**攻击不再被禁**，以及**伤害确实只剩四成**。
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
	check(g.actions._is_move_legal_now(imm, b), "固化上的骨肉瘤现在可以攻击了")
	mate["energy"] = 100
	g.immune_hit(mate, 20, imm, false)          ## 2.0 × 40% = 0.8
	check(mate["energy"] == 92, "固化上的骨肉瘤：2.0 伤害只吃到 0.8")
	g.tiles[b]["tissue"] = CWData.Tissue.CANCER
	mate["energy"] = 100
	g.immune_hit(mate, 20, imm, false)
	check(mate["energy"] == 80, "不在固化上则照常吃满 2.0")
	## 向下取整到十分位：0.5 × 40% = 0.2（不是 0.25）
	g.tiles[b]["tissue"] = CWData.Tissue.SOLID
	mate["energy"] = 100
	g.immune_hit(mate, 5, imm, false)
	check(mate["energy"] == 98, "0.5 伤害 ×40% 向下取整到 0.2")
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


# ---- 世界事件回合表：3/6/10/14（2026-09-07 随 15 回合制压缩）----
func t_event_rounds() -> void:
	print("[世界事件回合]")
	var hit: Array[int] = []
	for r in range(1, 41):
		if CWData.is_world_event_round(r):
			hit.append(r)
	check(hit == [3, 6, 10, 14], "触发回合正是 PRD 那四个（%s）" % str(hit))
	check(not CWData.is_world_event_round(15), "14 之后不再触发（终局那回合不插事件）")


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


## 「白送的击杀」标准场景（t_ai_mc ②④ 共用）：2 人局，全盘健康，蒙特卡洛桥坐免疫席，
## 免疫在 (0,0) 只剩 0.6 能量（刚够一次行动），癌在 (1,0) 只剩 0.1 能量（什么都买不起，
## 它那一轮不会掷任何骰 —— 否则它反击失败自伤致死会让「不打」那条 playout 也白捡终局分）。
## 先推进到免疫的行动询问再摆场景、就地重摊选项：蒙特卡洛只在 pending 边界上快照，
## 返回的 req 必须就是 _pending。返回 [game, mc, req]。
func _free_kill_scene(seed_value: int, rollouts: int, horizon: int) -> Array:
	var g := make_game(2, seed_value)
	var ip := _immune_pid(g)
	var mc := CWMonteCarloBridge.new()
	mc.game = g
	mc.rollouts = rollouts
	mc.horizon = horizon
	g.bridges[ip] = mc
	await run_setup(g)
	var req: Dictionary = {}
	while true:
		req = await g.pending()
		if req.is_empty() or (req["kind"] == "action" and req["pid"] == ip):
			break
		await g.step(await g.ask(req["pid"], req))
	for c in g.tiles.keys():
		g.tiles[c]["tissue"] = CWData.Tissue.HEALTHY
		g.tiles[c]["solid"] = 0
		g.tiles[c]["newborn"] = false
	var imm: Dictionary = g.cell_of(ip)
	var can: Dictionary = g.living_cells(CWData.Faction.CANCER)[0]
	imm["pos"] = Vector2i(0, 0)
	imm["energy"] = 6
	imm["hand"] = []
	can["pos"] = Vector2i(1, 0)
	can["energy"] = 1
	can["hand"] = []
	req["options"] = g.actions.build_options(imm)
	return [g, mc, req]


## 上面场景里「攻击那个残血癌细胞」的选项：攻击 = 迁移到它所在的格
func _is_free_kill(d: Dictionary) -> bool:
	return d.get("act", "") == "move" and d.get("to", Vector2i.MAX) == Vector2i(1, 0)


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
	## v2 惜命（2026-09-02）：死细胞不再免费
	var imm: Dictionary = g.living_cells(CWData.Faction.IMMUNE)[0]
	var base_i := CWEval.score(g, CWData.Faction.IMMUNE)
	imm["alive"] = false
	imm["respawn_round"] = g.round_no + 1
	var dead_i := CWEval.score(g, CWData.Faction.IMMUNE)
	check(CWEval.score(g, CWData.Faction.IMMUNE, false)
		== dead_i + CWEval.DEAD_IMMUNE_TRIP + CWEval.DEAD_IMMUNE_ROUND,
		"death_cost=false（v1 估值）→ 死亡不罚，只差那笔罚分")
	check(base_i - dead_i >= CWEval.DEAD_IMMUNE_ROUND,
		"免疫细胞死亡（下回合复活）：免疫分掉 %d（至少 %d）" % [base_i - dead_i, CWEval.DEAD_IMMUNE_ROUND])
	imm["respawn_round"] = g.round_no + 2
	check(CWEval.score(g, CWData.Faction.IMMUNE) == dead_i - CWEval.DEAD_IMMUNE_ROUND,
		"多罚停一个世界回合 → 正好再掉 %d（罚停旋钮进了估值）" % CWEval.DEAD_IMMUNE_ROUND)
	imm["respawn_round"] = -1
	check(dead_i - CWEval.score(g, CWData.Faction.IMMUNE)
		== CWEval.DEAD_FOREVER - CWEval.DEAD_IMMUNE_TRIP - CWEval.DEAD_IMMUNE_ROUND,
		"不再复活 → 比「下回合复活」再掉 %d" % (CWEval.DEAD_FOREVER - CWEval.DEAD_IMMUNE_TRIP - CWEval.DEAD_IMMUNE_ROUND))
	## 癌方视角不计任何死亡项（v2 定稿：计了反而把 MC 癌吓弱，见 CWEval 头注的表）
	imm["respawn_round"] = g.round_no + 1
	check(CWEval.score(g, CWData.Faction.CANCER) == CWEval.score(g, CWData.Faction.CANCER, false),
		"癌方视角：免疫死了也不算收益（= 不罚死亡的分）")
	imm["alive"] = true
	imm["respawn_round"] = -1
	check(CWEval.score(g, CWData.Faction.IMMUNE) == base_i, "复活回来分数复原")
	var can: Dictionary = g.living_cells(CWData.Faction.CANCER)[0]
	var base_ci := CWEval.score(g, CWData.Faction.IMMUNE)
	can["alive"] = false
	var dead_ci := CWEval.score(g, CWData.Faction.IMMUNE)
	check(dead_ci - base_ci >= CWEval.DEAD_CANCER_NO_BASE,
		"癌细胞死亡且场上无固化据点：免疫视角 +%d（至少 %d）" % [dead_ci - base_ci, CWEval.DEAD_CANCER_NO_BASE])
	check(CWEval.score(g, CWData.Faction.CANCER) == CWEval.score(g, CWData.Faction.CANCER, false),
		"癌方视角：自己死了也不另罚（陪练已把它的未来算保守，再罚是重复计价）")
	var solid_at: Vector2i = Vector2i.MAX
	for c in g.tiles.keys():
		if g.tiles[c]["tissue"] == CWData.Tissue.CANCER and g.tiles[c]["solid"] == 0:
			solid_at = c
			break
	g.tiles[solid_at]["tissue"] = CWData.Tissue.SOLID
	## 2026-09-04 起还要减掉 FIRST_BASE：一格无人占据的固化癌组织**直接挡住免疫的清场胜**
	## （`check_immune_win` 的原文），估值给它一次性加分
	check(CWEval.score(g, CWData.Faction.IMMUNE) - dead_ci
		== -(CWEval.DEAD_CANCER_NO_BASE - CWEval.DEAD_CANCER) - CWEval.TILE - CWEval.FIRST_BASE,
		"有固化据点可复活 → 免疫视角少赚 %d（另加固化格本身多算的 1 格 + 挡住清场胜的 %d）"
			% [CWEval.DEAD_CANCER_NO_BASE - CWEval.DEAD_CANCER, CWEval.FIRST_BASE])
	g.tiles[solid_at]["tissue"] = CWData.Tissue.CANCER
	can["alive"] = true
	g.dispose()


## 只记录【E-侵蚀】过场广播的桥
class ErosionRecorder extends CWBridge:
	var got: Array = []
	func show_erosion(at: Vector2i, dir: int) -> void:
		got.append([at, dir])


# ---- 【E-侵蚀】的两帧过场（美术 2026-09-03 交付，2026-09-05 接上）----
##
## 三件事分开验：帧序（纯函数）、方向取法（不许掷骰）、引擎到桥的广播。
## **方向与美术的对应是这一组测试的重点** —— 弄反了不会报错，只会让玩家
## 看见癌从空的那一侧漫过来，而这种错没人会在日志里发现。
# ---- 热座（本地多人）：配置面板席位表、换手遮罩、桥的判定、日志视角过滤、整条接线 ----
func press_action(name: String) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = name
	e.pressed = true
	return e


func t_hotseat() -> void:
	print("[热座 · 本地多人]")
	## ① 配置面板：第四档「本地多人」→ 右侧席位表；逐席拨真人 / AI；cfg.seats → 真人席位下标
	var p := CWConfigPanel.new()
	root.add_child(p)
	await process_frame
	p.open()
	check(p._n_rows() == CWConfigPanel.N_ROWS and not p._sheet.visible, "普通模式：四行、席位表不出")
	p.handle_input(press_action("ui_down"))                 ## → 我的阵营
	for i in 3:
		p.handle_input(press_action("ui_right"))            ## 免疫 → 癌 → 观战 → 本地多人
	check(p.config()["faction"] == CWConfigPanel.HOTSEAT, "「我的阵营」第四档 = 本地多人")
	check(p._n_rows() == CWConfigPanel.N_ROWS + 4 and p._sheet.visible, "四人局：多出 4 个席位行，席位表出现")
	var seats: Array = p.config()["seats"]
	check(seats.size() == 4 and not seats.has(false), "席位默认全部真人")
	check(p._value_text(CWConfigPanel.ROW_PLAYERS) == "4 人（4 真人 · 0 AI）", "人数行改写成真人 / AI 计数")
	check(p._value_text(CWConfigPanel.ROW_FACTION) == "本地多人", "阵营行显示「本地多人」")
	check(CWConfigPanel.seat_name(4, 0) == "免疫A" and CWConfigPanel.seat_name(4, 1) == "癌症A" \
		and CWConfigPanel.seat_name(4, 2) == "免疫B" and CWConfigPanel.seat_name(6, 5) == "癌症C",
		"席位名与引擎 players[].name 同一套规则：免疫A / 癌症A / 免疫B …")
	## **步数由常量推**，别写死：2026-09-08 加「世界事件」行时这里就因为写死 3 而红了。
	## 此刻焦点在「我的阵营」，一路往下走到左栏之外的第一个席位行（下标 = N_ROWS）。
	for i in CWConfigPanel.N_ROWS - CWConfigPanel.ROW_FACTION:
		p.handle_input(press_action("ui_down"))             ## …一路走到席位 1（免疫A）
	check(p._sel == CWConfigPanel.N_ROWS and p._name_labels[p._sel].text == "免疫A", "焦点从左栏走进席位表第一行")
	check(p._marker.position.x - 24 >= CWConfigPanel.SHEET_X, "焦点在席位行：菱形标连 48px 光晕都落在席位表内（Kevin 09-05）")
	check(p._name_labels[p._sel].position.x == CWConfigPanel.SEAT_NAME_X \
		and p._value_labels[p._sel].position.x == CWConfigPanel.SEAT_VALUE_X, "席位行摆在右侧席位表的列上")
	p.handle_input(press_action("ui_down"))                 ## → 席位 2（癌症A）
	p.handle_input(press_action("ui_right"))
	check(p.config()["seats"][1] == false and p._value_text(CWConfigPanel.N_ROWS + 1) == "AI", "拨一下：癌症A 改成 AI")
	check(CWConfigPanel.hotseat_seats(p.config()) == [0, 2, 3], "真人席位下标 = [0, 2, 3]")
	check(p._value_text(CWConfigPanel.ROW_PLAYERS) == "4 人（3 真人 · 1 AI）", "人数行同步")
	## 人数拨到 6：席位表 6 行，「进入棋盘」不动；自定义 + 热座：癌种行仍在左栏
	p._sel = CWConfigPanel.ROW_PLAYERS
	p.handle_input(press_action("ui_right"))                ## 4 → 6
	check(p._n_rows() == CWConfigPanel.N_ROWS + 6 and p._btn.position.y == CWConfigPanel.BTN_Y, "六人局：6 个席位行，按钮位置不变")
	check(p._seat_bars[5].visible and p._seat_bars[5].color == CWStyle.CANCER and p._seat_bars[0].color == CWStyle.IMMUNE, "六条阵营色竖条按席位阵营着色")
	p.custom = true
	p._repaint()
	check(p._n_rows() == CWConfigPanel.N_ROWS + 6 + 3 and p._name_labels[CWConfigPanel.N_ROWS + 6].text == "癌症A 种类" \
		and p._name_labels[CWConfigPanel.N_ROWS + 6].position.x == CWConfigPanel.SLOT_X, "自定义 + 热座：4 + 6 席 + 3 癌种，癌种行在左栏")
	p.custom = false
	## 拨回免疫：席位表淡出、cfg.seats 为空；取值局间保留（癌症A 仍是 AI）
	p._sel = CWConfigPanel.ROW_FACTION
	p.handle_input(press_action("ui_right"))                ## 本地多人 → 免疫
	check(p.config()["faction"] == CWData.Faction.IMMUNE and p.config()["seats"].is_empty() and p._n_rows() == CWConfigPanel.N_ROWS, "拨回免疫：cfg.seats 为空、席位行收起")
	await create_timer(CWConfigPanel.SHEET_FADE + 0.15).timeout
	check(not p._sheet.visible, "席位表淡出后隐藏")
	check(p._seats[1] == false, "席位取值局间保留")
	root.remove_child(p)
	p.free()

	## ② 换手遮罩单体：开演 / Esc 无效 / Enter 确认 / hide_now 放行
	var h := CWHandoff.new()
	root.add_child(h)
	await process_frame
	check(not h.visible and not h.active, "起手隐藏")
	var done := [0]
	var run := func() -> void:
		await h.pass_to(1, CWData.Faction.CANCER, "癌症A", Vector2i(2, 0))
		done[0] += 1
	run.call()
	await process_frame
	check(h.visible and h.active and h._name.text == "癌症A" and h.faction_color == CWStyle.CANCER \
		and h.cell_pos == Vector2i(2, 0) and h._bar.color == CWStyle.CANCER, "开演：可见、活动中、席位名与阵营色对上")
	check(h.pulse() >= 0.0 and h.pulse() <= 1.0, "脚下光环的呼吸值在 0~1")
	h._unhandled_input(press_action("ui_cancel"))
	check(h.active and done[0] == 0, "Esc 无效：隐私不是演出，不能跳过")
	h._unhandled_input(press_action("ui_accept"))
	await process_frame
	check(done[0] == 1 and not h.active, "Enter 确认：pass_to 返回、不再活动")
	await create_timer(CWHandoff.T_SCRIM + 0.15).timeout
	check(not h.visible, "出场动画完隐藏")
	run.call()
	await process_frame
	h.hide_now()
	await process_frame
	check(done[0] == 2 and not h.visible and not h.active, "hide_now 放掉等待并直接隐藏（拆局用）")
	root.remove_child(h)
	h.free()

	## ③ 判定是纯函数
	check(CWUIBridge.needs_handoff(true, -1, 0) and CWUIBridge.needs_handoff(true, 0, 1) \
		and not CWUIBridge.needs_handoff(true, 1, 1) and not CWUIBridge.needs_handoff(false, -1, 0),
		"换手判定：热座且换了人才弹（第一问也弹）；同一人连续询问、单人局不弹")

	## ④ 日志面板按视角过滤
	var g := bare_game()
	g.log_msg("免疫A 抽到【X】", 0, "免疫A 抽了一张牌")
	g.log_msg("公开一行")
	var lp := CWLogPanel.new()
	root.add_child(lp)
	await process_frame
	lp.filter = true
	lp.viewer = 1
	check(lp.line_text(g, 0) == "免疫A 抽了一张牌" and lp.line_text(g, 1) == "公开一行", "视角 = 癌症A：免疫A 的牌名换成公开替身，公开行照常")
	lp.viewer = 0
	check(lp.line_text(g, 0) == "免疫A 抽到【X】", "视角 = 免疫A：自己的牌名照常")
	lp.viewer = -1
	check(lp.line_text(g, 0) == "免疫A 抽了一张牌", "换手期间（无人视角）：秘密行全换")
	lp.filter = false
	check(lp.line_text(g, 0) == "免疫A 抽到【X】", "filter 关（无真人的观战局）：原文照出")
	## 视角一变，折好的行要重折
	lp.visible = true
	lp.filter = true
	lp.viewer = 1
	lp.refresh(g)
	var joined := "".join(lp._rows)
	check("抽了一张牌" in joined and not ("【X】" in joined), "面板行按视角折出")
	lp.viewer = 0
	lp.refresh(g)
	check("【X】" in "".join(lp._rows), "视角切换后整卷重折")
	g.dispose()
	root.remove_child(lp)
	lp.free()

	## ⑤ 接线：两位真人开局 → 第一问先弹遮罩、无人露牌；确认后免疫A 露牌；拆局（含遮罩期间）无残留
	var main_scene: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main_scene)
	await process_frame
	var m: CWMatch = main_scene.match_node
	m.human_players = [0, 1]
	CWSettings.ai_delay_ms = 0
	m.start()
	await process_frame
	await process_frame
	check(m.bridge.hotseat and m._handoff.active and m.bridge.current_human == -1, "两位真人：第一问先弹换手遮罩，此刻无人露牌")
	check(m._handoff._name.text == "免疫A" and m._handoff.faction_color == CWStyle.IMMUNE, "遮罩写的是先手的席位名与阵营色")
	check(m._log_panel.filter and m._log_panel.viewer == -1, "日志面板处于无人视角")
	m._handoff.confirm()
	await process_frame
	check(m.bridge.current_human == 0 and not m._handoff.active, "确认后：免疫A 成为露牌者、遮罩收起")
	check(m._log_panel.viewer == 0, "日志面板切到免疫A 的视角")
	m.teardown()
	await process_frame
	check(not m._handoff.active and not m._handoff.visible and m.bridge == null, "拆局：遮罩收掉")
	m.human_players = [0, 1]
	m.start()
	await process_frame
	await process_frame
	check(m._handoff.active, "第二局又先弹遮罩")
	m.teardown()
	await process_frame
	check(not m._handoff.active and not m._handoff.visible, "遮罩期间拆局：无残留")
	## 单人局不受影响：不弹遮罩，露牌者就是那一席
	m.human_players = [0]
	m.start()
	await process_frame
	await process_frame
	check(not m.bridge.hotseat and not m._handoff.active and m._log_panel.filter and m._log_panel.viewer == 0,
		"单人局：不是热座、不弹遮罩，但日志仍按这一席的视角过滤（AI 抽的牌名也收，Kevin 09-05）")
	m.teardown()
	await process_frame
	CWSettings.ai_delay_ms = 220
	root.remove_child(main_scene)
	main_scene.free()


# ---- 传送演出：状态差分判传送、残影/真身各自的材质与时序、拆局清干净、开关（规格 docs/动画规格_传送.md） ----
func t_teleport_fx() -> void:
	print("[传送演出]")
	## ① 单体：残影复制离场那一帧原地溶解；真身先藏住再凝出；演完材质摘掉、scale 归一、落地回调一次
	var stage := Node2D.new()
	root.add_child(stage)
	var body := Sprite2D.new()
	body.texture = CWMatch.CANCER_ART[CWData.CancerType.MELANOMA]
	body.hframes = CWMatch.BREATH_FRAMES
	body.offset = Vector2(0, -17)
	body.frame = 4
	body.position = Vector2(300, 200)
	stage.add_child(body)
	var fx := CWTeleportFx.new()
	var landed := [0]
	fx.play(stage, body, 7, Vector2(100, 100), 55, CWTeleportFx.EDGE_CANCER, 0.0,
		func() -> void: landed[0] += 1)
	check(fx.busy() and fx.ghost_count() == 1, "开演：一个残影在溶解")
	var ghost: Sprite2D = fx._ghosts[0]["node"]
	check(ghost.get_parent() == stage and ghost.position == Vector2(100, 100) and ghost.z_index == 55,
		"残影挂在给的父层、站在离场那一格的原站位（含 STACK_DX 错位）")
	check(ghost.texture == body.texture and ghost.hframes == body.hframes \
		and ghost.frame == 4 and ghost.offset == body.offset, "残影复制离场那一帧：同贴图、同帧、同脚底锚点")
	var gm := ghost.material as ShaderMaterial
	check(gm != null and gm.shader == CWTeleportFx.SHADER and float(gm.get_shader_parameter("emerge")) == 0.0 \
		and gm.get_shader_parameter("edge_color") == CWTeleportFx.EDGE_CANCER, "残影：沉入方向、阵营色边")
	var bm := body.material as ShaderMaterial
	check(bm != null and bm != gm and float(bm.get_shader_parameter("progress")) == 1.0 \
		and float(bm.get_shader_parameter("emerge")) == 1.0 and bm.get_shader_parameter("edge_color") == Color.WHITE,
		"真身：材质逐实例、先整个溶掉藏住、凝出方向 + 白边")
	fx.sync_breath(2, CWMatch.BREATH_FRAMES)
	check(ghost.frame == (2 + 7) % CWMatch.BREATH_FRAMES, "残影呼吸帧 = 全局步进 + 细胞下标（与 _animate_breath 同式）")
	await create_timer(CWTeleportFx.LAG + CWTeleportFx.EMERGE + 0.2).timeout
	await process_frame
	check(not fx.busy() and not is_instance_valid(ghost), "0.45s 后：残影已删、真身演完")
	check(body.material == null and body.scale == Vector2.ONE, "真身材质摘掉、scale 回到 ONE（否则下一帧 _sync_cells 覆写会抖一下）")
	check(landed[0] == 1, "落地回调恰好一次（调用方拿它白闪目标格）")
	## ② clear_all：补间先杀再删节点，真身还原
	fx.play(stage, body, 7, Vector2(1, 1), 1, CWTeleportFx.EDGE_IMMUNE, 0.3, Callable())
	check(fx.busy() and body.material != null, "带延迟的演出在排队，真身已藏住")
	fx.clear_all()
	await process_frame
	check(not fx.busy() and body.material == null and body.scale == Vector2.ONE \
		and stage.get_child_count() == 1, "clear_all：残影删净、补间杀掉、真身还原（只剩真身一个子节点）")
	root.remove_child(stage)
	stage.free()

	## ③ 接线：CWMatch._sync_cells 的状态差分（不走引擎信号）
	var main_scene: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main_scene)
	await process_frame
	var m: CWMatch = main_scene.match_node
	var g := bare_game()
	var imm := put_immune(g, Vector2i(0, 0))
	var can := CWSetup.make_cell(g.cells.size(), 1, CWData.Faction.CANCER, Vector2i(2, 0), -1, CWData.CancerType.MELANOMA, 60)
	g.cells.append(can)
	m.game = g
	m._sync_cells()                      ## 首帧：两个节点都是「刚出现」→ 淡入，不算传送
	check(m._cell_nodes.size() == 2 and not m._teleport_fx.busy(), "首帧出现走淡入，不触发传送")
	imm["pos"] = Vector2i(1, 0)          ## 相邻一格：普通迁移
	m._sync_cells()
	check(not m._teleport_fx.busy(), "挪到相邻格是迁移，不演")
	var before: Vector2 = m._cell_nodes[0].position
	imm["pos"] = Vector2i(-4, 2)         ## 跳远：传送
	m._sync_cells()
	check(m._teleport_fx.ghost_count() == 1 and m._teleport_fx.played == 1, "两格不相邻 → 判定为传送，开演一次")
	check(m._teleport_fx._ghosts[0]["node"].position == before, "残影落在上一帧实际画的位置")
	check(m._cell_nodes[0].position == m.board.tile_center(Vector2i(-4, 2)) + Vector2(0, CWMatch.CELL_FOOT_DY),
		"真身已经被 _sync_cells 摆到新格（演出不碰位移）")
	check((m._cell_nodes[0].material as ShaderMaterial).get_shader_parameter("edge_color") == Color.WHITE \
		and (m._teleport_fx._ghosts[0]["node"].material as ShaderMaterial).get_shader_parameter("edge_color") == CWTeleportFx.EDGE_IMMUNE,
		"免疫细胞：残影青边离场、真身白边落场")
	## 复活不是传送：死了再在远处活过来 → 淡入
	m._teleport_fx.clear_all()
	can["alive"] = false
	m._sync_cells()
	can["alive"] = true
	can["pos"] = Vector2i(-2, -2)
	m._sync_cells()
	check(not m._teleport_fx.busy(), "死而复活落在远处：走淡入，不当传送（先查复活再查传送）")
	## 血管互换：两端同帧检出，血管格先亮
	imm["pos"] = CWData.VESSELS[0]
	can["pos"] = CWData.VESSELS[1]
	m._sync_cells()
	m._teleport_fx.clear_all()
	m._flash.clear()
	imm["pos"] = CWData.VESSELS[1]
	can["pos"] = CWData.VESSELS[0]
	m._sync_cells()
	check(m._teleport_fx.ghost_count() == 2, "血管互换：两端同一帧各出一个残影")
	check(m._flash.has(CWData.VESSELS[0]) and m._flash.has(CWData.VESSELS[1]), "血管格先亮，交代「是血管干的」")
	## 开关：关掉后检测照做、演出全跳
	m._teleport_fx.clear_all()
	CWSettings.teleport_anim = false
	imm["pos"] = Vector2i(0, 0)
	m._sync_cells()
	check(not m._teleport_fx.busy() and m._last_pos[0] == Vector2i(0, 0), "开关关着：不演，位置记录照常更新")
	CWSettings.teleport_anim = true
	## 拆局：无残留
	imm["pos"] = Vector2i(4, -4)
	m._sync_cells()
	check(m._teleport_fx.busy(), "拆局前有一个演出在跑")
	m.teardown()
	await process_frame
	check(not m._teleport_fx.busy() and m._last_pos.is_empty() and m._cells_root.get_child_count() == 0,
		"拆局：补间杀掉、残影删净、位置记录清空")
	root.remove_child(main_scene)
	main_scene.free()


func t_erosion_fx() -> void:
	print("[侵蚀过场]")
	var fx := CWErosionFx.new()
	check(CWErosionFx.ART.size() == CWData.DIRS.size(),
		"6 个方向的图与 CWData.DIRS 一一对应")

	## 帧序：0~0.16 第一帧、0.16~0.32 第二帧、之后退场
	fx.play(Vector2i.ZERO, 0)
	check(fx.frame_of(Vector2i.ZERO) == CWErosionFx.ART[0][0], "刚开演：p33")
	fx.advance(CWErosionFx.FRAME_TIME)
	check(fx.frame_of(Vector2i.ZERO) == CWErosionFx.ART[0][1], "过了一帧：p66")
	fx.advance(CWErosionFx.FRAME_TIME)
	check(fx.frame_of(Vector2i.ZERO) == null and not fx.busy(),
		"演完自动退场（不用收尾代码，_sync_tiles 下一帧就画回癌组织）")
	## 没在演的格子不能返回图，否则 _sync_tiles 会把整块棋盘画成过场图
	check(fx.frame_of(Vector2i(3, 0)) == null, "没在演的格子返回 null")
	## 越界方向静默跳过：引擎取不到癌性邻居时传 -1
	fx.play(Vector2i(1, 0), -1)
	fx.play(Vector2i(2, 0), 99)
	check(not fx.busy(), "方向越界/-1：不演，也不崩")
	fx.play(Vector2i.ZERO, 3)
	fx.clear_all()
	check(not fx.busy(), "clear_all 清干净（拆局必须调，否则下一局同格会闪）")

	## ---- 方向取法：按 DIRS 固定顺序取第一个癌性邻居，**不掷骰** ----
	var g := bare_game()
	var here := Vector2i.ZERO
	for d in CWData.DIRS:
		g.tiles[here + d]["tissue"] = CWData.Tissue.HEALTHY
	check(g.world._erosion_dir(here) == -1, "四周都健康：返回 -1（不演）")
	## 只让 DIRS[4] 是癌 → 必须报 4
	g.tiles[here + CWData.DIRS[4]]["tissue"] = CWData.Tissue.CANCER
	check(g.world._erosion_dir(here) == 4, "唯一的癌性邻居：报它的 DIRS 下标")
	## 再让 DIRS[1] 也变癌 → 取下标更小的那个（固定顺序，不随机）
	g.tiles[here + CWData.DIRS[1]]["tissue"] = CWData.Tissue.SOLID
	var rng_before: int = g.rng.state
	check(g.world._erosion_dir(here) == 1, "多个癌性邻居：取 DIRS 顺序最靠前的（固化也算）")
	check(g.rng.state == rng_before,
		"取方向**不消耗随机数** —— 消耗了的话同种子复现与全部平衡扫描数据当场作废")
	g.dispose()

	## ---- 引擎 → 桥：每转化一格就广播一次，方向合法 ----
	var g2 := bare_game()
	var rec := ErosionRecorder.new()
	for pid in g2.order:
		g2.bridges[pid] = rec
	## 造一块被癌完全包住的健康孤岛：中心健康、六邻全癌，且不挨棋盘外缘
	for c: Vector2i in g2.tiles:
		g2.tiles[c]["tissue"] = CWData.Tissue.CANCER
	g2.tiles[here]["tissue"] = CWData.Tissue.HEALTHY
	g2.world._erosion()
	check(rec.got.size() >= 1, "侵蚀转化了格子 → 广播了过场（%d 次）" % rec.got.size())
	var ok := true
	for e in rec.got:
		if int(e[1]) < 0 or int(e[1]) >= CWData.DIRS.size():
			ok = false
	check(ok, "广播的方向下标都在 0~5 之内")
	check(rec.got[0][0] == here, "广播的格子就是被侵蚀的那一格")
	g2.dispose()

	## ---- 联机：演出报文必须进 STREAM_KINDS ----
	## 不在白名单里的报文会被 CWNetClient 当场 _apply 掉，而 _apply 的 match 没有兜底分支，
	## 于是**静默丢弃**：CWMatch._net_loop 里那个分支永远收不到，联机模式下动画就是不播，
	## 还不报任何错。2026-09-05 接侵蚀过场时就漏了这一条，靠读代码才发现。
	for kind in ["roll", "result", "notice", "erosion", "card_played", "event_drawn", "card_drawn"]:
		check(kind in CWNetClient.STREAM_KINDS, "演出报文「%s」在 STREAM_KINDS 里" % kind)


# ---- 【增生】【定殖】也走侵蚀那套过场（Kevin 2026-09-06）----
##
## 三处对玩家是同一件事「这一格变癌了、癌从哪一侧来」。这里验的是**方向怎么定**：
## 定殖取细胞的来路（相邻精确、远处取夹角最小的一侧、原地 -1），增生取转化**之前**的癌性邻居
## （同批转的邻居不能互当来源——错了不会报错，只会让玩家看见癌从空的那侧漫过来）。
func t_spread_fx() -> void:
	print("[增生 / 定殖过场]")
	var o := Vector2i.ZERO
	var all_exact := true
	for i in CWData.DIRS.size():
		if CWData.dir_toward(o, o + CWData.DIRS[i]) != i:
			all_exact = false
	check(all_exact, "dir_toward：六个相邻格各报自己的 DIRS 下标")
	check(CWData.dir_toward(o, o + CWData.DIRS[2] * 5) == 2, "跃进 5 格（轴线上）：报跃进来的那一侧")
	check(CWData.dir_toward(o, Vector2i(3, -1)) == 0, "不在轴线上的远格 (3,-1)：取夹角最小的 E 侧")
	check(CWData.dir_toward(o, Vector2i(-2, 3)) == 4, "远格 (-2,3)：取夹角最小的 SW 侧")
	check(CWData.dir_toward(o, o) == -1, "同一格：说不出哪一侧，-1（不演）")

	## ---- 定殖：癌细胞走进健康组织 → 广播一次，方向 = 来路那一侧 ----
	var g := bare_game()
	var rec := ErosionRecorder.new()
	for pid in g.order:
		g.bridges[pid] = rec
	var from := Vector2i(2, 0)
	var dest := Vector2i(1, 0)
	var cancer := CWSetup.make_cell(0, 1, CWData.Faction.CANCER, from, -1, CWData.CancerType.OSTEO)
	g.cells.append(cancer)
	g.tiles[dest]["tissue"] = CWData.Tissue.HEALTHY
	await g.actions.enter_tile(cancer, dest)
	check(g.tiles[dest]["tissue"] == CWData.Tissue.CANCER, "定殖：健康格转为癌组织")
	check(rec.got.size() == 1 and rec.got[0][0] == dest and int(rec.got[0][1]) == 0,
		"定殖广播一次：(2,0) 走进 (1,0)，癌从 E 侧（DIRS[0]）进来")
	## 走进已经是癌的格：没有定殖，也就没有过场
	rec.got.clear()
	g.tiles[o]["tissue"] = CWData.Tissue.CANCER
	await g.actions.enter_tile(cancer, o)
	check(rec.got.is_empty(), "走进癌组织：不定殖、不演")
	## 免疫细胞走进健康格：不演（净化有自己的表现，也不是「癌来了」）
	var imm := put_immune(g, Vector2i(-2, 0))
	g.tiles[Vector2i(-1, 0)]["tissue"] = CWData.Tissue.HEALTHY
	await g.actions.enter_tile(imm, Vector2i(-1, 0))
	check(rec.got.is_empty(), "免疫走进健康格：不演")
	## 跃进落地（不相邻）：取最接近来路的一侧
	g.tiles[Vector2i(4, 0)]["tissue"] = CWData.Tissue.HEALTHY
	await g.actions.enter_tile(cancer, Vector2i(4, 0))
	check(rec.got.size() == 1 and int(rec.got[0][1]) == 3,
		"从 (0,0) 跃到 (4,0)：癌从 W 侧（DIRS[3]）来")
	g.dispose()

	## ---- 增生：中心一格癌、必中 → 六邻全转，六次过场的方向全指向中心 ----
	var g2 := bare_game()
	var rec2 := ErosionRecorder.new()
	for pid in g2.order:
		g2.bridges[pid] = rec2
	for c: Vector2i in g2.tiles:
		g2.tiles[c]["tissue"] = CWData.Tissue.HEALTHY
	g2.tiles[o]["tissue"] = CWData.Tissue.CANCER
	g2.tune.proliferate_per_adjacent = 1000   ## 必中，隔离概率因素
	g2.world._proliferate()
	check(rec2.got.size() == 6, "增生六邻全转 → 广播六次（%d 次）" % rec2.got.size())
	var toward_center := true
	for e in rec2.got:
		if int(e[1]) != CWData.dir_toward(e[0], o):
			toward_center = false
	check(toward_center, "每格的方向都指向中心那格：方向在转化之前取，同批转的邻居不互当来源")
	g2.dispose()

	## ---- 卡牌 / 技能直接转癌的格也演（Kevin 2026-09-06 补）：方向都朝发动者 / 落点那一侧 ----
	var g3 := _fx_game(2)
	var rec3 := ErosionRecorder.new()
	for pid in g3.order:
		g3.bridges[pid] = rec3
	var a := CWSetup.make_cell(0, 0, CWData.Faction.CANCER, Vector2i(0, 0), -1, CWData.CancerType.MELANOMA)
	g3.cells.append(a)
	g3.round_no = 1
	await g3.card_fx.resolve_event(a, "克隆增殖")
	check(rec3.got.size() == 1 and int(rec3.got[0][1]) == CWData.dir_toward(rec3.got[0][0], a["pos"]),
		"【克隆增殖】转的那格演过场，癌从发动者那一侧来")
	## 【黏液破裂】：范围内随机转的格全演，方向朝引爆者；引爆者脚下那格取不出方向 → 引擎不广播
	var sig := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(3, 0), -1, CWData.CancerType.SIGNET, 100)
	g3.cells.append(sig)
	rec3.got.clear()
	g3.actions._do_mucus(sig)
	check(rec3.got.size() >= 1, "【黏液破裂】转的格演过场（%d 格）" % rec3.got.size())
	var toward_sig := true
	for e in rec3.got:
		if e[0] == Vector2i(3, 0) or int(e[1]) != CWData.dir_toward(e[0], Vector2i(3, 0)):
			toward_sig = false
	check(toward_sig, "方向都朝引爆者那一侧，且引爆者脚下那格没有广播")
	## 【早期血行转移】：落点本身走 enter_tile（上面验过），落点周围随机转的那几格也演，方向朝落点
	var mel := CWSetup.make_cell(2, 1, CWData.Faction.CANCER, CWData.VESSELS[0], -1, CWData.CancerType.MELANOMA, 100)
	g3.cells.append(mel)
	rec3.got.clear()
	var land := Vector2i(-3, 1)
	await g3.actions._do_homing(mel, land)
	check(rec3.got.size() >= 2 and rec3.got[0][0] == land,
		"落点先演（定殖），随后扩散的格也演（共 %d 格）" % rec3.got.size())
	var toward_land := true
	for i in range(1, rec3.got.size()):
		if int(rec3.got[i][1]) != CWData.dir_toward(rec3.got[i][0], land):
			toward_land = false
	check(toward_land, "扩散格的方向都朝落点那一侧")
	g3.dispose()


## 只记录全局通报的桥，给 t_match_panel 验 trigger → notice 用
class NoticeRecorder extends CWBridge:
	var got: Array = []
	func show_notice(text: String) -> void:
		got.append(text)


# ---- 启发式 v3（2026-09-02）：继承 v2 的随机分化与惜命；MC 固定预算升版本 ----
## v4（2026-09-04）：「别蹲在自己刚铺的格子上」从**规则**变成**策略**。
## 规则那一条已被 `newborn_protect` 关掉，但这个判断**不许跟着关** ——
## v3 跟着关的后果是全场癌细胞同时蹲下攒固化，6 人局癌胜 43% → 19%（§10.7）。
## 路径规划器（2026-09-04 Kevin 要的「拖一条路，程序算总价」）
##
## **最关键的一条**：报价必须等于**真走一遍**花掉的能量。价钱逐步会变
## （癌细胞踩过的健康组织当场变癌组织 → 下一步从 1.0 变 0.2；黑色素瘤【伪足穿透】
## 的「相邻 ≥3 格癌性」也会因此成立），所以这份账只能引擎算 ——
## 这个测试就是防它和真实结算漂开。
## 树突状细胞按 2026-09-04 新 PRD 重做：【I-各司其职】换机制 + 新增【I-趋化源】
## 「出去占一圈、再回到原来那格攒固化」——Kevin 2026-09-04 指出的真人打法。
## 先钉**规则**（回合末站在哪就给哪格加计数，与这一回合走了多远无关），
## 再钉 **AI 会不会用**（v6 的 `_base_return`）。
## 「借道前进」：2026-09-04 下午 PRD 从「穿过一个友军」推广到「穿过整个友军连通块」。
## 旧规则是新规则里链长为 1 的特例，所以两种都要过。
## `CWEval` 的固化计价必须**单调**：把固化修完不能让估值下跌。
## 2026-09-04 修的就是这个 —— 旧值 SOLID_TICK=30 下，「进度 1.0 的癌组织(400)」
## 比「修成的固化格(200)」还值钱，MC 于是**主动避免把据点修完**、到处留半成品，
## 癌方几乎拿不到复活据点。这条回归把「进度 → 完成」钉成单调不下降。
func t_eval_solid_monotone() -> void:
	print("[估值：固化进度到完成必须单调]")
	var g := bare_game()
	var c := Vector2i.ZERO
	CWTissue.to_cancer(g.tile(c), false)
	var scores: Array = []
	for tick in [0, CWData.SOLIDIFY_STEP, CWData.SOLIDIFY_THRESHOLD - 1]:
		g.tile(c)["tissue"] = CWData.Tissue.CANCER
		g.tile(c)["solid"] = tick
		scores.append(CWEval.score(g, CWData.Faction.CANCER))
	CWTissue.to_solid(g.tile(c))
	var done: int = CWEval.score(g, CWData.Faction.CANCER)
	check(scores[0] <= scores[1] and scores[1] <= scores[2],
		"进度越高分越高（%s）" % str(scores))
	check(done >= scores[2],
		"**修完固化不能掉分**：进度满 %d vs 修成 %d" % [scores[2], done])
	check(CWEval.SOLID_TICK * CWData.SOLIDIFY_THRESHOLD <= CWEval.TILE,
		"进度学分总和 %d 不超过「修成」的增量 %d"
			% [CWEval.SOLID_TICK * CWData.SOLIDIFY_THRESHOLD, CWEval.TILE])
	## 据点被免疫站住就不算「可复活」——与 check_immune_win 同一口径。
	## 只断言**方向**：往盘面上加一个细胞还会动到能量、离战线距离等别的项，
	## 拿它去凑精确差值是把测试写脆（第一版就是这么错的）。
	var im := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(4, 0),
		CWData.ImmuneType.BASIC, -1, 50)
	g.cells.append(im)
	var off_base: int = CWEval.score(g, CWData.Faction.CANCER)
	im["pos"] = c                       ## 同一个细胞挪到据点上，其余项不变
	check(CWEval.score(g, CWData.Faction.CANCER) < off_base,
		"免疫站上据点 → 癌方估值下降（不再算「挡得住清场胜」）")
	g.dispose()


func t_pass_through_chain() -> void:
	print("[借道前进（穿过友军连通块）]")
	var g := bare_game()
	var me := CWSetup.make_cell(0, 0, CWData.Faction.CANCER, Vector2i.ZERO, -1,
		CWData.CancerType.SIGNET, 300)
	g.cells.append(me)
	## 一串友军：(1,0) (2,0)。落点 (3,0) 要穿过**两个**才够得到 —— 旧实现给不出这一格
	g.cells.append(CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(1, 0), -1,
		CWData.CancerType.SIGNET, 100))
	g.cells.append(CWSetup.make_cell(2, 2, CWData.Faction.CANCER, Vector2i(2, 0), -1,
		CWData.CancerType.SIGNET, 100))
	var m: Dictionary = g.actions.pass_through_map(me)
	check(m.has(Vector2i(2, 0)) == false, "友军自己占的格不是落点（不能停在人身上）")
	check(m.has(Vector2i(3, 0)), "穿过**两个**友军能落到 (3,0)（链式借道，旧实现做不到）")
	## 费用 = 沿途每格各按自己的组织类型计一次
	var step: int = g.tune.cancer_move_healthy
	check(int(m[Vector2i(3, 0)][0]) == step * 3,
		"费用 = 三格之和 %s（实为 %s）" % [CWData.fmt(step * 3), CWData.fmt(int(m[Vector2i(3, 0)][0]))])
	check(m[Vector2i(3, 0)][1] == Vector2i(1, 0), "第一跳记的是紧挨着我的那个友军")
	check(int(g.actions._move_base_cost(me, Vector2i(3, 0))) == step * 3, "报价走同一个口")
	check(Vector2i(3, 0) in g.actions.move_dests(me), "落点进了 move_dests")
	check(g.actions._is_move_legal_now(me, Vector2i(3, 0)), "合法性谓词也认")
	## 相邻格不该出现在借道表里（普通迁移更便宜，不能出两个同名选项）
	for n in CWData.neighbors(me["pos"]):
		check(not m.has(n), "相邻格 %s 不进借道表" % str(n))
		break
	## 敌军挡路不给借道
	var g2 := bare_game()
	var me2 := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i.ZERO,
		CWData.ImmuneType.BASIC, -1, 300)
	g2.cells.append(me2)
	g2.cells.append(CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(1, 0), -1,
		CWData.CancerType.SIGNET, 100))
	check(g2.actions.pass_through_map(me2).is_empty(), "敌军不能借道")
	g.dispose()
	g2.dispose()


func t_solidify_roundtrip() -> void:
	print("[绕一圈回来照样攒固化（真人打法）]")
	var g := bare_game()
	var home := Vector2i.ZERO
	var away := Vector2i(1, 0)
	CWTissue.to_cancer(g.tile(home), false)
	var c := CWSetup.make_cell(0, 0, CWData.Faction.CANCER, home, -1,
		CWData.CancerType.SIGNET, 200)
	g.cells.append(c)
	## ① 规则：走出去（把健康格定殖掉）再走回来，回合末照样给 home 加计数
	check(g.tile(away)["tissue"] == CWData.Tissue.HEALTHY, "邻格一开始是健康组织")
	await g.actions.execute(c, { "act": "move", "to": away,
		"cost": g.actions._move_cost_mod(c, away, g.actions._move_base_cost(c, away)) })
	check(g.tile(away)["tissue"] == CWData.Tissue.CANCER, "走过去把它定殖成癌组织")
	await g.actions.execute(c, { "act": "move", "to": home,
		"cost": g.actions._move_cost_mod(c, home, g.actions._move_base_cost(c, home)) })
	check(c["pos"] == home, "又走回了原来那一格")
	var before: int = g.tile(home)["solid"]
	g.world._solidify()
	check(g.tile(home)["solid"] == before + CWData.SOLIDIFY_STEP,
		"回合末仍然给 home 加计数（占地与攒固化**不是二选一**）")
	## ② AI：本回合没有值得走的占地步时，退到固化计数最高的那一格结束回合
	var h := CWHeuristicBridge.new()
	h.game = g
	var side := Vector2i(0, 1)
	CWTissue.to_cancer(g.tile(side), false)
	await g.actions.execute(c, { "act": "move", "to": side,
		"cost": g.actions._move_cost_mod(c, side, g.actions._move_base_cost(c, side)) })
	check(c["pos"] == side and int(g.tile(side)["solid"]) == 0, "此刻站在一格没有进度的癌组织上")
	var opts: Array = g.actions.build_options(c)
	var pick: int = h._base_return(opts, c)
	check(pick >= 0 and opts[pick]["data"]["to"] == home,
		"AI 选择退回**计数最高**的 home（选了 %s）"
			% (str(opts[pick]["data"].get("to", "?")) if pick >= 0 else "没选"))
	## 已经站在最高的那一格上时不再乱动（否则会来回抖）
	await g.actions.execute(c, opts[pick]["data"])
	check(h._base_return(g.actions.build_options(c), c) < 0, "已在据点上就不再移动，不来回抖")
	h.game = null
	g.dispose()


func t_dendritic_rework() -> void:
	print("[树突状细胞（2026-09-04 新 PRD）]")
	# ---- ① 【I-各司其职】：不能移向癌细胞占据的格（= 攻不了）----
	var g := bare_game()
	var foe_at := Vector2i(1, 0)
	var dc := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i.ZERO,
		CWData.ImmuneType.DENDRITIC, -1, 150)
	g.cells.append(dc)
	g.cells.append(CWSetup.make_cell(1, 1, CWData.Faction.CANCER, foe_at,
		-1, CWData.CancerType.SCLC, 50))
	check(not g.actions._is_move_legal_now(dc, foe_at), "树突：癌细胞占据的格走不进去")
	check(g.actions.move_block_reason(dc, foe_at).contains("各司其职"),
		"挡路原因点名【各司其职】：%s" % g.actions.move_block_reason(dc, foe_at))
	var moves := 0
	for o in g.actions.build_options(dc):
		if o["data"].get("act", "") == "move" and o["data"]["to"] == foe_at:
			moves += 1
	check(moves == 0, "选项里没有「攻击那一格」")
	## 换成巨噬：同一格立刻可攻 —— 证明拦的是种类，不是别的
	dc["itype"] = CWData.ImmuneType.MACRO
	check(g.actions._is_move_legal_now(dc, foe_at), "巨噬照旧能攻同一格")
	dc["itype"] = CWData.ImmuneType.DENDRITIC

	# ---- ② 【I-趋化源】：2.0 建一个、场上仅一个、持续 2 回合 ----
	check(g.chemo.is_empty(), "开局场上没有趋化源")
	var has_chemo := func() -> bool:
		for o in g.actions.build_options(dc):
			if o["data"].get("act", "") == "chemo":
				return true
		return false
	check(has_chemo.call(), "树突有【趋化源】选项")
	dc["energy"] = CWData.CHEMO_COST - 1
	check(not has_chemo.call(), "钱不够 → 选项消失")
	dc["energy"] = 150
	## 落点靠 chemo_target 询问；这里用固定桥答第 0 个（= 遍历 tiles 的第一格）
	var spot := Vector2i(3, 0)
	g.bridges[0] = _FixedTileBridge.new(spot)
	var before: int = dc["energy"]
	await g.actions.execute(dc, { "act": "chemo" })
	check(g.chemo.get("at", Vector2i.MAX) == spot and g.chemo["left"] == CWData.CHEMO_ROUNDS,
		"建立成功：%s 持续 %s" % [str(g.chemo.get("at", "?")), str(g.chemo.get("left", "?"))])
	check(dc["energy"] == before - CWData.CHEMO_COST, "付了 2.0（%s → %s）"
		% [CWData.fmt(before), CWData.fmt(dc["energy"])])
	check(not has_chemo.call(), "同一时刻仅一个 → 选项消失")

	# ---- ③ 方向判定与百分比：免疫朝它 -30%、癌方背它 +40%、横着走两条都不沾 ----
	var imm := CWSetup.make_cell(2, 2, CWData.Faction.IMMUNE, Vector2i(1, 0),
		CWData.ImmuneType.B_CELL, -1, 150)
	g.cells.append(imm)
	var plain: int = g.tune.immune_move_healthy[g.immune_level]
	var toward := Vector2i(2, 0)      ## 离 (3,0) 更近
	var away := Vector2i(0, 0)        ## 更远
	check(CWData.hex_dist(toward, spot) < CWData.hex_dist(imm["pos"], spot), "(2,0) 确实更靠近趋化源")
	var q_toward: int = g.actions._move_cost_mod(imm, toward, plain)
	check(q_toward == int(ceil(plain * CWData.CHEMO_IMMUNE_PCT / 100.0)),
		"免疫朝它走：%s → %s（-30%%，向上取整）" % [CWData.fmt(plain), CWData.fmt(q_toward)])
	check(g.actions._move_cost_mod(imm, away, plain) == plain, "免疫背它走：不打折")
	var can := CWSetup.make_cell(3, 3, CWData.Faction.CANCER, Vector2i(1, 0),
		-1, CWData.CancerType.SCLC, 150)
	g.cells.append(can)
	var cplain: int = g.tune.cancer_move_healthy
	var c_away: int = g.actions._move_cost_mod(can, away, cplain)
	## 取整走 `CWData.round_tenth`（四舍五入，2026-09-08 起全仓统一）。
	## ⚠ 这里原来写的是 `ceil`：+40% 时 12×1.4=16.8 两种取整都得 17，**巧合地对**，
	## 一直没暴露；2026-09-09 改成 +20% 后 14.4 才分道扬镳（round 得 14、ceil 得 15）。
	check(c_away == CWData.round_tenth(cplain * CWData.CHEMO_CANCER_PCT, 100),
		"癌方背它走：%s → %s（+%d%%，四舍五入）"
			% [CWData.fmt(cplain), CWData.fmt(c_away), CWData.CHEMO_CANCER_PCT - 100])
	check(g.actions._move_cost_mod(can, toward, cplain) == cplain, "癌方朝它走：不加价")

	# ---- ④ 进快照与哈希：它改变后续所有移动的价钱，漏了它推演就会算错 ----
	var h0 := g.state_hash()
	var snap := g.snapshot()
	g.chemo = {}
	check(g.state_hash() != h0, "趋化源进哈希（清掉后哈希变了）")
	g.restore(snap)
	check(g.state_hash() == h0 and g.chemo["at"] == spot, "restore 把趋化源带回来")

	# ---- ⑤ 倒计时：E 阶段每回合减一，归零消散 ----
	g.world._tick_chemo()
	check(g.chemo["left"] == CWData.CHEMO_ROUNDS - 1, "回合末减一")
	g.world._tick_chemo()
	check(g.chemo.is_empty(), "归零 → 消散")
	g.world._tick_chemo()   ## 空场再走一次不能崩
	check(g.chemo.is_empty(), "场上没有时倒计时是空操作")
	g.dispose()

	# ---- ⑥ 【I-标记】：被伤害消耗掉之后，只要还贴着树突就该回补（同一回合可多次获得）----
	var g2 := bare_game()
	var d2 := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i.ZERO,
		CWData.ImmuneType.DENDRITIC, -1, 150)
	g2.cells.append(d2)
	var vic := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(1, 0),
		-1, CWData.CancerType.SCLC, 200)
	g2.cells.append(vic)
	g2.update_marks()
	check(vic["marked"], "贴着树突 → 自动获得标记")
	var mac := CWSetup.make_cell(2, 2, CWData.Faction.IMMUNE, Vector2i(1, -1),
		CWData.ImmuneType.MACRO, -1, 150)
	g2.cells.append(mac)
	var hit := g2.immune_hit(vic, 10, mac)
	check(hit == 20, "标记让这一击翻倍（%s）" % CWData.fmt(hit))
	## 2026-09-07 PRD：「【标记】无法重叠，同一回合一癌细胞仅可获得一次标记」——
	## 旧行为（伤害吃掉后光环立刻回补）等于站在树突边上永久双倍，正是这次要堵的
	check(not vic["marked"], "同一回合不再回补标记")
	g2.round_no += 1
	g2.update_marks()
	check(vic["marked"], "下一个世界回合光环才会再给一次")
	g2.dispose()

	# ---- ⑦ 漩涡演出的轨道是纯函数：粒子不许跑出格子 ----
	var maxr := 0.0
	var squash_ok := true
	for ring in CWChemoFx.RINGS:
		for idx in CWChemoFx.PER_RING:
			for k in 24:
				var pos := CWChemoFx.particle_at(ring, idx, k * 0.13)
				maxr = maxf(maxr, absf(pos.x))
				if absf(pos.y) > CWChemoFx.ORBIT_R[ring] * CWChemoFx.ORBIT_SQUASH \
						+ CWChemoFx.RING_LIFT[ring] + 0.01:
					squash_ok = false
	check(is_equal_approx(maxr, CWChemoFx.ORBIT_R[CWChemoFx.RINGS - 1]) or maxr <= 32.5,
		"横向不超出格子外接圆（实测 %.1f）" % maxr)
	check(squash_ok, "纵向被压扁（贴六边形的斜视角）")


## 只答「某一格」的桥：给 chemo_target 那种「全局任意一格」的询问用
class _FixedTileBridge:
	extends CWBridge
	var want: Vector2i
	func _init(at: Vector2i) -> void:
		want = at
	func ask(req: Dictionary) -> int:
		for i in req["options"].size():
			if req["options"][i]["data"].get("to", Vector2i.MAX) == want:
				return i
		return 0


func t_plan_path() -> void:
	print("[路径规划器]")
	var g := make_game(4, 5)
	await run_setup(g)
	var can: Dictionary = g.living_cells(CWData.Faction.CANCER)[0]
	can["energy"] = 200
	## 贪心挑一条 4 步的空格路线（每一步都问引擎「从这儿还能去哪」）
	var path: Array[Vector2i] = []
	var at: Vector2i = can["pos"]
	for _k in 4:
		var nexts: Array = g.actions.plan_next_dests(can, at)
		if nexts.is_empty():
			break
		at = nexts[0]
		path.append(at)
	check(path.size() == 4, "挑出一条 4 步路线（实为 %d 步）" % path.size())

	## ① 纯查询：算完盘面一个字节都没动
	var before := g.state_hash()
	var q: Dictionary = g.actions.quote_path(can, path)
	check(g.state_hash() == before, "报价是纯查询：算完状态哈希不变")
	check(can["pos"] == path[0] - (path[0] - can["pos"]), "细胞位置没被挪走")
	check(q["ok"] and q["steps"].size() == 4, "四步全通（%s）" % str(q.get("ok", false)))
	check(q["total"] > 0 and q["left"] == can["energy"] - q["total"] + int(q["gained"]),
		"合计 %s、走完剩 %s" % [CWData.fmt(q["total"]), CWData.fmt(q["left"])])

	## ② 报价 == 真走一遍。逐步执行的是引擎自己的 _do_move，走的是提交那条路
	var e0: int = can["energy"]
	var spent_steps: Array = []
	for i in path.size():
		var opts: Array = g.actions.build_options(can)
		var pick := -1
		for j in opts.size():
			var d: Dictionary = opts[j]["data"]
			if d.get("act", "") == "move" and d["to"] == path[i]:
				pick = j
				break
		check(pick >= 0, "第 %d 步在真实选项里找得到" % (i + 1))
		if pick < 0:
			break
		var before_e: int = can["energy"]
		await g.actions.execute(can, opts[pick]["data"])
		spent_steps.append(before_e - can["energy"])
	var spent: int = e0 - can["energy"]
	check(spent == q["total"], "真走一遍花掉 %s == 规划器报价 %s（逐步 %s）"
		% [CWData.fmt(spent), CWData.fmt(q["total"]), str(spent_steps)])
	var quoted: Array = []
	for s in q["steps"]:
		quoted.append(s["cost"])
	check(str(quoted) == str(spent_steps), "每一步的价钱也对得上（报价 %s）" % str(quoted))
	check(can["pos"] == path[-1], "细胞确实走到了路线终点")
	g.dispose()

	## ③ 走不通的路：撞上别人 → 停在那一步并给出原因；能量不够 → 同样停下
	var g2 := make_game(4, 7)
	await run_setup(g2)
	var me: Dictionary = g2.living_cells(CWData.Faction.CANCER)[0]
	me["energy"] = 200
	var other: Dictionary = g2.living_cells(CWData.Faction.CANCER)[1]
	var blocked_path: Array[Vector2i] = [other["pos"]]
	var q2: Dictionary = g2.actions.quote_path(me, blocked_path)
	check(not q2["ok"] and q2["stop"] == 0 and q2["total"] == 0,
		"第一步就撞上别的细胞 → 停在第 0 步、总价 0")
	check(q2["steps"][0]["blocked"].contains("占据"),
		"给出原因：%s" % q2["steps"][0]["blocked"])
	## 能量刚好只够一步
	var one: Array = g2.actions.plan_next_dests(me, me["pos"])
	if not one.is_empty():
		var probe: Array[Vector2i] = [one[0]]
		var step_cost: int = int(g2.actions.quote_path(me, probe)["total"])
		var two: Array = g2.actions.plan_next_dests(me, one[0])
		if not two.is_empty():
			me["energy"] = step_cost
			var q3: Dictionary = g2.actions.quote_path(me, [one[0], two[0]] as Array[Vector2i])
			check(not q3["ok"] and q3["stop"] == 1 and q3["total"] == step_cost,
				"钱只够第一步 → 停在第 1 步、总价 = 第一步的价（%s）" % CWData.fmt(step_cost))
			check(q3["steps"][1]["blocked"].contains("能量"),
				"原因写明能量不够：%s" % q3["steps"][1]["blocked"])
	g2.dispose()


## 规划器要不要算【代谢核心】的收入（Kevin 2026-09-08 报「规划路径不会计算代谢核心给的能量」）。
##
## 少算它**不会**让某一步的单价错，但会让后面几步的 `afford` 判错 ——
## 症状是「明明走得完的路，规划器说第 2 步钱不够」，玩家只好放弃这条路线。
## 所以这组里 ④ 那条（钱只够一步、核心的钱接上第二步）才是真正要钉住的。
func t_plan_core_gain() -> void:
	print("[规划器：代谢核心收入]")
	var g := bare_game()
	var core: Vector2i = CWData.CORES[0]
	var side: Array = CWData.neighbors(core)
	var me := put_immune(g, side[0])
	g.tile(core)["store"] = 20

	## 基准：走一格普通健康组织多少钱（拿另一个邻格量，别用核心那格）
	var step_cost: int = int(g.actions.quote_path(me, [side[1]] as Array[Vector2i])["total"])
	check(step_cost > 0, "基准：走一格健康组织 %s" % CWData.fmt(step_cost))

	## ① 收入进账；`total` 保持纯花费、不与收入相抵
	me["energy"] = 100
	var before := g.state_hash()
	var q: Dictionary = g.actions.quote_path(me, [core] as Array[Vector2i])
	check(int(q["gained"]) == 20 and int(q["steps"][0]["gain"]) == 20,
		"踩上核心：gained = 2.0（实为 %s）" % CWData.fmt(int(q["gained"])))
	check(int(q["total"]) == step_cost,
		"total 仍是纯花费 %s，不与收入相抵" % CWData.fmt(int(q["total"])))
	check(int(q["left"]) == 100 - step_cost + 20, "走完剩 = 现有 − 花费 + 核心收入")

	## ② 纯查询：预演不能把核心吸干（store 进快照，所以哈希抓得到）
	check(g.state_hash() == before and int(g.tile(core)["store"]) == 20,
		"报价是纯查询：核心存量原样放回")

	## ③ 同一个核心来回踩两趟只收一次
	var q2: Dictionary = g.actions.quote_path(me, [core, side[0], core] as Array[Vector2i])
	check(q2["ok"] and int(q2["gained"]) == 20,
		"来回踩两趟只收一次（gained = %s）" % CWData.fmt(int(q2["gained"])))

	## ④ **Kevin 报的那个症状**：钱只够第一步，而第一步站上核心、收到的钱接上第二步
	var beyond: Array = g.actions.plan_next_dests(me, core)
	check(not beyond.is_empty(), "核心那格还能往外走")
	if not beyond.is_empty():
		me["energy"] = step_cost
		var q3: Dictionary = g.actions.quote_path(me, [core, beyond[0]] as Array[Vector2i])
		check(q3["ok"], "钱只够一步，核心的 2.0 接上了第二步（改之前这里判「钱不够」）")
		## 对照组：把核心取空，同一条路立刻走不通 —— 证明上面那条确实是核心的钱在起作用
		g.tile(core)["store"] = 0
		var q4: Dictionary = g.actions.quote_path(me, [core, beyond[0]] as Array[Vector2i])
		check(not q4["ok"] and int(q4["stop"]) == 1,
			"对照组：核心空了 → 同一条路停在第 2 步")
		g.tile(core)["store"] = 20

	## ⑤ 同源性：报价说的「走完剩」必须等于真走一遍之后账上的数。
	##    这条最要紧 —— 规划器与 collect_special 共用 core_gain()，这里验它们真没分家
	me["energy"] = 100
	var q5: Dictionary = g.actions.quote_path(me, [core] as Array[Vector2i])
	var opts: Array = g.actions.build_options(me)
	var pick := -1
	for j in opts.size():
		var d: Dictionary = opts[j]["data"]
		if d.get("act", "") == "move" and d.get("to", Vector2i.MAX) == core:
			pick = j
			break
	check(pick >= 0, "核心那格在真实选项里找得到")
	if pick >= 0:
		await g.actions.execute(me, opts[pick]["data"])
		check(me["energy"] == int(q5["left"]),
			"真走一遍剩 %s == 报价 %s" % [CWData.fmt(me["energy"]), CWData.fmt(int(q5["left"]))])
		check(int(g.tile(core)["store"]) == 0, "真走一遍之后核心才真的被取空")
	g.dispose()


func t_heur_no_squat_on_fresh() -> void:
	print("[启发式 v4：不蹲在刚铺的格子上]")
	check(CWHeuristicBridge.AI_VERSION == "v11", "AI 版本号 v11（改 AI 行为要升号；v11 = 血管上不蹲固化）")
	var g := _fx_game(2)
	var can := CWSetup.make_cell(0, 0, CWData.Faction.CANCER, Vector2i.ZERO, -1,
		CWData.CancerType.MELANOMA)
	can["energy"] = 60
	g.cells.append(can)
	var h := CWHeuristicBridge.new()
	h.game = g
	var here: Dictionary = g.tile(Vector2i.ZERO)
	## 场上没有任何固化据点、脚下是**本回合刚铺的**癌组织 —— 正是 v3 会蹲下去的局面
	CWTissue.to_cancer(here, true)
	check(g.count_tissue(CWData.Tissue.SOLID) == 0, "场上还没有固化据点（v3 蹲点的触发条件）")
	for protect in [false, true]:
		g.tune.newborn_protect = protect
		check(not h._worth_solidifying(can),
			"刚铺的格子不值得蹲（旋钮 newborn_protect = %s 时同样）" % str(protect))
	## 同一格，不是新生了 → 才值得从头熬一个据点（这是老行为，别一起改没了）
	here["newborn"] = false
	check(h._worth_solidifying(can), "同一格不再是「新生」→ 值得熬据点")
	## 差最后一轮就固化 → 无论如何都值得停。
	## 注意「新生」与「差最后一轮」在真实盘面上互斥：`CWTissue.to_cancer` 会把 solid 清零，
	## 所以刚转成癌组织的格子计数必然是 0，构造不出「又新生又快固化」的格
	here["solid"] = g.tune.solidify_threshold - 1
	check(h._worth_solidifying(can), "差最后一轮就固化 → 停")
	CWTissue.to_cancer(here, true)
	check(here["solid"] == 0, "转成癌组织会清零固化计数 →「新生」与「差最后一轮」不会同时出现")
	## 已经有据点了，且脚下才刚起步 → 不值得再耗两个回合
	here["newborn"] = false
	CWTissue.to_solid(g.tile(Vector2i(3, 0)))
	check(not h._worth_solidifying(can), "已有据点、脚下才起步 → 继续铺，不蹲")
	h.game = null
	g.dispose()


func t_heur_lifecare() -> void:
	print("[启发式：随机分化与惜命]")
	## ① 分化：同局面同答案、不消耗 rng、不同 rng 状态选到不同种类、四种都选得到
	var g := make_game(4, 5)
	await run_setup(g)
	var imm: Dictionary = g.living_cells(CWData.Faction.IMMUNE)[0]
	g.immune_level = 2
	var h: CWHeuristicBridge = g.bridges[imm["pid"]]
	var opts: Array = g.actions.build_options(imm)
	var seen := {}
	var same := true
	var untouched := true
	var st0: int = g.rng.state
	for k in 40:
		g.rng.state = st0 + k * 7919
		var a: int = h._immune_action(imm["pid"], opts)
		var b: int = h._immune_action(imm["pid"], opts)
		same = same and a == b
		untouched = untouched and g.rng.state == st0 + k * 7919
		if opts[a]["data"].get("act", "") == "differentiate":
			seen[opts[a]["data"]["type"]] = true
	g.rng.state = st0
	check(same, "同一局面两次问答案一致")
	check(untouched, "选分化不消耗 rng")
	check(seen.size() == 4, "40 个 rng 状态下四种细胞都被选到过（%d 种）" % seen.size())
	## 退回 v1（按实例）：拿选项列表第一个
	h.set_version("v1")
	var first := -1
	for i in opts.size():
		if opts[i]["data"].get("act", "") == "differentiate":
			first = i
			break
	check(h._immune_action(imm["pid"], opts) == first and h.version_tag() == "v1",
		"set_version(v1) → 拿选项列表第一个、版本标 v1")
	h.set_version("v3")
	check(h.version_tag() == CWHeuristicBridge.AI_VERSION, "拨回当前版本（%s）" % h.version_tag())
	## MC 桥的版本串可带交叉验证用的修饰
	var m := CWMonteCarloBridge.new()
	m.set_version("v3-nodc")
	check(not m.death_cost and m.lifecare and not m.sim_no_lifecare and m.version_tag() == "v3-nodc",
		"v3-nodc：估值不罚死亡、其余照 v3")
	m.set_version("v3-simnolc")
	check(m.death_cost and m.lifecare and m.sim_no_lifecare, "v3-simnolc：只有陪练不惜命")
	m.set_version("v1")
	check(not m.death_cost and not m.lifecare and m.fixed_lineup and m.version_tag() == "v1", "v1：全关")
	g.dispose()
	## ② 免疫惜命：能量 2.0，相邻两格可净化的癌组织 —— A 走进去回合末压迫 1.0、B 压迫 0
	## （A 的六个邻格里五癌一健康 → 1/4 ×（5 − 1）= 1.0；付完迁移费剩的正好不高于它，仍判为活不下去）
	var g2 := bare_game()
	var me := put_immune(g2, Vector2i.ZERO)
	me["energy"] = 20
	var h2 := CWHeuristicBridge.new()
	h2.game = g2
	var a := Vector2i(1, 0)
	var b := Vector2i(-1, 0)
	g2.tiles[a]["tissue"] = CWData.Tissue.CANCER
	g2.tiles[b]["tissue"] = CWData.Tissue.CANCER
	for n in CWData.neighbors(a):
		if n != Vector2i.ZERO:
			g2.tiles[n]["tissue"] = CWData.Tissue.CANCER
	check(g2.world.pressure_at(a) == 10 and g2.world.pressure_at(b) == 0, "场景：A 压迫 1.0、B 压迫 0")
	var pick: int = h2._immune_action(0, g2.actions.build_options(me))
	var pd: Dictionary = g2.actions.build_options(me)[pick]["data"]
	## A 是癌性邻格最多的候选（5 个），旧版必选它；v2 只在活得下去的候选里挑（B 或 A 周围那圈里压迫为 0 的格）
	check(pd.get("act", "") == "move" and pd["to"] != a
		and me["energy"] - int(pd["cost"]) > g2.world.pressure_at(pd["to"]),
		"净化不选会被压死的 A，选活得下去的格（旧版必选 A）：选了 %s" % str(pd))
	h2.set_version("v1")
	pick = h2._immune_action(0, g2.actions.build_options(me))
	check(g2.actions.build_options(me)[pick]["data"].get("to", Vector2i.MAX) == a,
		"退回 v1 → 仍选癌性邻格最多的 A（旧行为可复现，交叉验证的前提）")
	h2.set_version("v2")
	## 脚下本身会被压死 → 先逃到活得下去的格
	## 系数改成 1/4 之后**六面全癌只有 1.5**，压不死 2.0 能量的细胞 —— 场景会空转。
	## 改成三癌三固化：1/4 ×（3 + 3×2）= 2.3 > 2.0，仍是「站着必死」，
	## 而且留了三格普通癌组织当逃生口（六面全固化的话净化不了、无处可逃，验的就不是惜命了）。
	var nb0: Array = CWData.neighbors(Vector2i.ZERO)
	for i in nb0.size():
		g2.tiles[nb0[i]]["tissue"] = CWData.Tissue.SOLID if i >= 3 else CWData.Tissue.CANCER
	check(g2.world.pressure_at(Vector2i.ZERO) == 23, "场景：脚下压迫 2.3 > 全部能量 2.0，站着必死")
	pick = h2._immune_action(0, g2.actions.build_options(me))
	pd = g2.actions.build_options(me)[pick]["data"]
	check(pd.get("act", "") == "move" and me["energy"] - int(pd["cost"]) > g2.world.pressure_at(pd["to"]),
		"先逃生：挪到净化后仍活得下去的格（%s，压迫 %s）" % [str(pd.get("to")), CWData.fmt(g2.world.pressure_at(pd.get("to", Vector2i.ZERO)))])
	h2.game = null
	g2.dispose()
	## ③ 癌方惜命：免疫在 2 格外，能量 3.0 —— 不往免疫身边铺（铺完剩 1.8 < 3.0 储备），往远处铺
	var g3 := bare_game()
	var foe := put_immune(g3, Vector2i(2, 0))
	foe["energy"] = 50
	var can := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i.ZERO, -1,
		CWData.CancerType.MELANOMA)
	can["energy"] = 30
	g3.cells.append(can)
	var h3 := CWHeuristicBridge.new()
	h3.game = g3
	var opts3: Array = g3.actions.build_options(can)
	var p3: int = h3._cancer_action(1, opts3)
	var d3: Dictionary = opts3[p3]["data"]
	check(d3.get("act", "") == "move" and CWData.hex_dist(d3["to"], Vector2i(2, 0)) >= 3,
		"3.0 能量的癌细胞往离免疫 ≥3 格的方向铺，不贴脸花光：选了 %s" % str(d3))
	h3.game = null
	g3.dispose()


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

	## ② 白送的击杀要拿：残血且动弹不得的癌细胞贴脸，免疫只剩**一次行动**的能量。
	## 先打 = 2/3 当场清场；先抽卡 = 这回合再也打不成。评出来的应是攻击那一步。
	## 能量刻意只给 0.6：给 8.0 时「先抽再打」和「先打」只差骰运（代打免疫在推演里
	## 反正会补一刀），旧版断言其实是靠推演偷看到真骰子（5，成功）过的 —— 推演改诚实后
	## 三条 playout 里抽卡那条两次靠后手补刀拿到终局分，攻击反而落选。
	## horizon=0：只看这一步的即时结果。截断只要跨进下一世界回合，免疫 +3.0 收入之后
	## 「下回合再打」在推演里和「现在打」一样好，这一问就分不出高下了。
	var scene: Array = await _free_kill_scene(55, 3, 0)
	var g2: CWGame = scene[0]
	var mc2: CWMonteCarloBridge = scene[1]
	req = scene[2]
	var pick: int = await mc2.ask(req)
	var pd: Dictionary = req["options"][pick]["data"]
	check(_is_free_kill(pd), "残血癌细胞贴脸、只剩一次行动 → 蒙特卡洛选择攻击（选了 %s）" % str(pd))
	g2.dispose()

	## ④ 推演不许偷看真骰子（2026-09-01）。同一场景，先把真 rng 烧到「下一颗 d6 必是失败面」
	## 再让 rollouts=1 的 MC 决策：偷看真状态的旧实现看到的永远是失败，8 个种子里 **0** 次去打；
	## 诚实的 MC 只按自己那条派生流抽样，约 2/3 会去打。
	## horizon=2 是实测最能分开两者的档：horizon=0 时「打失败=自己死」在估值里反而不吃亏
	## （复活免费、还免了离战线的罚分），旧实现在 0 步下也会 8/8 去打，分不出来。
	var real_fail_attacks := 0
	for s in 8:
		var sc: Array = await _free_kill_scene(100 + s, 1, 2)
		var g4: CWGame = sc[0]
		var mc4: CWMonteCarloBridge = sc[1]
		var rq4: Dictionary = sc[2]
		while true:
			var st: int = g4.rng.state
			var v := g4.rng.randi_range(1, 6)
			if g4.actions.base_verdict(v) == "fail":
				g4.rng.state = st
				break
		var p4: int = await mc4.ask(rq4)
		if _is_free_kill(rq4["options"][p4]["data"]):
			real_fail_attacks += 1
		g4.dispose()
	check(real_fail_attacks >= 4,
		"真骰子必失败的 8 个局面里，诚实 MC 仍去打了 %d 次（偷看真状态的实现为 0 次）" % real_fail_attacks)

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


## ---- MC 确定性工作量预算：不以墙钟截断，且统计不允许外部改写 ----
func t_mc_budget() -> void:
	print("[AI·MC 确定性预算]")
	var g := make_game(2, 20260902)
	var pid := _immune_pid(g)
	var mc := CWMonteCarloBridge.new()
	mc.game = g
	mc.rollouts = 2
	mc.horizon = 12
	mc.max_sim_steps = 3
	g.bridges[pid] = mc
	var req := await _to_action_for_test(g, pid)
	var h := g.state_hash()
	var first: int = await mc.ask(req)
	var stat := mc.last_stats
	check(stat["sim_steps"] == 3 and stat["budget_exhausted"] and stat["snapshots"] == 1
		and stat["restores"] == stat["rollouts"], "3 步预算严格截断 rollout，且记录快照/恢复数")
	stat["sim_steps"] = -1
	check(mc.last_stats["sim_steps"] == 3, "last_stats 返回副本，调用方不能改写桥内记录")
	var second: int = await mc.ask(req)
	check(first == second and g.state_hash() == h, "固定种子与固定步数预算：答案稳定且不污染主线")
	mc.max_sim_steps = 0
	await mc.ask(req)
	check(not mc.last_stats["budget_exhausted"] and mc.last_stats["sim_steps"] > 3,
		"预算 0 保持旧版无限工作量语义")
	g.dispose()
	## 2/4/6 人浅层冒烟：同一固定种子重复决策，选择与统计均一致。
	for n in [2, 4, 6]:
		var picks: Array[int] = []
		var steps: Array[int] = []
		for repeat in 2:
			var smoke := make_game(n, 7000 + n)
			var smoke_pid := _immune_pid(smoke)
			var shallow := CWMonteCarloBridge.new()
			shallow.game = smoke
			shallow.rollouts = 1
			shallow.horizon = 2
			shallow.max_sim_steps = 24
			smoke.bridges[smoke_pid] = shallow
			var smoke_req := await _to_action_for_test(smoke, smoke_pid)
			picks.append(await shallow.ask(smoke_req))
			steps.append(shallow.last_stats["sim_steps"])
			smoke.dispose()
		check(picks[0] == picks[1] and steps[0] == steps[1] and steps[0] <= 24,
			"%d 人浅层 MC 冒烟：固定种子选择/步数一致（%d 步）" % [n, steps[0]])


# ---- AI·独立 MCTS（树搜索）：零污染、确定性、树能分叉回落、预算截断、白送击杀要拿 ----
func t_ai_mcts() -> void:
	print("[AI·独立 MCTS]")
	## ① 主线零污染 + 同局面同答案
	var g := make_game(2, 33)
	var ip := _immune_pid(g)
	var mc := CWMCTSBridge.new()
	mc.game = g
	mc.iterations = 6
	mc.horizon = 4
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
	check(g.state_hash() == h0, "MCTS 评估完主线状态逐位不变")
	check(g.logs.size() == n0, "MCTS 推演没有留下日志")
	check(not g.sim_quiet, "评估完静音已关（真日志照常记录）")
	var a2: int = await mc.ask(req)
	check(a1 == a2, "同局面两次评估答案一致（确定性）")
	g.dispose()

	## ② 白送的击杀要拿：残血癌细胞贴脸、免疫只剩**一次行动**的能量（同扁平 MC 的场景口径）
	var scene: Array = await _free_kill_scene(55, 1, 2)   ## rollouts/horizon 参数在共享helper里；这里只取 game/req
	var g2: CWGame = scene[0]
	## _free_kill_scene 造的是扁平 MC 桥；就地换一个 MCTS 桥再评估
	var mc2 := CWMCTSBridge.new()
	mc2.game = g2
	mc2.iterations = 30
	mc2.horizon = 6
	g2.bridges[_immune_pid(g2)] = mc2
	var pick: int = await mc2.ask(scene[2])
	var pd: Dictionary = scene[2]["options"][pick]["data"]
	check(_is_free_kill(pd), "残血癌细胞贴脸、只剩一次行动 → MCTS 选择攻击（选了 %s）" % str(pd))
	g2.dispose()

	## ③ UCT 会复用已建分支：多次迭代统计出节点与访问，且高迭代下不退化
	var g3 := make_game(2, 900)
	var ip3 := _immune_pid(g3)
	var mc3 := CWMCTSBridge.new()
	mc3.game = g3
	mc3.iterations = 20
	mc3.horizon = 8
	g3.bridges[ip3] = mc3
	await run_setup(g3)
	var r3: Dictionary = {}
	while true:
		r3 = await g3.pending()
		if r3.is_empty() or (r3["kind"] == "action" and r3["pid"] == ip3):
			break
		await g3.step(await g3.ask(r3["pid"], r3))
	await mc3.ask(r3)
	var st3 := mc3.last_stats
	check(int(st3["iterations"]) == 20, "统计记录迭代预算")
	check(int(st3["nodes"]) <= int(st3["rollouts"]) and int(st3["nodes"]) >= 1,
		"树里建过至少一个动作节点（%d 节点 / %d rollout）" % [int(st3["nodes"]), int(st3["rollouts"])])
	g3.dispose()

	## ④ 预算按 step 截断：固定种子 + max_sim_steps 下答案/步数稳定，且不污染主线
	var g4 := make_game(2, 20260907)
	var ip4 := _immune_pid(g4)
	var mc4 := CWMCTSBridge.new()
	mc4.game = g4
	mc4.iterations = 50
	mc4.horizon = 12
	mc4.max_sim_steps = 5
	g4.bridges[ip4] = mc4
	var r4 := await _to_action_for_test(g4, ip4)
	var h4 := g4.state_hash()
	var first: int = await mc4.ask(r4)
	var s4 := mc4.last_stats
	check(int(s4["sim_steps"]) == 5 and bool(s4["budget_exhausted"]),
		"5 步预算严格截断树搜索（实际 %d 步）" % int(s4["sim_steps"]))
	var second: int = await mc4.ask(r4)
	check(first == second and g4.state_hash() == h4,
		"固定种子与固定步数预算：答案稳定且不污染主线")
	mc4.max_sim_steps = 0
	await mc4.ask(r4)
	check(not mc4.last_stats["budget_exhausted"] and int(mc4.last_stats["sim_steps"]) > 5,
		"预算 0 保持旧版无限工作量语义")
	g4.dispose()

	## ⑤ 2/4/6 人浅层冒烟：同一固定种子重复决策，选择与统计均一致
	for n in [2, 4, 6]:
		var picks: Array[int] = []
		var nodes: Array[int] = []
		for repeat in 2:
			var smoke := make_game(n, 8000 + n)
			var smoke_pid := _immune_pid(smoke)
			var shallow := CWMCTSBridge.new()
			shallow.game = smoke
			shallow.iterations = 5
			shallow.horizon = 2
			shallow.max_sim_steps = 30
			smoke.bridges[smoke_pid] = shallow
			var smoke_req := await _to_action_for_test(smoke, smoke_pid)
			picks.append(await shallow.ask(smoke_req))
			nodes.append(int(shallow.last_stats["sim_steps"]))
			smoke.dispose()
		check(picks[0] == picks[1] and nodes[0] == nodes[1] and nodes[0] <= 30,
			"%d 人浅层 MCTS 冒烟：固定种子选择/步数一致（%d 步）" % [n, nodes[0]])

	## ⑥ 副线程路径与同步路径逐位一致（较强 AI 人机对局用它，见 match.gd）
	var g5 := make_game(2, 20260707)
	var ip5 := _immune_pid(g5)
	var mc_sync := CWMCTSBridge.new()
	mc_sync.game = g5
	mc_sync.iterations = 5
	mc_sync.horizon = 3
	g5.bridges[ip5] = mc_sync
	var r5 := await _to_action_for_test(g5, ip5)
	var s_pick: int = await mc_sync.ask(r5)
	var s_stats := mc_sync.last_stats
	g5.dispose()

	var g6 := make_game(2, 20260707)
	var ip6 := _immune_pid(g6)
	var mc_thr := CWMCTSBridge.new()
	mc_thr.game = g6
	mc_thr.iterations = 5
	mc_thr.horizon = 3
	mc_thr.use_threading = true
	g6.bridges[ip6] = mc_thr
	var r6 := await _to_action_for_test(g6, ip6)
	var t_pick: int = await mc_thr.ask(r6)
	var t_stats := mc_thr.last_stats
	check(s_pick == t_pick and s_stats == t_stats,
		"副线程与同步路径选择一致")
	g6.dispose()


func _to_action_for_test(g: CWGame, pid: int) -> Dictionary:
	while true:
		var req: Dictionary = await g.pending()
		if req.is_empty() or (req["kind"] == "action" and req["pid"] == pid):
			return req
		await g.step(await g.ask(req["pid"], req))
	return {}


# ---- 对局配置面板：默认值 / 拨值 / 座位规则 / AI 强度接线 ----
func t_config_panel() -> void:
	print("[对局配置面板]")
	## 配置页和设置页共用的点击底座：保留命中、手型与左键回调，页面自己仍管理焦点。
	var click_host := Control.new()
	root.add_child(click_host)
	var taps := [0]  ## 闭包按值捕获标量；数组让回调与断言共享同一可变槽。
	var clicky := CWStyle.clickable_label(click_host, "<", Vector2(12, 18),
		func() -> void: taps[0] += 1)
	var mouse := InputEventMouseButton.new()
	mouse.button_index = MOUSE_BUTTON_LEFT
	mouse.pressed = true
	clicky.gui_input.emit(mouse)
	check(clicky.position == Vector2(12, 18), "CWStyle.clickable_label 保留文字位置")
	check(clicky.mouse_filter == Control.MOUSE_FILTER_STOP, "CWStyle.clickable_label 拦截点击命中")
	check(clicky.mouse_default_cursor_shape == Control.CURSOR_POINTING_HAND,
		"CWStyle.clickable_label 保留手型光标")
	check(taps[0] == 1, "CWStyle.clickable_label 保留左键回调")
	root.remove_child(click_host)
	click_host.free()

	var p := CWConfigPanel.new()
	root.add_child(p)
	await process_frame   ## _ready（面板搭建）在入树后的下一帧才跑
	var cfg := p.config()
	check(cfg["players"] == 4 and cfg["faction"] == CWData.Faction.IMMUNE \
		and cfg["ai"] == CWMatch.AI_NORMAL, "默认配置：4 人 · 免疫细胞 · 普通 AI")
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
	## 步数 = 左栏行数（从第一行走到按钮）。**别写死** —— 加一行就会红
	for i in CWConfigPanel.N_ROWS:
		p.handle_input(down)   ## 一路走到「进入棋盘」
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
	check(p.config()["ai"] == CWMatch.AI_MC, "AI 强度 → 较强")
	p._cycle(CWConfigPanel.ROW_SMART, 1)
	check(p.config()["ai"] == CWMatch.AI_MCTS, "再拨一格 → 树搜索（第三档，2026-09-07）")
	p._cycle(CWConfigPanel.ROW_SMART, 1)
	check(p.config()["ai"] == CWMatch.AI_NORMAL, "三档循环，拨回普通")
	p._cycle(CWConfigPanel.ROW_SMART, -1)
	check(p.config()["ai"] == CWMatch.AI_MCTS, "反向拨同样绕回来")
	## 同上：从「AI 强度」走到「随机种子」的步数由常量推
	for _i in CWConfigPanel.ROW_SEED - CWConfigPanel.ROW_SMART:
		p.handle_input(down)
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
	check(p.config()["players"] == 2 and p.config()["ai"] == CWMatch.AI_MCTS \
		and p.config()["faction"] == -1, "再次打开保留上次取值")
	## 箭头定位固定；按钮变白按「最后动的设备」裁决（Kevin 8-30 终稿）：
	## 键盘选到按钮=白；鼠标一旦介入按悬停算，直到下一次键盘按键夺回
	## 「返回主菜单」链接（2026-09-04 Kevin：两种配置页都要有鼠标出口，同联机连接页）
	var back: Label = p._back
	check(back != null and back.text == "返回主菜单", "配置页有「返回主菜单」链接")
	check(is_equal_approx(back.position.y, p._btn_y() + 5)
		and back.position.x > CWConfigPanel.SLOT_X + CWConfigPanel.BTN_W,
		"链接在「进入棋盘」按钮右侧、同一行")
	var before := cancels.size()
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	back.gui_input.emit(click)
	check(not p.visible and cancels.size() == before + 1, "点链接：收面板并发 cancelled（同 Esc）")
	p.open()
	check(p._arrows[0][1].position.x == CWConfigPanel.ARROW_R_X, "右箭头在固定位置")
	p.handle_input(right)   ## 换一档，值文案长度变了
	check(p._arrows[0][1].position.x == CWConfigPanel.ARROW_R_X, "换档后右箭头不挪窝")
	for k in CWConfigPanel.N_ROWS:
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


## 迁移耗能的接线：桥把引擎算好的 cost 抄进 move_costs，退出时清空。
func _t_move_cost_wiring() -> void:
	var board := make_board()
	root.add_child(board)
	var bar := CWActionBar.new()
	root.add_child(bar)
	var g := CWGame.new()
	g.init(CWData.FACTION_ORDER[2], 3)
	var b := CWUIBridge.new()
	b.game = g
	b.board = board
	b.bar = bar
	b.human_pids = [0]
	var cell := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i.ZERO,
		CWData.ImmuneType.BASIC, -1)
	g.cells.append(cell)

	check(b.move_costs.is_empty(), "没进迁移态时价目表是空的")
	var opts: Array = [
		{ "label": "", "data": { "act": "move", "to": Vector2i(1, 0), "cost": 5 } },
		{ "label": "", "data": { "act": "move", "to": Vector2i(0, 1), "cost": 17 } },
	]
	var done := [false]
	var run := func() -> void:
		await b._pick_move(cell, opts, [0, 1])
		done[0] = true
	run.call()
	await process_frame
	check(b.move_costs == { Vector2i(1, 0): 5, Vector2i(0, 1): 17 },
		"价目表逐格抄自引擎的 cost（%s）" % str(b.move_costs))
	check(b.move_verb == "迁移", "免疫用「迁移」（%s）" % b.move_verb)
	## 2026-09-04 起 0 号是「规划路径」，「结束迁移」永远是最后一枚
	bar.chosen.emit(_buttons(bar) - 1)      ## 「结束迁移」
	await process_frame
	check(done[0] and b.move_costs.is_empty(),
		"退出迁移后价目表清空（否则悬停会显示上一轮的旧价钱）")
	g.dispose()
	bar.free()
	board.free()


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
	## **写死人读的字面，不要拿常量插值**：拿常量插值等于把实现的格式化方式抄一遍，
	## 实现打成「15 / 30」时期望串也跟着变成「15 / 30」，两边一起错、测试照样绿
	## （2026-09-01 队友截图报的就是这个）。固化计数是十分整数，1.5 点存成 15
	check(all.contains("癌组织") and all.contains("固化 0.2 / 2.0"),
		"详情：组织与固化进度按小数显示，不是原始的十分整数")
	check(all.contains("代谢核心 · 储量 1.0"), "详情：核心储量")
	check(all.contains("恶性黑色素瘤") and all.contains("能量 3.8") and all.contains("标记 ×1"),
		"详情：占据者、能量与标记")
	check(CWTileInfo.describe(g, Vector2i(0, 0)).size() == 1, "健康空格只有一行")

	## 迁移耗能行（团队 2026-09-01 要的）：不在迁移态时不出，在迁移态时紧跟组织名。
	## 规则里免疫叫「迁移」、癌症叫「移动」，是两个词，这一行也得跟着分
	var empty_tile := Vector2i(0, 0)
	check(CWTileInfo.describe(g, empty_tile, -1, "迁移").size() == 1,
		"不在迁移态（cost < 0）→ 不出耗能行")
	var with_cost := CWTileInfo.describe(g, empty_tile, 5, "迁移")
	## ⚠ 这里**不**断言 rows.size() —— 第一版写死了 == 2，2026-09-01 加压迫行时当场变红。
	## 断言要钉的是「耗能行紧跟组织名」这个**意图**，不是当时恰好有几行。
	check(with_cost[1]["text"] == "迁移耗能 0.5",
		"迁移态：耗能行紧跟组织名（%s）" % with_cost[1]["text"])

	## ---- 微环境压迫行（2026-09-01）----
	## 五局手打死了 6 次、4 次栽在没算这一刀上，而它完全算得出。这几条钉三件事：
	## ① 只在「正在为这一格做决定」时出；② 数值与引擎同源；③ 措辞是「至少」不是精确值。
	var pg := _fx_game(2)
	var mid := Vector2i(0, 0)
	var nbs: Array = CWData.neighbors(mid)
	var me := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, mid,
		CWData.ImmuneType.BASIC, -1)
	pg.cells.append(me)
	var far := Vector2i(5, 0)          ## 既不是迁移候选、也没人站
	check(CWTileInfo.describe(pg, far, -1, "迁移").size() == 1,
		"压迫行：不是候选格、也没有免疫细胞 → 不出")
	var here0: Array = CWTileInfo.describe(pg, mid, -1, "迁移")
	check(str(here0).contains("回合末压迫 无"),
		"压迫行：站着免疫细胞就出，哪怕不在迁移态；相邻 0 格癌 → 无")
	## 加权式（PRD 2026-09-08）：max(0, 癌 + 固化×2 − 健康) × 0.5。
	## **三癌三健康 = 不掉能量**是这条新式最要紧的性质 —— 站在战线上不再挨刀，
	## 深入癌区才急剧变贵。旧式在同样盘面是 0.5，这一条正是改动的意义所在。
	for i in 3:
		pg.tiles[nbs[i]]["tissue"] = CWData.Tissue.CANCER
	check(str(CWTileInfo.describe(pg, mid, -1, "迁移")).contains("回合末压迫 无"),
		"压迫行：三癌三健康 → 抵消掉，不掉能量")
	pg.tiles[nbs[3]]["tissue"] = CWData.Tissue.CANCER
	check(str(CWTileInfo.describe(pg, mid, -1, "迁移")).contains("至少 0.5"),
		"压迫行：四癌两健康 → 1/4 ×（4−2）= 0.5")
	for i in range(4, 6):
		pg.tiles[nbs[i]]["tissue"] = CWData.Tissue.CANCER
	check(str(CWTileInfo.describe(pg, mid, -1, "迁移")).contains("至少 1.5"),
		"压迫行：六面癌组织 → 1/4 × 6 = 1.5")
	## 固化权重翻倍：同样六面、全换成固化 → 12 × 0.5 = 6.0（新式的真上限）
	for i in 6:
		pg.tiles[nbs[i]]["tissue"] = CWData.Tissue.SOLID
	check(str(CWTileInfo.describe(pg, mid, -1, "迁移")).contains("至少 3.0"),
		"压迫行：六面固化 → 1/4 × 12 = 3.0（上限，固化权重 ×2）")
	for i in 6:
		pg.tiles[nbs[i]]["tissue"] = CWData.Tissue.CANCER
	## **同源性**：界面显示的数必须等于 E 阶段真正扣掉的数。
	## 这一条是这组断言里最重要的 —— 界面抄第二份算式正是本项目反复栽的坑。
	me["energy"] = 100
	pg.world._pressure()
	check(100 - me["energy"] == pg.world.pressure_at(mid),
		"压迫行：界面读的 pressure_at() 与 E 阶段实际扣的是同一个数")
	## 迁移候选格（还没站人）也要出 —— 这才是「移过去会挨多少」的那一问
	var cand: Vector2i = nbs[0]
	pg.tiles[cand]["tissue"] = CWData.Tissue.HEALTHY
	check(str(CWTileInfo.describe(pg, cand, 5, "迁移")).contains("回合末压迫"),
		"压迫行：迁移候选格也出（这才是「移过去会挨多少」）")
	check(not str(CWTileInfo.describe(pg, cand, 12, "移动")).contains("压迫"),
		"压迫行：癌方的移动候选格不出 —— 压迫只扣免疫细胞（2026-09-03 Kevin 截图）")
	check(str(CWTileInfo.describe(pg, mid, 12, "移动")).contains("回合末压迫"),
		"压迫行：癌方选目标时若那格站着免疫细胞，仍然出（说的是那个免疫细胞会挨多少）")
	check(CWTileInfo.describe(g, empty_tile, 10, "移动")[1]["text"] == "移动耗能 1.0",
		"癌方用「移动」不用「迁移」")
	check(with_cost[1]["color"] == CWStyle.IMMUNE,
		"耗能行用高亮色，和格子高亮同一个青")
	## 0 也要显示 —— 免费迁移是【趋化募集】那类技能的效果，正是玩家最想确认的一格
	check(CWTileInfo.describe(g, empty_tile, 0, "迁移")[1]["text"] == "迁移耗能 0.0",
		"耗能 0 也要显示（免费迁移是技能效果，不是「没有数据」）")
	## 加了一行之后宽度得跟着撑开，别把字压到框外（试玩第一轮出过这个框）
	check(CWTileInfo.width_for(with_cost) >= 208.0, "有耗能行时宽度仍不小于最小宽")

	## 接线：价目表由 _pick_move 从**引擎算好的选项**里抄，退出迁移要清干净。
	## 纯函数测得再全，这一段坏了照样什么都不显示 / 显示上一轮的旧价钱
	await _t_move_cost_wiring()

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


# ---- 悬停层级：最上面的图层说了算（Kevin 2026-09-06 截图：固定态技能框的详情和底下那一格的详情叠在一起）----
##
## 指针停在界面控件上时，STOP / PASS 过滤会把鼠标事件标成已处理，棋盘的 _unhandled_input 收不到
## 「移出了格子」，hovered 就停在进控件前的最后一格。修法是棋盘每帧问一下「指针是不是被控件占着」。
## 无头视口不跟踪悬停控件（喂事件也不更新，探过），所以那一问做成可替换的 Callable，这里直接换掉验流程；
## 真机那一段靠 tests/screenshot.gd 的 `move:` 步骤看图。
func t_hover_layer() -> void:
	print("[悬停层级]")
	var board := make_board()
	root.add_child(board)   ## make_input_local 要在树里才能算
	var got: Array = []
	board.tile_hovered.connect(func(c: Vector2i) -> void: got.append(c))
	var here := Vector2i.ZERO
	var mv := InputEventMouseMotion.new()
	mv.position = board.tile_center(here)
	mv.global_position = mv.position
	var default_check: Callable = board.pointer_on_control
	check(not default_check.call(), "默认那一问对着视口：无头下没有悬停控件 → false，不炸")
	## 详情框必须压在出牌列 / 日志面板上面：装配时它们都「插到 _tile_info 的位置」，
	## 后插的反而更靠上，_card_info 是第一个插的（Kevin 2026-09-07 报的重叠就是这么来的）。
	## 走真场景：CWMatch 光 new() 出来没有 ui 容器，装配整段都不会跑。
	var lscene: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(lscene)
	await process_frame
	var lm: CWMatch = lscene.match_node
	lm.start()
	await process_frame
	check(lm._card_info.get_index() > lm._feed.get_index()
		and lm._card_info.get_index() > lm._log_panel.get_index(),
		"卡面详情压在出牌列与日志面板之上（详情 %d / 出牌列 %d / 日志 %d）"
		% [lm._card_info.get_index(), lm._feed.get_index(), lm._log_panel.get_index()])
	check(lm._tile_info.get_index() > lm._feed.get_index(), "格子详情同样压在出牌列之上")
	lm.teardown()
	lscene.queue_free()
	await process_frame

	board._unhandled_input(mv)
	check(board.hovered == here and got == [here], "指针停在格上：报那一格")
	board._process(0.0)
	check(board.hovered == here and got.size() == 1, "没被控件占着：每帧问一下不改变什么")
	## 指针被控件占着：立刻当「没停在任何格上」，报一次 NO_TILE（格子详情随之收起），之后不重复报
	board.pointer_on_control = func() -> bool: return true
	board._process(0.0)
	board._process(0.0)
	check(board.hovered == board.NO_TILE and got.size() == 2 and got[1] == board.NO_TILE,
		"指针被控件占着：清掉悬停格、只报一次 NO_TILE")
	## 回到棋盘：下一次移动重新报格（格子详情从头计时，和平时移进一格一样）
	board.pointer_on_control = func() -> bool: return false
	board._unhandled_input(mv)
	check(got.size() == 3 and got[2] == here, "指针回到棋盘：下一次移动重新报那一格")
	root.remove_child(board)
	board.free()

	## 右栏技能框：固定态整块底板也收鼠标（指针在框内任何位置都算「被控件占着」），不固定时照旧放行
	var g := _fx_game(2)
	g.cells.append(CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(5, 0),
		CWData.ImmuneType.BASIC, -1))
	var can := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(0, 0), -1, CWData.CancerType.MELANOMA)
	g.cells.append(can)
	var panel := CWMatchPanel.new()
	root.add_child(panel)
	await process_frame
	panel.refresh(g)     ## 第一遍先按人数把行建出来
	panel._tip_pinned = 1
	panel.refresh(g)
	check(panel._tip != null and panel._tip.visible, "固定态：浮出全套技能框")
	check(panel._tip.get_child(0).mouse_filter == Control.MOUSE_FILTER_STOP,
		"固定态底板 STOP：框内空白处也不漏给棋盘")
	panel._tip_pinned = -1
	panel._tip_pid = 1
	can["equipped"] = ["组织驻留"]
	panel.refresh(g)
	check(panel._tip.visible and panel._tip.get_child(0).mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"不固定：底板照旧放行（框随指针离开玩家行而收起，挡事件会变成「移不开」）")
	panel.reset()
	root.remove_child(panel)
	panel.free()
	g.dispose()


## 骨肉瘤【骨样硬化】标记格的脉冲色标（Kevin 2026-09-07 要的显示效果）。
## 色标本身是纯函数，喂固定毫秒就能核对，不必真跑一帧。
## 趋化源最后一回合的闪烁警告（Kevin 2026-09-07：颜色不许变，改成闪）。
func t_chemo_blink() -> void:
	print("[趋化源闪烁]")
	## 一拍 = 1/HZ（floor(t*HZ)%2 每过一拍翻一次，整周期是两拍）
	var beat: float = 1.0 / CWChemoFx.BLINK_HZ
	check(is_equal_approx(CWChemoFx.blink_alpha(0.0, false), 1.0)
		and is_equal_approx(CWChemoFx.blink_alpha(beat, false), 1.0),
		"不是最后一回合：一直全亮，不闪")
	check(is_equal_approx(CWChemoFx.blink_alpha(0.0, true), 1.0)
		and is_equal_approx(CWChemoFx.blink_alpha(beat, true), CWChemoFx.BLINK_DIM),
		"最后一回合：亮半拍、暗半拍")
	check(is_equal_approx(CWChemoFx.blink_alpha(beat * 2.0, true), 1.0), "下一拍又亮回来")
	check(not ("COLOR_LAST" in CWChemoFx.new().get_property_list().reduce(
		func(a: String, p: Dictionary) -> String: return a + String(p["name"]), "")),
		"暖橙那档颜色已经拿掉（警告只靠闪烁，颜色仍是免疫青）")


func t_ossify_mark() -> void:
	print("[骨样硬化色标]")
	var lo: float = CWMatch.OSSIFY_ALPHA.x
	var hi: float = CWMatch.OSSIFY_ALPHA.y
	var half_ms: int = int(500.0 / CWMatch.OSSIFY_HZ)   ## 慢档半个周期
	var a0 := CWMatch.ossify_mark(5, 1, 0)
	var a1 := CWMatch.ossify_mark(5, 1, half_ms)
	check(not is_equal_approx(a0.a, a1.a), "脉冲真的在动（%.3f → %.3f）" % [a0.a, a1.a])
	var in_range := true
	for ms in [0, 137, 250, 400, 613, 900]:
		var a := CWMatch.ossify_mark(5, 1, ms).a
		if a < lo - 0.001 or a > hi + 0.001:
			in_range = false
	check(in_range, "透明度始终落在 %.2f~%.2f 之间" % [lo, hi])
	check(CWMatch.ossify_mark(5, 1, 0).is_equal_approx(CWMatch.ossify_mark(5, 1, 0)),
		"同一时刻同一格 → 同一个色（纯函数）")
	## 只剩一个世界回合时脉冲翻倍：同一毫秒下两档相位已经错开
	check(not is_equal_approx(CWMatch.ossify_mark(5, 1, half_ms / 2).a,
		CWMatch.ossify_mark(2, 1, half_ms / 2).a), "最后一回合脉冲更快")
	## 这里原本还有一条：`MARK_OSSIFY != MARK_SOLID`（骨样硬化的脉冲别和固化格的压暗撞色）。
	## `MARK_SOLID` 2026-09-09 随石化贴图上线删了 —— 固化格现在有自己的贴图，
	## 不再往标记层放色标，这条断言没有了对照物。


## 【效应应答】四个 + 树突【E-组织黏连】（PRD 一直写着，引擎 2026-09-07 才实装）。
## 门槛（X 级 / 已分化 / 每细胞每局 1 次 / 免疫方每世界回合 1 次 / 15 效应记忆）钉在第一段，
## 四个效果各钉一段。
func t_effector_responses() -> void:
	print("[效应应答]")

	## ---- ① X 级：抗原记忆改名【效应记忆】并从零重数 ----
	var g0 := bare_game()
	g0.memory = CWData.LEVEL_MIN_MEMORY[3] - 1
	g0.gain_memory(1)
	check(g0.immune_level == 3 and g0.memory == 0,
		"升到 X 级：抗原记忆升级为效应记忆、就地清零（%d）" % g0.memory)
	g0.dispose()

	## ---- ② 发动门槛 ----
	var g := _fx_game(2)
	var bc := CWSetup.make_cell(g.cells.size(), 0, CWData.Faction.IMMUNE, Vector2i.ZERO,
		CWData.ImmuneType.B_CELL, -1, 100)
	g.cells.append(bc)
	g.memory = 100
	check(not g.can_effector(bc), "III 级以下发动不了")
	g.immune_level = 3
	g.memory = CWData.EFFECTOR_COST - 1
	check(not g.can_effector(bc), "效应记忆不够发动不了")
	g.memory = CWData.EFFECTOR_COST
	check(g.can_effector(bc), "X 级 + 已分化 + 够 15 效应记忆 → 可以发动")
	var basic := CWSetup.make_cell(g.cells.size(), 0, CWData.Faction.IMMUNE, Vector2i(0, 2),
		CWData.ImmuneType.BASIC, -1, 100)
	g.cells.append(basic)
	check(not g.can_effector(basic), "未分化的免疫细胞不能发动")
	bc["effector_used"] = true
	check(not g.can_effector(bc), "每个细胞每局只有 1 次")
	bc["effector_used"] = false
	g.effector_round = g.round_no
	check(not g.can_effector(bc), "免疫方每个世界回合只有 1 次")
	g.dispose()

	## ---- ③ 中和抗体：与健康组织相邻的癌细胞，种类技能与永久卡当前回合和下一回合失效 ----
	var pack := _choice_game()
	g = pack[0]
	var b: CWScriptBridge = pack[1]
	g.immune_level = 3
	g.memory = 100
	var bb := CWSetup.make_cell(g.cells.size(), 0, CWData.Faction.IMMUNE, Vector2i.ZERO,
		CWData.ImmuneType.B_CELL, -1, 100)
	g.cells.append(bb)
	var sclc := CWSetup.make_cell(g.cells.size(), 1, CWData.Faction.CANCER, Vector2i(3, 0),
		-1, CWData.CancerType.SCLC, 100)
	sclc["equipped"] = ["GLUT1高表达"]
	g.cells.append(sclc)
	g.tiles[Vector2i(3, 0)]["tissue"] = CWData.Tissue.CANCER
	check(g.type_ability_on(sclc) and g.has_skill(sclc, "GLUT1高表达"), "中和之前：种类技能与永久卡都在")
	await g.actions._do_effector(bb)
	check(g.memory == 100 - CWData.EFFECTOR_COST, "扣 15 效应记忆（余 %d）" % g.memory)
	check(not g.type_ability_on(sclc), "被中和：种类特殊效果失效")
	check(not g.has_skill(sclc, "GLUT1高表达"), "被中和：永久卡牌效果一并失效")
	## **2026-09-08 云端修订版缩短成「持续 1 世界回合」**（= 只到本回合末，通用规则 3）。
	## 原来是「当前回合与下一回合」，那时下一回合仍失效、再下一回合才恢复。
	g.round_no += 1
	check(g.type_ability_on(sclc), "下一个世界回合就恢复了（持续 1 世界回合 = 只到本回合末）")
	g.dispose()

	## ---- ④ 免疫猎杀：标记 + 追踪趋化源；死了源留在死亡格 ----
	pack = _choice_game()
	g = pack[0]
	b = pack[1]
	g.immune_level = 3
	g.memory = 100
	var dc := CWSetup.make_cell(g.cells.size(), 0, CWData.Faction.IMMUNE, Vector2i.ZERO,
		CWData.ImmuneType.DENDRITIC, -1, 100)
	g.cells.append(dc)
	var prey := CWSetup.make_cell(g.cells.size(), 1, CWData.Faction.CANCER, Vector2i(5, 0),
		-1, CWData.CancerType.SCLC, 100)
	g.cells.append(prey)
	b.answers = [_pick_by("cid", prey["id"])]
	await g.actions._do_effector(dc)
	check(prey["marked"], "猎杀目标获得【标记】")
	check(int(g.chemo_track.get("cid", -1)) == int(prey["id"])
		and g.chemo_track_at() == prey["pos"], "附上【追踪趋化源】，位置现读那个细胞")
	prey["pos"] = Vector2i(4, 0)
	check(g.chemo_track_at() == Vector2i(4, 0), "它走到哪儿源跟到哪儿")
	g.kill(prey)
	check(g.chemo_track_at() == Vector2i(4, 0) and int(g.chemo_track["cid"]) == -1,
		"死亡后源留在死亡格、不再跟随")
	for i in CWData.HUNT_CHEMO_ROUNDS:
		g.world._tick_chemo_track()
	check(g.chemo_track.is_empty(), "持续 %d 个世界回合后消散" % CWData.HUNT_CHEMO_ROUNDS)
	g.dispose()

	## ---- ⑤ Excalibur：主射线转健康 + 坏死，固化不动；射线 -2.0、侧向 -1.0 ----
	pack = _choice_game()
	g = pack[0]
	b = pack[1]
	g.immune_level = 3
	g.memory = 100
	var tc := CWSetup.make_cell(g.cells.size(), 0, CWData.Faction.IMMUNE, Vector2i.ZERO,
		CWData.ImmuneType.T_CELL, -1, 100)
	g.cells.append(tc)
	var dir: Vector2i = CWData.DIRS[0]
	var on_ray: Vector2i = dir * 2
	g.tiles[on_ray]["tissue"] = CWData.Tissue.CANCER
	var solid_at: Vector2i = dir * 3
	g.tiles[solid_at]["tissue"] = CWData.Tissue.SOLID
	var victim := CWSetup.make_cell(g.cells.size(), 1, CWData.Faction.CANCER, on_ray,
		-1, CWData.CancerType.SCLC, 500)
	g.cells.append(victim)
	b.answers = [_pick_by("dir", 0)]
	await g.actions._do_effector(tc)
	check(g.tiles[on_ray]["tissue"] == CWData.Tissue.HEALTHY
		and g.tiles[on_ray]["necrosis"] > 0, "主射线上的癌组织转健康并进入坏死")
	check(g.tiles[solid_at]["tissue"] == CWData.Tissue.SOLID, "固化癌组织不被转化")
	check(victim["energy"] == 500 - CWData.EXCALIBUR_RAY_DMG,
		"主射线上的癌细胞 -%s" % CWData.fmt(CWData.EXCALIBUR_RAY_DMG))
	g.dispose()

	## ---- ⑥ E-组织黏连：传染两格内，且本阶段的感染不连锁 ----
	g = bare_game()
	var den := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i.ZERO,
		CWData.ImmuneType.DENDRITIC, -1, 150)
	g.cells.append(den)
	var near := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(2, 0), -1, CWData.CancerType.SCLC, 100)
	var mid := CWSetup.make_cell(2, 1, CWData.Faction.CANCER, Vector2i(4, 0), -1, CWData.CancerType.SCLC, 100)
	var far := CWSetup.make_cell(3, 1, CWData.Faction.CANCER, Vector2i(6, 0), -1, CWData.CancerType.SCLC, 100)
	g.cells.append(near)
	g.cells.append(mid)
	g.cells.append(far)
	g.update_marks()
	check(near["marked"] and not mid["marked"], "光环只够到 2 格内的那个")
	g.world._mark_adhesion()
	check(mid["marked"], "【组织黏连】把标记传染给两格内的癌细胞")
	check(not far["marked"], "本阶段造成的感染不连锁（far 只挨着刚被染上的 mid）")
	g.dispose()


## 【E-增生】的连通块分档 + 【E-侵蚀】的格数（PRD 2026-09-07 两条一起改）。
##
## 【E-增生】的概率公式（PRD 2026-09-08 云端修订版）：
##   每个癌性邻居的贡献 = 3% + 1% × **它所在连通块里的固化癌组织数**。
## 此前是「块里有固化 → 一律 4%」，不随固化数增长。
##
## **不赌概率**：把旋钮拨到让 chance 正好落在 0 或 ≥1000 上（`randi_range(1,1000) <= chance`），
## 于是每条断言要么必转要么必不转，验的是算式本身而不是运气。
func t_proliferate_tiers() -> void:
	print("[增生概率 / 侵蚀格数]")
	check(CWData.PROLIFERATE_PER_ADJ == 30 and CWData.PROLIFERATE_PER_SOLID == 10,
		"默认 3% + 每个固化 1%")

	## ① 数的是「**邻居所属连通块**里的固化数」，不是「这个邻居自己是不是固化」，
	## 也不是全图固化数。摆两处互不相邻：a 的邻居那块没固化，b 的邻居那块更远处有一格。
	var g := _blank_board()
	g.tune.proliferate_per_adjacent = 0     ## 基础档拨到 0：只剩固化那一项在起作用
	g.tune.proliferate_per_solid = 1000     ## 一格固化就顶满 → 必转
	var target_a := Vector2i(-4, 0)
	var target_b := Vector2i(3, 0)
	var na: Vector2i = target_a + CWData.DIRS[0]
	var nb: Vector2i = target_b + CWData.DIRS[0]
	var far: Vector2i = nb + CWData.DIRS[0]    ## 与 nb 相连、离 target_b 两格
	g.tiles[na]["tissue"] = CWData.Tissue.CANCER
	g.tiles[nb]["tissue"] = CWData.Tissue.CANCER
	g.tiles[far]["tissue"] = CWData.Tissue.SOLID
	check(CWData.hex_dist(na, nb) > 1 and CWData.hex_dist(na, far) > 1,
		"两处互不相邻，各成一个连通块")
	g.world._proliferate()
	check(g.tiles[target_a]["tissue"] == CWData.Tissue.HEALTHY,
		"邻居那块固化数 = 0 → 概率 0，不转")
	check(g.tiles[target_b]["tissue"] != CWData.Tissue.HEALTHY,
		"邻居自己不是固化，但同块里有 1 格 → 概率顶满，必转")
	g.dispose()

	## ② **固化数进乘法**：每格 500 时，一格固化只有 500（不保证），两格就顶满 1000。
	## 与 ① 的「一格 ×1000 必转」合起来，钉住的正是「乘以固化数」这件事。
	var g2 := _blank_board()
	g2.tune.proliferate_per_adjacent = 0
	g2.tune.proliferate_per_solid = 500
	var far2: Vector2i = far + CWData.DIRS[0]   ## 再接一格，凑成同块两格固化
	g2.tiles[nb]["tissue"] = CWData.Tissue.CANCER
	g2.tiles[far]["tissue"] = CWData.Tissue.SOLID
	g2.tiles[far2]["tissue"] = CWData.Tissue.SOLID
	g2.world._proliferate()
	check(g2.tiles[target_b]["tissue"] != CWData.Tissue.HEALTHY,
		"同块两格固化 × 每格 500 = 顶满，必转（一格时只有 500，不保证）")
	g2.dispose()

	## ③ 固化那一项拨到 0 = 退回「只按基础档」的老口径（旋钮要能扫回去做对照）
	var g3 := _blank_board()
	g3.tune.proliferate_per_adjacent = 0
	g3.tune.proliferate_per_solid = 0
	g3.tiles[nb]["tissue"] = CWData.Tissue.CANCER
	g3.tiles[far]["tissue"] = CWData.Tissue.SOLID
	g3.world._proliferate()
	check(g3.tiles[target_b]["tissue"] == CWData.Tissue.HEALTHY,
		"固化项拨到 0：固化再多也不加成")
	g3.dispose()

	## ③ 侵蚀格数：2/3 → 2 格、1/3 → 3 格
	var counts := {}
	for seed_i in 60:
		var probe := _erosion_scene(seed_i)
		var before: int = probe.count_tissue(CWData.Tissue.HEALTHY)
		probe.world._erosion()
		counts[before - probe.count_tissue(CWData.Tissue.HEALTHY)] = true
		probe.dispose()
	var got: Array = counts.keys()
	got.sort()
	check(got == [2, 3], "一次侵蚀转 2 或 3 格，不再有 1 格（实测 %s）" % str(got))


## 一块全健康、没有细胞的棋盘（增生测试用）
func _blank_board() -> CWGame:
	var g := bare_game()
	for c in g.tiles:
		g.tiles[c]["tissue"] = CWData.Tissue.HEALTHY
		g.tiles[c]["solid"] = 0
	return g


## 「被癌性组织完全包围、内部有十来个合法格」的局面（侵蚀格数统计用）
func _erosion_scene(seed_value: int) -> CWGame:
	var g := bare_game()
	g.rng.seed = seed_value
	for c: Vector2i in g.tiles:
		g.tiles[c]["tissue"] = CWData.Tissue.CANCER if CWData.hex_dist(c, Vector2i.ZERO) > 2 \
			else CWData.Tissue.HEALTHY
		g.tiles[c]["solid"] = 0
	return g


## 出牌流水进对局状态（方案甲，2026-09-07）：左侧那一列原先只靠一次性广播吃饭，
## 客户端断线重连期间广播过的那几条就永久错过了。改成随快照走之后要保证三件事：
## 记得下、不进哈希、快照往返还在。
func t_feed_log() -> void:
	print("[出牌流水进状态]")
	check(CWData.FEED_KEEP >= CWFeed.MAX_ROWS,
		"状态里留的条数 %d ≥ 那一列画得下的 %d（少了重连就补不满）"
		% [CWData.FEED_KEEP, CWFeed.MAX_ROWS])

	var g := bare_game()
	check(g.feed_log.is_empty() and g.feed_seq == 0, "开局是空的")
	g.note_feed("play", 0, CWData.Faction.IMMUNE, "炎症趋化")
	g.note_feed("event", 1, CWData.Faction.CANCER, "克隆增殖")
	g.note_feed("world", -1, -1, "基质阻隔", 2)
	check(g.feed_log.size() == 3 and g.feed_seq == 3, "三条都记下了，seq 跟着涨")
	check(int(g.feed_log[0]["seq"]) == 1 and String(g.feed_log[2]["kind"]) == "world"
		and int(g.feed_log[2]["left"]) == 2, "字段齐全（含世界事件的剩余回合）")

	## 只留最近 FEED_KEEP 条
	for i in CWData.FEED_KEEP + 3:
		g.note_feed("play", 0, CWData.Faction.IMMUNE, "炎症趋化")
	check(g.feed_log.size() == CWData.FEED_KEEP, "最多留 %d 条" % CWData.FEED_KEEP)
	check(int(g.feed_log[0]["seq"]) > 1, "挤掉的是最旧的")

	## **不进哈希**：它是展示用的流水，改它不该让联机的一致性校验报警
	var h0 := g.state_hash()
	g.note_feed("play", 0, CWData.Faction.IMMUNE, "CXCR3趋化")
	check(g.state_hash() == h0, "出牌流水不进状态哈希")

	## 快照往返：重连补齐就靠这一条
	var snap := g.snapshot()
	var seq_before: int = g.feed_seq
	var n_before: int = g.feed_log.size()
	g.feed_log = []
	g.feed_seq = 0
	g.restore(snap)
	check(g.feed_log.size() == n_before and g.feed_seq == seq_before,
		"快照往返后流水还在（%d 条 / seq %d）" % [g.feed_log.size(), g.feed_seq])

	## 推演不记：副本里的假动作不该污染快照
	g.sim_quiet = true
	var n2: int = g.feed_log.size()
	g.note_feed("play", 0, CWData.Faction.IMMUNE, "炎症趋化")
	check(g.feed_log.size() == n2, "sim_quiet 期间不记流水")
	g.sim_quiet = false
	g.dispose()


## CWEval 拆成「特征 × 权重」之后的守护（2026-09-07，为回归权重铺路）。
##
## **最要紧的一条是「默认权重下打分逐位不变」**：扁平 MC 是平衡标尺，
## 估值一动整套平衡表作废。这里把公式照抄一份对拍 —— 抄第二份平时是坏事，
## 但守「重构不改行为」正需要一份独立的参照。
func t_eval_features() -> void:
	print("[估值特征化]")
	check(CWEval.FEATURE_NAMES.size() == CWEval.WEIGHTS.size(),
		"特征名与权重一一对应（%d / %d）" % [CWEval.FEATURE_NAMES.size(), CWEval.WEIGHTS.size()])

	var g := bare_game()
	g.setup.build_board()
	var f: Array[int] = CWEval.features(g)
	check(f.size() == CWEval.FEATURE_NAMES.size(), "特征向量长度对得上")

	## 逐位不变：随便走一局，每一步都拿两种视角、两种 death_cost 对拍
	var bad := 0
	var n := 0
	for seed_i in 3:
		var probe := make_game(4, 41000 + seed_i)
		probe.sim_quiet = true
		await probe.run_game()
		for fac in [CWData.Faction.CANCER, CWData.Faction.IMMUNE]:
			for dc in [true, false]:
				n += 1
				if CWEval.score(probe, fac, dc) != _eval_reference(probe, fac, dc):
					bad += 1
		probe.dispose()
	check(bad == 0, "默认权重下 score 与参照实现逐位一致（对拍 %d 次）" % n)

	## 权重可注入：把「一格癌组织」的权重翻倍，分数必须跟着动
	var g2 := bare_game()
	g2.setup.build_board()
	var w: Array = CWEval.WEIGHTS.duplicate()
	var base: int = CWEval.score(g2, CWData.Faction.CANCER, false)
	var tiles: int = CWEval.features(g2)[0]
	w[0] = int(w[0]) * 2
	check(CWEval.score_with(g2, CWData.Faction.CANCER, w, false) == base + tiles * CWEval.TILE,
		"权重可注入：癌组织那一项翻倍，分数正好多出一份")
	g2.dispose()
	g.dispose()


## `CWEval.score` 特征化**之前**的公式，逐字照抄，只给上面那条对拍用。
func _eval_reference(g: CWGame, faction: int, death_cost: bool) -> int:
	var adv := 0
	var has_base := false
	if g.winner >= 0:
		adv = CWEval.WIN if g.winner == CWData.Faction.CANCER else -CWEval.WIN
		return adv if faction == CWData.Faction.CANCER else -adv
	for c in g.tiles.keys():
		var t: Dictionary = g.tiles[c]
		if t["tissue"] == CWData.Tissue.CANCER:
			adv += CWEval.TILE + t["solid"] * CWEval.SOLID_TICK
		elif t["tissue"] == CWData.Tissue.SOLID:
			adv += CWEval.TILE * 2
			if g.cells_at(c, CWData.Faction.IMMUNE).is_empty():
				has_base = true
	if has_base:
		adv += CWEval.FIRST_BASE
	for cell in g.cells:
		if not cell["alive"]:
			if death_cost and faction == CWData.Faction.IMMUNE:
				var cost := CWEval._death_cost(g, cell)
				adv += -cost if cell["faction"] == CWData.Faction.CANCER else cost
			continue
		var worth: int = cell["energy"] + cell["hand"].size() * CWEval.CARD \
			+ cell["equipped"].size() * CWEval.EQUIP
		if cell["faction"] == CWData.Faction.CANCER:
			adv += worth
		else:
			adv -= worth
			adv += mini(CWEval._dist_to_cancerous(g, cell["pos"]), 6) * CWEval.FAR
	adv -= g.memory * CWEval.MEMORY + g.immune_level * CWEval.LEVEL
	return adv if faction == CWData.Faction.CANCER else -adv


## 线上版 PRD（Kevin 2026-09-07 拉的正本）带来的三条**行为**改动。
## 常量类的改动（15 回合终局、事件回合、卡池分期、坏死减半、X 级 30）钉在各自原有的测试里。
func t_prd_online_0907() -> void:
	print("[线上版 PRD·09-07]")

	## ① 【攻击】累积「与造成伤害的绝对值向下取整」的抗原记忆。
	## 引擎此前**整条没实现**：只有【净化】给记忆，攻击一点不给。
	var g := _fx_game(2)
	var im := put_immune(g, Vector2i.ZERO)
	var ca := CWSetup.make_cell(g.cells.size(), 1, CWData.Faction.CANCER,
		Vector2i(1, 0), -1, CWData.CancerType.SCLC, 500)
	g.cells.append(ca)
	g.tiles[Vector2i(1, 0)]["tissue"] = CWData.Tissue.CANCER
	var m0: int = g.memory
	_rig_roll(g, 6, [3])                   ## 成功 → 1.0
	await g.actions._do_move(im, Vector2i(1, 0), 0)
	check(g.memory == m0 + 1, "攻击成功造成 1.0 → +1 抗原记忆（%d → %d）" % [m0, g.memory])
	m0 = g.memory
	_rig_roll(g, 6, [6])                   ## 大成功 → 2.0
	await g.actions._do_move(im, Vector2i(1, 0), 0)
	check(g.memory == m0 + 2, "大成功 2.0 → +2")
	m0 = g.memory
	_rig_roll(g, 6, [1])                   ## 失败 → 不造成伤害
	await g.actions._do_move(im, Vector2i(1, 0), 0)
	check(g.memory == m0, "攻击失败不给记忆（按实际伤害算，不是尝试值）")
	g.dispose()

	## ② 【标记】无法重叠，同一癌细胞一个世界回合只能获得一次。
	## 旧 PRD 是「可多次获得」，于是标记被伤害吃掉后光环立刻补一个 —— 站在树突边上等于永久双倍。
	g = bare_game()
	var dc := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i.ZERO,
		CWData.ImmuneType.DENDRITIC, -1, 150)
	g.cells.append(dc)
	var cc := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(1, 0),
		-1, CWData.CancerType.SCLC, 100)
	g.cells.append(cc)
	g.update_marks()
	check(cc["marked"], "树突光环：先拿到一个标记")
	cc["marked"] = false                   ## 假装被伤害消耗掉
	cc["mark_left"] = 0
	g.update_marks()
	check(not cc["marked"], "同一世界回合内不再补第二个标记")
	g.round_no += 1
	g.update_marks()
	check(cc["marked"], "下一个世界回合可以再拿一次")
	g.dispose()

	## ③ 【骨样硬化】标记格上的蹲守净化：从「下一回合 S 阶段」挪到**本回合 E 阶段**
	## （PRD：「须停留在该格，世界回合结束时完成【净化】」）
	g = _fx_game(2)
	var camp := put_immune(g, Vector2i(2, 0))
	g.tiles[Vector2i(2, 0)]["tissue"] = CWData.Tissue.CANCER
	camp["camp_round"] = g.round_no
	camp["camp_pos"] = Vector2i(2, 0)
	await g.world.round_start()
	check(g.tiles[Vector2i(2, 0)]["tissue"] == CWData.Tissue.CANCER, "S 阶段不再补净化")
	await g.world.e_phase()
	check(g.tiles[Vector2i(2, 0)]["tissue"] == CWData.Tissue.HEALTHY,
		"E 阶段（世界回合结束时）完成净化")
	g.dispose()


# ---- 【I-标记】光环范围「相邻格」→「相邻 2 格内」（Kevin 2026-09-06，PRD 正本已同步）----
func t_mark_range() -> void:
	print("[标记光环 2 格]")
	check(CWData.MARK_RANGE == 2, "范围常量 = 2（Kevin 2026-09-06：相邻 2 格内）")
	var g := bare_game()
	var dc := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i.ZERO, CWData.ImmuneType.DENDRITIC, -1, 150)
	g.cells.append(dc)
	var near := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(2, 0), -1, CWData.CancerType.SCLC, 100)
	var far := CWSetup.make_cell(2, 1, CWData.Faction.CANCER, Vector2i(3, 0), -1, CWData.CancerType.SCLC, 100)
	g.cells.append(near)
	g.cells.append(far)
	g.update_marks()
	check(near["marked"] and near["mark_left"] == 1, "距离 2 的癌细胞自动获得标记")
	check(not far["marked"], "距离 3 的不获得")
	## 任意时间：挪进 2 格内（斜向 (1,1) 距离也是 2）再刷就有
	far["pos"] = Vector2i(1, 1)
	g.update_marks()
	check(far["marked"], "挪进 2 格内 → 立刻获得（任意时间）")
	## 树突不在场：不施加（已有的标记归伤害结算去消耗，这里不管）
	near["marked"] = false
	near["mark_left"] = 0
	dc["alive"] = false
	g.update_marks()
	check(not near["marked"], "树突不在场：不施加")
	g.dispose()
	## 文案现读：细胞详情是 PRD 原文，逐字对上改后的正本
	check(CWData.IMMUNE_TYPE_TEXT[CWData.ImmuneType.DENDRITIC].contains("相邻2格内的癌细胞自动获得【标记】"),
		"细胞详情文案（PRD 原文）已改成 2 格")


# ---- 趋化源：格子详情标出来 + 漩涡改像素风（Kevin 2026-09-06）----
func t_chemo_info() -> void:
	print("[趋化源详情与像素漩涡]")
	var g := bare_game()
	var at := Vector2i(2, -1)
	g.chemo = { "at": at, "left": 2, "by": 0 }
	var all := ""
	for r in CWTileInfo.describe(g, at):
		all += r["text"] + "|"
	check(all.contains("趋化源 · 还剩 2 回合"), "详情：趋化源与剩余回合（%s）" % all)
	check(all.contains("免疫朝它 -%d%% · 癌方背它 +%d%%"
			% [100 - CWData.CHEMO_IMMUNE_PCT, CWData.CHEMO_CANCER_PCT - 100]),
		"详情：效果一句话，数字现读 CWData（这条断言自己以前也把数字写死了）")
	g.chemo["left"] = 1
	all = ""
	for r in CWTileInfo.describe(g, at):
		all += r["text"] + "|"
	check(all.contains("趋化源 · 最后一回合"), "只剩 1 回合写「最后一回合」（和漩涡转暖橙同一口径）")
	var other := ""
	for r in CWTileInfo.describe(g, Vector2i(0, 0)):
		other += r["text"] + "|"
	check(not other.contains("趋化源"), "别的格不标")
	g.chemo = {}
	all = ""
	for r in CWTileInfo.describe(g, at):
		all += r["text"] + "|"
	check(not all.contains("趋化源"), "消散后不标")
	g.dispose()

	## 像素风：时间按 1/12 秒步进、粒子落在整数格上且不出格子附近、残影 = 前几格的位置
	check(CWChemoFx.frame_of(0.10) == CWChemoFx.frame_of(0.12), "同一格时间画得一样")
	check(CWChemoFx.frame_of(0.10) != CWChemoFx.frame_of(0.20), "跨格时间才动")
	check(is_equal_approx(CWChemoFx.quantize(0.12), 1.0 / CWChemoFx.PIX_FPS), "quantize 取格子起点")
	var inside := true
	for ring in CWChemoFx.RINGS:
		for idx in CWChemoFx.PER_RING:
			for f in 40:
				var p := CWChemoFx.frame_pos(ring, idx, f)
				if absi(p.x) > 33 or p.y > 10 or p.y < -31:
					inside = false
	check(inside, "40 帧内所有粒子像素都在格子附近（横向 ≤33、纵向 -31..10：整体上抬 5 之后不压前缘）")
	check(CWChemoFx.pixel_at(0, 0, 5.0 / CWChemoFx.PIX_FPS + 0.01) == CWChemoFx.frame_pos(0, 0, 5),
		"pixel_at = 该时刻所在格的 frame_pos")
	check(CWChemoFx.TRAIL + 1 == CWChemoFx.ALPHA_STEPS.size(), "残影每段一个透明度档位（本体 + TRAIL 段）")


# ---- 对局日志面板：窗口/着色是纯函数，开关与滚动走真节点 ----
func t_log_panel() -> void:
	print("[对局日志面板]")
	check(CWLogPanel.first_line(100, 20, 0) == 80, "窗口贴底")
	check(CWLogPanel.first_line(100, 20, 30) == 50, "上翻 30 行")
	check(CWLogPanel.first_line(10, 20, 0) == 0, "不足一屏从头显示")
	## 长行折行：真机上「免疫A（免疫细胞）经由【基因表达】抽到【永久】LFA-1黏附」
	## 被 TRIM_ELLIPSIS 截成省略号，而截掉的恰恰是「抽到了什么牌」（Kevin 2026-09-04 报的）
	var long_line := "免疫A（免疫细胞）经由【基因表达】抽到【永久】LFA-1黏附（LFA-1黏附）"
	var row_w: float = CWLogPanel.RECT.size.x - CWLogPanel.PAD * 2 - 10
	var segs := CWLogPanel.wrap_line(long_line, row_w)
	check(segs.size() > 1, "长行被折成多行（%d 行）" % segs.size())
	var joined := ""
	for seg in segs:
		joined += seg.lstrip(" ")
	check(joined == long_line, "折行不丢字：拼回去等于原文")
	for seg in segs:
		check(CWStyle.FONT.get_string_size(seg, HORIZONTAL_ALIGNMENT_LEFT, -1,
			CWStyle.SIZE_LABEL).x <= row_w, "每段都放得进行宽")
	check(CWLogPanel.wrap_line("短行", row_w).size() == 1, "短行不折")
	check(CWLogPanel.wrap_line("", row_w).size() == 1, "空行也给一行，别把行数算漏")

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
	## 折行后的显示行数 ≥ 日志条数，且续行的颜色跟源日志走（不能因为缩进就变灰）
	g.log_msg("★ " + "很长的一条升级日志".repeat(6))
	p._scroll(-999)          ## 上一段把窗口翻到顶了，先滚回底部才看得到这条
	p.refresh(g)
	check(p._rows.size() > g.logs.size(), "有长行时显示行数多于日志条数")
	var tail_color: Color = p._lines[p._visible_n - 1].get_theme_color("font_color")
	check(tail_color == CWStyle.IMMUNE, "续行沿用源日志的颜色（★ 仍是免疫色）")
	p._scroll(-999)
	p.refresh(g)
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
	## 方案 A（Kevin 2026-09-06）：入口长成迷你日志，但**不压棋盘顶行**（棋盘顶边 y=75）
	check(chip.position.y + chip.size.y <= 72.0, "迷你日志条底 %.0f 在棋盘顶边（75）之上" % (chip.position.y + chip.size.y))
	var lg := bare_game()
	var lp := CWLogPanel.new()
	root.add_child(lp)
	await process_frame
	lg.log_msg("▶ 癌症A 的回合（能量 6.0）")
	lg.log_msg("　【定殖】(5, -4) 转为癌组织")
	lg.log_msg("　癌症A 结束回合（能量 0.5）")
	chip.refresh(lg, lp)
	check(chip._rows[0].text == "　【定殖】(5, -4) 转为癌组织" and chip._rows[1].text == "　癌症A 结束回合（能量 0.5）",
		"迷你日志显示日志尾巴的最后两行（%s | %s）" % [chip._rows[0].text, chip._rows[1].text])
	check(chip._rows[1].get_theme_color("font_color").a > chip._rows[0].get_theme_color("font_color").a,
		"越旧越淡，最后一行全亮")
	lg.log_msg("这一句故意写得很长很长很长很长很长很长很长很长很长很长很长很长很长很长很长很长很长很长很长很长")
	chip.refresh(lg, lp)
	check(chip._rows[0].text.length() > 0 and chip._rows[1].text.begins_with("  "),
		"超宽的一条按面板同款折行，尾巴两行是同一条的两段（续行带缩进）")
	## 视角过滤同面板那份：别人的秘密行换公开替身
	lg.log_msg("免疫B 抽到【永久】LFA-1黏附", 1, "免疫B 抽到一张【永久】")
	lp.filter = true
	lp.viewer = 0
	chip.refresh(lg, lp)
	check(chip._rows[1].text == "免疫B 抽到一张【永久】", "迷你日志按面板视角换替身（%s）" % chip._rows[1].text)
	lp.queue_free()
	lg.dispose()
	var hits := [0]
	chip.pressed.connect(func() -> void: hits[0] += 1)
	var mev := InputEventMouseButton.new()
	mev.pressed = true
	mev.button_index = MOUSE_BUTTON_LEFT
	chip.gui_input.emit(mev)
	check(hits[0] == 1, "点提示发出开关手势")
	root.remove_child(chip)
	chip.free()


## 格子详情框里的「黏液侵染」行（Kevin 2026-09-08：「粘液信息没有显示在格子的详情栏中」）。
##
## 它是这一格上**唯一一个会改价钱、却在格子上看不出来**的状态 —— 坏死、固化、
## 趋化源、特殊组织都有行，只有它没有，于是免疫玩家踏进去才发现多付了 0.5。
func t_mucus_row() -> void:
	print("[格子详情·黏液侵染]")
	var g := bare_game()
	var c := Vector2i(2, 0)
	var dump := func() -> String:
		var out := ""
		for r in CWTileInfo.describe(g, c):
			out += r["text"] + "|"
		return out

	check(not dump.call().contains("黏液"), "没黏液的格子：不出这一行")
	g.tile(c)["mucus"] = true
	var said: String = dump.call()
	check(said.contains("黏液侵染"), "有黏液 → 出这一行（%s）" % said)
	check(said.contains(CWData.fmt(g.tune.mucus_move_surcharge)),
		"写明免疫踏入要多付多少（现读旋钮 %s，不写死）" % CWData.fmt(g.tune.mucus_move_surcharge))
	check(said.contains("消失"), "也写明「被免疫接触后消失」——这是免疫方唯一的清除手段")

	## 旋钮调成 0 时那半句不出：写着「+0.0」比不写更糟
	g.tune.mucus_move_surcharge = 0
	var zero: String = dump.call()
	check(zero.contains("黏液侵染") and not zero.contains("踏入"),
		"加价关掉时只说状态、不报价（%s）" % zero)
	g.tune.mucus_move_surcharge = CWData.MUCUS_MOVE_SURCHARGE
	g.dispose()


# ---- 规则速查：数字必须现读常量/旋钮，不许抄第二份 ----
## 特殊组织「还有几回合产出」（2026-09-04 Kevin 要的）。周期 / 产量现读 CWData，
## 这里连措辞一起钉：三种情况（每回合产、存满、按剩余回合）说的是三件不同的事
func t_production_row() -> void:
	print("[特殊组织产出倒计时]")
	var core := CWSetup.make_tile(CWData.CORES[0])
	check(core["special"] == CWData.Special.CORE, "取到的确实是代谢核心格")
	var text := func(t: Dictionary) -> String: return CWTileInfo.production_row(t)["text"]
	check(text.call(core) == "还有 %d 回合产出 +%s"
		% [CWData.CORE_HEALTHY_PERIOD, CWData.fmt(CWData.CORE_HEALTHY_GAIN)],
		"健康核心刚归零：还有 %d 回合（得「%s」）" % [CWData.CORE_HEALTHY_PERIOD, text.call(core)])
	core["prod"] = CWData.CORE_HEALTHY_PERIOD - 1
	check(text.call(core).begins_with("下回合产出"), "只差一回合时说「下回合」，不说「还有 1 回合」")
	core["prod"] = 0
	CWTissue.to_cancer(core, false)
	check(text.call(core) == "每回合 +%s" % CWData.fmt(CWData.CORE_CANCER_GAIN),
		"癌性核心每回合都产，没有周期可倒数（得「%s」）" % text.call(core))
	core["store"] = CWData.CORE_STORE_MAX
	check(text.call(core).begins_with("已满"), "存满了就说「已满」——再报倒计时是骗人")
	var marrow := CWSetup.make_tile(CWData.MARROWS[0])
	check(text.call(marrow) == "还有 %d 回合产出 +1 张" % CWData.MARROW_HEALTHY_PERIOD,
		"健康骨髓周期 %d（得「%s」）" % [CWData.MARROW_HEALTHY_PERIOD, text.call(marrow)])
	CWTissue.to_cancer(marrow, false)
	check(text.call(marrow) == "还有 %d 回合产出 +1 张" % CWData.MARROW_CANCER_PERIOD,
		"癌化骨髓周期缩到 %d" % CWData.MARROW_CANCER_PERIOD)
	marrow["cards"] = CWData.MARROW_STORE_MAX
	check(text.call(marrow).begins_with("已满"), "骨髓存满一张也说「已满」")
	## 真进详情：核心 / 骨髓两种格都要多出这一行，血管不该有
	var g := bare_game()
	var rows := CWTileInfo.describe(g, CWData.CORES[0])
	var joined := ""
	for r in rows:
		joined += r["text"] + "|"
	check(joined.contains("代谢核心") and joined.contains("回合产出"), "核心格详情里有产出行")
	var vessel := ""
	for r in CWTileInfo.describe(g, CWData.VESSELS[0]):
		vessel += r["text"] + "|"
	check(vessel.contains("血管") and not vessel.contains("产出"), "血管不产出，不加这一行")
	g.dispose()


## 技能详情（2026-09-04 Kevin 要的「技能栏显示详细作用」）：
## ① 行动栏每个按钮都带 info；② 右栏玩家行点一下固定、条目可悬停
func t_skill_info() -> void:
	print("[技能详情]")
	## 每个会上行动栏的技能都得有名字和 PRD 原文——漏登记在这里当场报出来
	var missing: Array = []
	## **遍历 ACT_NAMES**（2026-09-08 由手写清单改过来）：原来那份清单漏了 effector，
	## 于是【效应应答】的详情框空了一整块也没人报 —— Kevin 截图报上来才发现。
	## play / discard 不上行动栏（名字只给日志和护栏用），跳过。
	for act in CWData.ACT_NAMES:
		if act in ["play", "discard"]:
			continue
		if not CWData.ACT_NAMES.has(act):
			missing.append(act + "(名字)")
		for f in [CWData.Faction.IMMUNE, CWData.Faction.CANCER]:
			if CWData.skill_text(act, f) == "":
				missing.append("%s(文案 f%d)" % [act, f])
	check(missing.is_empty(), "行动栏的技能都有名字和 PRD 原文（缺的：%s）" % str(missing))
	check(CWUIBridge.ACT_TITLE == CWData.ACT_NAMES, "行动栏名表就是 CWData 那一份，没有第二份")
	## 阵营分两套措辞：规则里免疫叫【迁移】、癌症叫【移动】，抽卡价也不同
	check(CWData.skill_text("move", CWData.Faction.IMMUNE).contains("【迁移】")
		and CWData.skill_text("move", CWData.Faction.CANCER).contains("【移动】"),
		"迁移 / 移动按阵营给各自的 PRD 原文")
	check(CWData.skill_text("draw", CWData.Faction.IMMUNE)
		!= CWData.skill_text("draw", CWData.Faction.CANCER), "两边【基因表达】价钱不同，文案也不同")
	## 折行后每一行都要放得进详情框（同手牌详情那条纪律）
	var toolong: Array = []
	for act in CWData.ACT_NAMES:
		for f in [CWData.Faction.IMMUNE, CWData.Faction.CANCER]:
			var d := CWCardInfo.describe_act(act, f)
			for l in d["lines"]:
				if CWStyle.FONT.get_string_size(l, HORIZONTAL_ALIGNMENT_LEFT, -1,
						CWStyle.SIZE_LABEL).x > CWCardInfo.W - CWCardInfo.PAD_H * 2.0:
					toolong.append("%s：%s" % [act, l])
	for t in CWData.CANCER_TYPE_TEXT:
		for l in CWCardInfo.describe_ctype(t)["lines"]:
			if CWStyle.FONT.get_string_size(l, HORIZONTAL_ALIGNMENT_LEFT, -1,
					CWStyle.SIZE_LABEL).x > CWCardInfo.W - CWCardInfo.PAD_H * 2.0:
				toolong.append("癌种：%s" % l)
	check(toolong.is_empty(), "技能正文折行后没有一行超宽（超的：%s）" % str(toolong.slice(0, 3)))
	check(CWCardInfo.describe_act("draw", CWData.Faction.IMMUNE)["name"] == "基因表达",
		"名字取自 ACT_NAMES")
	## 摆位：右缘不许进右侧竖条（竖条上是回合数 / 能量 / 免疫等级，盖住就看不见了）
	var screen := Vector2(960, 540)
	var wide := Vector2(CWCardInfo.W, 160)
	var far := CWCardInfo.place_at(wide, 900.0, screen)   ## 贴最右那枚按钮
	check(far.x + wide.x <= screen.x - CWMatchPanel.RECT.size.x - 8.0,
		"贴右缘的按钮：详情框往左让，不压右栏（右缘 %d，竖条左缘 %d）"
			% [far.x + wide.x, screen.x - CWMatchPanel.RECT.size.x])
	check(CWCardInfo.place_at(wide, 120.0, screen).x == 120.0, "左边放得下就贴着按钮不动")
	check(far.y >= 8.0 and far.y + wide.y <= screen.y - 8.0, "上下不越出画布")
	check(CWCardInfo.describe_ctype(CWData.CancerType.SCLC)["kind"] == "【细胞种类】"
		and CWCardInfo.describe_ctype(CWData.CancerType.SCLC)["name"] == "小细胞肺癌",
		"癌种详情给种类名与类别")
	## 右栏：悬停只列已装备（老行为不许变吵），点一下固定才列全套
	var g := _fx_game(2)
	## cells 的下标就是 pid（cell_of 按下标取），追加顺序必须和玩家顺序一致
	var imm := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(5, 0),
		CWData.ImmuneType.BASIC, -1)
	g.cells.append(imm)
	var can := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(0, 0),
		-1, CWData.CancerType.MELANOMA)
	g.cells.append(can)
	can["equipped"] = ["组织驻留"]
	check(CWMatchPanel.tip_rows(g, 0, false).is_empty(), "没装备时悬停不列任何东西（老行为）")
	var hov := CWMatchPanel.tip_rows(g, 1, false)
	check(hov.size() == 2 and hov[0]["head"] == "已装备 · 持续生效"
		and hov[1]["text"] == "组织驻留", "有装备时悬停仍只列已装备")
	var full := CWMatchPanel.tip_rows(g, 1, true)
	var heads: Array = []
	var items: Array = []
	for r in full:
		if r.has("head"):
			heads.append(r["head"])
		else:
			items.append(r["text"])
	check(heads == ["细胞种类", "主动技能", "已装备 · 持续生效"], "固定后分三段：%s" % str(heads))
	check("组织驻留" in items and "突变" in items and "移动" in items,
		"固定后列出装备、突变与移动（得 %s）" % str(items))
	check(not ("迁移" in items), "癌方那一行说「移动」不说「迁移」——规则里是两个词")
	check(CWData.act_name("move", CWData.Faction.IMMUNE) == "迁移"
		and CWCardInfo.describe_act("move", CWData.Faction.CANCER)["name"] == "移动",
		"详情框标题也按阵营给词")
	## 主动技能那一段和行动栏同一份清单，不许各写各的
	var kinds: Array = []
	for a in g.actions.action_kinds(can):
		kinds.append(CWData.act_name(a, can["faction"]))
	for k in kinds:
		check(k in items, "行动栏的「%s」在固定详情里也有" % k)
	## 每一条都带 info，停上去才有东西浮
	var noinfo: Array = []
	for r in full:
		if not r.has("head") and (not r.has("info") or r["info"]["lines"].is_empty()):
			noinfo.append(r.get("text", "?"))
	check(noinfo.is_empty(), "固定详情每一条都带 PRD 原文（缺的：%s）" % str(noinfo))
	## 未分化的免疫细胞没有种类文案，那一段整段不出（不能留个空标题）
	var basic := CWMatchPanel.tip_rows(g, 0, true)
	var bheads: Array = []
	for r in basic:
		if r.has("head"):
			bheads.append(r["head"])
	check(not ("细胞种类" in bheads), "未分化免疫没有种类技能，那一段不出（得 %s）" % str(bheads))
	## 框高按条目算；固定态底下多一行操作提示
	check(CWMatchPanel.tip_height(hov, false) == 16.0 + 15.0 + 24.0, "悬停态框高 = 内边距 + 标题 + 一条")
	check(CWMatchPanel.tip_height(hov, true) == 16.0 + 15.0 + 24.0 + 15.0, "固定态多一行提示")
	## 点行 = 固定 / 再点取消（走真实控件，连信号一起验）
	var panel := CWMatchPanel.new()
	root.add_child(panel)
	await process_frame
	panel.refresh(g)
	var seen: Array = []
	panel.skill_hovered.connect(func(rows: Dictionary, _x: float, _y: float) -> void: seen.append(rows))
	var hits: Array = panel.find_children("*", "Control", false, false)
	var row_hit: Control = null
	for n in hits:
		if n.size == Vector2(CWMatchPanel.W, CWMatchPanel.ROW_H) \
				and is_equal_approx(n.position.y, CWMatchPanel.PAD + CWMatchPanel.ROUND_H
					+ CWMatchPanel.GAP + CWMatchPanel.SCORE_H + CWMatchPanel.GAP + CWMatchPanel.ROW_H):
			row_hit = n
	check(row_hit != null, "找到癌方那一行的感应区")
	if row_hit != null:
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = true
		row_hit.gui_input.emit(click)
		check(panel._tip_pinned == 1, "点一下固定到癌方那一行")
		panel.refresh(g)
		check(panel._tip != null and panel._tip.visible, "固定后详情框在场")
		## **停在条目上要真的把详情发出来** —— 这一整条链（条目收鼠标 → 信号 → 详情框）
		## 只有在这里才验得到；截图工具的点击不一定造得出悬停态，别指望它兜底
		var hot: Array = []
		var conn := func(rows: Dictionary, x: float, _y: float) -> void:
			if not rows.is_empty():
				hot.append([rows["name"], x])
		panel.skill_hovered.connect(conn)
		var stops := 0
		for c in panel._tip.get_children():
			if c is Label and (c as Label).mouse_filter == Control.MOUSE_FILTER_STOP:
				stops += 1
				(c as Label).mouse_entered.emit()
		check(stops == items.size(),
			"固定态每个条目都收鼠标（条目 %d，收鼠标的 %d）" % [items.size(), stops])
		var names: Array = []
		for h in hot:
			names.append(h[0])
		check(names == items, "每个条目各浮出自己的详情，顺序一致（得 %s）" % str(names))
		check(hot.size() == stops and hot[0][1] < CWMatchPanel.RECT.position.x,
			"详情框贴在详情条左侧，不盖住它（x=%s）" % str(hot[0][1] if hot.size() > 0 else -1))
		panel.skill_hovered.disconnect(conn)
		row_hit.gui_input.emit(click)
		check(panel._tip_pinned == -1, "再点同一行取消固定")
		check(seen.size() >= 2 and seen[0].is_empty(), "固定 / 取消都先把浮出的详情收掉")
	panel.reset()
	root.remove_child(panel)
	panel.free()
	g.dispose()


func t_rules_page() -> void:
	print("[规则速查]")
	var all := ""
	for s in CWRulesPage.sections():
		all += s["title"] + "|"
		for line in s["lines"]:
			all += line + "|"
	var tune := CWTuning.new()
	check(all.contains("加权占地达到 %d" % tune.cancer_win_weighted), "胜利线跟着旋钮走")
	check(all.contains("连续 %d 个世界回合末" % tune.cancer_win_hold_rounds), "占地胜利的连续回合数跟着旋钮走（定案 B）")
	check(all.contains("上限 %d 个世界回合" % CWData.LIMIT_ROUND), "回合上限跟着常量走")
	check(all.contains("-%s" % CWData.fmt(tune.attack_dmg_success))
		and all.contains("-%s" % CWData.fmt(tune.attack_dmg_crit)), "攻击伤害跟着旋钮走")
	## PRD：攻击失败自身 -0.5（口径 #84）。这一条**两个方向都要钉**——
	## 只钉「显示了」的话，把条件式换成无脑拼接也照样绿。
	check(all.contains("受反击 %s" % CWData.fmt(tune.counter_dmg_on_fail)),
		"反弹自损跟着旋钮走，速查页显示 %s" % CWData.fmt(tune.counter_dmg_on_fail))
	var no_counter := CWTuning.new()
	no_counter.counter_dmg_on_fail = 0
	var off := ""
	for s2 in CWRulesPage.sections(no_counter):
		for line in s2["lines"]:
			off += line + "|"
	check(not off.contains("受反击"), "旋钮关掉时那半句要消失")
	## 攻击次数上限（口径 #88）同样正反都钉
	check(all.contains("每个行动回合最多攻击 %d 次" % tune.attack_max_per_turn),
		"速查页写出攻击次数上限 %d" % tune.attack_max_per_turn)
	var no_cap := CWTuning.new()
	no_cap.attack_max_per_turn = 0
	var uncapped := ""
	for s3 in CWRulesPage.sections(no_cap):
		for line in s3["lines"]:
			uncapped += line + "|"
	check(uncapped.contains("攻击次数不限"),
		"上限设 0 时速查页改口说「不限」，不许留着和引擎不符的数")
	check(all.contains("上限 %d 张" % CWData.HAND_MAX)
		and all.contains("每回合至多 %d 次" % CWData.DRAW_MAX_PER_TURN), "手牌与抽卡上限")
	## 同上：门槛存的是十分整数（30 = 3.0），而这句说的是「几个回合」。
	## 原先拿 solidify_threshold 直接插值，页面显示「蹲满 30 回合」而测试照样绿
	check(all.contains("蹲满 %d 回合" % (CWData.SOLIDIFY_THRESHOLD / CWData.SOLIDIFY_STEP)),
		"固化门槛按回合数显示，不是十分整数")
	check(not all.contains("蹲满 %d 回合" % CWData.SOLIDIFY_THRESHOLD), "别再把十分整数当回合数打出来")
	## 【无氧呼吸】的时机跟着旋钮走（Kevin 2026-09-05 拍板：与知识之书同口径）。2026-09-06 Kevin 改回 E 阶段统一结算 →
	## 默认写在 E 阶段那行、玩家回合段不提它；旋钮拨成回合末（eturn=1）时那句搬到玩家回合段
	check(all.contains("E 阶段：癌方【无氧呼吸】") and not all.contains("结算自己的【无氧呼吸】"),
		"无氧呼吸默认写在 E 阶段，玩家回合段不提它（2026-09-06 改回）")
	var per_turn := CWTuning.new()
	per_turn.anaerobic_on_turn_end = true
	var ep := ""
	for s5 in CWRulesPage.sections(per_turn):
		for line in s5["lines"]:
			ep += line + "|"
	check(ep.contains("「结束回合」时结算自己的【无氧呼吸】") and not ep.contains("E 阶段：癌方【无氧呼吸】"),
		"旋钮拨成回合末结算时，那句搬到玩家回合段、E 阶段那行不再提它")
	## 反击旋钮开了，那半句要跟着出现（平衡实验档）
	## sections() 用的是默认 CWTuning，这里只验固定文案的另一半确实受控于旋钮：
	## 直接构造开旋钮的行文对比不可行（sections 内建 tune），改为验默认关。见上一条。

	## 排版（2026-09-04 Kevin 截图：长行冲进右栏叠字）。**每一行都要放得进栏宽** ——
	## 裁切只是兜底，玩家不该看到省略号
	var wide: Array = []
	for s4 in CWRulesPage.sections():
		for line in s4["lines"]:
			var w := CWStyle.FONT.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1,
				CWStyle.SIZE_LABEL).x
			if w > CWRulesPage.COL_W:
				wide.append("%s：%d px" % [line, w])
	check(wide.is_empty(), "每行都放得进栏宽 %d（超的：%s）" % [CWRulesPage.COL_W, str(wide)])
	var cols := CWRulesPage.columns(CWRulesPage.sections(), CWRulesPage.column_budget())
	check(cols.size() == 2, "内容正好铺两栏（实为 %d 栏）" % cols.size())
	var overflow: Array = []
	for c in cols:
		if c["height"] > CWRulesPage.column_budget():
			overflow.append(c["height"])
	check(overflow.is_empty(), "两栏都没有超出可用高度 %d（超的：%s）"
		% [CWRulesPage.column_budget(), str(overflow)])
	check(CWRulesPage.PAD + CWRulesPage.COL_W * 2 + 20 + CWRulesPage.PAD <= CWRulesPage.W,
		"两栏加中缝放得进面板宽 %d" % CWRulesPage.W)
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
## 热更新（2026-09-09 第一阶段）。**整条链是渲染验的**（真打补丁 → 挂上 → 主菜单标题变了；
## 另验了指纹不符隔离、上次没活下来回退、新增 class_name 打包直接拒），见开发日志。
## 这里守的是代码里能守的两件事：指纹算得对不对，以及那条「启动器不许碰游戏类」的硬约束。
func t_hot_patch() -> void:
	print("[热更新]")
	var PatchState := load("res://scripts/patch_state.gd")

	## SHA-256 拿一个已知答案的空串对：补丁是可执行代码，指纹算错等于护栏形同虚设
	var tmp := "user://_t_hot_probe.bin"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	f.store_string("")
	f.close()
	check(PatchState.sha256_of(tmp)
		== "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
		"空文件的 SHA-256 = 标准值（算法接对了）")
	f = FileAccess.open(tmp, FileAccess.WRITE)
	f.store_string("abc")
	f.close()
	check(PatchState.sha256_of(tmp)
		== "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
		"「abc」的 SHA-256 = 标准值")
	check(PatchState.sha256_of("user://_不存在的文件_.bin") == "", "文件不在 → 空串（挂载前必然对不上）")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))

	## **启动器不许引用游戏里的类。** 引用谁，谁就在挂载补丁之前被解析进缓存，
	## 于是那个类**永远打不了补丁**；实验里还撞到过 Godot 直接挂死。
	## 这条约束只活在注释里的话，下一个人加一行 `CWStyle.label(...)` 就会静默毁掉整个热更。
	for path in ["res://scripts/boot.gd", "res://scripts/patch_state.gd"]:
		var src := FileAccess.open(path, FileAccess.READ).get_as_text()
		var offenders: Array = []
		for line in src.split("\n"):
			var code: String = line.split("##")[0].split("#")[0]
			for m in ["CWStyle", "CWData", "CWMatch", "CWNet", "CWGame", "CWSettings"]:
				if code.contains(m):
					offenders.append(m)
		check(offenders.is_empty(),
			"%s 不碰任何游戏类（碰了的：%s）" % [path.get_file(), str(offenders)])

	## 主场景必须是启动器 —— 直接指向 Main 的话补丁永远盖不上（挂载晚于首次 load）
	check(ProjectSettings.get_setting("application/run/main_scene") == "res://scenes/Boot.tscn",
		"run/main_scene 指向启动器")
	check(PatchState.PCK.begins_with(PatchState.DIR)
		and PatchState.STATE.begins_with(PatchState.DIR), "补丁文件都在 user://patch 底下")
	## ⚠ 基线号**必须是脚本常量**，不能放进 .txt：导出预设是 `export_filter="all_resources"`，
	## 而没有导入器的散文件不算 resource —— 2026-09-09 第一版放在 base_build.txt 里，
	## 根本没进导出包，线上读出来是 0、每次都判「基线太老」，补丁一个也收不到。
	check(PatchState.base_build() == PatchState.BASE_BUILD and PatchState.BASE_BUILD > 0,
		"基线号读得出来且来自脚本常量（散文件进不了导出包）")

	## ---- 第二阶段：「该不该装这个补丁」的判定（纯函数）----
	var Boot := load("res://scripts/boot.gd")
	var SHA := "a".repeat(64)
	var good := { "build": 200, "min_base": 100, "sha256": SHA,
		"pck": Boot.HOST + "patch-latest/patch-200.pck" }

	check(Boot.decide(good, 100, 0, 100)["act"] == "install", "有更新且基线够 → 装")
	check(Boot.decide({}, 0, 0, 100)["act"] == "skip", "拿不到 manifest（断网/超时）→ 照原样进游戏")
	check(Boot.decide(good, 200, 0, 100)["act"] == "skip", "已经是这一版 → 不动")
	check(Boot.decide(good, 300, 0, 100)["act"] == "skip", "本地比它新 → 不动（不许降级）")
	## 没有这一条会**死循环**：坏补丁挂了→隔离→manifest 还推同一版→又下→又挂
	check(Boot.decide(good, 0, 200, 100)["act"] == "skip", "这一版装崩过 → 永不再下")
	check(Boot.decide(good, 100, 0, 99)["act"] == "too_old",
		"基线比 min_base 老 → 提示下完整包，而不是硬套一个可能用不了的补丁")
	## 读不出基线时**放行**，两种失败模式的代价不对称：拦错了 = 热更看着在跑其实一个补丁都收不到
	## （2026-09-09 真踩过），放行错了有 SHA 校验、启动证明期与拉黑名单兜着。
	check(Boot.decide(good, 100, 0, 0)["act"] == "install",
		"基线读不出来（0）→ 放行，而不是一律判太老")

	## manifest 不干净就当没看见 —— 它给的地址与指纹都要再挡一道
	var evil: Dictionary = good.duplicate()
	evil["pck"] = "https://evil.example.com/patch.pck"
	check(Boot.decide(evil, 100, 0, 100)["act"] == "skip", "下载地址不在写死的前缀底下 → 拒绝")
	evil = good.duplicate()
	evil["pck"] = "http://github.com/Kevinnb66699/Cell-War/releases/download/x/p.pck"
	check(Boot.decide(evil, 100, 0, 100)["act"] == "skip", "明文 http → 拒绝（HOST 本身带 https）")
	for bad_sha in ["", "abc", "z".repeat(64), "a".repeat(63)]:
		evil = good.duplicate()
		evil["sha256"] = bad_sha
		if Boot.decide(evil, 100, 0, 100)["act"] != "skip":
			check(false, "指纹「%s」应被拒绝" % bad_sha)
			break
	check(true, "指纹必须是 64 位十六进制，否则拒绝（空 / 太短 / 非法字符都试过）")
	check(Boot.HOST.begins_with("https://github.com/"), "下载来源写死在常量里且是 HTTPS")

	## **一次启动失败不该判死刑。** 2026-09-09 验下载链路时真误伤过：截图工具 5 秒杀进程，
	## 补丁没活到 mark_good，下一次开机就把一个好补丁永久拉黑了 ——
	## 换成玩家就是「开了游戏随手关掉」。真坏的补丁每次都起不来，两次就够认。
	check(PatchState.STRIKES >= 2, "要连续失败 %d 次才永久拉黑（不是一次）" % PatchState.STRIKES)
	check(PatchState.PROVE_SEC > 0.0 and PatchState.PROVE_SEC <= 5.0,
		"证明期 %.1f 秒：够盖住主场景构建与首帧，又不至于长到随手一关就算失败"
			% PatchState.PROVE_SEC)


func t_save_load() -> void:
	print("[存档读档]")
	CWSave.clear()
	check(not CWSave.exists(), "起手无档")
	check(not CWSave.can_continue(), "起手没有可恢复的档")
	var g := make_game(2, 88)
	check(not CWSave.write(g, [0], false), "还没到 pending 边界：拒写")
	await run_setup(g)
	## 走到第 2 回合的第一个询问再存：每步都选最后一项「结束回合」，谁也不花钱、谁也死不了。
	## 此前是随机走 30 步 —— 2026-09-05 有氧基数一改（2 人局 2.5→2.0），随机序列跟着变，
	## 癌细胞把自己花死、局在第 1 回合就结束，存档点根本没等到。存档测的是快照往返，不该被数值牵着走。
	while g.round_no < 2:
		var walk: Dictionary = await g.pending()
		if walk.is_empty():
			break
		await g.step(walk["options"].size() - 1)
	var req: Dictionary = await g.pending()
	check(not req.is_empty(), "停在一个待决询问上（第 %d 回合）" % g.round_no)
	check(CWSave.write(g, [0], true), "pending 边界：写档成功")
	check(CWSave.exists(), "档落在盘上")
	check(CWSave.can_continue(), "完整 v1 档可以继续")
	var h0 := g.state_hash()

	var data := CWSave.read()
	check(data["players"] == 2 and CWSave.ai_level_of(data) == CWMatch.AI_MC
		and int(data["human"][0]) == 0,
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
	## 文件存在但内容坏了时，菜单不能点亮「继续对局」。
	var bad := FileAccess.open(CWSave.PATH, FileAccess.WRITE)
	bad.store_string("not a save")
	bad.close()
	check(CWSave.exists() and not CWSave.can_continue(), "损坏档存在但不可继续")
	## 结构截断同样必须拒绝，避免点击后 restore() 才爆。
	bad = FileAccess.open(CWSave.PATH, FileAccess.WRITE)
	bad.store_string(var_to_str({ "version": CWSave.VERSION, "players": 2,
		"human": [0], "smart": false, "snap": {} }))
	## 老档没有 ai_level，按 smart 折回两档；新档以 ai_level 为准（三档都存得住）
	check(CWSave.ai_level_of({ "smart": false }) == CWMatch.AI_NORMAL
		and CWSave.ai_level_of({ "smart": true }) == CWMatch.AI_MC,
		"老档：按 smart 折回普通 / 较强")
	check(CWSave.ai_level_of({ "smart": true, "ai_level": CWMatch.AI_MCTS }) == CWMatch.AI_MCTS,
		"新档：以 ai_level 为准，第三档存得住")
	bad.close()
	check(not CWSave.can_continue(), "截断快照不可继续")

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


# ---- 组织转换：CWTissue 是 tissue 及关联生命周期字段的唯一所有者 ----
func t_tissue_transitions() -> void:
	print("[组织转换不变量]")
	var g := make_game(2, 71)
	g.setup.build_board()
	var special: Vector2i = CWData.MARROWS[0]
	var t: Dictionary = g.tile(special)
	t["store"] = 30
	t["cards"] = 2
	t["prod"] = 1
	t["mucus"] = true
	t["solid"] = 20
	t["necrosis"] = 4
	t["newborn"] = true
	CWTissue.to_healthy(t)
	check(CWTissue.is_valid(t) and t["necrosis"] == 0, "转健康：清除固化/新生/坏死组合")
	check(t["store"] == 30 and t["cards"] == 2 and t["prod"] == 1 and t["mucus"],
		"无关转换保留特殊组织库存与黏液")
	CWTissue.to_cancer(t, true)
	check(CWTissue.is_valid(t) and t["newborn"], "转癌：显式保留本回合新生语义")
	CWTissue.to_solid(t)
	check(CWTissue.is_valid(t) and not t["newborn"], "转固化：清除新生与坏死")
	CWTissue.crack_to_cancer(t)
	check(CWTissue.is_valid(t) and not t["newborn"] and t["solid"] == 0,
		"拆固化：降级为非新生普通癌组织")

	# 进入格子：坏死健康组织定殖后不能同时是癌组织和坏死。
	var colonize := Vector2i(1, 0)
	g.tile(colonize)["necrosis"] = 3
	var cancer := CWSetup.make_cell(0, 0, CWData.Faction.CANCER, Vector2i.ZERO,
		-1, CWData.CancerType.MELANOMA)
	g.cells.append(cancer)
	await g.actions.enter_tile(cancer, colonize)
	check(CWTissue.is_valid(g.tile(colonize)) and g.tile(colonize)["newborn"],
		"进入格子：定殖清除坏死并标为新生")

	# 侵蚀与增生都必须通过同一条新生转癌路径。
	var erode := Vector2i(2, 0)
	for c in g.tiles.keys():
		CWTissue.to_cancer(g.tile(c), false)
	CWTissue.to_healthy(g.tile(erode))
	g.tile(erode)["necrosis"] = 2
	g.world._erosion()
	check(CWTissue.is_valid(g.tile(erode)) and g.tile(erode)["newborn"],
		"侵蚀：坏死健康格转癌后坏死清零")
	for c in g.tiles.keys():
		CWTissue.to_healthy(g.tile(c))
	var source := Vector2i.ZERO
	var grow := Vector2i(1, 0)
	CWTissue.to_cancer(g.tile(source), false)
	g.tile(grow)["necrosis"] = 2
	g.tune.proliferate_per_adjacent = 1000
	g.world._proliferate()
	check(CWTissue.is_valid(g.tile(grow)) and g.tile(grow)["newborn"],
		"增生：坏死健康格转癌后坏死清零")

	# 放疗、基质重塑、复活分别覆盖健康、拆固化与复活的转换语义。
	var radio := Vector2i(-1, 0)
	CWTissue.to_cancer(g.tile(radio), false)
	g.card_fx._radiotherapy(radio)
	check(g.tile(radio)["tissue"] == CWData.Tissue.HEALTHY and g.tile(radio)["necrosis"] > 0,
		"放疗：癌组织先转健康，再施加坏死")
	var solid := Vector2i(-2, 0)
	CWTissue.to_cancer(g.tile(solid), false)
	g.tile(solid)["solid"] = g.tune.solidify_threshold
	CWTissue.to_solid(g.tile(solid))
	var stop_bridge := CWBridge.new()
	stop_bridge.game = g
	g.bridges[0] = stop_bridge  # 基质重塑的「最多」分支固定选择停止，便于只验拆固化。
	await g.card_fx._remodel(cancer, solid)
	check(CWTissue.is_valid(g.tile(solid)) and g.tile(solid)["tissue"] == CWData.Tissue.CANCER,
		"基质重塑：固化组织降级后不误标新生")
	var revive := Vector2i(-3, 0)
	g.tile(revive)["solid"] = g.tune.solidify_threshold
	CWTissue.to_solid(g.tile(revive))
	g.tile(revive)["necrosis"] = 3  # 构造旧代码曾能留下的非法状态。
	cancer["alive"] = false
	await g.world.revive_cancer(0, { "to": revive })
	check(CWTissue.is_valid(g.tile(revive)) and g.tile(revive)["tissue"] == CWData.Tissue.CANCER,
		"复活：固化组织降级后清除坏死")
	for tile in g.tiles.values():
		check(CWTissue.is_valid(tile), "全盘组织状态符合不变量")
	g.dispose()


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


## **shader 的 fragment 里不许 `return`** —— Godot 4 直接拒绝编译，
## 而且**失败是静默的**：`load()` 照样给你一个 Shader 对象，`preload` 也不报错，
## 只有真正渲染那一刻才在控制台吐一行 SHADER ERROR，画面上就是「这个效果没了」。
##
## 2026-09-08 撞上一次：`solid_progress.gdshader`（癌细胞固化进度外圈）从上线起
## 就是这么写的，一直没画出来，直到新写 store_progress 时报同一条错才发现。
## 这条护栏就是不让它再发生第二次 —— 无头测试渲染不了，只能从源码上守。
func t_shader_no_return() -> void:
	print("[shader 源码护栏]")
	var dir := DirAccess.open("res://assets/shaders")
	check(dir != null, "打得开 shader 目录")
	if dir == null:
		return
	var bad: Array = []
	var seen := 0
	for f in dir.get_files():
		if not f.ends_with(".gdshader"):
			continue
		seen += 1
		var src := FileAccess.get_file_as_string("res://assets/shaders/" + f)
		var at := src.find("void fragment()")
		if at < 0:
			continue
		## 只看 fragment 这一段：vertex / 自定义函数里的 return 是合法的
		var rest := src.substr(at)
		var stop := rest.find("\nvoid ", 1)
		if stop > 0:
			rest = rest.substr(0, stop)
		## **先把注释剥掉**：这条护栏自己的说明就写着「fragment 里不许 return」，
		## 不剥的话它会指着自己的注释报错（2026-09-08 当场误报了一次）。
		var code := ""
		for line in rest.split("\n"):
			var c: int = line.find("//")
			code += (line if c < 0 else line.substr(0, c)) + "\n"
		if code.contains("return"):
			bad.append(f)
	check(seen >= 4, "扫到了 %d 个 shader（漏扫等于没守）" % seen)
	check(bad.is_empty(), "没有 shader 在 fragment 里 return（犯规的：%s）" % str(bad))


## 没能量时**不再替玩家自动结束回合**（Kevin 2026-09-08 要求删掉）。
##
## 删之前是「只剩「结束回合」一个选项 → 直接跳过这一席」。玩家那边看到的是
## 「还没轮到我就过去了」，读不出这是「我确实没得动了」还是程序漏了我。
##
## 这条**删掉的时候一条测试都没红** —— 那个行为从来没人守。补上，免得哪天又被顺手加回去。
func t_no_auto_end_turn() -> void:
	print("[没能量也照样问]")
	var g := make_game(2, 11)
	await run_setup(g)
	## 把当前这一席榨干：0 能量、没手牌 —— 除了「结束回合」什么都做不了
	var req: Dictionary = await g.pending()
	check(not req.is_empty(), "开局停在一问上")
	var cell: Dictionary = g.cell_of(int(req["pid"]))
	cell["energy"] = 0
	cell["hand"] = []
	var opts: Array = g.actions.build_options(cell)
	check(opts.size() == 1 and opts[0]["data"].get("act", "") == "end",
		"0 能量的细胞只剩「结束回合」一个选项（实为 %d 个）" % opts.size())

	## **关键一条**：把**另一席**也榨干，然后结束当前这一席。
	## 询问是提前建好的，所以只能拿下一席来验 —— 删改之前它会被静默跳过，
	## 现在必须照样弹出一问（哪怕那一问里只有「结束回合」）。
	for other in g.cells:
		other["energy"] = 0
		other["hand"] = []
	var pid0: int = int(req["pid"])
	var end_at := -1
	for i in req["options"].size():
		if req["options"][i]["data"].get("act", "") == "end":
			end_at = i
	check(end_at >= 0, "当前这一问里找得到「结束回合」")
	await g.step(end_at)
	var nxt: Dictionary = await g.pending()
	check(not nxt.is_empty() and nxt.get("kind", "") == "action"
			and int(nxt["pid"]) != pid0,
		"下一席没能量也照样被问到，不再自动跳过（kind=%s pid=%s）"
			% [str(nxt.get("kind", "")), str(nxt.get("pid", -1))])
	check(nxt["options"].size() == 1
			and nxt["options"][0]["data"].get("act", "") == "end",
		"那一问里确实只剩「结束回合」——玩家自己按，不替他按")
	g.dispose()


## 【突变】三个面各自的结算。
##
## **这一组是 2026-09-08 补的**：那天 PRD 把第 3 面从「扣 1.0 / 削 3 记忆」改成
## 「扣 0.8 / 削 2 记忆」，改完**一条测试都没红** —— 三个面此前根本没人验。
## 掷骰那半（roll_shown）不在这里，`apply_mutation` 收下点数直接结算，正好单独验。
func t_mutation_faces() -> void:
	print("[突变三面]")
	var g := bare_game()
	var can := CWSetup.make_cell(0, 1, CWData.Faction.CANCER, Vector2i(0, 0), -1,
		CWData.CancerType.MELANOMA, 100)
	g.cells.append(can)
	g.memory = 50

	## 第 1 面：什么都不动
	var e0: int = can["energy"]
	var m0: int = g.memory
	await g.actions.apply_mutation(can, 1)
	check(can["energy"] == e0 and g.memory == m0, "第 1 面：无事发生，能量与记忆都不动")

	## 第 2 面：抽一张 + 削 1 记忆
	var h0: int = can["hand"].size()
	await g.actions.apply_mutation(can, 2)
	check(can["hand"].size() == h0 + 1 and g.memory == m0 - 1,
		"第 2 面：抽 1 张、削 1 抗原记忆（手牌 %d→%d，记忆 %d→%d）"
			% [h0, can["hand"].size(), m0, g.memory])

	## 第 3 面：再扣能量 + 削记忆。**数值现读常量**——写死的话下次改 PRD 又会悄悄溜过去
	var e1: int = can["energy"]
	var m1: int = g.memory
	await g.actions.apply_mutation(can, 3)
	check(can["energy"] == e1 - CWData.MUTATE_EXTRA_LOSS,
		"第 3 面：再扣 %s 能量" % CWData.fmt(CWData.MUTATE_EXTRA_LOSS))
	check(g.memory == m1 - CWData.MUTATE_MEMORY_CUT,
		"第 3 面：削 %d 抗原记忆" % CWData.MUTATE_MEMORY_CUT)
	check(CWData.MUTATE_EXTRA_LOSS == 8 and CWData.MUTATE_MEMORY_CUT == 2,
		"当前定值 = 0.8 能量 / 2 记忆（PRD 2026-09-08）")

	## 第 3 面的扣减是**效果扣减不是费用支付**，所以可致死（规则总则）
	can["energy"] = CWData.MUTATE_EXTRA_LOSS
	await g.actions.apply_mutation(can, 3)
	check(not can["alive"], "第 3 面扣到 0 → 死亡（效果扣减可致死，区别于费用支付）")

	## 记忆不会被削成负数
	g.memory = 1
	var alive := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(2, 0), -1,
		CWData.CancerType.SIGNET, 100)
	g.cells.append(alive)
	await g.actions.apply_mutation(alive, 3)
	check(g.memory == 0, "记忆削到 0 就停，不会变负")
	g.dispose()


## 【I-标记】光环范围的常驻粒子（Kevin 2026-09-08）。
##
## 轨道是**纯函数**，所以这几条不用真渲染就能守 —— 同 chemo_fx 那套纪律。
## 「整体密度合不合适」代码验不了，那个看 `tests/preview_mark_aura.gd` 的图。
func t_mark_aura() -> void:
	print("[标记光环粒子]")
	check(CWMarkAuraFx.SEED_OFFSET.size() >= CWMarkAuraFx.PER_TILE,
		"每格 %d 个粒子，起手偏移表够用" % CWMarkAuraFx.PER_TILE)

	## 时间量化：同一格时间里任何时刻画出来都一样（像逐帧动画，不逐帧平滑）
	var f0 := CWMarkAuraFx.frame_of(1.0)
	check(CWMarkAuraFx.frame_of(1.0 + 0.5 / CWMarkAuraFx.PIX_FPS) == f0,
		"同一格时间内帧号不变（%d）" % f0)
	check(CWMarkAuraFx.frame_of(1.0 + 1.5 / CWMarkAuraFx.PIX_FPS) == f0 + 1, "跨一格就 +1")

	## 相位：同一格每次都给同一个值（否则粒子会原地乱跳），且落在 0~1
	var t1 := Vector2(120.0, -44.0)
	check(is_equal_approx(CWMarkAuraFx.phase_of(t1), CWMarkAuraFx.phase_of(t1)),
		"同一格的相位是稳定的")
	var phases := {}
	for c in CWData.all_coords():
		var ph := CWMarkAuraFx.phase_of(Vector2(c) * 36.0)
		if ph < 0.0 or ph >= 1.0:
			phases["bad"] = ph
	check(not phases.has("bad"), "所有格子的相位都落在 [0,1)")

	## 进度在 [0,1)；透明度只取分档表里的值，没有连续渐变
	var bad_prog := 0
	var bad_alpha := 0
	for fr in 40:
		var prog := CWMarkAuraFx.progress_of(fr, 0.37)
		if prog < 0.0 or prog >= 1.0:
			bad_prog += 1
		if not CWMarkAuraFx.ALPHA_STEPS.has(CWMarkAuraFx.alpha_of(prog)):
			bad_alpha += 1
	check(bad_prog == 0, "进度始终落在 [0,1)")
	check(bad_alpha == 0, "透明度只取分档表里的值（不做连续渐变）")

	## **粒子不许跑出自己的格子**：这是第一版真栽过的地方——飘 11px 会跨进邻格，
	## 整片就成了随机闪烁，看不出范围。格宽 36，所以半格 18 是硬线。
	var max_off := 0.0
	for k in CWMarkAuraFx.PER_TILE:
		for dir in [Vector2(1, 0), Vector2(-1, 0), Vector2(0.7, 0.7), Vector2(0, -1)]:
			for step in 20:
				var off: Vector2i = CWMarkAuraFx.offset_at(k, dir, step / 19.0)
				max_off = maxf(max_off, Vector2(off).length())
	check(max_off < 18.0, "粒子始终留在自己格子里（最远 %.1f < 半格 18）" % max_off)

	## 朝树突飘：进度越大离树突越近。方向性正是「这一片归那只细胞管」的读法来源
	var toward := Vector2(0, -100)          ## 树突在正上方
	var near: Vector2i = CWMarkAuraFx.offset_at(0, toward, 1.0)
	var far: Vector2i = CWMarkAuraFx.offset_at(0, toward, 0.0)
	check(near.y < far.y, "粒子朝树突那一侧移动（y %d → %d）" % [far.y, near.y])

	## **每格必须拿自己那格的 z**。棋盘按排分层（组织块 z = 自己的 y，前一排 +20），
	## 整只演出共用一个 z 的话，靠前那几排会正正当当把粒子盖掉 ——
	## Kevin 2026-09-08 报的「有时候不显示」就是这个，而且树突站得越靠后盖得越多。
	var board := make_board()
	var fx := CWMarkAuraFx.new()
	board.add_child(fx)
	var at := Vector2i.ZERO
	var tiles: Array = []
	for c in CWData.all_coords():
		var dist := CWData.hex_dist(c, at)
		if dist > 0 and dist <= CWData.MARK_RANGE:
			tiles.append({ "pos": board.tile_center(c), "z": board.tile_z(c, board.Z_MARK) })
	fx.sync(0.1, [{ "origin": board.tile_center(at), "tiles": tiles }])
	var zs := {}
	var shown := 0
	for ch in fx.get_children():
		if (ch as Node2D).visible:
			shown += 1
			zs[(ch as Node2D).z_index] = true
	check(shown == tiles.size(), "范围内 %d 格各有一个节点（实为 %d）" % [tiles.size(), shown])
	check(zs.size() > 1, "这些节点的 z **不是同一个**（按排分层，共用一个 z 就会被盖住）")
	## 每格的 z 必须正好等于那一格的 Z_MARK 层 —— 差一层就会钻到别的排后面
	var want := {}
	for e in tiles:
		want[int(e["z"])] = true
	check(zs.keys().size() == want.keys().size(), "z 的取值与棋盘给的逐一对上")
	## 树突走开 / 死了：多出来的节点要藏起来，不能留在场上
	fx.sync(0.1, [])
	var left := 0
	for ch in fx.get_children():
		if (ch as Node2D).visible:
			left += 1
	check(left == 0 and not fx.visible, "场上没树突 → 全部藏起来")
	board.queue_free()


## 「回合末会被压死」的预警（Kevin 2026-09-08：能量 < 回合末压迫时做个特效）。
##
## **这一组的重点不是「大于还是小于」，是「别自己另算一份」**：压迫走的是完整的
## 伤害管线，【缺氧适应】那面 −1.0 的盾在管线里。界面若拿 `energy < pressure_at()`
## 糊弄，就会对着一只死不了的细胞报警 —— 误报的预警比没有预警更糟，
## 玩家会为了躲一个不存在的死亡白跑一趟。
func t_pressure_doom() -> void:
	print("[回合末必死预警]")
	var g := bare_game()
	var at := Vector2i.ZERO
	var imm := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, at,
		CWData.ImmuneType.BASIC, -1)
	var can := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(5, 0), -1,
		CWData.CancerType.MELANOMA)
	g.cells.append(imm)
	g.cells.append(can)

	## 没有压迫的地方：一律不报
	check(not g.world.pressure_lethal(imm), "脚下没压迫 → 不报警")

	## 四癌两健康 → 加权和 2 → 1/4 × 2 = 0.5
	var nb: Array = CWData.neighbors(at)
	for i in nb.size():
		g.tiles[nb[i]]["tissue"] = CWData.Tissue.CANCER if i < 4 else CWData.Tissue.HEALTHY
	var raw: int = g.world.pressure_at(at)
	check(raw == 5, "场景：脚下压迫 %s" % CWData.fmt(raw))

	imm["energy"] = raw + 1
	check(not g.world.pressure_lethal(imm), "能量比压迫多一点 → 不报警")
	imm["energy"] = raw
	check(g.world.pressure_lethal(imm),
		"能量正好等于压迫 → 报警（减到 0 就算死，不用减成负数）")
	imm["energy"] = raw - 1
	check(g.world.pressure_lethal(imm), "能量比压迫少 → 报警")

	## **最要紧的一条**：有盾时不许报。【缺氧适应】在损失管线里减 1.0，
	## 拿 `energy < pressure_at()` 糊弄的话这里必然误报
	imm["hand"] = ["缺氧适应"]
	await g.card_fx.play(imm, { "act": "play", "card": "缺氧适应" })
	check(not g.world.pressure_lethal(imm),
		"【缺氧适应】的盾吃掉了这点压迫 → **不报警**（界面不能自己算）")

	## 预警是纯查询：问一遍不能动任何状态
	var e0: int = imm["energy"]
	var n0: int = g.logs.size()
	for i in 5:
		g.world.pressure_lethal(imm)
	check(imm["energy"] == e0 and g.logs.size() == n0,
		"连问 5 次：能量没动、一条日志都没多（界面每帧都要问）")

	## 癌细胞不吃压迫，别给它报
	can["pos"] = at
	can["energy"] = 1
	check(not g.world.pressure_lethal(can), "癌细胞不吃压迫 → 不报警")
	## 死人也不报
	imm["alive"] = false
	check(not g.world.pressure_lethal(imm), "死了的不报警")

	## 脉冲透明度：始终落在设定的两档之间
	var lo := 9.0
	var hi := -9.0
	for ms in range(0, 2000, 37):
		var a := CWMatch.doom_pulse(ms)
		lo = minf(lo, a)
		hi = maxf(hi, a)
	check(lo >= CWMatch.DOOM_ALPHA.x - 0.001 and hi <= CWMatch.DOOM_ALPHA.y + 0.001,
		"脉冲透明度在 [%.2f, %.2f] 之间（实测 %.2f~%.2f）"
			% [CWMatch.DOOM_ALPHA.x, CWMatch.DOOM_ALPHA.y, lo, hi])
	g.dispose()


## 黑色素瘤【早期血行转移】的按钮价签（Kevin 2026-09-08：「黑色素放不出血行转移，
## 这回合并没有使用过这个技能」，截图里按钮写着 1.0、细胞有 6.9 能量，却是灰的）。
##
## 根因：**按钮上的价签和「能不能用」的判定不是同一个数**。
## 判定走 `skill_move_cost`（过【基质阻隔】的翻倍），价签直接返回常量 1.0。
## 于是「写着 1.0、我有 6.9、却点不动」——玩家只能理解成 bug。
##
## 【转移】（小细胞肺癌）同一条路，一并验。
func t_skill_move_price_tag() -> void:
	print("[技能移动的价签]")
	var g := make_game(2, 7)
	g.setup.build_board()
	var vessel: Vector2i = CWData.VESSELS[0]
	var mel := CWSetup.make_cell(0, 1, CWData.Faction.CANCER, vessel, -1,
		CWData.CancerType.MELANOMA, 69)
	g.cells.append(mel)
	var bridge := CWUIBridge.new()
	bridge.game = g

	## ① 没有【基质阻隔】时：价签 = 真费用，按钮亮着
	var base_tag: String = bridge._cost_text(mel, "homing")
	var base_real: int = g.actions.skill_move_cost(mel, CWData.MELANOMA_HOMING_COST)
	check(base_tag == CWData.fmt(base_real),
		"没有世界事件时价签 %s = 真费用 %s" % [base_tag, CWData.fmt(base_real)])

	## ② 挂上【基质阻隔】：真费用翻倍，价签必须跟着翻
	g.events["active"].append({ "name": "基质阻隔", "left": 2, "stacks": 2, "data": {} })
	var tag: String = bridge._cost_text(mel, "homing")
	var real: int = g.actions.skill_move_cost(mel, CWData.MELANOMA_HOMING_COST)
	## 2 层 ×2 就该是 ×4。**曾经是 ×16** —— 层数在 `_emit` 和 `_apply` 里各算了一遍
	## （单层时两种算法结果相同，所以这个坑一直没露头）。
	check(real == base_real * 4,
		"2 层【基质阻隔】= ×4（%s → %s），不是把层数算两遍的 ×16"
			% [CWData.fmt(base_real), CWData.fmt(real)])
	check(tag == CWData.fmt(real),
		"价签跟着涨到 %s（曾经写死成基础价 %s，于是「写着 1.0 我有 6.9 却点不动」）"
			% [CWData.fmt(real), tag])

	## ③ 价签与「能不能用」必须同口径：付得起就该有选项，付不起就该没有
	## `can_pay` 是**严格大于**（付完至少要留 0.1），所以「正好等于」是付不起的
	mel["energy"] = real + 1
	var opts: Array = g.actions.build_options(mel)
	var has_homing := false
	for o in opts:
		if o["data"].get("act", "") == "homing":
			has_homing = true
	check(has_homing, "比真费用多 0.1 → 出得来（费用 %s）" % CWData.fmt(real))
	mel["energy"] = real
	opts = g.actions.build_options(mel)
	has_homing = false
	for o in opts:
		if o["data"].get("act", "") == "homing":
			has_homing = true
	check(not has_homing, "正好等于真费用 → 出不来（付完要留 0.1）；此时按钮该灰、价签写的就是这个数")

	## ④ 小细胞肺癌【转移】走同一条报价，别只修一个
	var sclc := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(0, 0), -1,
		CWData.CancerType.SCLC, 200)
	g.cells.append(sclc)
	check(bridge._cost_text(sclc, "jump")
			== CWData.fmt(g.actions.skill_move_cost(sclc, g.tune.metastasis_cost)),
		"【转移】的价签同样跟着世界事件走")
	g.dispose()


## 受【双重触发】影响的世界事件要在界面上标出来（Kevin 2026-09-08：
## 「不然玩家们不知道有双重触发」）。
##
## **三档都要验**。原来只有「数值翻倍」那一档因为 stacks>1 顺带露出个「×2」，
## 另外两档（持续翻倍、连演两回合）在界面上和普通事件长得一模一样 ——
## 玩家看不出这一条为什么格外难缠，只会觉得是 bug（血行转移那次就是这么来的）。
func t_doubled_marker() -> void:
	print("[双重触发的标记]")
	var g := make_game(2, 3)
	g.setup.build_board()

	## ---- ① 引擎：三档各自记下自己是哪一档 ----
	## 「数值类」持续事件 → stacks=2
	var got := {}
	for probe in [{"name": "基质阻隔", "want": "stacks"},      ## 持续 + 可叠
			{"name": "抗原引导", "want": "rounds"},               ## 持续 + 不可叠（开关类）
			{"name": "营养缺乏", "want": "repeat"}]:               ## 本回合类
		var name: String = probe["name"]
		g.events["active"] = []
		g.events["pool"] = [name]
		g.events["double_next"] = true
		g.world_fx.trigger()
		var e: Dictionary = {}
		for x in g.events["active"]:
			if x["name"] == name:
				e = x
		got[name] = String(e.get("doubled", "")) if not e.is_empty() else "（没挂上）"
		check(got[name] == probe["want"],
			"【%s】被双重触发 → 记作 %s（实为 %s）" % [name, probe["want"], got[name]])

	## 没有【双重触发】时不该留下标记
	g.events["active"] = []
	g.events["pool"] = ["基质阻隔"]
	g.events["double_next"] = false
	g.world_fx.trigger()
	var plain: Dictionary = g.events["active"][0]
	check(String(plain.get("doubled", "")) == "", "没被双重触发 → 不留标记")

	## ---- ② 界面：名字后面挂「双重」，三档都挂 ----
	var txt_plain := CWMatchPanel.active_events_text(g)
	check(not txt_plain.contains("双重"), "普通事件行不出现「双重」（%s）" % txt_plain)

	for mode in ["stacks", "rounds", "repeat"]:
		g.events["active"] = [{ "name": "基质阻隔", "left": 2, "stacks": 1,
			"doubled": mode, "data": {} }]
		var txt := CWMatchPanel.active_events_text(g)
		check(txt.contains("【基质阻隔·双重】"),
			"%s 档也挂上了「双重」标（%s）" % [mode, txt])

	## ---- ③ 悬浮详情：三档说三件不同的事 ----
	var lines := {}
	for mode in ["stacks", "rounds", "repeat"]:
		lines[mode] = CWMatchPanel.doubled_line(mode)
		check(lines[mode] != "", "%s 档有自己的说明" % mode)
	check(lines["stacks"] != lines["rounds"] and lines["rounds"] != lines["repeat"]
			and lines["stacks"] != lines["repeat"],
		"三档的说明各不相同 —— 「数值翻倍」和「多演一个回合」玩家的应对完全不同")
	check(CWMatchPanel.doubled_line("") == "", "没被加倍时不出这一句")

	## ---- ④ 旧存档没有这个键：不能因为补字段就炸 ----
	g.events["active"] = [{ "name": "基质阻隔", "left": 2, "stacks": 1, "data": {} }]
	var old_txt := CWMatchPanel.active_events_text(g)
	check(old_txt.contains("基质阻隔") and not old_txt.contains("双重"),
		"旧档（没有 doubled 键）照读不误，也不误标（%s）" % old_txt)
	g.dispose()


## 「关闭世界事件」开关（Kevin 2026-09-08：单机与联机都要能整局关掉）。
func t_world_events_off() -> void:
	print("[世界事件总开关]")

	## ---- ① 关掉就不触发，事件池原样留着 ----
	var g := make_game(2, 5)
	g.setup.build_board()
	var pool_n: int = g.events["pool"].size()
	g.tune.world_events_on = false
	for i in 3:
		g.world_fx.trigger()
	check(g.events["active"].is_empty(), "关掉后连触发 3 次：一个事件都没挂上")
	check(g.events["pool"].size() == pool_n,
		"事件池一张没少（%d）—— 中途拨回来还能照常开抽" % g.events["pool"].size())

	## ---- ② 拨回来立刻恢复 ----
	g.tune.world_events_on = true
	g.world_fx.trigger()
	check(not g.events["active"].is_empty() or g.events["double_next"],
		"拨回来 → 照常抽（抽到【双重触发】时它不挂 active，所以两者取其一）")
	check(g.events["pool"].size() == pool_n - 1, "池里少了一张")

	## ---- ③ **必须进 RULE_FIELDS**：联机靠快照把它带给客户端 ----
	check("world_events_on" in CWTuning.RULE_FIELDS,
		"world_events_on 在 RULE_FIELDS 里 —— 否则客户端影子对局会以为该放事件，两边对不上账")
	var off := make_game(2, 5)
	off.setup.build_board()
	off.tune.world_events_on = false
	var snap: Dictionary = CWStateCodec.snapshot(off)
	var shadow := make_game(2, 999)
	shadow.setup.build_board()
	check(shadow.tune.world_events_on, "影子对局默认是开的")
	CWStateCodec.restore(shadow, snap)
	check(not shadow.tune.world_events_on, "快照还原之后跟着关上了（联机就靠这一条）")
	off.dispose()
	shadow.dispose()
	g.dispose()

	## ---- ④ 右栏那行别再倒计时一个永远不来的事件 ----
	var g2 := make_game(2, 5)
	g2.setup.build_board()
	var p := CWMatchPanel.new()
	root.add_child(p)
	await process_frame
	p.refresh(g2)
	check(p._phase.text.contains("世界事件"), "开着时那行照旧写世界事件")
	g2.tune.world_events_on = false
	p.refresh(g2)
	check(p._phase.text.contains("已关闭"),
		"关掉后写「已关闭」，不再倒计时（%s）" % p._phase.text)
	p.queue_free()
	g2.dispose()

	## ---- ⑤ 单机：配置面板拨得动、进得了 cfg ----
	var cp := CWConfigPanel.new()
	root.add_child(cp)
	await process_frame
	cp.open()
	check(cp.config()["world_events"], "默认开")
	check(cp._value_text(CWConfigPanel.ROW_EVENTS) == "开", "值文案：开")
	cp._cycle(CWConfigPanel.ROW_EVENTS, 1)
	check(not cp.config()["world_events"]
			and cp._value_text(CWConfigPanel.ROW_EVENTS).begins_with("关"),
		"拨一下 → 关（%s）" % cp._value_text(CWConfigPanel.ROW_EVENTS))
	cp._cycle(CWConfigPanel.ROW_EVENTS, 1)
	check(cp.config()["world_events"], "再拨一下 → 拨回开（两档来回）")
	cp.queue_free()

	## ---- ⑥ 联机：房间存得住、房间状态里说得出 ----
	var room := CWRoom.new()
	room.configure(null, "TEST", 4, 60, true, false)
	check(not room.world_events, "建房时拨的「关」存进了房间")
	check(room.summary().get("world_events", true) == false,
		"大厅列表里也带着 —— 进来的人看得到这房不放事件")
	var room2 := CWRoom.new()
	room2.configure(null, "TEST2", 4, 60, true)
	check(room2.world_events, "不传这个参数时默认开（= 改动之前的行为）")


## PRD 2026-09-08 云端版的新术语「n 环」（曼哈顿距离 ≤ n，**含中心格**），
## 以及它带来的第一处真实范围变化：【细胞毒素】由「相邻所有格」改成「1 环」。
func t_ring_and_toxin() -> void:
	print("[n 环 · 细胞毒素含中心格]")
	var r0: Array[Vector2i] = CWData.ring(Vector2i.ZERO, 0)
	check(r0.size() == 1 and r0[0] == Vector2i.ZERO, "0 环 = 只有中心格本身")
	var r1: Array[Vector2i] = CWData.ring(Vector2i.ZERO, 1)
	check(r1.size() == 7 and r1.has(Vector2i.ZERO),
		"1 环 = 中心 + 六个邻格 = 7 格（实为 %d）" % r1.size())
	check(CWData.ring(Vector2i.ZERO, 2).size() == 19, "2 环 = 19 格")
	## 棋盘外不算：最边上的格子环里格数会少
	check(CWData.ring(Vector2i(6, 0), 1).size() < 7, "贴边的格子：棋盘外的方向不计")

	## **含中心格是真的会差一格**：免疫细胞确实可能站在癌组织上
	## （骨样硬化标记过的格要蹲一回合才净化，传送/卡牌位移进来的也没净化）
	var g := bare_game()
	var at := Vector2i(2, 0)
	var t := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, at, CWData.ImmuneType.T_CELL, -1, 200)
	g.cells.append(t)
	g.tiles[at]["tissue"] = CWData.Tissue.CANCER          ## 脚下这格
	g.tiles[CWData.neighbors(at)[0]]["tissue"] = CWData.Tissue.CANCER
	await g.actions._do_toxin(t)
	check(g.tile(at)["tissue"] == CWData.Tissue.HEALTHY,
		"**脚下那格也被转成健康组织**（1 环含中心格，Kevin 2026-09-08 确认）")
	check(g.tile(CWData.neighbors(at)[0])["tissue"] == CWData.Tissue.HEALTHY, "邻格照旧转化")
	check(g.tile(at)["necrosis"] > 0, "脚下那格同样进入「坏死」")
	g.dispose()


## 代谢核心 / 骨髓的「积累进度外圈」（Kevin 2026-09-08 拍的 A′ 案）。
##
## 算式住在 `CWData.store_progress`，界面只负责画 —— 这组两头都验：
## 算式本身对不对，以及棋盘只给该有的格子建了覆盖层。
func t_store_ring() -> void:
	print("[特殊组织积累进度]")
	var g := bare_game()

	## ---- 算式 ----
	var plain: Dictionary = g.tile(Vector2i(1, 0))
	check(CWData.store_progress(plain) < 0.0,
		"普通格返回负数（= 不画圈；不能拿 0 表示「没有」，0 是「空仓」）")

	var core: Dictionary = g.tile(CWData.CORES[0])
	core["store"] = 0
	check(is_equal_approx(CWData.store_progress(core), 0.0), "核心空仓 → 0.0")
	core["store"] = CWData.CORE_STORE_MAX / 2
	check(is_equal_approx(CWData.store_progress(core), 0.5), "核心 1.0 / 2.0 → 0.5")
	core["store"] = CWData.CORE_STORE_MAX
	check(is_equal_approx(CWData.store_progress(core), 1.0), "核心满仓 → 1.0")

	var mar: Dictionary = g.tile(CWData.MARROWS[0])
	mar["cards"] = 1
	check(is_equal_approx(CWData.store_progress(mar), 1.0), "骨髓有卡 → 1.0（可以来拿了）")
	mar["cards"] = 0
	mar["prod"] = 1
	check(is_equal_approx(CWData.store_progress(mar), 1.0 / 3.0),
		"骨髓健康、攒了 1 回合 → 1/3（周期 %d）" % CWData.MARROW_HEALTHY_PERIOD)
	mar["tissue"] = CWData.Tissue.CANCER
	check(is_equal_approx(CWData.store_progress(mar), 0.5),
		"同一格癌变之后 → 1/2（癌变周期 %d 更快）" % CWData.MARROW_CANCER_PERIOD)
	mar["tissue"] = CWData.Tissue.HEALTHY

	## **走真流程再验一遍**（Kevin 2026-09-08 报「骨髓把卡抽了以后贴图不变」）：
	## 上面那几条是直接改字段，这里让细胞真的踩上去，看 enter_tile → collect_special
	## 那条链走完之后进度有没有跟着掉。
	mar["cards"] = 1
	mar["prod"] = 0
	var before: float = CWData.store_progress(mar)
	var walker := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0),
		CWData.ImmuneType.BASIC, -1, 200)
	g.cells.append(walker)
	await g.actions.enter_tile(walker, CWData.MARROWS[0])
	var after: float = CWData.store_progress(mar)
	check(is_equal_approx(before, 1.0) and after < before,
		"踩上去把卡拿走 → 进度从 %.2f 掉到 %.2f（不是一直满着）" % [before, after])
	## **别断言「进了手牌」**：骨髓抽到的可能是**事件卡**，那种立即结算并弃置、
	## 根本不进手牌（第一版这么写当场就红了）。要验的是「格子清空 + 确实抽了一张」。
	check(int(mar["cards"]) == 0, "→ 格子里的卡清空了")
	check("|".join(g.logs).contains("经由「骨髓」抽到"), "→ 日志里确实抽了一张")

	## 骨髓「有卡 / 空仓」两套贴图（Kevin 2026-09-08：卡抽走以后贴图不变）。
	## 进度环其实是变的（上面刚验过 1.0 → 0），但一圈细边不够醒目 ——
	## 图标里的骨头有没有，隔着半个屏幕都看得出。
	var bd := make_board()
	var mc := CWData.MARROWS[0]
	var mspr: Sprite2D = bd.map[bd.axial_to_rc(mc)]["instance"]
	bd.set_tissue(mc, CWData.Tissue.HEALTHY, CWData.Special.MARROW, true)
	var stocked: Texture2D = mspr.texture
	bd.set_tissue(mc, CWData.Tissue.HEALTHY, CWData.Special.MARROW, false)
	check(mspr.texture != stocked, "骨髓空仓 → 换另一张贴图")
	bd.set_tissue(mc, CWData.Tissue.CANCER, CWData.Special.MARROW, false)
	check(mspr.texture != stocked and mspr.texture != bd.MARROW_EMPTY_TEX[0],
		"癌变的空仓骨髓也有自己那张（四种组合各一张）")
	## 别的组织不吃这个参数 —— 只有骨髓有「有 / 没有」这种二态
	var cc := CWData.CORES[0]
	var cspr: Sprite2D = bd.map[bd.axial_to_rc(cc)]["instance"]
	bd.set_tissue(cc, CWData.Tissue.HEALTHY, CWData.Special.CORE, true)
	var core_tex: Texture2D = cspr.texture
	bd.set_tissue(cc, CWData.Tissue.HEALTHY, CWData.Special.CORE, false)
	check(cspr.texture == core_tex, "代谢核心不分两套（它存的是连续能量，没有二态）")
	bd.queue_free()

	## ---- 棋盘：只给该有的格子建覆盖层 ----
	var board := make_board()
	var with_ring: Array[Vector2i] = []
	for c in CWData.all_coords():
		var t: Sprite2D = board.map[board.axial_to_rc(c)]["instance"]
		if t.get_node_or_null("StoreRing") != null:
			with_ring.append(c)
	var want: Array[Vector2i] = []
	want.append_array(CWData.CORES)
	want.append_array(CWData.MARROWS)
	with_ring.sort()
	want.sort()
	check(with_ring == want,
		"只有 %d 个核心/骨髓建了覆盖层（实为 %d 格）" % [want.size(), with_ring.size()])

	## 可见性与进度：负数 → 藏起来；0~1 → 显示并把值喂给 shader
	var tile: Sprite2D = board.map[board.axial_to_rc(CWData.CORES[0])]["instance"]
	## **只有环这一层**：B 案的进度条 2026-09-08 当天加完又被 Kevin 撤掉了
	var ring: Sprite2D = tile.get_node("StoreRing")
	check(tile.get_node_or_null("StoreBar") == null, "条那一层已撤掉，不留残节点")
	board.set_store(CWData.CORES[0], -1.0, CWData.Special.CORE)
	check(not ring.visible, "负数 → 圈藏起来")
	board.set_store(CWData.CORES[0], 0.5, CWData.Special.CORE)
	var mat := ring.material as ShaderMaterial
	check(ring.visible and is_equal_approx(float(mat.get_shader_parameter("progress")), 0.5),
		"0.5 → 显示，且进度喂到了 shader")
	var half: Color = mat.get_shader_parameter("lit_color")
	board.set_store(CWData.CORES[0], 1.0, CWData.Special.CORE)
	var full: Color = mat.get_shader_parameter("lit_color")
	check(full != half and full.v > half.v, "满仓换成更亮的一档（「还在攒」和「可以来拿」要分得开）")
	board.queue_free()
	g.dispose()


## 固化计数的石化贴图族（Kevin 2026-09-09 选定「结晶核扩散」）。
##
## 图**长什么样**代码验不了（见 `tests/preview_solidify.gd` 的真机图），
## 这里守的是选图逻辑那几条会静默出错的：档位分界、门槛跟旋钮走、变体只认坐标。
func t_solid_tissue_art() -> void:
	print("[固化石化贴图]")
	var g := bare_game()

	## ---- 算式：门槛**必须**从外面传，不能写死 20 ----
	var t: Dictionary = g.tile(Vector2i(1, 0))
	CWTissue.to_cancer(t, false)
	t["solid"] = 10
	check(is_equal_approx(CWData.solid_progress(t, 20), 0.5), "计数 1.0 / 门槛 2.0 → 0.5")
	check(is_equal_approx(CWData.solid_progress(t, 40), 0.25),
		"同一格、门槛调到 4.0 → 0.25（平衡旋钮动了界面要跟着动）")
	## 【基质硬化】能把计数顶过门槛（15 的格子 +2.0 = 35），不钳住就会算出大于 1
	t["solid"] = 35
	check(is_equal_approx(CWData.solid_progress(t, 20), 1.0), "计数超过门槛 → 钳到 1.0")
	CWTissue.to_solid(t)
	check(is_equal_approx(CWData.solid_progress(t, 20), 1.0), "固化格恒为 1.0")
	CWTissue.to_healthy(t)
	check(is_equal_approx(CWData.solid_progress(t, 20), 0.0), "健康组织 → 0.0")

	## ---- 棋盘选图 ----
	var bd := make_board()
	var c := Vector2i(1, 0)
	var spr: Sprite2D = bd.map[bd.axial_to_rc(c)]["instance"]
	bd.set_tissue(c, CWData.Tissue.CANCER, CWData.Special.NONE, true, 0.0)
	var clean: Texture2D = spr.texture

	## **任何非零进度都要换图**：刚攒上 0.5 的格子和干净格子长得一样的话，这套贴图就白做了
	bd.set_tissue(c, CWData.Tissue.CANCER, CWData.Special.NONE, true, 0.01)
	check(spr.texture != clean, "进度只要 > 0 就换图（档位向上取整，不是向下）")

	## 四档必须是四张不同的图，否则中间档等于没做
	var seen := {}
	for frac in [0.25, 0.5, 0.75, 1.0]:
		bd.set_tissue(c, CWData.Tissue.CANCER, CWData.Special.NONE, true, frac)
		seen[spr.texture] = true
	check(seen.size() == 4, "0.25/0.5/0.75/1.0 各自一张（实为 %d 张）" % seen.size())

	## 变体只认格坐标：同一格反复刷必须稳定，否则图案会逐帧乱跳
	bd.set_tissue(c, CWData.Tissue.CANCER, CWData.Special.NONE, true, 0.5)
	var first: Texture2D = spr.texture
	bd.set_tissue(c, CWData.Tissue.HEALTHY, CWData.Special.NONE, true, 0.0)
	bd.set_tissue(c, CWData.Tissue.CANCER, CWData.Special.NONE, true, 0.5)
	check(spr.texture == first, "同一格同一进度 → 同一张（变体按坐标定，不掷骰子）")

	## 血管不可固化（CWTissue.solidifiable），所以贴图族里根本没有它那一套
	var vc: Vector2i = CWData.VESSELS[0]
	var vspr: Sprite2D = bd.map[bd.axial_to_rc(vc)]["instance"]
	bd.set_tissue(vc, CWData.Tissue.CANCER, CWData.Special.VESSEL, true, 0.0)
	var vtex: Texture2D = vspr.texture
	bd.set_tissue(vc, CWData.Tissue.CANCER, CWData.Special.VESSEL, true, 1.0)
	check(vspr.texture == vtex, "血管不画石头（它压根不可固化，查不到贴图就照原样）")

	## 核心 / 骨髓有自己那一族 —— 传普通癌组织那张的话，图标会被石头盖掉
	var cc: Vector2i = CWData.CORES[0]
	var cspr: Sprite2D = bd.map[bd.axial_to_rc(cc)]["instance"]
	bd.set_tissue(cc, CWData.Tissue.CANCER, CWData.Special.CORE, true, 1.0)
	bd.set_tissue(c, CWData.Tissue.CANCER, CWData.Special.NONE, true, 1.0)
	check(cspr.texture != spr.texture, "核心的石化图和普通癌组织不是同一张")
	bd.queue_free()
	g.dispose()


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
	## 2026-09-04 起选目标态有两枚按钮：「规划路径」+「结束迁移」（规划器，见 t_plan_path）
	check(_buttons(bar) == 2 and b.marks.size() == 2,
		"上一步走的是迁移 → 这一问直接回到选目标格，不再经过按钮栏")
	## 规划器：开 → 多一枚「按此路径走」；拖两格 → 路径染色；报价进提示行
	bar.chosen.emit(0)                        ## 「规划路径」
	await process_frame
	check(b._planning and _buttons(bar) == 3, "开规划器：按此路径走 / 退出规划 / 结束迁移")
	board.tile_clicked.emit(Vector2i(0, 1))   ## 按下起一条路
	await process_frame
	check(b._plan.size() == 1 and b._plan[0] == Vector2i(0, 1),
		"按下高亮格 → 路线第一步（%s）" % str(b._plan))
	## 提示行的「高亮 N 格可达」必须是**这一问真实的可达数** ——
	## 读 `_tiles` 会读到还没赋值的旧值，真机上写成过「高亮 0 格可达」（2026-09-04）
	check(b._plan_hint({ "energy": 100 }, 2).contains("2 格可达")
		or b._planning, "非规划态的提示行用传进来的可达数")
	var saved_planning := b._planning
	b._planning = false
	check(b._plan_hint({ "energy": 100 }, 7).contains("7 格可达"),
		"可达数如实写进提示行：%s" % b._plan_hint({ "energy": 100 }, 7))
	b._planning = saved_planning
	## 这一问的选项是测试合成的，未必真走得通 —— 所以这里只核对「染上了规划色」，
	## 报价语义（合计 / 走得通 / 停在第几步）由 t_plan_path 在**真对局**上核对
	check(b.marks.get(Vector2i(0, 1)) in [board.MARK_PLAN, board.MARK_PLAN_BAD],
		"路线那一格染成规划色（%s）" % str(b.marks.get(Vector2i(0, 1))))
	check(r3[0] == -99, "规划态里点棋盘不作答")
	board.tile_clicked.emit(Vector2i(0, 1))   ## 再点同一格 → 砍到它为止（不变）
	await process_frame
	check(b._plan.size() == 1, "点回路线上的格子只砍它之后的几步")
	bar.chosen.emit(1)                        ## 「退出规划」
	await process_frame
	check(not b._planning and b._plan.is_empty() and _buttons(bar) == 2, "退出规划：路线清掉、按钮回到两枚")
	bar.chosen.emit(1)                        ## 「结束迁移」
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

	## 「下一次世界事件在第几回合」：3 / 6 / 10 / 14，之后没有了（返回 0）——
	## 最后那对钉的是 2026-09-07 那个死循环：事件表有尽头，查找就必须有上界
	var ev := true
	for pair in [[1, 3], [3, 3], [4, 6], [7, 10], [11, 14], [14, 14], [15, 0]]:
		if p._next_event_round(pair[0]) != pair[1]:
			ev = false
	check(ev, "世界事件回合表：3 / 6 / 10 / 14，之后返回 0（不空转）")

	## 定案 B（2026-09-01）的警报：标题只读引擎的 cancer_win_streak，界面自己不数
	var g := make_game(6, 7)
	await run_setup(g)
	p.refresh(g)
	check(p._weighted_caption.text == "癌性加权", "平时标题是「癌性加权」")
	## 进行中的世界事件常驻一行（2026-09-02 Kevin：此前只有日志里看得到）
	check(not p._events.visible and p._events.text == "", "没有事件 → 那一行隐藏")
	g.events["active"].append({ "name": "基质阻隔", "left": 2, "stacks": 1, "data": {} })
	g.events["active"].append({ "name": "TGF-β释放", "left": 2, "stacks": 1, "data": {} })   ## 卡牌挂的全局修饰，不列
	g.events["active"].append({ "name": "增殖抑制", "left": 1, "stacks": 2, "data": {} })
	p.refresh(g)
	check(p._events.visible and p._events.text == "【基质阻隔】剩2回合·【增殖抑制】×2本回合",
		"列出世界事件、剩余回合与叠数，不列卡牌全局修饰：%s" % p._events.text)
	check(p._events.position.y >= p._phase.position.y + 12
		and p._events.position.y < CWMatchPanel.PAD + CWMatchPanel.ROUND_H + CWMatchPanel.GAP,
		"那一行落在阶段行下面、胜负进度块上面的空档里（y=%d）" % int(p._events.position.y))
	## 悬停事件行 → 左侧浮出每个事件的一句话效果与剩余回合（Kevin 2026-09-02 追加）
	p._event_hover = true
	p.refresh(g)
	var tip_texts: Array = []
	if p._event_tip != null:
		for c in p._event_tip.get_children():
			if c is Label:
				tip_texts.append((c as Label).text)
	## 效果正文现在是**自己折行**的（2026-09-08），所以比的是折行后的样子，不是 BLURB 原串
	var wrapped_blurb := "
".join(CWCardInfo.wrap_text(CWWorldFx.BLURB["基质阻隔"],
		CWMatchPanel.EVENT_TIP_W - 24.0))
	check(p._event_tip != null and p._event_tip.visible
		and tip_texts.has("【基质阻隔】") and tip_texts.has(wrapped_blurb)
		and tip_texts.has("【增殖抑制】×2") and tip_texts.has("剩 2 回合") and tip_texts.has("本回合"),
		"悬浮详情：每个世界事件的名字、叠数、剩余回合与一句话效果（%d 个标签）" % tip_texts.size())
	## **字不许出框**：2026-09-08 Kevin 截图报【抗原变异】那句单行冲出右边框，
	## 根因是赌了 Label 的 autowrap。这条守的是结果——把 BLURB 全表逐句折行后量宽。
	## 顺带守块高：正文行数现算，三行的句子不许压到下一个事件的名字上。
	var over: Array = []
	for name in CWWorldFx.BLURB:
		for line in CWCardInfo.wrap_text(CWWorldFx.BLURB[name], CWMatchPanel.EVENT_TIP_W - 24.0):
			if CWStyle.FONT.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1,
					CWStyle.SIZE_LABEL).x > CWMatchPanel.EVENT_TIP_W - 24.0:
				over.append("%s：%s" % [name, line])
	check(over.is_empty(), "世界事件效果正文折行后没有一行出框（超的：%s）" % str(over.slice(0, 3)))
	var bottom := 0.0
	for c in p._event_tip.get_children():
		if c is Label:
			bottom = maxf(bottom, (c as Label).position.y + CWMatchPanel.EVENT_LINE_H)
	check(bottom <= p._event_tip.size.y,
		"框高盖得住所有行（最低一行 %d、框高 %d）" % [int(bottom), int(p._event_tip.size.y)])
	check(not tip_texts.has("【TGF-β释放】"), "卡牌全局修饰不进悬浮详情")
	p._event_hover = false
	p.refresh(g)
	check(not p._event_tip.visible, "移开鼠标 → 悬浮框藏起")
	g.events["active"].clear()
	p.refresh(g)
	check(not p._events.visible, "事件到期移除 → 那一行收起")
	## 一句话效果表覆盖全部 18 个事件，一个不多一个不少
	var blurbed := true
	for ev_name in CWWorldFx.EVENTS:
		if not CWWorldFx.BLURB.has(ev_name) or String(CWWorldFx.BLURB[ev_name]).is_empty():
			blurbed = false
	check(blurbed and CWWorldFx.BLURB.size() == CWWorldFx.EVENTS.size(), "BLURB 覆盖全部 %d 个世界事件" % CWWorldFx.EVENTS.size())
	## 抽到事件 → 全局通报一句「世界事件【X】：效果（持续 N 回合）」，每个桥对象只收一次
	var rec := NoticeRecorder.new()
	rec.game = g
	for pid in g.order:
		g.bridges[pid] = rec
	g.events["pool"] = ["基质阻隔"]
	await g.world_fx.trigger()
	check(rec.got == ["世界事件【基质阻隔】：癌细胞移动能量花费翻倍（持续 2 回合）"],
		"trigger → notice 文本含效果与持续期、只通报一次：%s" % str(rec.got))
	## 2026-09-07 起通报不再在顶带弹气泡：世界事件只写日志，抽到的事件卡以卡面进左侧出牌列
	## （Kevin：「右上角的提示太过拥挤」）—— 那两条摆位断言随之作废。
	## **出牌列与机位是一起算的**：它整列必须落在棋盘可用区间的左边，一格都不许压
	## （Kevin 2026-09-07 亲自点出旧的一列压住了棋盘左上角）
	var span := CWView.board_span()
	check(CWFeed.RECT.end.x <= span.x and CWFeed.RECT.position.x >= 0.0,
		"出牌列整列在棋盘左缘 %.0f 之外（%s）" % [span.x, str(CWFeed.RECT)])
	check(CWFeed.RECT.position.y >= CWLogHint.SIZE.y + CWLogPanel.RECT.position.y
		and CWFeed.RECT.end.y <= CWHand.REST_TOP,
		"出牌列在迷你日志下方、不伸进手牌抽屉（%s）" % str(CWFeed.RECT))
	check(CWView.LEFT_STRIP == int(CWFeed.RECT.size.x), "机位让出的宽度就是出牌列的宽度")
	check(span.y <= CWView.screen_size().x - CWView.PANEL_WIDTH, "右边照旧让给竖条")
	## 两档时长（Kevin 2026-09-06）：骰子**结果文字** ≥2 s（骰子本身的演出在 CWDice，这里碰不到）；非骰子说明更长
	check(CWUIBridge.RESULT_HOLD >= 2.0 and CWUIBridge.TEXT_HOLD >= 3.0,
		"骰子结果 %.1f s、非骰子说明 %.1f s" % [CWUIBridge.RESULT_HOLD, CWUIBridge.TEXT_HOLD])
	## 通报排队（Kevin 2026-09-06「都显示得太快」的另一半）：忙着时后来的排着，走完一条才上下一条；收起清队
	var tq := CWToast.new()
	root.add_child(tq)
	await process_frame
	## 锚点随便给一个（这里验的是排队本身，不是摆位）
	var q_at := Rect2(Vector2(400, 300), Vector2.ZERO)
	tq.queue_at("一", q_at, 1.0)
	tq.queue_at("二", q_at, 1.0)
	check(tq._label.text == "一" and tq._queue.size() == 1 and tq._busy, "第二条排队，不顶掉第一条")
	tq._on_done()
	check(tq._label.text == "二" and tq._queue.is_empty() and tq._busy, "第一条走完 → 第二条上")
	tq.hide_now()
	check(tq._queue.is_empty() and not tq._busy, "收起清队")
	## 出牌列：一列**手牌那张卡缩一半**（Kevin 2026-09-07：「不要用小卡，就把手牌区抽到的卡
	## 缩小放上去就行」「注明是谁打出的就行」）。喂它的是 CWMatch 的 card_played / event_drawn
	## 两个回调（本地与联机都会响），所以这里直接验控件本身
	var fd := CWFeed.new()
	var t_res := CWToast.new()   ## 骰子旁那只：下面那段气泡断言还要用
	root.add_child(fd)
	root.add_child(t_res)
	await process_frame
	var rows_a: Dictionary = CWCardInfo.describe("糖酵解爆发", CWData.Faction.CANCER, 0)
	fd.add_card("糖酵解爆发", "癌症A", CWData.Faction.CANCER, rows_a)
	check(fd._rows.size() == 1 and String(fd._rows[0]["who"]) == "癌症A", "记一张：卡名 + 谁打的")
	fd.add_card("炎症趋化", "免疫B", CWData.Faction.IMMUNE,
		CWCardInfo.describe("炎症趋化", CWData.Faction.IMMUNE, 0))
	var top: Control = fd._rows[fd._rows.size() - 1]["box"]
	var second: Control = fd._rows[fd._rows.size() - 2]["box"]
	check(top.position.y < second.position.y, "最新的一张画在最上面")
	## 事件卡：谁都没打出，底下写「世界事件」
	fd.add_card("增殖抑制", "", CWData.Faction.CANCER,
		CWCardInfo.describe("增殖抑制", CWData.Faction.CANCER, 0), true)
	check(String(fd._rows[fd._rows.size() - 1]["who"]).ends_with(CWFeed.EVENT_SUFFIX),
		"事件卡底行写「<抽到者>·抽」（%s）" % String(fd._rows[fd._rows.size() - 1]["who"]))
	check(CWFeed.EVENT_SUFFIX != "世界事件" and CWFeed.WORLD_WHO == "世界事件",
		"事件卡与世界事件是两行不同的字")
	## 世界事件那张卡也要点得开：2026-09-07 它那条路是照着 add_card 手抄的，抄漏了 gui_input
	fd.add_world_event("基质阻隔", 2)
	var last_box: Control = fd._rows[fd._rows.size() - 1]["box"]
	check(not last_box.gui_input.get_connections().is_empty(), "世界事件那张卡接了点击")
	var opened: Array = []
	fd.card_pressed.connect(func(rows: Dictionary, _x: float, _y: float) -> void: opened.append(rows))
	var tap := InputEventMouseButton.new()
	tap.pressed = true
	tap.button_index = MOUSE_BUTTON_LEFT
	last_box.gui_input.emit(tap)
	check(opened.size() == 1 and String(opened[0]["name"]).contains("基质阻隔"),
		"点世界事件 → 出详情（%s）" % str(opened))
	## 卡面就是手牌那张卡的顶上一截：同宽、字号一步不动（缩过一版，10px 变 5px 糊成马赛克），
	## 卡名折行也照搬手牌那套
	var face: Control = fd._rows[0]["box"]
	check(face.size == Vector2(CWFeed.CARD_W, CWFeed.CARD_H) and face.scale == Vector2.ONE
		and is_equal_approx(CWFeed.CARD_W, CWHand.CARD.x),
		"卡面与手牌同宽、原大不缩放（%s）" % str(face.size))
	check(face.get_child_count() == 2 + CWHand.name_lines("糖酵解爆发").size(),
		"卡面 = 底板 + 折好的卡名 + 一行「谁打的」")
	check(CWHand.name_lines("自分泌生存信号").size() == 2, "长卡名照旧折两行（卡面装得下）")
	## 点一张 → 把卡面内容交给详情框（同右栏历史小卡那条路）
	var pressed := []
	fd.card_pressed.connect(func(r: Dictionary, x: float, y: float) -> void: pressed.append([r, x, y]))
	var click := InputEventMouseButton.new()
	click.pressed = true
	click.button_index = MOUSE_BUTTON_LEFT
	face.gui_input.emit(click)
	check(pressed.size() == 1 and (pressed[0][0] as Dictionary) == rows_a, "点一张 → 出详情框")
	## 最多留 MAX_ROWS 张，旧的挤掉
	for k in CWFeed.MAX_ROWS + 3:
		fd.add_card("糖酵解爆发", "癌症A", CWData.Faction.CANCER, rows_a)
	check(fd._rows.size() == CWFeed.MAX_ROWS, "最多留 %d 张，旧的挤掉" % CWFeed.MAX_ROWS)
	fd.clear_all()
	check(fd._rows.is_empty(), "拆局清空")
	fd.queue_free()
	## 引擎侧：打出即时 / 永久卡都会广播 card_played；文案用席位名
	var cp := CardPlayRecorder.new()
	cp.game = g
	for pid in g.order:
		g.bridges[pid] = cp
	var mel_c := CWSetup.make_cell(g.cells.size(), 1, CWData.Faction.CANCER, Vector2i(3, 3), -1, CWData.CancerType.MELANOMA)
	mel_c["energy"] = 100
	mel_c["hand"] = ["GLUT1高表达", "上皮—间质转化"]
	g.cells.append(mel_c)
	g.round_no = 1
	await g.card_fx.play(mel_c, { "act": "play", "card": "GLUT1高表达" })
	await g.card_fx.play(mel_c, { "act": "play", "card": "上皮—间质转化" })
	check(cp.got == [[1, "癌症A 打出【GLUT1高表达】"], [1, "癌症A 打出【上皮—间质转化】"]],
		"永久 / 即时卡打出都广播，文案用席位名（%s）" % str(cp.got))
	## 非骰子的说明带 linger（事件卡效果 / 复活失败 / 次数用尽……），骰子那几条不带
	g.announce("攻击成功", Vector2i.ZERO)
	g.announce("事件【X】效果", Vector2i.ZERO, true)
	check(cp.results == [["攻击成功", false], ["事件【X】效果", true]], "announce 的 linger 逐桥传到（%s）" % str(cp.results))
	## 界面：linger 走独立气泡，不碰骰子旁那只、互不顶掉；淡出后自毁
	t_res.hide_now()
	t_res.show_at("攻击成功", Rect2(300, 300, 40, 40), 1.0)
	var b1: Control = t_res.bubble_at("事件【一】", Rect2(300, 300, 40, 40), 1.0)
	var b2: Control = t_res.bubble_at("事件【二】", Rect2(300, 300, 40, 40), 1.0)
	check(t_res._label.text == "攻击成功" and t_res._bubbles.size() == 2 and b1 != b2,
		"气泡各自一只，骰子旁那行字原样")
	check(not Rect2(b1.position, b1.size).intersects(Rect2(b2.position, b2.size)), "第二只气泡避开第一只（%s / %s）" % [str(b1.position), str(b2.position)])
	## 骰子结果也各自一只气泡：掷骰时的「攻击」标签在结果到时收掉，两次攻击的结果并存
	t_res.hide_box()
	check(is_zero_approx(t_res._box.modulate.a) and t_res._bubbles.size() == 2, "hide_box 只收骰子旁那只，气泡不动")
	t_res.hide_now()
	check(t_res._bubbles.is_empty(), "收起时气泡一并清掉")
	for n in [tq, t_res]:
		n.queue_free()
	g.cancer_win_streak = 1
	p.refresh(g)
	check(p._weighted_caption.text == "★ 警报 1/2", "警报期标题换成「★ 警报 1/2」（%s）" % p._weighted_caption.text)
	g.cancer_win_streak = 0
	p.refresh(g)
	check(p._weighted_caption.text == "癌性加权", "回落后标题复原")
	g.dispose()

	p.queue_free()

# ---- 右栏「预计收入」：能量旁的小字来自引擎纯查询，和真结算逐位一致（Kevin 2026-09-06）----
func t_income_display() -> void:
	print("[预计收入]")
	var g := _fx_game(2)
	var imm := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(5, 0), CWData.ImmuneType.BASIC, -1, 100)
	var can := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(0, 0), -1, CWData.CancerType.OSTEO, 100)
	g.cells.append(imm)
	g.cells.append(can)
	## 免疫：预计 = 真结算的差额
	var want: int = g.world.aerobic_income(imm)
	var e0: int = imm["energy"]
	g.world.aerobic()
	check(want > 0 and imm["energy"] - e0 == want, "有氧：预计 %s = 结算差额 %s" % [CWData.fmt(want), CWData.fmt(imm["energy"] - e0)])
	## 【TGF-β释放】挂着：预计已经把 -20% 算进去，结算后消耗
	g.events["active"].append({ "name": "TGF-β释放", "left": 2, "stacks": 1, "data": {} })
	var want_tgf: int = g.world.aerobic_income(imm)
	check(want_tgf == want * 8 / 10, "TGF-β 在场：预计按 -20% 算（%s → %s）" % [CWData.fmt(want), CWData.fmt(want_tgf)])
	e0 = imm["energy"]
	g.world.aerobic()
	check(imm["energy"] - e0 == want_tgf and g.events["active"].is_empty(), "结算差额一致，TGF-β 消耗掉")
	check(g.world.aerobic_income(imm) == want, "预计是纯查询：没有消耗 TGF-β（消耗后回到原值）")
	## 站在坏死格：整份打折（Kevin 2026-09-07 由「一份不给」改成 80%）；永久技能加成也在这一份里
	g.tiles[imm["pos"]]["necrosis"] = 2
	check(g.world.aerobic_income(imm) == want * CWData.NECROSIS_AEROBIC_PCT / 100,
		"坏死格上预计打折（%s → %s）" % [CWData.fmt(want), CWData.fmt(g.world.aerobic_income(imm))])
	g.tune.necrosis_aerobic_pct = 0
	check(g.world.aerobic_income(imm) == 0, "necro=0 扫回旧行为：一份不给")
	g.tune.necrosis_aerobic_pct = CWData.NECROSIS_AEROBIC_PCT
	g.tiles[imm["pos"]]["necrosis"] = 0
	imm["equipped"].append("代谢适应")
	var want_bonus: int = g.world.aerobic_income(imm)
	e0 = imm["energy"]
	g.world.aerobic()
	check(want_bonus == want + CWData.AEROBIC_ADAPT and imm["energy"] - e0 == want_bonus,
		"【代谢适应】的额外获得算进预计，且与结算一致")
	## 癌症：预计 = 回合末结算的差额（口径本来就是 anaerobic_gain_for），E 阶段那条路也一样
	for c in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 1)]:
		g.tiles[c]["tissue"] = CWData.Tissue.CANCER
	var want_c: int = g.world.anaerobic_gain_for(can)
	var c0: int = can["energy"]
	g.world.settle_anaerobic_turn(can)
	check(want_c > 0 and can["energy"] - c0 == want_c, "无氧：预计 %s = 回合末结算差额" % CWData.fmt(want_c))
	c0 = can["energy"]
	g.world._anaerobic()
	check(can["energy"] - c0 == want_c, "E 阶段整体结算那条路差额也一样")
	## 右栏：小字文案 = 「+预计」，死亡 / 待落子不显示；摆在能量数左边、「技 N」再往左
	var p := CWMatchPanel.new()
	root.add_child(p)
	await process_frame
	p.refresh(g)
	check(p._rows[0]["income"].text == "+" + CWData.fmt(g.world.aerobic_income(imm)),
		"免疫行：%s" % p._rows[0]["income"].text)
	check(p._rows[1]["income"].text == "+" + CWData.fmt(want_c), "癌症行：%s" % p._rows[1]["income"].text)
	var inc: Label = p._rows[0]["income"]
	var en: Label = p._rows[0]["energy"]
	var sk: Label = p._rows[0]["skills"]
	## 顶行从右往左：+x.x（贴行右缘）→ 能量 → 技 N（Kevin 2026-09-06 看截图定的顺序）
	var pip_right: float = p._rows[0]["pips"][CWData.HAND_MAX - 1].position.x + CWMatchPanel.PIP
	check(inc.position.x + inc.size.x == pip_right
		and en.position.x + en.size.x == inc.position.x + inc.size.x - CWMatchPanel.INCOME_RESERVE
		and sk.position.x + sk.size.x == en.position.x + en.size.x - CWMatchPanel.ENERGY_RESERVE
		and inc.position.y == sk.position.y,
		"小字贴行右缘（与手牌方块同一右缘），能量右对齐到它左边，「技 N」再让出 ENERGY_RESERVE")
	check(p._rows[0]["name"].size.x == CWMatchPanel.NAME_W
		and p._rows[0]["name"].position.x + CWMatchPanel.NAME_W <= sk.position.x + sk.size.x
			- CWStyle.FONT.get_string_size("技 0", HORIZONTAL_ALIGNMENT_LEFT, -1, CWStyle.SIZE_LABEL).x,
		"玩家名裁剪区不压到「技 N」")
	can["alive"] = false
	p.refresh(g)
	check(p._rows[1]["income"].text == "", "死亡：不显示预计")
	p.reset()
	root.remove_child(p)
	p.free()
	g.dispose()


# ---- 技能栏列出即时修饰（Kevin 2026-09-06：「现在看不到即时的 buff」）----
func t_mods_tip() -> void:
	print("[技能栏·即时修饰]")
	var g := _fx_game(2)
	g.cells.append(CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(5, 0), CWData.ImmuneType.BASIC, -1, 100))
	var can := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(0, 0), -1, CWData.CancerType.MELANOMA, 100)
	g.cells.append(can)
	check(CWMatchPanel.tip_rows(g, 1, false).is_empty(), "没装备也没修饰：悬停不浮框")
	g.add_mod(can, "上皮—间质转化", 2, "turn")
	g.add_mod(can, "DNA损伤修复", 1, "")
	g.add_mod(can, "细胞因子网络·待发", 1, "round")   ## 引擎内部标记，不列
	var names := func(rows: Array) -> Array:
		var out: Array = []
		for r in rows:
			out.append(r.get("head", r.get("text", "")))
		return out
	var hover: Array = CWMatchPanel.tip_rows(g, 1, false)
	check(names.call(hover) == ["即时 · 本回合", "上皮—间质转化 ×2", "即时 · 待触发", "DNA损伤修复"],
		"悬停：按时钟分段、次数写 ×N、内部标记不列（%s）" % str(names.call(hover)))
	check(hover[1]["info"]["name"] == "上皮—间质转化" and not hover[1]["info"]["lines"].is_empty(),
		"条目悬停浮出那张卡的原文")
	var full: Array = CWMatchPanel.tip_rows(g, 1, true)
	var fnames: Array = names.call(full)
	check(fnames.has("细胞种类") and fnames.find("即时 · 本回合") > fnames.find("细胞种类")
		and fnames[fnames.size() - 1] == "DNA损伤修复", "固定态：即时段排在最后")
	## 用掉一层 → ×2 没了；本回合到期 → 那一段消失；已装备 + 即时同时有
	g.spend_one_mod(can, "上皮—间质转化")
	check(names.call(CWMatchPanel.tip_rows(g, 1, false))[1] == "上皮—间质转化", "剩 1 次不写 ×N")
	g.clear_mods(can, "turn")
	can["equipped"].append("癌症干性")
	check(names.call(CWMatchPanel.tip_rows(g, 1, false)) == ["已装备 · 持续生效", "癌症干性", "即时 · 待触发", "DNA损伤修复"],
		"本回合的到期后消失；已装备在前、即时在后")
	## 真控件：修饰变化要触发重搭（键里带次数）
	var p := CWMatchPanel.new()
	root.add_child(p)
	await process_frame
	p.refresh(g)
	p._tip_pid = 1
	p.refresh(g)
	check(p._tip != null and p._tip.visible and p._tip.get_child_count() == 1 + 4, "悬浮框 = 底板 + 两段四行")
	g.add_mod(can, "细胞膜修复", 1, "")
	p.refresh(g)
	check(p._tip.get_child_count() == 1 + 5, "新挂一条修饰 → 框跟着重搭")
	p.reset()
	root.remove_child(p)
	p.free()
	g.dispose()


# ---- 迁移选目标态下直接打 / 弃手牌（Kevin 2026-09-06）----
func t_move_hand() -> void:
	print("[选目标态·手牌]")
	var board := make_board()
	var bar := CWActionBar.new()
	var hand := CWHand.new()
	root.add_child(board)
	root.add_child(bar)
	root.add_child(hand)
	var g := CWGame.new()
	g.init(CWData.FACTION_ORDER[2], 3)
	var b := CWUIBridge.new()
	b.game = g
	b.board = board
	b.bar = bar
	b.hand = hand
	b.human_pids = [0]
	var cell := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i.ZERO, CWData.ImmuneType.BASIC, -1)
	g.cells.append(cell)
	var opts: Array = [
		{ "label": "", "data": { "act": "move", "to": Vector2i(1, 0), "cost": 5 } },
		{ "label": "", "data": { "act": "play", "card": "溶酶体强化" } },
		{ "label": "", "data": { "act": "discard", "card": "乳酸酸化" } },
		{ "label": "", "data": { "act": "discard", "card": "溶酶体强化" } },
	]
	## ① 选目标态里双击一张无目标卡 → 直接交出那张卡的选项下标（引擎结算后会再问，_sticky_move 让它回到选目标态）
	var r := [-99]
	var run := func() -> void: r[0] = await b._pick_move(cell, opts, [0])
	run.call()
	await process_frame
	hand.play_requested.emit("溶酶体强化")
	await process_frame
	check(r[0] == 1, "选目标态下双击卡 → 打出（下标 %d）" % r[0])
	check(b.move_costs.is_empty(), "交出答案时价目表收干净")
	## ② 右键双击卡 → 弃置（不再被当成「结束迁移」）
	r[0] = -99
	run.call()
	await process_frame
	hand.discard_requested.emit("乳酸酸化")
	await process_frame
	check(r[0] == 2, "选目标态下右键双击卡 → 弃置（下标 %d）" % r[0])
	## ③ 从卡的流程退回：留在选目标态，不算结束迁移；「结束迁移」照旧退出
	r[0] = -99
	run.call()
	await process_frame
	hand.play_requested.emit("乳酸酸化")            ## 打不出（没有 play 选项）→「还打不出」条
	await process_frame
	check(r[0] == -99 and _buttons(bar) == 2, "打不出的卡：浮出「弃置它 / 返回」，这一问还没结束")
	bar.chosen.emit(1)                               ## 返回
	await process_frame
	check(r[0] == -99 and b.move_verb == "迁移" and b.move_costs == { Vector2i(1, 0): 5 },
		"退回后仍在选目标态（价目表还在）")
	bar.chosen.emit(_buttons(bar) - 1)               ## 结束迁移
	await process_frame
	check(r[0] is String and r[0] == "cancel" and b.move_costs.is_empty(), "「结束迁移」照旧退出")
	g.dispose()
	hand.free()
	bar.free()
	board.free()


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

	## 每种结局各有各的标签，判定那两种不能写得像击溃
	var chips := true
	for kind in ["immune_clear", "cancer_weighted", "limit_immune", "limit_cancer",
			"surrender_immune", "surrender_cancer"]:
		if not CWSettleScreen.KIND_CHIP.has(kind):
			chips = false
	check(chips, "六种 win_kind 都有结局标签")
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
	## 结算屏出场前要收掉左侧出牌列（Kevin 2026-09-07：它压在结算屏上）
	main_scene.match_node._feed.add_card("糖酵解爆发", "癌症A", CWData.Faction.CANCER,
		CWCardInfo.describe("糖酵解爆发", CWData.Faction.CANCER, 0))
	check(not main_scene.match_node._feed._rows.is_empty(), "先往出牌列里放一张")
	main_scene.match_node.clear_transient_hud()
	check(main_scene.match_node._feed._rows.is_empty(), "结算前出牌列清空")
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

	## 返场/重开的过场被玩家点击**跳过**时：跳过只快进了相机补间（main.gd 的 `_tween`），
	## 而 `fade_out()` 建在 `_cells_root` 上那条**没人管**。`_cells_root` 又是 teardown()
	## 不销毁的节点，于是那条补间活过拆局、跑进下一局，继续把细胞 alpha 拉向 0 ——
	## 表现就是「新局开局棋盘上一个细胞都看不见，HUD 却正常」
	## （HUD 那几条只有 0.6 倍时长，通常已经先跑完了，所以只有细胞中招）。
	## 这里用「长淡出 + 立刻拆局重开」复现，不依赖任何时序竞态。
	main_scene.match_node.fade_out(5.0)
	await process_frame
	main_scene.match_node.teardown()
	main_scene.match_node.start()
	await process_frame
	await process_frame
	check(is_equal_approx(main_scene.match_node._cells_root.modulate.a, 1.0),
		"跳过过场后重开：细胞不透明（上一局的淡出补间已被杀掉）")

	## 同一个触发条件下的第二个症状：`fade_to_healthy()` 的过渡叠层挂在 `_marks` 下，
	## 却不在 `set_marks` 管的表里，清不掉；它的回调会把格子刷成健康贴图。
	## 而贴图只在 `set_tissue()` 时更新、**不是每帧重刷**，所以那一格会一直错下去。
	## 用短淡出（0.05s）+ 立刻取消 + 等到远超淡出时长来判：没取消的话回调早就落下了。
	var b2 := make_board()
	root.add_child(b2)          ## **必须进场景树**：不在树里的节点补间根本不跑，
	await process_frame         ## 那样这条测试无论修没修都是绿的（已实测过）
	var cc := Vector2i(1, 0)
	b2.set_tissue(cc, CWData.Tissue.CANCER, CWData.Special.NONE)
	var tile2: Sprite2D = b2.map[b2.axial_to_rc(cc)]["instance"]
	var before2: Texture2D = tile2.texture
	b2.fade_to_healthy(0.05)
	check(not b2._fade_overs.is_empty(), "淡回健康：过渡叠层已建起来（前提成立）")
	## ⚠ **先把补间引用抓在手里再取消**：cancel_fade() 里有一句 `_fade_tweens.clear()`，
	## 清空之后再去遍历那个列表，补间死没死都是「空」—— 断言等于没写。
	## 第一版就是这么写的，撤掉 kill() 之后照样全绿（当场验过）。
	## 这就是本项目 2026-09-01 反复踩的「测试和实现共享同一份记账」。
	var watched: Array[Tween] = []
	for tw in b2._fade_tweens:
		watched.append(tw)
	check(not watched.is_empty(), "抓到了在跑的补间（前提成立）")
	b2.cancel_fade()
	## 确定性判据：不靠等，直接看那几条补间死没死。
	## 下面 0.3 秒墙钟那条原本是唯一判据，而它只在机器被压满时才失败 ——
	## 因为真 bug 是 cancel_fade() 靠 queue_free()（帧末才生效）杀补间，
	## 单帧 delta 一大补间就先跑完并把回调落下了。两条一起留：一条钉机制，一条钉行为。
	var alive := 0
	for tw in watched:
		if tw != null and tw.is_valid():
			alive += 1
	check(alive == 0 and b2._fade_overs.is_empty(),
		"取消淡出：补间当场被 kill 掉，不是等 queue_free 顺手带走")
	await create_timer(0.3).timeout
	check(tile2.texture == before2, "取消淡出后，残留回调不会再把格子刷成健康")
	b2.queue_free()

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
	var n_tiles := CWData.init_cancer_tiles(m.game.order.size())
	check(hidden >= n_tiles - 1,
		"绽开刚开始时还有 %d 格没揭开（不是一次全出）" % hidden)
	check(m.bridge.opening, "绽开期间桥被闸住，落子提示不弹出来")
	check(m.game.count_tissue(CWData.Tissue.CANCER) == n_tiles,
		"引擎那边 %d 格初始癌组织其实早就就位了（藏起来的只是画面）" % n_tiles)

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
	var settings_at := -1
	var codex_at := -1
	for i in CWPauseMenu.ITEMS.size():
		match CWPauseMenu.ITEMS[i]["id"]:
			"codex": codex_at = i
			"settings": settings_at = i
	## 「规则速查」2026-09-07 从 Esc 菜单去掉（主菜单那份 09-06 已撤）——
	## 硬数字总览交给知识之书，一份规则两处维护本来就容易漂
	var has_rules := false
	for it in CWPauseMenu.ITEMS:
		if it["id"] == "rules":
			has_rules = true
	check(not has_rules, "Esc 菜单里没有「规则速查」")
	check(pm._enabled(CWPauseMenu.ITEMS[codex_at]) \
		and pm._enabled(CWPauseMenu.ITEMS[settings_at]), "知识之书与设置不再灰着")
	pm._activate(codex_at)
	check(pm._codex.visible and pm.visible and pm.get_tree().paused \
		and not pm._panel.visible, "打开知识之书：页压页、树保持冻结、列表让位")
	check(fired.size() == 1, "子页入口不发 chose（在菜单内部消化）")
	pm._unhandled_input(esc)
	check(not pm._codex.visible and pm._panel.visible and pm.get_tree().paused,
		"子页上 Esc：只关子页，暂停不解除")
	pm._activate(settings_at)
	check(pm._settings.visible, "打开设置页")
	var sright := InputEventAction.new()
	sright.action = "ui_right"
	sright.pressed = true
	pm._unhandled_input(sright)          ## 路由给设置页第一行：标准 → 慢
	check(CWSettings.ai_delay_ms == CWSettings.AI_DELAYS[2], "键盘路由到设置页：拨值即时生效")
	pm._unhandled_input(esc)
	check(not pm._settings.visible and pm._panel.visible, "设置页上 Esc 退回暂停列表")
	## 再开一次书，验方向键路由（上面那次是验「页压页」；codex_at 复用上面找到的那个 ——
	## 2026-09-07 去掉「规则速查」时这里留了一段旧块，重复声明把整个测试脚本弄得编译不过）
	pm._activate(codex_at)
	check(pm._codex.visible and pm.visible and pm.get_tree().paused and not pm._panel.visible,
		"再次打开知识之书：页压页、树保持冻结、列表让位")
	pm._unhandled_input(sright)
	check(pm._codex._page == 1, "方向键路由给书翻页")
	pm._unhandled_input(esc)
	check(not pm._codex.visible and pm._panel.visible and pm.get_tree().paused, "书上 Esc：只关书，暂停不解除")
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
	func show_result(text: String, at: Vector2i, _linger := false) -> void:
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
	## 攻击那条**单独摆一次确定性的**：一局 AI 对局里会不会真的发生攻击，随规则改动而变
	## （2026-09-07 攻击开始给抗原记忆之后，seed 99 那局的轨迹就不再包含攻击了）——
	## 拿「某个种子的局里恰好打过一架」当断言，本质上是在赌运气。
	var g3 := bare_game()
	var rec3 := ResultRecorder.new()
	rec3.game = g3
	for pid in g3.order:
		g3.bridges[pid] = rec3
	var im3 := put_immune(g3, Vector2i.ZERO)
	var ca3 := CWSetup.make_cell(g3.cells.size(), 1, CWData.Faction.CANCER,
		Vector2i(1, 0), -1, CWData.CancerType.SCLC, 500)
	g3.cells.append(ca3)
	g3.tiles[Vector2i(1, 0)]["tissue"] = CWData.Tissue.CANCER
	rec3.said.clear()
	await g3.actions._do_move(im3, Vector2i(1, 0), 0)
	var kinds3 := {}
	for t: String in rec3.said:
		kinds3[t.split("：")[0].substr(0, 2)] = true
	check(kinds3.has("攻击"), "攻击的判定结果有通报（%s）" % str(rec3.said))
	g3.dispose()
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

	## Kevin 2026-09-08 报的那一套原样复现：恶黑的四个行动。
	## 出事的是「移动」那枚 —— 它原来把所有档位列成「0.2 / 0.3 / 0.5 / 0.7 / 1.2」，
	## 五档之后一枚按钮就宽到把【血行转移】挤出屏幕。现在移动**不带价签**。
	var bar3 := CWActionBar.new()
	root.add_child(bar3)
	bar3.show_bar("", "", [
		{ "title": "移动", "cost": "" },
		{ "title": "基因表达", "cost": "1.0 抽卡" },
		{ "title": "突变", "cost": "0.5" },
		{ "title": "血行转移", "cost": "1.0" }])
	var w3 := 0.0
	var k3 := 0
	for c in bar3._row.get_children():
		if c is PanelContainer:
			w3 += (c as Control).get_combined_minimum_size().x
			k3 += 1
	w3 += CWActionBar.GAP * maxi(k3 - 1, 0)
	check(k3 == 4 and w3 <= CWActionBar.BAR_RECT.size.x,
		"恶黑四行动合计 %d px，放得进 %d px（移动不带价签之后）"
			% [int(w3), int(CWActionBar.BAR_RECT.size.x)])
	## 反过来钉一下：把那串价签加回去就会超宽 —— 说明这条用例真的在守这件事
	bar3.show_bar("", "", [
		{ "title": "移动", "cost": "0.2 / 0.3 / 0.5 / 0.7 / 1.2" },
		{ "title": "基因表达", "cost": "1.0 抽卡" },
		{ "title": "突变", "cost": "0.5" },
		{ "title": "血行转移", "cost": "1.0" }])
	var w4 := 0.0
	for c in bar3._row.get_children():
		if c is PanelContainer:
			w4 += (c as Control).get_combined_minimum_size().x
	w4 += CWActionBar.GAP * maxi(k3 - 1, 0)
	check(w4 > CWActionBar.BAR_RECT.size.x,
		"加回五档价签就超宽（%d > %d）—— 这才是当初挤没【血行转移】的原因"
			% [int(w4), int(CWActionBar.BAR_RECT.size.x)])
	bar3.queue_free()
	## 目标选择态放不下（2026-09-02 Kevin 报【代谢耦联】第三档被挡在屏幕外）。
	## ① 现在的【代谢耦联】文案（「1.0 → 1.2」+ 提示「转出 → 接收方得」）必须原字号放得下 —— 文案是根治
	var bar2 := CWActionBar.new()
	root.add_child(bar2)
	var real_prompt := "【代谢耦联】转出 → 接收方得"
	bar2.show_bar(real_prompt, "", [
		{ "title": "1.0 → 1.2", "cost": "" }, { "title": "1.5 → 2.0", "cost": "" }, { "title": "2.0 → 2.5", "cost": "" }])
	check(bar2._row.get_combined_minimum_size().x <= CWActionBar.PROMPT_RECT.size.x,
		"【代谢耦联】三档新文案原字号放得下（%d / %d px）" % [int(bar2._row.get_combined_minimum_size().x), int(CWActionBar.PROMPT_RECT.size.x)])
	check(CWActionBar._title_of(bar2._buttons[2]).get_theme_font_size("font_size") == CWStyle.SIZE_BODY, "→ 没有触发缩字号")
	bar2.show_bar("【代谢耦联】选择转移方向", "", [{ "title": "送给 癌症B", "cost": "" }, { "title": "向 癌症B 索取", "cost": "" }])
	check(bar2._row.get_combined_minimum_size().x <= CWActionBar.PROMPT_RECT.size.x, "方向两档（只写玩家名）也放得下")
	## ② 兜底：同样的提示塞四档（原字号约 770px 放不下）。
	## **2026-09-08 起让位的是提示，不是按钮** —— 提示能省略号截断、最小宽度归零，
	## 于是按钮保持原字号且不会被顶出右缘（Kevin 截图：【全身免疫动员】那条把按钮切掉了半个字）。
	## 按钮缩字号退成第二道闸：只在**按钮自己都摆不下**时才触发。
	bar2.show_bar(real_prompt, "", [
		{ "title": "1.0 → 1.2", "cost": "" }, { "title": "1.5 → 2.0", "cost": "" },
		{ "title": "2.0 → 2.5", "cost": "" }, { "title": "2.5 → 3.0", "cost": "" }])
	await process_frame
	await process_frame
	var right_edge: float = CWActionBar.PROMPT_RECT.end.x
	var inside := true
	var same_row := true
	for b in bar2._buttons:
		var r: Rect2 = (b as Control).get_global_rect()
		inside = inside and r.end.x <= right_edge + 0.5
		same_row = same_row and b.get_parent() == bar2._row
	var shrunk: int = CWActionBar._title_of(bar2._buttons[0]).get_theme_font_size("font_size")
	check(bar2._buttons.size() == 4 and bar2._count() == 4 and same_row, "四个按钮都在、都还在原来那一行")
	check(shrunk == CWStyle.SIZE_BODY, "按钮保持原字号 %d —— 让位的是提示，不是按钮" % shrunk)
	check(inside, "每个按钮的右缘都在 %d px 之内" % int(right_edge))

	## ③ Kevin 2026-09-08 报的那一条原样复现：提示里带玩家昵称，长得多。
	## 从前它会把右边按钮切掉半个字；现在提示自己截断，按钮完整。
	bar2.show_bar("【全身免疫动员】Kevin（树突状细胞） 可立即迁移 1 次（费用照付）", "高亮 4 格可选", [
		{ "title": "免疫监视", "cost": "" }, { "title": "免疫增援", "cost": "" },
		{ "title": "躲藏迁移", "cost": "" }])
	await process_frame
	await process_frame
	var long_ok := true
	for b in bar2._buttons:
		long_ok = long_ok and (b as Control).get_global_rect().end.x <= right_edge + 0.5
	check(long_ok, "长提示 + 三按钮：按钮右缘仍在 %d px 之内（原 bug 的样子）" % int(right_edge))
	check(bar2._row.get_combined_minimum_size().x <= CWActionBar.PROMPT_RECT.size.x,
		"整行最小宽度不再被提示顶爆（%d / %d px）"
			% [int(bar2._row.get_combined_minimum_size().x), int(CWActionBar.PROMPT_RECT.size.x)])
	check(not bar2._is_disabled(3), "第 4 个按钮可点")
	bar2.show_bar("选择分化方向", "", [{ "title": "B细胞", "cost": "" }, { "title": "T细胞", "cost": "" }])
	check(CWActionBar._title_of(bar2._buttons[0]).get_theme_font_size("font_size") == CWStyle.SIZE_BODY,
		"放得下的下一问字号回到 20（按钮每问新建，不带旧字号）")
	bar2.clear()
	check(bar2._buttons.is_empty(), "clear() 清空按钮表")
	bar2.queue_free()

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

	main_scene._begin({ "players": 4, "faction": CWData.Faction.IMMUNE, "ai": CWMatch.AI_NORMAL })
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
	## 八项：开始 / 自定义 / 联机 / 继续 / 知识之书 / 新手引导 / 设置 / 退出
	## （2026-09-03 加「自定义对局」；2026-09-05 加「知识之书」「新手引导」；2026-09-06 Kevin 去掉「规则速查」，只留 Esc 菜单那份）
	check(menu_script.ITEMS.size() == 8 and menu_script.ITEMS[1]["node"] == "Custom"
		and menu_script.ITEMS[4]["node"] == "Codex" and menu_script.ITEMS[5]["node"] == "Guide",
		"「自定义对局」「知识之书」「新手引导」按序排在主菜单，没有「规则速查」")
	var has_rules := false
	for item in menu_script.ITEMS:
		if item["node"] == "Rules":
			has_rules = true
	check(not has_rules and not items.has_node("Rules"), "主菜单里没有「规则速查」（脚本表与场景都没有）")
	var no_save := [true, true, true, false, true, true, true, true]
	check(menu_script.next_enabled(2, 1, no_save) == 4, "无档：从「联机对战」往下跳过「继续对局」落到知识之书")
	check(menu_script.next_enabled(4, 1, no_save) == 5, "知识之书再往下是新手引导")
	check(menu_script.next_enabled(last, -1, no_save) == 6, "键盘从「退出游戏」往上一步到设置")
	check(menu_script.next_enabled(0, -1, no_save) == 0, "到顶了就停在原地，不绕回")
	var with_save := [true, true, true, true, true, true, true, true]
	check(menu_script.next_enabled(2, 1, with_save) == 3, "有档：从「联机对战」往下落到「继续对局」")
	## 八项要排得下：最后一项底边不出屏，相邻两项不重叠（行距 28：20px 字、28px 行框，字形不叠）
	var ys: Array = []
	for item in menu_script.ITEMS:
		ys.append((items.get_node(item["node"]) as Label).position.y)
	var spaced := true
	for i in range(1, ys.size()):
		if ys[i] - ys[i - 1] < 26:
			spaced = false
	## 整块上移 14px（Kevin 2026-09-05 选乙案）：首项 292 → 278，末项底边 528 → 514，屏幕底留 26px
	check(spaced and ys[0] == 278 and ys[-1] + 28 <= 514, "八项行距 ≥ 26、首项 278、末项底边 ≤ 514（%s）" % str(ys))
	var sub: Control = scene.get_node("UI/Screen/Sub")
	var logo: Control = scene.get_node("UI/Screen/Logo")
	check(sub.position.y == 119 and logo.position.y == 172, "副标题 / 标题跟着菜单项一起上移 14px（%d / %d）" % [sub.position.y, logo.position.y])

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


## 教程局的整场景装配（队友 09-04 设计、09-05 接入）：桥换成 CWGuideBridge、面板挂在 UI 层暂停菜单下、
## 第一次询问就喂提示；引导面板「知识之书」直达对局内图鉴、Esc 先关书；拆局清干净；正式局不受影响。
## 不碰 CWGuideProgress（那是 user:// 里玩家真实的引导进度，测试不该改它）。
func t_tutorial() -> void:
	print("[教程局 · 引导装配]")
	var main_scene: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main_scene)
	await process_frame
	var m: CWMatch = main_scene.match_node
	CWSettings.ai_delay_ms = 0
	## 与 main.gd _begin_tutorial() 同一组参数（不走过场，直接开）
	m.tutorial = true
	m.player_count = 2
	m.human_players = [0]
	m.ai_level = CWMatch.AI_NORMAL
	m.match_seed = 20260903
	m.cancer_types = [CWData.CancerType.OSTEO]   ## main.gd _begin_tutorial 钉死的对手
	m.start()
	await process_frame
	await process_frame
	check(m.bridge is CWGuideBridge, "教程局的桥是 CWGuideBridge")
	check(m._guide != null and is_instance_valid(m._guide) and m._guide.visible and m._guide.active,
		"开局挂上引导面板并处于激活态")
	check((m.bridge as CWGuideBridge).guide == m._guide, "引导桥拿到了面板引用")
	check(m.game.player(1)["faction"] == CWData.Faction.CANCER
		and m.game.player(1)["cancer_type"] == CWData.CancerType.OSTEO, "教程对手钉死为骨肉瘤（不随种子抽）")
	check(m._guide.get_parent() == m.ui and m._guide.get_index() < m.pause_menu.get_index(),
		"面板在 UI 层、压在暂停菜单下面")
	check(m._guide._hint.text.contains("免疫细胞"),
		"第一次询问（落子）就把「现在做什么」喂给了面板：%s" % m._guide._hint.text)
	check(m._guide._chapter_label.text.begins_with("1/%d" % CWGuideData.CHAPTER_COUNT),
		"没有进度时从第 1 关开始（%s）" % m._guide._chapter_label.text)
	## 底部三个按钮不能贴在一起（接入时真机截图里「跳过引导知识之书」连成了一句）
	var skip_r: float = m._guide._skip.position.x + m._guide._skip.size.x
	var codex_r: float = m._guide._codex_btn.position.x + m._guide._codex_btn.size.x
	check(m._guide._codex_btn.get_parent() == m._guide and m._guide._codex_btn.position.x - skip_r >= 16.0
		and m._guide._btn.position.x - codex_r >= 16.0,
		"「跳过引导」「知识之书」「继续」都挂在面板上且彼此至少隔 16px（%.0f / %.0f）"
		% [m._guide._codex_btn.position.x - skip_r, m._guide._btn.position.x - codex_r])
	## 竖向也不挤（Kevin 09-05 看截图提的）：提示行在标题 20px 行框（28px）之下，正文在提示行之下，按钮基线离底边够远
	check(m._guide._hint.position.y >= m._guide._title.position.y + 28
		and m._guide._content.position.y >= m._guide._hint.position.y + 18
		and CWGuide.PANEL.size.y - (m._guide._btn.position.y + 22) >= 16.0,
		"标题 / 提示行 / 正文 / 按钮四段上下留空：提示 %.0f、正文 %.0f、按钮基线到底边 %.0f"
		% [m._guide._hint.position.y - m._guide._title.position.y, m._guide._content.position.y - m._guide._hint.position.y,
			CWGuide.PANEL.size.y - (m._guide._btn.position.y + 22)])
	check(m.pause_menu.codex_open.is_valid() and not m.pause_menu.codex_open.call(),
		"暂停菜单拿到了「书开着吗」判据，此刻没开")
	## 「继续」代做落子（Kevin 2026-09-05）：翻到「第一步：落子」时按继续 = 替玩家把第一个免疫细胞放下，再翻到下一步；
	## 剧本没走到那一步之前提示行没有尾巴。这里直接把面板拨到第 2 关第 1 步（不写进度文件）
	check(m._spotlight != null and is_instance_valid(m._spotlight) and m._spotlight.get_parent() == m.ui
		and m._spotlight.get_index() < m._guide.get_index(), "提亮层挂在 UI 层、引导面板之下")
	check(not m._guide._hint.text.contains("继续"), "第 1 关（讲解）里提示行没有「继续代做」尾巴")
	m._guide._chapter = 1
	m._guide._step = 0
	m._guide._render()
	check(m._guide._hint.text.ends_with(CWGuide.OFFER_TAIL % "继续"), "翻到「第一步：落子」：提示行接上「点继续我替你做」（%s）" % m._guide._hint.text)
	check(m.game.cells.is_empty(), "按继续之前棋盘上还没有细胞")
	m._guide._advance()
	await process_frame
	await process_frame
	check(m.game.cells.size() == 2 and m.game.cell_of(0)["faction"] == CWData.Faction.IMMUNE,
		"按「继续」→ 免疫细胞替玩家落下，AI 随后也落了（%d 个细胞）" % m.game.cells.size())
	check(m._guide.chapter() == 1 and m._guide.step_no() == 1,
		"落完子剧本翻到下一步（%d/%d）" % [m._guide.chapter(), m._guide.step_no()])
	var foot: Vector2i = m.game.cell_of(0)["pos"]
	var by_cancer := false
	for n in CWData.neighbors(foot):
		if m.game.tiles.has(n) and m.game.is_cancerous(n):
			by_cancer = true
	check(by_cancer, "代做的落点紧邻癌区（和剧本建议的一样）")
	check(m.game.round_no == 1 and m.action_bar.visible, "随后轮到玩家的第一个行动回合，行动栏已出现")
	check(m._guide._hint.text == CWGuideBridge.STEP_HINTS["move"]["hint"], "「能量就是生命」这一步：提示是通用的迁移句、没有代做尾巴（%s）" % m._guide._hint.text)
	m._guide._step = 4      ## 「别忘了结束回合」：翻页后提示换成结束回合那句、带代做尾巴（只 _render，不写进度）
	m._guide._render()
	check(m._guide._hint.text == CWGuideBridge.STEP_HINTS["end"]["hint"] + CWGuide.OFFER_TAIL % "下一章",
		"翻到「别忘了结束回合」：提示跟着换成结束回合那句 + 代做尾巴（%s）" % m._guide._hint.text)
	m._guide._step = 1
	m._guide._render()
	## 提亮层：按 flag 找目标（棋盘 / 特殊组织 / 可落子格 / 右栏 / 行动栏按钮 / 结束回合 / 手牌抽屉）
	var sp := m._spotlight
	sp.sync("board", m)
	check(sp.rects.size() == 1 and sp.hexes.is_empty() and sp.rects[0].size.x > 300, "board：整张棋盘一个包围框")
	var n_special := 0
	for c in CWData.all_coords():
		if CWData.special_of(c) != CWData.Special.NONE:
			n_special += 1
	sp.sync("special", m)
	check(sp.hexes.size() == n_special and n_special > 0, "special：%d 个特殊组织格各描一圈" % n_special)
	sp.sync("place", m)
	check(sp.hexes.size() > 0 and sp.hexes.size() < 40, "place：只描紧邻癌区的可落子格（%d 格）" % sp.hexes.size())
	sp.sync("energy", m)
	check(sp.rects.size() == 1 and sp.rects[0] == m.panel.rect_of("row:0")
		and sp.rects[0].position.x >= CWMatchPanel.RECT.position.x, "energy：右栏里人类那一行")
	sp.sync("immune_defend", m)
	check(sp.hexes.size() == 1, "immune_defend：自己的免疫细胞脚下")
	sp.sync("attack", m)
	check(sp.hexes.size() == 1, "attack：癌细胞脚下")
	sp.sync("purify", m)
	check(sp.hexes.size() > 0, "purify：脚边可净化的癌组织（%d 格）" % sp.hexes.size())
	sp.sync("draw", m)
	check(sp.rects.size() == 1 and sp.rects[0] == m.action_bar.button_rect(CWData.ACT_NAMES["draw"]), "draw：行动栏「基因表达」按钮")
	sp.sync("move", m)
	check(sp.rects.size() == 1 and sp.rects[0] == m.action_bar.button_rect("迁移"), "move：行动栏「迁移」按钮")
	sp.sync("attack_limit", m)
	check(sp.rects.size() == 1 and sp.rects[0] == m.action_bar.bar_rect(), "attack_limit：整条行动栏")
	sp.sync("end", m)
	check(sp.rects.size() == 1 and m.panel._end.visible and sp.rects[0] == m.panel._end.get_global_rect(), "end：右栏「结束回合」按钮")
	sp.sync("hand_card", m)
	check(sp.rects.size() == 1 and sp.rects[0].position.y == CWHand.REST_TOP, "hand_card：左下角手牌抽屉")
	sp.sync("hand_limit", m)
	check(sp.rects.size() == 1 and sp.rects[0].size.x > 30, "hand_limit：右栏你那一行的手牌方块")
	sp.sync("differentiate", m)
	check(sp.rects.size() == 1 and sp.rects[0] == m.panel.rect_of("level"), "differentiate：I 级还没「分化」按钮 → 描右栏免疫等级块")
	sp.sync("round", m)
	check(sp.rects.size() == 1 and sp.rects[0] == m.panel.rect_of("round"), "round：右栏顶部回合块")
	sp.sync("world_event", m)
	check(sp.rects.size() == 2, "world_event：回合块 + 左上角「对局日志」入口")
	sp.sync("graduated", m)
	check(sp.rects.is_empty() and sp.hexes.is_empty(), "graduated：没有目标就什么都不画")
	sp.sync("", m)
	check(sp.rects.is_empty() and sp.hexes.is_empty(), "没有 flag 的步骤不画")
	## 引导收起（跳过）后 _process 不再喂 flag
	m._guide.dismiss()
	await process_frame
	check(sp.rects.is_empty() and sp.hexes.is_empty(), "跳过引导后提亮层清空")
	m._guide.active = true
	m._guide.visible = true
	## 关卡最后一步按钮写「下一章」、全部最后一步写「完成引导」：尾巴要跟着按钮的字走，按钮按实际宽度靠右、右边留 PAD
	## （Kevin 2026-09-05 截图：「别忘了结束回合 5/5」尾巴还说「继续」，「下一章」贴到边框）
	m._guide._chapter = 1
	m._guide._step = CWGuideData.steps(1).size() - 1      ## 「别忘了结束回合」：教 end，此刻正等行动 → 可代做
	m._guide._render()
	check(m._guide._btn.text == "下一章" and m._guide._hint.text.ends_with(CWGuide.OFFER_TAIL % "下一章"),
		"关卡最后一步：尾巴写的是「下一章」（%s）" % m._guide._hint.text)
	check(m._guide._btn.size.x >= 60 and m._guide._btn.position.x + m._guide._btn.size.x <= CWGuide.PANEL.size.x - CWGuide.PAD,
		"「下一章」按实际宽度靠右，右边留 ≥ %d（右缘 %.0f）" % [CWGuide.PAD, m._guide._btn.position.x + m._guide._btn.size.x])
	m._guide._chapter = CWGuideData.CHAPTER_COUNT - 1
	m._guide._step = CWGuideData.steps(CWGuideData.CHAPTER_COUNT - 1).size() - 1
	m._guide._render()
	check(m._guide._btn.text == "完成引导" and m._guide._btn.position.x + m._guide._btn.size.x <= CWGuide.PANEL.size.x - CWGuide.PAD
		and m._guide._btn.position.x - (m._guide._codex_btn.position.x + m._guide._codex_btn.size.x) >= 16.0,
		"「完成引导」四个字同样靠右留边，且离「知识之书」≥ 16px")
	check(not m._guide._hint.text.contains("我替你做"), "收尾页不教动作 → 没有代做尾巴（%s）" % m._guide._hint.text)
	## 引导面板「知识之书」直达：第 4 关（下标 3）对应 CODEX_PAGE[3]
	m._guide._chapter = 3
	m._guide.open_codex_at_current()
	check(m._codex != null and m._codex.visible and m._codex._page == CWGuideData.CODEX_PAGE[3],
		"直达：对局内知识之书翻到当前关对应的那一章（第 %d 页）" % (m._codex._page + 1))
	check(m._codex.get_parent() == m.ui and m._codex.get_index() < m.pause_menu.get_index(),
		"对局内的书也在 UI 层、暂停菜单下面")
	check(m.pause_menu.codex_open.call(), "书开着：暂停菜单让位")
	m._unhandled_input(press_action("ui_right"))
	check(m._codex._page == CWGuideData.CODEX_PAGE[3] + 1, "书开着时方向键由 CWMatch 路由给书翻页")
	m._unhandled_input(press_action("ui_cancel"))
	check(not m._codex.visible and m._guide.visible, "Esc 先关书，引导面板还在")
	check(not m.pause_menu.codex_open.call(), "书关了：判据回到「没开」")
	m.teardown()
	await process_frame
	check(m._guide == null and m._spotlight == null and not m._codex.visible and not m.pause_menu.codex_open.is_valid(),
		"拆局：面板与提亮层销毁、书隐藏、让位判据清空")
	## 正式局不带引导：同一个 CWMatch 复用
	m.tutorial = false
	m.start()
	await process_frame
	await process_frame
	check(not (m.bridge is CWGuideBridge) and m._guide == null, "正式局：普通桥、没有引导面板")
	m.teardown()
	await process_frame
	CWSettings.ai_delay_ms = 220
	root.remove_child(main_scene)
	main_scene.free()

func t_guide_data() -> void:
	print("[新手引导剧本]")
	check(CWGuideData.CHAPTER_COUNT == 6, "引导剧本共 6 关")
	var want := [0, 4, 5, 6, 3, 8]
	check(CWGuideData.CODEX_PAGE.size() == 6 and CWGuideData.CODEX_PAGE == want,
		"每关都挂钩到知识之书的对应章节（%s）" % str(CWGuideData.CODEX_PAGE))
	check(CWGuideData.chapter_titles().size() == CWGuideData.CHAPTER_COUNT,
		"每关都有标题")
	check(CWGuideData.chapter_subtitles().size() == CWGuideData.CHAPTER_COUNT,
		"每关都有一句概括")
	var sum := 0
	for i in CWGuideData.CHAPTER_COUNT:
		var sts: Array = CWGuideData.steps(i)
		check(not sts.is_empty(), "第 %d 关至少一步" % i)
		for st in sts:
			check(st.has("t") and st.has("b") and (st["b"] as Array).size() > 0,
				"第 %d 关每步都有标题与正文" % i)
		sum += sts.size()
	check(CWGuideData.total_steps() == sum,
		"total_steps() 与逐关步骤数之和一致（%d）" % sum)
	var cells: Array = CWGuideData.steps(5)
	check(cells.size() >= 6, "细胞图鉴关覆盖免疫 / 癌方 / 速查（%d 步）" % cells.size())
	## 2026-09-05 核对：剧本文字同样现读规则，且每行装得进面板正文栏
	var text := ""
	var wide: Array = []
	var budget: int = int(CWGuide.PANEL.size.x) - CWGuide.PAD * 2
	for i in CWGuideData.CHAPTER_COUNT:
		for st in CWGuideData.steps(i):
			for line in st["b"]:
				text += str(line) + " "
				if CWStyle.FONT.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, CWStyle.SIZE_LABEL).x > budget:
					wide.append(line)
	check(wide.is_empty(), "每行都放得进引导面板正文栏 %d（超的：%s）" % [budget, str(wide)])
	check(text.contains("%d 升 III 级" % CWData.LEVEL_MIN_MEMORY[2]) and not text.contains("16 升"),
		"剧本的记忆门槛现读 LEVEL_MIN_MEMORY")
	check(text.contains("标记脚下") and not text.contains("固化成型更快"), "剧本的骨肉瘤按重做后的骨样硬化描述")
	check(text.contains("癌方结算【无氧呼吸】") and not text.contains("结束回合时结算【无氧呼吸】"),
		"剧本的世界回合按 E 阶段无氧结算描述（eturn=0，Kevin 2026-09-06 改回）")
	check(text.contains("左下角「跳过引导」"), "「跳过引导」按钮的位置说对了（面板左下角）")
	check(text.contains("传到另一端"), "血管说的是「S 阶段传送」，不只是血行转移")


func t_codex() -> void:
	print("[知识之书]")
	var chs: Array = CWCodex.chapters()
	check(chs.size() >= 13, "知识之书至少 13 章（当前 %d 章）" % chs.size())
	var codex_ch: Dictionary = {}
	for ch in chs:
		check(ch.has("title") and not (ch["entries"] as Array).is_empty(), "每章都有标题与条目")
		if ch["title"] == "细胞图鉴":
			codex_ch = ch
	check(not codex_ch.is_empty(), "知识之书存在「细胞图鉴」章节")
	if codex_ch.is_empty():
		return
	var entries: Array = codex_ch["entries"]
	check(entries.size() == 9, "细胞图鉴恰好 9 个条目（当前 %d 个）" % entries.size())
	var blob := ""
	for e in entries:
		blob += str(e["t"]) + " " + " ".join(e["b"]) + " "
	var need := ["抗体", "裂解", "标记", "血行转移", "黏液破裂", "骨样硬化", "瓦伯格"]
	for kw in need:
		check(blob.contains(kw), "细胞图鉴提到「%s」" % kw)
	## 2026-09-05 核对：图鉴文字跟着现行规则与旋钮走，且每一行都装得进正文栏（裁切只是兜底，玩家不该看到省略号）
	var tune := CWTuning.new()
	var all_text := ""
	var wide: Array = []
	var budget: int = CWCodex.W - CWCodex.PAD * 2
	for ch in chs:
		for e in ch["entries"]:
			all_text += str(e["t"]) + " " + " ".join(e["b"]) + " "
			for line in e["b"]:
				if CWStyle.FONT.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, CWStyle.SIZE_LABEL).x > budget:
					wide.append(line)
	check(wide.is_empty(), "每行都放得进正文栏宽 %d（超的：%s）" % [budget, str(wide)])
	check(all_text.contains("平方") and all_text.contains(CWData.fmt(CWData.AEROBIC_LEVEL_BASE)),
		"有氧呼吸按现行公式描述（等级差的平方 × 0.5 + 基数）")
	check(all_text.contains("次方") and all_text.contains("全图") and all_text.contains("E 阶段结算【无氧呼吸】")
		and not all_text.contains("行动回合末结算【无氧呼吸】"),
		"无氧呼吸：现行式（块内癌组织的次方 + 全图固化）+ E 阶段统一结算")
	check(not all_text.contains("占比") and not all_text.contains("最多存 0") and not all_text.contains("低保"),
		"09-05 之前的口径（盘面占比 / 存量上限 / 低保）不再出现")
	check(all_text.contains("%d 升 III 级" % CWData.LEVEL_MIN_MEMORY[2]) and not all_text.contains("16 升"),
		"记忆门槛现读 LEVEL_MIN_MEMORY")
	check(all_text.contains("标记脚下") and all_text.contains("%d 个世界回合后直接固化" % tune.osteo_ossify_rounds)
		and not all_text.contains("固化计数 +"),
		"骨样硬化按 09-05 重做后的主动技能描述")
	check(all_text.contains("连续 %d 个世界回合末" % tune.cancer_win_hold_rounds), "癌方占地胜写明连续达标回合数")
	check(all_text.contains("第 3、6、10、14 回合") and CWCodex.event_rounds_text(tune.limit_round) == "3、6、10、14",
		"世界事件回合现算（与 is_world_event_round 一致）")
	## 搜索（Kevin 2026-09-06）：纯函数找档 —— 子串、大小写不分、标题与正文都搜、空词为空
	var hits: Array = CWCodex.search("血管")
	var hit_ok := not hits.is_empty()
	for h in hits:
		var src: Dictionary = chs[h["page"]]
		if src["title"] != h["chapter"] or not (String(h["t"]).contains("血管") or String(h["line"]).contains("血管")):
			hit_ok = false
	check(hit_ok, "搜「血管」：每条都指回它所在的章，标题或那一行确实含词（%d 条）" % hits.size())
	check(CWCodex.search("e 阶段").size() == CWCodex.search("E 阶段").size() and not CWCodex.search("e 阶段").is_empty(),
		"大小写不分")
	check(CWCodex.search("").is_empty() and CWCodex.search("   ").is_empty() and CWCodex.search("不存在的词xyz").is_empty(),
		"空词 / 找不到 → 空")
	check(CWCodex.search("细胞").size() <= CWCodex.MAX_HITS, "最多 %d 条" % CWCodex.MAX_HITS)
	## 界面：打字铺结果页、回车跳第一条并滚到那个条目、Esc 先收起搜索再关书；结果页不翻章
	var book := CWCodex.new()
	root.add_child(book)
	await process_frame
	book.open()
	book._search.text = "血管"
	book._on_query("血管")
	check(book._in_results and book._title.text == "搜索「血管」" and book._page_label.text == "%d 条" % hits.size()
		and book._content.get_child_count() >= hits.size(), "打字 → 结果页：标题、条数、每条一行（%s）" % book._title.text)
	var page_before: int = book._page
	book._next_page()
	check(book._in_results and book._page == page_before, "结果页里方向键不翻章")
	book._on_submit("血管")
	check(not book._in_results and book._page == int(hits[0]["page"]) and book._title.text == chs[book._page]["title"],
		"回车 → 翻到第一条所在的那一章（第 %d 页）" % (book._page + 1))
	var esc := InputEventAction.new()
	esc.action = "ui_cancel"
	esc.pressed = true
	book._on_query("血管")
	book.handle_input(esc)
	check(book.visible and not book._in_results and book._search.text == "", "结果页上 Esc：只收起搜索、清词，书还开着")
	book.handle_input(esc)
	check(not book.visible, "再按 Esc 才关书")
	book.open()
	book._on_query("不存在的词xyz")
	check(book._in_results and book._page_label.text == "0 条", "找不到：结果页写 0 条")

	## 翻页箭头的悬停辉光（Kevin 2026-09-09 报「换页箭头没有加辉光」）。
	## **无头视口不跟踪悬停控件**，所以这里直接摆 `_hot_arrow` 再调 `_paint_arrows()` ——
	## 与 mouse_entered 回调走的是同一条路（回调本身只做这两件事）。
	var glow := func(a: Label) -> int:
		return int(a.get_theme_constant("outline_size"))
	book._on_query("")            ## 回到正常翻页页面
	book.open_to(0)
	book._hot_arrow = null
	book._paint_arrows()
	check(glow.call(book._next) == 0 and glow.call(book._prev) == 0, "没悬停 → 两枚都不发光")
	book._hot_arrow = book._next
	book._paint_arrows()
	check(glow.call(book._next) == 8
		and book._next.get_theme_color("font_color") == Color.WHITE,
		"悬停可翻的那枚 → 8px 白光 + 字转白（同 CWConfigPanel 的拨值箭头）")
	## 首页的「<」翻不动：**悬停它也不该发光** —— 亮起来等于许一个做不到的承诺
	book._hot_arrow = book._prev
	book._paint_arrows()
	check(glow.call(book._prev) == 0
		and book._prev.get_theme_color("font_color") == CWStyle.TEXT_OFF,
		"首页悬停「<」→ 不发光、保持压暗（到头了，点了也没反应）")
	## 末页反过来
	book.open_to(chs.size() - 1)
	book._hot_arrow = book._next
	book._paint_arrows()
	check(glow.call(book._next) == 0, "末页悬停「>」→ 不发光")
	## 结果页两枚都翻不动（_prev_page / _next_page 见 _in_results 直接 return）
	book._on_query("血管")
	book._hot_arrow = book._next
	book._paint_arrows()
	check(glow.call(book._next) == 0 and glow.call(book._prev) == 0,
		"结果页：两枚都翻不动，悬停也不发光")
	book.queue_free()


class FakeGuide:
	extends CWGuide
	var hints: Array[String] = []
	func _init() -> void:
		active = true
		_chapter = 1
		_step = 0
	func set_hint(text: String) -> void:
		hints.append(text)


func t_guide_bridge() -> void:
	print("[引导桥]")
	var data_acts := {}
	for i in 4:
		for st in CWGuideData.steps(i):
			var a: String = str(st.get("act", ""))
			if a != "":
				data_acts[a] = true
	check(not data_acts.is_empty(), "剧本里有需要玩家动手的动作步骤")
	var missing := []
	for a in data_acts:
		if not CWGuideBridge.STEP_HINTS.has(a):
			missing.append(a)
	check(missing.is_empty(), "STEP_HINTS 覆盖剧本全部动作键（%s）" % str(data_acts.keys()))
	check(CWGuideBridge.STEP_HINTS.size() == 5, "STEP_HINTS 恰好五组动作提示")
	check(CWGuideBridge.AUTO_ACTS.size() == 3 and CWGuideBridge.AUTO_ACTS.has("place")
		and CWGuideBridge.AUTO_ACTS.has("end") and CWGuideBridge.AUTO_ACTS.has("draw"),
		"AUTO_ACTS 只含一步到位的 place/end/draw")
	check(not CWGuideBridge.AUTO_ACTS.has("move") and not CWGuideBridge.AUTO_ACTS.has("attack"),
		"move/attack 是两段式选格，留给玩家亲手点")
	## 实跑一次：轮到人类时只喂提示、不再自动演示（Kevin 2026-09-05：落子要么亲手点、要么点「继续」代做）
	var g := CWGame.new()
	g.init(CWData.FACTION_ORDER[2], 7)
	var b := CWGuideBridge.new()
	b.game = g
	b.human_pids = [0]
	var fake := FakeGuide.new()
	b.guide = fake
	var req := { "kind": "setup_place", "pid": 0, "prompt": "选位置", "options": [
		{ "label": "a", "data": { "to": Vector2i(1, 0) } },
		{ "label": "b", "data": { "to": Vector2i(2, 0) } }] }
	var idx: int = await b.ask(req)
	check(idx >= 0 and idx < 2 and fake.hints.size() == 1 and not fake.hints[0].contains("演示"),
		"落子那一问只喂提示、不替玩家落（无界面时退回 AI 代答）")
	check(b._cur_req.is_empty() and not b.can_demo(), "作答完这一问就不再可代做")
	## 「继续」代做：模拟一问正卡在等玩家（_pending 有值、_cur_req 是这一问）
	var got: Array = []
	var ans := CWUIBridge.Answer.new()
	ans.done.connect(func(v: Variant) -> void: got.append(v))
	b._cur_req = req
	b._pending = ans
	check(b.can_demo(), "正在教落子（第 2 关第 1 步）且引擎正等落子 → 「继续」可代做")
	check(b.take_offer() and got.size() == 1 and int(got[0]) >= 0 and int(got[0]) < 2,
		"按「继续」替玩家答了一个合法下标（%s）" % str(got))
	check(not b.take_offer(), "同一问不会代做第二次")
	## 教的不是一步到位的动作 → 不代做
	fake._step = 2      ## 「第二步：迁移」（两段式，留给玩家亲手点）
	b._cur_req = req
	b._pending = CWUIBridge.Answer.new()
	check(not b.can_demo() and not b.take_offer(), "教迁移时「继续」不代做（两段式选格留给玩家）")
	## 结束回合 / 抽卡：从行动那一问里挑出对应选项的下标
	fake._step = 4      ## 「别忘了结束回合」
	var act_req := { "kind": "action", "pid": 0, "prompt": "", "options": [
		{ "label": "迁移", "data": { "act": "move", "to": Vector2i(1, 0) } },
		{ "label": "抽卡", "data": { "act": "draw" } },
		{ "label": "结束回合", "data": { "act": "end" } }] }
	got.clear()
	var ans2 := CWUIBridge.Answer.new()
	ans2.done.connect(func(v: Variant) -> void: got.append(v))
	b._cur_req = act_req
	b._pending = ans2
	check(b.can_demo() and b.take_offer() and got == [2], "教结束回合时「继续」= 答「结束回合」那个下标")
	## 提示跟着正在教的那一步走：同一问里教结束回合就说结束回合，教抽卡就说抽卡，教的不在这一问里就退回迁移那句
	b._cur_req = act_req
	check(b.current_hint() == CWGuideBridge.STEP_HINTS["end"]["hint"], "教结束回合：提示是结束回合那句")
	fake._step = 1      ## 「能量就是生命」（展示型，不教动作）
	check(b.current_hint() == CWGuideBridge.STEP_HINTS["move"]["hint"], "展示型步骤：退回通用的迁移提示")
	fake._chapter = 2
	fake._step = 0      ## 「怎么发起攻击」
	check(b.current_hint() == CWGuideBridge.STEP_HINTS["attack"]["hint"], "教攻击：提示是攻击那句（选项里攻击就是迁移）")
	b._cur_req = {}
	check(b.current_hint() == "", "没在等人：没有提示")
	fake._chapter = 3
	fake._step = 0      ## 「抽卡入口」
	b._cur_req = act_req
	check(b._demo_index() == 1, "教抽卡时「继续」= 答「基因表达」那个下标")
	## 落子代做挑紧邻癌区的格：g.init() 还没铺盘（开局第一步才铺），先铺一张全健康的盘、正中手涂一格癌组织，
	## 再各找一格「挨着癌区」和「不挨」的健康格，两种顺序都验（之前直接读 g.tiles 报了 SCRIPT ERROR：套件只看断言，
	## 运行时报错要靠 tools/run_tests.sh 才抓得到）
	g.setup.build_board()
	g.tiles[Vector2i.ZERO]["tissue"] = CWData.Tissue.CANCER
	fake._chapter = 1
	fake._step = 0
	var near := Vector2i(9999, 9999)   ## 哨兵：还没找到
	var far := near
	for c in CWData.all_coords():
		if g.tiles[c]["tissue"] != CWData.Tissue.HEALTHY:
			continue
		var adj := false
		for n in CWData.neighbors(c):
			if g.tiles.has(n) and g.is_cancerous(n):
				adj = true
		if adj and near == Vector2i(9999, 9999):
			near = c
		if not adj and far == Vector2i(9999, 9999):
			far = c
	check(near != Vector2i(9999, 9999) and far != Vector2i(9999, 9999), "盘面上既有挨着癌区的健康格也有不挨的（%s / %s）" % [near, far])
	var far_req := { "kind": "setup_place", "pid": 0, "prompt": "选位置", "options": [
		{ "label": "far", "data": { "to": far } },
		{ "label": "near", "data": { "to": near } }] }
	b._cur_req = far_req
	b._pending = CWUIBridge.Answer.new()
	check(b._demo_index() == 1, "代做落子挑紧邻癌区的那一格（剧本建议的位置）")
	var near_req := { "kind": "setup_place", "pid": 0, "prompt": "选位置", "options": [
		{ "label": "near", "data": { "to": near } },
		{ "label": "far", "data": { "to": far } }] }
	b._cur_req = near_req
	check(b._demo_index() == 0, "顺序反过来也是挑挨着癌区的那格")
	var none_req := { "kind": "setup_place", "pid": 0, "prompt": "选位置", "options": [
		{ "label": "far", "data": { "to": far } }] }
	b._cur_req = none_req
	check(b._demo_index() == 0, "没有挨着癌区的候选就退回第一个合法格")
	## guide 为空（无头 / 面板还没挂上）不能崩
	b.guide = null
	b._cur_req = req
	b._pending = CWUIBridge.Answer.new()
	check(not b.can_demo() and not b.take_offer(), "没有引导面板时不代做")
	var idx3: int = await b.ask(req)
	check(idx3 >= 0, "没有引导面板时桥照常作答、不解引用空面板")
	fake.free()
	g.dispose()


## 引导提亮区域（Kevin 2026-09-05 拍板做完整版）：剧本每个 flag 都要有归宿，六边形描边的几何要和棋盘对得上。
## 真对局里各 flag 找到什么目标，在 t_tutorial 里就着活的对局验。
func t_guide_spotlight() -> void:
	print("[引导提亮区域]")
	var used := {}
	for i in CWGuideData.CHAPTER_COUNT:
		for st in CWGuideData.steps(i):
			var f: String = str(st.get("flag", ""))
			if f != "":
				used[f] = true
	var missing: Array = []
	for f in used:
		if not CWGuideSpotlight.FLAGS.has(f):
			missing.append(f)
	check(missing.is_empty(), "剧本 %d 个提亮键全部登记在 FLAGS 表（缺：%s）" % [used.size(), str(missing)])
	var dead: Array = []
	for f in CWGuideSpotlight.FLAGS:
		if not used.has(f):
			dead.append(f)
	check(dead.is_empty(), "FLAGS 表里没有剧本不用的键（多：%s）" % str(dead))
	## 六边形描边：宽 = 横向格距 36 × 缩放，高 ≈ 贴图顶面 26.7 × 缩放
	var pts := CWGuideSpotlight.hex_points(Vector2(100, 100), 2.0)
	var lo := pts[0]
	var hi := pts[0]
	for p in pts:
		lo = lo.min(p)
		hi = hi.max(p)
	check(pts.size() == 7 and pts[0] == pts[6], "六边形描边 6 个顶点首尾闭合")
	check(absf((hi.x - lo.x) - 72.0) < 0.01 and absf((hi.y - lo.y) - 53.3) < 0.2,
		"描边宽高 = 格距 36 / 顶面 26.7 乘缩放 2（实为 %s）" % str(hi - lo))
	check(absf((lo.x + hi.x) / 2.0 - 100.0) < 0.01 and absf((lo.y + hi.y) / 2.0 - 100.0) < 0.01, "描边以顶面中心为中心")


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
	## 同上：攻击那条摆一次确定性的，不赌「这一局的 AI 会不会去打架」
	var g4 := bare_game()
	var spy := CWRollSpy.new()
	spy.game = g4
	for pid in g4.order:
		g4.bridges[pid] = spy
	var im4 := put_immune(g4, Vector2i.ZERO)
	var ca4 := CWSetup.make_cell(g4.cells.size(), 1, CWData.Faction.CANCER,
		Vector2i(1, 0), -1, CWData.CancerType.SCLC, 500)
	g4.cells.append(ca4)
	g4.tiles[Vector2i(1, 0)]["tissue"] = CWData.Tissue.CANCER
	spy.rolls.clear()
	await g4.actions._do_move(im4, Vector2i(1, 0), 0)
	var reasons4 := {}
	for r in spy.rolls:
		reasons4[r["reason"]] = true
	check(reasons4.has("攻击"), "攻击掷骰走了演出钩子（%s）" % str(reasons4.keys()))
	g4.dispose()

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


## CWStateCodec 的包含/排除边界。每次只动一个会改变后续结算的字段，哈希都必须变。
func t_state_codec() -> void:
	print("[状态编码]")
	var g := make_game(2, 103)
	await run_setup(g)
	await g.pending()  ## 进入顶层待决边界，pending 本身也是规则状态。
	var base := g.snapshot()
	var cases := [
		func(): g.rng.state += 1,
		func(): g.flow["acts"] += 1,
		func(): g._pending["pid"] = 1 - int(g._pending["pid"]),
		func(): g.current_pid = int(g.current_pid) + 1,
		func(): g.differentiated.append(CWData.ImmuneType.T_CELL),
		func(): g.events["pool"].pop_back(),
		func(): g.cells[0]["draws_used"] += 1,
		func(): g.cells[0]["fx_turn"]["test"] = 1,
		func(): g.cells[0]["antibody_used"] += 1,
		func(): g.cells[0]["differentiated"] = not g.cells[0]["differentiated"],
		func(): g.cells[0]["armor_used"] = not g.cells[0]["armor_used"],
		func(): g.cells[0]["mutate_used"] = not g.cells[0]["mutate_used"],
		func(): g.cells[0]["toxin_used"] += 1,
		func(): g.cells[0]["metastasis_used"] = not g.cells[0]["metastasis_used"],
		func(): g.cells[0]["hand"].append("状态测试卡"),
		func(): g.cells[0]["mods"].append({ "name": "状态测试", "uses": 1, "until": "turn", "seq": 1, "data": {} }),
		func(): _codec_mutate_tile(g),
		func(): g.tune.attack_max_per_turn += 1,
	]
	for i in cases.size():
		var mutate: Callable = cases[i]
		g.restore(base)
		var h := g.state_hash()
		mutate.call()
		check(g.state_hash() != h, "规则字段 #%d 单独变化会改变 state_hash" % i)
	g.restore(base)
	var h0 := g.state_hash()
	g.logs.append("纯表现日志")
	g.phase = "界面文案变化"
	g.cells[0]["play_n"] += 99
	check(g.state_hash() == h0, "日志、phase 与 play_n 不改变 state_hash")
	g.restore(base)
	var r := g.rng.randi()
	g.restore(base)
	check(g.rng.randi() == r and g.flow == base["flow"], "restore 同时还原 RNG 与流程游标")
	g.dispose()


func _codec_mutate_tile(g: CWGame) -> void:
	var coords := g.tiles.keys()
	coords.sort()
	g.tiles[coords[0]]["store"] += 1


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
	## 裂解（2026-09-01 改写）：目标是**相邻**的固化癌组织，每格一个顶层选项
	imm["itype"] = CWData.ImmuneType.T_CELL
	imm["pos"] = Vector2i.ZERO
	imm["energy"] = 50
	var nbs: Array[Vector2i] = CWData.neighbors(Vector2i.ZERO)
	g.tiles[Vector2i.ZERO]["tissue"] = CWData.Tissue.SOLID   ## 脚下那格**不该**再算目标
	g.tiles[nbs[0]]["tissue"] = CWData.Tissue.SOLID
	g.tiles[nbs[1]]["tissue"] = CWData.Tissue.SOLID
	var lyse: Array[Vector2i] = []
	for o in g.actions.build_options(imm):
		if o["data"].get("act", "") == "lyse":
			lyse.append(o["data"]["to"])
	check(lyse.size() == 2 and nbs[0] in lyse and nbs[1] in lyse,
		"两格相邻固化 → 两个顶层选项，脚下那格不算")
	g.actions._do_lyse(imm, nbs[0])
	check(g.tiles[nbs[0]]["tissue"] == CWData.Tissue.HEALTHY
		and g.tiles[nbs[0]]["solid"] == 0, "裂解：相邻固化一步转为健康组织")
	var mem_before: int = g.memory
	g.actions._do_lyse(imm, nbs[1])
	check(g.memory == mem_before, "裂解不再算【净化】，不给抗原记忆")
	g.tiles[Vector2i.ZERO]["tissue"] = CWData.Tissue.HEALTHY
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
## 分化提问里悬停种类按钮 → 浮该细胞种类的详情（2026-09-03 Kevin 要的）
func t_diff_info() -> void:
	print("[分化提问悬停细胞详情]")
	var max_w := CWCardInfo.W - CWCardInfo.PAD_H * 2.0
	var missing: Array = []
	var toolong: Array = []
	for t in [CWData.ImmuneType.B_CELL, CWData.ImmuneType.T_CELL, CWData.ImmuneType.MACRO, CWData.ImmuneType.DENDRITIC]:
		var d := CWCardInfo.describe_type(t)
		if d["lines"].is_empty():
			missing.append(CWData.IMMUNE_TYPE_NAMES[t])
		for l in d["lines"]:
			if CWStyle.FONT.get_string_size(l, HORIZONTAL_ALIGNMENT_LEFT, -1, CWStyle.SIZE_LABEL).x > max_w:
				toolong.append(l)
		check(d["name"] == CWData.IMMUNE_TYPE_NAMES[t] and d["kind"] == "【分化】", "%s：名字 + 【分化】" % d["name"])
	check(missing.is_empty() and toolong.is_empty(), "四种细胞都有 PRD 原文、折行后没有超宽（%s %s）" % [str(missing), str(toolong)])
	check(CWCardInfo.describe_type(CWData.ImmuneType.BASIC)["lines"].is_empty(), "未分化没有文案，不崩")
	var b_lines: PackedStringArray = CWCardInfo.describe_type(CWData.ImmuneType.B_CELL)["lines"]
	check(b_lines[0].begins_with("【抗体】") and b_lines.size() >= 3, "B细胞：【抗体】起头、列表项各占一行（%d 行）" % b_lines.size())
	## 询问桥：分化的子选项条目带 info，别的不带
	var br := CWUIBridge.new()
	var e := br._sub_entry("differentiate", { "act": "differentiate", "type": CWData.ImmuneType.MACRO })
	check(e["title"] == "巨噬细胞" and e.has("info") and e["info"]["name"] == "巨噬细胞", "分化条目：标题种类名 + info")
	check(not br._sub_entry("lyse", { "act": "lyse", "purge": true }).has("info"), "裂解条目不带 info")
	## 行动栏：悬停信号进 / 出，按钮位置
	var bar := CWActionBar.new()
	root.add_child(bar)
	await process_frame
	var got: Array = []
	bar.hovered.connect(func(i: int) -> void: got.append(i))
	bar.show_bar("选择分化的目标", "", [e, { "title": "取消", "cost": "右键 / Esc" }], 1)
	await process_frame
	bar._set_hot(0)
	bar._set_hot(0)
	bar._set_hot(-1)
	check(got == [0, -1], "行动栏悬停信号：进 0、出 -1，重复不重发（%s）" % str(got))
	check(bar.button_x(0) >= CWActionBar.PROMPT_RECT.position.x and bar.button_x(9) == CWActionBar.PROMPT_RECT.position.x,
		"button_x：按钮画布 x；越界下标退回提示条左缘")
	## 详情框：等 0.25s 浮出、贴按钮左缘、压在行动栏上方；靠右不越界；离开即收
	var box := CWCardInfo.new()
	root.add_child(box)
	await process_frame
	box.on_hover_info(CWCardInfo.describe_type(CWData.ImmuneType.T_CELL), 300.0)
	box.sync(0.1, CWData.Faction.IMMUNE, false)
	check(not box.visible, "0.1s 还没浮出（与手牌详情同 0.25s）")
	box.sync(0.2, CWData.Faction.IMMUNE, false)
	check(box.visible and box.position.x == 300.0
		and box.position.y + box.size.y <= CWActionBar.PROMPT_RECT.position.y, "0.25s 后浮出：贴按钮左缘、框底在行动栏上方")
	box.on_hover_info(CWCardInfo.describe_type(CWData.ImmuneType.DENDRITIC), 900.0)
	check(not box.visible, "换按钮：先收起重新计时")
	box.sync(0.3, CWData.Faction.IMMUNE, false)
	## 2026-09-04 起「往左让」的界线是**右侧竖条的左缘**，不是画布右缘 ——
	## 让到画布内还不够，压在竖条上就看不见自己的能量了
	check(box.visible and box.position.x + CWCardInfo.W
		<= CWView.screen_size().x - CWMatchPanel.RECT.size.x - 8.0,
		"靠右的按钮：框往左让到右栏之外（右缘 %d）" % (box.position.x + CWCardInfo.W))
	box.on_hover_info({}, 0.0)
	check(not box.visible, "离开按钮：立刻收起")
	box.on_hover("补体级联")
	box.sync(0.3, CWData.Faction.IMMUNE, false)
	check(box.visible and box.position.x == CWHand.LEFT, "之后手牌悬停照常走原来的摆位")
	bar.queue_free()
	box.queue_free()


## 7 字以上的卡名折两行（2026-09-03 Kevin 报「自分泌生存信号」抬起后尾字被裁）
func t_hand_long_name() -> void:
	print("[手牌长卡名折行]")
	check(CWHand.name_lines("补体级联") == PackedStringArray(["补体级联"]), "6 字以内不折")
	check(CWHand.name_lines("BCL-2抗凋亡") == PackedStringArray(["BCL-2抗凋亡"]), "8 字但 ASCII 窄、只有 55px → 不折（按像素宽判）")
	check(CWHand.name_lines("穿孔素-颗粒酶") == PackedStringArray(["穿孔素-", "颗粒酶"]), "穿孔素-颗粒酶 66px → 折")
	check(CWHand.name_lines("自分泌生存信号") == PackedStringArray(["自分泌", "生存信号"]), "自分泌 / 生存信号")
	check(CWHand.name_lines("抗体依赖细胞毒作用") == PackedStringArray(["抗体依赖", "细胞毒作用"]), "抗体依赖 / 细胞毒作用")
	check(CWHand.name_lines("一二三四五六七") == PackedStringArray(["一二三四", "五六七"]), "没登记的按前半折")
	var unregistered: Array[String] = []
	var bad: Array[String] = []
	for cname in CWCardData.CARDS:
		var lines := CWHand.name_lines(cname)
		for line in lines:
			if CWStyle.FONT.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, CWStyle.SIZE_LABEL).x \
					+ CWHand.NAME_PAD > CWHand.CARD.x:
				bad.append(cname)
		if lines.size() > 1 and not CWHand.NAME_BREAK.has(cname):
			unregistered.append(cname)
		if "".join(lines) != cname:
			bad.append(cname + "(漏字)")
	check(unregistered.is_empty(), "卡池里一行放不下的名字都登记了折行点（%s）" % str(unregistered))
	check(bad.is_empty(), "每一行都放得进 72px 卡宽、拼回去还是全名（%s）" % str(bad))
	var hand := CWHand.new()
	root.add_child(hand)
	hand.sync(2, Vector2.INF, PackedStringArray(["自分泌生存信号", "补体级联"]))
	await process_frame
	var long_card: Control = hand._cards[0]
	var short_card: Control = hand._cards[1]
	check((long_card.get_node("Name") as Label).text == "自分泌" and (long_card.get_node("Name2") as Label).text == "生存信号"
		and long_card.get_node("Name2").visible, "长名两行：Name / Name2")
	check(long_card.get_node("Name").position.y == CWHand.NAME_Y2[0]
		and long_card.get_node("Name2").position.y == CWHand.NAME_Y2[1], "两行顶边 2 / 13")
	var strip: float = CWView.screen_size().y - CWHand.REST_TOP
	check(CWHand.NAME_Y2[1] + CWStyle.FONT.get_ascent(CWStyle.SIZE_LABEL) <= strip,
		"第二行基线也落在静止露出的 %d px 里" % int(strip))
	check((short_card.get_node("Name") as Label).text == "补体级联" and not short_card.get_node("Name2").visible
		and short_card.get_node("Name").position.y == CWHand.NAME_Y, "短名单行、位置不变")
	hand.queue_free()


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
	## PRD 2026-09-01 把上限从「满了不让抽」改成「抽完弃回 8 张」，两条都翻面：
	check(_has_act(g.actions.build_options(cell), "draw"),
		"满 8 张照样能抽（超限改成抽完再弃）")
	## 骨髓：手牌满也照发，发完弃回上限（弃哪张由桥来答，基类答 0）
	var m: Vector2i = CWData.MARROWS[0]
	g.tiles[m]["cards"] = 1
	await g.actions.collect_special(cell, m)
	check(g.tiles[m]["cards"] == 0 and cell["hand"].size() == CWData.HAND_MAX,
		"手牌满时踩骨髓：照样拿卡，随后弃回 8 张")
	## 直接超发两张也要弃干净（while 而不是 if）
	cell["hand"].append("细胞膜修复")
	cell["hand"].append("细胞膜修复")
	await g.cards.discard_to_limit(cell)
	check(cell["hand"].size() == CWData.HAND_MAX, "超 2 张时连弃两次，弃到上限为止")
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
	check(CWCardData.cancer_phase(5) == 0 and CWCardData.cancer_phase(6) == 1 \
		and CWCardData.cancer_phase(10) == 1 and CWCardData.cancer_phase(11) == 2,
		"癌症卡分期切在第 6 / 11 回合（PRD：1—5 / 6—10 / 11—15）")

	## ---- 效果原文（2026-09-01 加，给手牌悬停详情用）----
	## 只钉「每张都有、且不是空壳」——正文内容由生成脚本从 PRD 逐字抄，
	## 在这里重写一遍断言就等于把 PRD 抄第三份了
	var missing: Array = []
	for n in CWCardData.CARDS:
		var e: String = CWCardData.CARDS[n].get("effect", "")
		if e.length() < 6:
			missing.append(n)
	check(missing.is_empty(), "66 张卡都带效果原文（缺：%s）" % str(missing))
	## 【代谢耦联】是唯一同时进两个卡池的卡，PRD 给了它按阵营镜像的两套措辞
	var mc_i := CWCardData.effect_of("代谢耦联", CWData.Faction.IMMUNE)
	var mc_c := CWCardData.effect_of("代谢耦联", CWData.Faction.CANCER)
	check(mc_i != mc_c and mc_i.contains("免疫细胞") and mc_c.contains("癌细胞"),
		"【代谢耦联】按阵营给不同措辞")
	var only_split := 0
	for n in CWCardData.CARDS:
		if CWCardData.CARDS[n].has("effect_cancer"):
			only_split += 1
	check(only_split == 1, "只有它一张需要分阵营（实为 %d 张）" % only_split)
	check(CWCardData.effect_of("不存在的卡", CWData.Faction.IMMUNE) == "",
		"问不认识的卡名返回空串，不崩")
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
	## I 级池的技能张数决定了 I 级手牌实际能有多少 —— 碰不到 8 的那个上限。
	## **2026-09-08 由 6 变成 7**：【局部吞噬】从事件卡改成了即时技能，从事件那半挪到了技能这半。
	## 这是那次改动的真实后果之一（不是测试写错），所以数字跟着走。
	cell["equipped"] = []
	var skills := 0
	for c in CWCardData.pool_of(CWData.Faction.IMMUNE, 0, 1):
		if CWCardData.CARDS[c["name"]]["kind"] != CWCardData.Kind.EVENT:
			skills += 1
	check(skills == 7, "I 级池有 %d 张技能 → I 级手牌上限实际是 7" % skills)
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
		texts.append((c.get_node("Name") as Label).text + (c.get_node("Name2") as Label).text)
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
			[CWData.CancerType.OSTEO, "ossify"]]:
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


## 「新手引导」入口的对手癌种（Kevin 2026-09-05 拍板）：首次钉死骨肉瘤直接开；引导全部看完后先弹一层挑对手。
## 「看完了吗」的判据可注入，不读也不写 user:// 里玩家真实的引导进度。
func t_tutorial_pick() -> void:
	print("[教程对手癌种]")
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
	var got: Array = []
	menu.tutorial_requested.connect(func(t: int) -> void: got.append(t))
	var guide_i := -1
	for i in menu.ITEMS.size():
		if menu.ITEMS[i]["node"] == "Guide":
			guide_i = i
	menu.guide_done_check = func() -> bool: return false
	menu._activate(guide_i)
	check(got == [CWData.CancerType.OSTEO] and (menu._confirm == null or not menu._confirm.visible),
		"没看完引导：直接开教程、对手钉死骨肉瘤、不弹选种")
	menu.guide_done_check = func() -> bool: return true
	menu._activate(guide_i)
	await process_frame
	check(got.size() == 1 and menu._confirm != null and menu._confirm.visible, "引导全看完：先弹对手癌种选择，不直接开")
	check(menu._confirm_title.text == menu.TUTORIAL_PICK_TITLE
		and menu._confirm_items.size() == CWData.CancerType.size()
		and menu._confirm_items[menu._confirm_sel] == CWData.CANCER_TYPE_NAMES[CWData.CancerType.OSTEO],
		"四种癌全列出、默认停在骨肉瘤（%s）" % str(menu._confirm_items))
	var down := InputEventAction.new()
	down.action = "ui_down"
	down.pressed = true
	var accept := InputEventAction.new()
	accept.action = "ui_accept"
	accept.pressed = true
	menu._confirm_input(down)
	menu._confirm_input(accept)
	check(got.size() == 2 and got[1] == CWData.CancerType.SCLC and not menu._confirm.visible,
		"往下一项回车：选中的癌种随信号发出、覆盖层收起")
	menu._activate(guide_i)
	var esc := InputEventAction.new()
	esc.action = "ui_cancel"
	esc.pressed = true
	menu._confirm_input(esc)
	check(got.size() == 2 and not menu._confirm.visible, "Esc = 不开教程，回主菜单")
	## 退出确认共用这块覆盖层，别被改坏：标题、两项、默认停在「取消」
	menu._activate(menu.ITEMS.size() - 1)
	check(menu._confirm.visible and menu._confirm_title.text == menu.CONFIRM_TITLE
		and menu._confirm_items == menu.CONFIRM_ITEMS and menu._confirm_sel == 1,
		"退出确认仍是「退出游戏？」两项、默认停在「取消」")
	menu._pick_confirm(1)
	check(not menu._confirm.visible, "退出确认的「取消」照旧收层")
	root.queue_free()


# ---- 卡牌效果（CWCardFx）：全场铺健康再手搭场景，别依赖开局癌区 ----
## 【基质硬化】选目标必须和 raise_solid 用同一把尺（团队 2026-09-05 报「用了没反应」）。
##
## **单独开一局**：这几条要往盘面上加细胞、改组织，塞进 t_card_instants 中间会把
## 后面「肿瘤细胞募集」随机选空癌性组织那条冲掉（本次真踩到了）。
func t_stroma_targets() -> void:
	print("[基质硬化选目标]")
	var g := _fx_game(2)
	var foot := Vector2i(4, 0)
	var st := CWSetup.make_cell(g.cells.size(), 0, CWData.Faction.CANCER,
		foot, -1, CWData.CancerType.MELANOMA)
	st["energy"] = 500
	st["hand"] = ["基质硬化"]
	g.cells.append(st)
	g.tiles[foot]["tissue"] = CWData.Tissue.CANCER
	var o1: Array = []
	g.card_fx.hand_options(st, o1)
	check(_has_target(o1, foot), "脚下的普通癌组织是合法目标（PRD：自身所在格或相邻1格癌组织）")

	g.tiles[foot]["tissue"] = CWData.Tissue.SOLID
	var o2: Array = []
	g.card_fx.hand_options(st, o2)
	check(not _has_target(o2, foot), "脚下已固化 → 不给选项（PRD 写的是「癌组织」）")

	g.tiles[foot]["tissue"] = CWData.Tissue.CANCER
	g.events["active"].append({ "name": "TNF-α局部炎症", "stacks": 1, "left": 1,
		"data": { foot: true } })
	check(g.solid_frozen(foot), "solid_frozen 认得出冻结格")
	var o3: Array = []
	g.card_fx.hand_options(st, o3)
	check(not _has_target(o3, foot), "脚下被冻住 → 不给选项（原来会白吃一张卡）")
	g.dispose()


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
	## 【急性炎症反应】2026-09-08 起给的是「等同于一次有氧呼吸」，不再是固定 1.5。
	## **期望值现读 `aerobic_income`**：写死一个数就等于把有氧那套算式抄了第二份，
	## 人数分档 / 免疫等级 / TGF-β / 坏死打折任何一处一动，这条就会指着旧数报错。
	var e_before: int = imm["energy"]
	var aero: int = g.world.aerobic_income(imm)
	await g.card_fx.resolve_event(imm, "急性炎症反应")
	check(aero > 0 and imm["energy"] == e_before + aero,
		"急性炎症反应：+%s 能量（= 该细胞一次有氧）" % CWData.fmt(aero))
	## 坏死格上的一次有氧是打折的，这张卡也该跟着打折 —— 卡面说的是「一次有氧呼吸」
	g.tile(imm["pos"])["necrosis"] = 2
	var cut: int = g.world.aerobic_income(imm)
	var e2: int = imm["energy"]
	await g.card_fx.resolve_event(imm, "急性炎症反应")
	check(cut < aero and imm["energy"] == e2 + cut,
		"站在坏死格上：给的也是打折后的 %s（原 %s）" % [CWData.fmt(cut), CWData.fmt(aero)])
	g.tile(imm["pos"])["necrosis"] = 0
	await g.card_fx.resolve_event(imm, "抗原摄取")
	check(g.memory == 1, "抗原摄取：不邻癌性组织 +1 记忆")
	g.tiles[Vector2i(1, 0)]["tissue"] = CWData.Tissue.CANCER
	await g.card_fx.resolve_event(imm, "抗原摄取")
	check(g.memory == 3, "抗原摄取：邻癌性组织改为 +2 记忆")
	await g.card_fx.resolve_event(imm, "抗原呈递增强")
	check(g.memory == 6, "抗原呈递增强：+3 记忆")
	## 【局部吞噬】2026-09-08 由事件卡改成**即时技能** —— 走「打出」，不再是抽到即生效。
	## 留在这一组里是因为效果本身没变，验的还是「转化唯一相邻癌组织并 +1 记忆」。
	imm["hand"] = ["局部吞噬"]
	await g.card_fx.play(imm, { "act": "play", "card": "局部吞噬" })
	check(g.tiles[Vector2i(1, 0)]["tissue"] == CWData.Tissue.HEALTHY and g.memory == 7,
		"局部吞噬：转化唯一相邻癌组织并 +1 记忆")
	check(imm["hand"].is_empty(), "打出后从手牌消失")
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
	## 全身性免疫清除：12 个孤立候选，随机清 SYSTEMIC_CLEAR 格（PRD 2026-09-09 由 10 改 5）
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
	check(left == spots.size() - CWData.SYSTEMIC_CLEAR,
		"全身性免疫清除：%d 个候选随机清掉 %d 个" % [spots.size(), CWData.SYSTEMIC_CLEAR])
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
	g.round_no = 8
	await g.card_fx.resolve_event(a, "肿瘤血管生成")
	check(a["energy"] == 25 and b["energy"] == 20, "肿瘤血管生成：中期全体 +2.0、抽卡者 +2.5（第 8 回合 = 中期）")
	g.round_no = 1
	await g.card_fx.resolve_event(a, "克隆增殖")
	var newborns := 0
	for n in CWData.neighbors(Vector2i(0, 0)):
		if g.tiles[n]["tissue"] == CWData.Tissue.CANCER:
			newborns += 1
	check(newborns == 1, "克隆增殖：前期恰好转化 1 格")
	## 糖酵解爆发：块里 3 格普通癌 + 全图 1 格固化 / 1 细胞，口径与 E 阶段一致（2026-09-07 新式）
	for c in g.tiles.keys():
		g.tiles[c]["tissue"] = CWData.Tissue.HEALTHY
	for c in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)]:
		g.tiles[c]["tissue"] = CWData.Tissue.CANCER
	g.tiles[Vector2i(3, 0)]["tissue"] = CWData.Tissue.SOLID
	a["energy"] = 0
	await g.card_fx.resolve_event(a, "糖酵解爆发")
	check(a["energy"] == _share(_pool_of(3, 1), 1),   ## 这局是 _fx_game()：2 人
		"糖酵解爆发：立刻结算一次无氧呼吸（3 普通癌 + 1 固化独占 = %s）" % CWData.fmt(_share(_pool_of(3, 1), 1)))
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
	func show_result(text: String, _at: Vector2i, _linger := false) -> void:
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

	## ⑥ 基因组不稳定：免费突变不计次数；两掷二选一（2026-09-07 删掉「第 20 世界回合起」）
	pack = _choice_game()
	g = pack[0]
	b = pack[1]
	var mut := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(3, 3), -1, CWData.CancerType.MELANOMA)
	mut["energy"] = 30
	g.cells.append(mut)
	g.round_no = 5
	_rig_roll(g, 3, [1, 2])   ## 两掷不同 → 触发二选一
	b.answers = [_pick_by("r", 1)]   ## 挑「无事发生」
	var h0: int = mut["hand"].size()
	await g.card_fx.resolve_event(mut, "基因组不稳定")
	check(not mut["mutate_used"] and mut["energy"] == 30,
		"基因组不稳定：免费（不扣 0.5）也不占每回合的突变次数")
	check(b.asked.size() == 1 and b.asked[0]["kind"] == "pick"
		and b.asked[0]["options"].size() == 2, "第 5 回合也两掷二选一（不再挂第 20 回合）")
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
	## 2026-09-07 起**卡牌引发的净化不积累抗原记忆**（Kevin）：格子照净化，记忆不涨
	check(chx["pos"] == Vector2i(1, 0) and g.tiles[Vector2i(1, 0)]["tissue"] == CWData.Tissue.HEALTHY
		and g.memory == cm0, "第一步进癌组织触发净化（打出的卡引发：不给抗原记忆）")
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

	## ⑧-补 代谢耦联：选项生成之后、结算之前双方都变得付不起 → 落空，不许越界
	## 真实触发路径：选项按**扣费前**能量算，而这张卡自己要花 0.2~0.3。
	## 下面按那个顺序复现：先在 1.1 能量下拿选项，再扣成 0.9 才结算。
	pack = _choice_game()
	g = pack[0]
	var pr1 := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.BASIC, -1)
	pr1["energy"] = 11
	pr1["hand"] = ["代谢耦联"]
	g.cells.append(pr1)
	var pr2 := CWSetup.make_cell(1, 1, CWData.Faction.IMMUNE, Vector2i(0, 3), CWData.ImmuneType.BASIC, -1)
	pr2["energy"] = 9
	g.cells.append(pr2)
	kopts = []
	g.card_fx.hand_options(pr1, kopts)
	check(kopts.size() == 1, "代谢耦联：扣费前 1.1 能量还能生成选项")
	pr1["energy"] = 9          ## 打出这张卡自己花掉 0.2，两边就都付不起最低档了
	var pn0 := g.logs.size()
	await g.card_fx.play(pr1, kopts[0]["data"])
	check(pr1["energy"] == 9 and pr2["energy"] == 9, "双方都付不起 → 能量一分不动")
	check(g.logs.size() > pn0 and g.logs[-1].contains("落空"), "落空要留一行日志")
	## 反过来也确认一遍：真的两边都付不起时，选项压根不该出现
	pr2["energy"] = 9
	kopts = []
	g.card_fx.hand_options(pr1, kopts)
	check(kopts.is_empty(), "代谢耦联：双方都付不起时选项不出现")
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
	check(g.count_necrosis() == CWData.RADIO_REGION,
		"放疗：恰好 %d 格进入坏死（PRD 2026-09-09 由 15 改 10）" % CWData.RADIO_REGION)
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
	## ② 组织驻留：每行动回合**前两次**向健康组织迁移免费（PRD 2026-09-01，此前是一次）
	var base_h: int = g.tune.immune_move_healthy[0]
	check(g.actions._move_cost_mod(imm, Vector2i(0, 1), base_h) == 0, "组织驻留：首次向健康组织迁移标价 0")
	await g.actions._do_move(imm, Vector2i(0, 1), 0)
	check(imm["energy"] == 100, "免费移动没扣钱")
	check(g.actions._move_cost_mod(imm, Vector2i(0, 2), base_h) == 0, "第二次仍是标价 0")
	await g.actions._do_move(imm, Vector2i(0, 2), 0)
	check(imm["energy"] == 100, "第二次也没扣钱")
	check(g.actions._move_cost_mod(imm, Vector2i(0, 3), base_h) == base_h, "本回合第三次恢复原价")
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
	## 目的地必须是**相邻格**：这里原先写的 (2,2) 相对 (1,1) 并不相邻，
	## 旧代码照走，2026-08-31 补上的合法性复验把它拦下来了（谓词生效的旁证）
	check(g.actions._move_cost_mod(imm, Vector2i(2, 1), base_h) == 0, "组织巡航：首移免费")
	await g.actions._do_move(imm, Vector2i(2, 1), 0)
	check(g.actions._move_cost_mod(imm, Vector2i(2, 2), base_h)
		== maxi(base_h - CWData.CRUISE_CUT, CWData.MOVE_CUT_MIN), "此后每次迁移 −0.2")
	g.dispose()

	## ⑤ 代谢适应 / 自分泌生存信号：有氧额外 +0.5/+0.8；GLUT1：无氧额外（分期）
	g = _fx_game(4)
	var ae := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.BASIC, -1)
	ae["energy"] = 0
	ae["equipped"] = ["代谢适应", "自分泌生存信号"]
	g.cells.append(ae)
	g.world.aerobic()
	check(ae["energy"] == CWData.AEROBIC_LEVEL_BASE + CWData.AEROBIC_ADAPT + CWData.AEROBIC_AUTOCRINE,
		"有氧 %s（I 级）+ 代谢适应 0.5 + 自分泌 0.8" % CWData.fmt(CWData.AEROBIC_LEVEL_BASE))
	var gl := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(5, 0), -1, CWData.CancerType.MELANOMA)
	gl["energy"] = 0
	gl["equipped"] = ["GLUT1高表达"]
	g.cells.append(gl)
	g.tiles[Vector2i(5, 0)]["tissue"] = CWData.Tissue.CANCER
	g.round_no = 8   ## 中期（PRD 分期 2026-09-07 改成 1—5 / 6—10 / 11—15）
	check(g.world.anaerobic_gain_for(gl) == _share(_pool_of(1, 0, 4), 1) + CWData.GLUT1_BONUS[1],
		"GLUT1：单格块无氧 %s + 中期 0.8（糖酵解爆发同口径）" % CWData.fmt(_share(_pool_of(1, 0, 4), 1)))
	g.world._anaerobic()
	check(gl["energy"] == _share(_pool_of(1, 0, 4), 1) + CWData.GLUT1_BONUS[1], "E 阶段无氧同样加成")
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
	g.round_no = 3   ## 增生只在世界事件回合结算（PRD 2026-09-01）
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
	## 四癌两健康 = 压迫 0.5（1/4 × 2）。三癌三健康在加权式下正好抵平成 0、场景会空转，所以补到四癌
	for n in [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 1), Vector2i(-1, 0)]:
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

	## ⑫ 抗体亲和力成熟：抗体费**降低** 0.5 / 初始伤害 2.0；攻击邻健康的目标**每次** +0.5
	## （2026-09-07 卡面三处都改了：降为→降低、1.5→2、删掉「每个行动回合第一次」）
	g = _fx_game(4)
	var bm := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.B_CELL, -1)
	bm["energy"] = 100
	bm["equipped"] = ["抗体亲和力成熟"]
	g.cells.append(bm)
	var bt := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(1, 0), -1, CWData.CancerType.MELANOMA)
	bt["energy"] = 500
	g.cells.append(bt)
	var bm_fee: int = CWData.ANTIBODY_COST - CWData.MATURED_ANTIBODY_CUT
	check(g.actions.antibody_cost(bm) == bm_fee, "抗体费降低 0.5")
	await g.actions._do_antibody(bm)
	check(bm["energy"] == 100 - bm_fee
		and bt["energy"] == 500 - CWData.MATURED_ANTIBODY_DMG, "抗体初始伤害 2.0")
	var bt0: int = bt["energy"]
	_rig_roll(g, 6, [3])
	await g.actions._do_move(bm, Vector2i(1, 0), 0)
	check(bt["energy"] == bt0 - g.tune.attack_dmg_success - CWData.MATURED_ATTACK_EXTRA,
		"攻击邻健康的癌细胞 +0.5")
	bt0 = bt["energy"]
	_rig_roll(g, 6, [3])
	await g.actions._do_move(bm, Vector2i(1, 0), 0)
	check(bt["energy"] == bt0 - g.tune.attack_dmg_success - CWData.MATURED_ATTACK_EXTRA,
		"同一行动回合第二次攻击照样 +0.5（2026-09-07 取消「首次」闸门）")
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
	## 设计 §七.2：commit 按当前状态重新报价，调用方传的旧价钱不作数 ——
	## 所以这里要把真实迁移费算进期望值，不能再假设「传 0 就免费」
	var ph_fee: int = g.actions._move_cost_mod(ph, Vector2i(1, 0),
		g.actions._move_base_cost(ph, Vector2i(1, 0)))
	_rig_roll(g, 6, [3])
	await g.actions._do_move(ph, Vector2i(1, 0), 0)
	check(not pv["alive"], "吞噬体成熟：目标剩 1.2 ≤ 1.5，直接死亡")
	check(ph["energy"] == ph0 - ph_fee + 10 + CWData.SKILL_HEAL,
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
	var f1: int = g.actions._move_cost_mod(ra, Vector2i(1, 0),
		g.actions._move_base_cost(ra, Vector2i(1, 0)))
	await g.actions._do_move(ra, Vector2i(1, 0), 0)
	check(ra["energy"] == 100 - f1 + CWData.RAS_HEAL[0], "首次定殖 +0.3（前期）")
	var e1: int = ra["energy"]
	var f2: int = g.actions._move_cost_mod(ra, Vector2i(2, 0),
		g.actions._move_base_cost(ra, Vector2i(2, 0)))
	await g.actions._do_move(ra, Vector2i(2, 0), 0)
	check(ra["energy"] == e1 - f2, "同回合第二次定殖不再触发")
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
		"干性复活：能量 2.0 → 3.0（前期；2026-09-07 由 2.5 提到 3）")
	g.tiles[Vector2i(4, 0)]["tissue"] = CWData.Tissue.CANCER
	check(g.actions._move_cost_mod(sc, Vector2i(4, 0), CWData.CANCER_MOVE_CANCEROUS) == 0,
		"本世界回合向癌性组织移动免费")
	await g.actions._do_move(sc, Vector2i(4, 0), 0)
	g.tiles[Vector2i(5, 0)]["tissue"] = CWData.Tissue.CANCER
	## 2026-09-07 卡面：免费额度从「1 次（20 回合起 2 次）」统一成**前两次**
	check(g.actions._move_cost_mod(sc, Vector2i(5, 0), CWData.CANCER_MOVE_CANCEROUS) == 0,
		"第二次向癌性组织移动也免费")
	await g.actions._do_move(sc, Vector2i(5, 0), 0)
	g.tiles[Vector2i(6, 0)]["tissue"] = CWData.Tissue.CANCER
	check(g.actions._move_cost_mod(sc, Vector2i(6, 0), CWData.CANCER_MOVE_CANCEROUS)
		== CWData.CANCER_MOVE_CANCEROUS, "两次额度用完，第三次恢复原价")
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
		## 2026-08-30 起按队友《费用结算系统设计》走**语义阶段**：
		## 基础值替换（阶段③）恒在固定减费（阶段⑤）之前，所以打出顺序不再影响结果。
		## 旧口径 #73（按打出先后逐张结算）下这两种顺序会算出 0.2 / 0.5 两个数。
		check(got == CWData.MOVE_CUT_MIN,
			"语义阶段：无论先打哪张，都是「改为 0.5」再 −0.5 → 下限 0.2（%s 先）" % order[0])
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

	## ①d 世界事件排在所有卡牌之后：【基质阻隔】翻倍作用在卡牌算完的价上。
	## 2026-09-06 起它只翻癌细胞（Kevin），顺序拿癌方的【上皮—间质转化】来钉；免疫那边顺手钉「不再翻倍」
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
		== CWData.INFLAM_CHEMO_COST,
		"基质阻隔不翻免疫：炎症趋化的 0.5 原样（2026-09-06 起仅癌细胞）")
	var emt := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(-2, 0), -1, CWData.CancerType.MELANOMA)
	emt["energy"] = 100
	g.cells.append(emt)
	g.round_no = 1
	emt["hand"] = ["上皮—间质转化"]
	await g.card_fx.play(emt, { "act": "play", "card": "上皮—间质转化" })
	check(g.actions._move_cost_mod(emt, Vector2i(-3, 0), CWData.CANCER_MOVE_HEALTHY)
		== CWData.EMT_MOVE_COST * 2,
		"基质阻隔在最后翻倍：EMT 改成 0.2 → 0.4（不是先翻倍再被覆盖成 0.2）")
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

	## ②b 上皮—间质转化 × 黑色素瘤【伪足穿透】：2026-08-31 抬价后**新出现**的组合。
	## 抬价前基准价就是 0.2、EMT 的「改为 0.2」是空操作（见 定案D范围确认 顺手带上④）；
	## 现在基准 0.5 > EMT 的 0.2，这张卡对黑色素瘤第一次真的有用。
	## 第一条断言钉的是**这个组合存在的前提** —— 谁把伪足穿透改回 0.2，这里会先红。
	check(CWData.PSEUDOPOD_COST > CWData.EMT_MOVE_COST,
		"伪足穿透(%s) 比 EMT 的改写值(%s) 贵，EMT 才有意义" % [
			CWData.fmt(CWData.PSEUDOPOD_COST), CWData.fmt(CWData.EMT_MOVE_COST)])
	g = _fx_game(4)
	## 让 (1,0) 邻接三格癌组织，把【伪足穿透】的条件凑齐（门槛 2026-09-06 Kevin 由 2 改 3：两格不够）
	g.tiles[Vector2i(1, -1)]["tissue"] = CWData.Tissue.CANCER
	g.tiles[Vector2i(0, 1)]["tissue"] = CWData.Tissue.CANCER
	var mel := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(0, 0), -1, CWData.CancerType.MELANOMA)
	mel["energy"] = 100
	g.cells.append(mel)
	g.round_no = 1
	check(CWData.PSEUDOPOD_MIN_ADJ == 3 and g.actions._cancer_move_cost(mel, Vector2i(1, 0)) == CWData.CANCER_MOVE_HEALTHY,
		"只邻接 2 格癌性组织 → 不触发【伪足穿透】，照付健康格全价")
	g.tiles[Vector2i(1, 1)]["tissue"] = CWData.Tissue.CANCER
	var base_cost: int = g.actions._cancer_move_cost(mel, Vector2i(1, 0))
	check(base_cost == CWData.PSEUDOPOD_COST, "邻接 3 格 → 黑色素瘤基准价走【伪足穿透】")
	mel["hand"] = ["上皮—间质转化"]
	await g.card_fx.play(mel, { "act": "play", "card": "上皮—间质转化" })
	check(g.actions._move_cost_mod(mel, Vector2i(1, 0), base_cost) == CWData.EMT_MOVE_COST,
		"EMT 把伪足穿透的 %s 改写为 %s（抬价前这一步是空操作）" % [
			CWData.fmt(CWData.PSEUDOPOD_COST), CWData.fmt(CWData.EMT_MOVE_COST)])
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
	g.world_fx.tick_durations()
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
	## 四癌两健康 = 压迫 0.5（1/4 × 2；加权式下三癌三健康正好是 0）
	for n in [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 1), Vector2i(-1, 0)]:
		g.tiles[n]["tissue"] = CWData.Tissue.CANCER
	hyp2["hand"] = ["缺氧适应"]
	await g.card_fx.play(hyp2, { "act": "play", "card": "缺氧适应" })
	g.world_fx.tick_durations()
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
	## 两层同时在场：一次攻击**只吃一层**，而且是**最早打出**的那层（团队 2026-09-01 裁定）。
	## 刻意不走定案 #57 的「同名一次全算」—— 那样两张会被同一次攻击一起吃掉，
	## 判定掉到「失败」之后再降没有意义，第二张等于白扔。
	pd["hand"] = ["PD-L1表达", "PD-L1表达"]
	await g.card_fx.play(pd, { "act": "play", "card": "PD-L1表达" })
	await g.card_fx.play(pd, { "act": "play", "card": "PD-L1表达" })
	var two: Array = g.mods_of(pd, "PD-L1表达")
	check(two.size() == 2, "两层同时在场（同名【即时技能】手牌只留 1 张，但可以先打一张再抽一张）")
	var early: int = mini(int(two[0]["seq"]), int(two[1]["seq"]))
	var late: int = maxi(int(two[0]["seq"]), int(two[1]["seq"]))
	pd_e = pd["energy"]
	_rig_roll(g, 6, [4])
	pk["pos"] = Vector2i(0, 0)
	pk["attacks_used"] = 0        ## 这段一路打了好几次，别撞上每回合 3 次的上限
	await g.actions._do_move(pk, Vector2i(1, 0), 0)
	var rest: Array = g.mods_of(pd, "PD-L1表达")
	check(rest.size() == 1, "一次攻击只消耗一层，剩一层")
	check(int(rest[0]["seq"]) == late, "消耗的是**较早**打出的那层，晚的留下")
	check(pd["energy"] == pd_e, "这一次只压一级：成功 → 失败，没伤害")
	## 判定本来就已经是失败时，**照样消耗**（团队明确要，不加减伤那套 ON_BENEFIT）
	_rig_roll(g, 6, [1])
	pk["pos"] = Vector2i(0, 0)
	pk["attacks_used"] = 0
	await g.actions._do_move(pk, Vector2i(1, 0), 0)
	check(g.mods_of(pd, "PD-L1表达").is_empty(), "判定已是失败也照样消耗最后一层")
	check(int(early) < int(late), "seq 确实记录了打出先后（前提成立）")
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
	g.world_fx.tick_durations()
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
	g.world_fx.tick_durations()
	g.world._decay()
	check(g.tiles[Vector2i(3, 0)]["solid"] == 5, "事件到期后衰减恢复")
	var iw := CWSetup.make_cell(1, 1, CWData.Faction.IMMUNE, Vector2i(-5, 0), CWData.ImmuneType.BASIC, -1)
	iw["energy"] = 0
	g.cells.append(iw)
	await g.card_fx.resolve_event(dr, "TGF-β释放")
	await g.card_fx.resolve_event(dr, "TGF-β释放")
	g.world.aerobic()
	## 基准 = I 级有氧；两份 −20% 逐份向下取整（整数除法）。按常量算，基数改了这里不用跟
	var tgf_want: int = CWData.AEROBIC_LEVEL_BASE * 8 / 10 * 8 / 10
	check(iw["energy"] == tgf_want, "TGF-β 两份叠加：%s → 逐份 ×80%% 向下取整 = %s" % [
		CWData.fmt(CWData.AEROBIC_LEVEL_BASE), CWData.fmt(tgf_want)])
	check(g.event_stacks("TGF-β释放") == 0, "结算一次即整体消耗")
	iw["energy"] = 0
	g.world.aerobic()
	check(iw["energy"] == CWData.AEROBIC_LEVEL_BASE, "下一次有氧恢复原额")
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
	## 事件池大小跟着 CWWorldFx.EVENTS 走，别写死数字对不上：
	## 17（09-07 删【固化加速】）→ 16（09-08 删【免疫抑制因子】）→ **15**（09-08 云端版删【抗原丢失】）
	check(g.events["pool"].size() == CWWorldFx.EVENTS.size()
		and g.events["pool"].size() == 15, "开局事件池 15 个 = EVENTS 表的长度")
	for i in 7:
		await g.world_fx.trigger()
	check(g.events["pool"].size() == CWWorldFx.EVENTS.size() - 7,
		"7 次触发后事件池少 7 个（同局不重复，定案 #42）")
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
	_install(g, "抗原引导", 1, 2)
	check(g.actions.attack_outcome(1) == "success" and g.actions.attack_outcome(2) == "success",
		"抗原引导：失败概率并给成功（定案 W3）")
	check(g.actions.attack_outcome(6) == "crit", "抗原引导：大成功不受影响")
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
	## 【抗原引导】保证判定必然非失败 —— 后面那几条都靠它把随机性摘掉。
	## （这里原本还验【抗原丢失】让攻击不掉能量，那个事件 2026-09-08 随 PRD 删了。）
	_install(g, "抗原引导", 1, 2)
	var e0: int = can["energy"]
	await g.actions._do_move(imm, Vector2i(1, 0), 0)
	check(can["energy"] < e0, "抗原引导下攻击必然造成能量损失")
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
	## 基质阻隔：**只翻癌细胞**（Kevin 2026-09-06；此前免疫也翻）—— 免疫移动原价，癌细胞移动与技能移动翻倍
	_install(g, "基质阻隔", 1, 2)
	var opts: Array = []
	g.actions._immune_options(imm, opts)
	check(_find_act(opts, "move")["data"]["cost"] == g.tune.immune_move_healthy[0],
		"基质阻隔：免疫移动费不翻倍（2026-09-06 起仅癌细胞）")
	var blk := CWSetup.make_cell(g.cells.size(), 1, CWData.Faction.CANCER, Vector2i(3, 0), -1,
		CWData.CancerType.MELANOMA)
	blk["energy"] = 100
	g.cells.append(blk)
	opts = []
	g.actions._cancer_options(blk, opts)
	var blk_mv := {}
	for o in opts:
		if o["data"].get("act", "") == "move" and o["data"]["to"] == Vector2i(2, 0):
			blk_mv = o
	check(blk_mv["data"]["cost"] == CWData.CANCER_MOVE_HEALTHY * 2, "基质阻隔：癌细胞移动费翻倍")
	check(g.actions.skill_move_cost(blk, g.tune.metastasis_cost) == g.tune.metastasis_cost * 2,
		"基质阻隔：癌细胞技能移动（【转移】那类）也翻倍")
	g.cells.erase(blk)
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


func t_solidify_threshold() -> void:
	print("[固化·门槛]")
	var g := _fx_game(2)
	## 世界事件【固化加速】2026-09-07 随 PRD 删除（阈值降到 2.0 后它与常规固化同义）。
	## 这里留下的是它当年真正在守的那半条：raise_solid 只认阈值，涨过就转、没涨过就不转。
	var pos := Vector2i(2, 2)
	g.tiles[pos]["tissue"] = CWData.Tissue.CANCER
	g.tiles[pos]["solid"] = 15
	g.raise_solid(pos, 4)
	check(g.tiles[pos]["tissue"] == CWData.Tissue.CANCER, "没涨到阈值不转化（1.5 + 0.4）")
	g.raise_solid(pos, 5)
	check(g.tiles[pos]["tissue"] == CWData.Tissue.SOLID, "涨过阈值即转固化（1.9 + 0.5）")


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
	g.dispose()

	## E 阶段的步骤顺序（口径 #86）：第 7 步「其他 E 类效果」（＝紊乱返回）
	## 必须排在第 9 步「移除新生」**之前**。
	## 判据用一条**不变量**：跑完整个 e_phase()，盘面上不该剩下任何「新生」标记。
	## 改回旧顺序（round_end 排在 _clear_newborn 之后）时这条会红 ——
	## 紊乱返回触发【定殖】造出的癌组织会带着「新生」跨到下个世界回合，下回合也固化不了。
	g = _fx_game(2)
	var c2 := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(0, 6), -1, CWData.CancerType.MELANOMA)
	c2["energy"] = 50
	g.cells.append(c2)
	g.tiles[Vector2i(0, 6)]["tissue"] = CWData.Tissue.CANCER
	g.tiles[Vector2i(0, 5)]["tissue"] = CWData.Tissue.CANCER
	var e2 := _install(g, "紊乱")
	await g.world_fx._chaos(e2)
	check(c2["pos"] == Vector2i(0, 5), "紊乱：癌细胞已传走")
	## 把原位改回健康组织，这样返回时会触发【定殖】造出一格**新生**癌组织
	g.tiles[Vector2i(0, 6)]["tissue"] = CWData.Tissue.HEALTHY
	g.tiles[Vector2i(0, 6)]["newborn"] = false
	await g.world.e_phase()
	check(g.tiles[Vector2i(0, 6)]["tissue"] == CWData.Tissue.CANCER,
		"紊乱返回触发【定殖】，原位转回癌组织")
	var leftover := 0
	for c in g.tiles.keys():
		if g.tiles[c]["newborn"]:
			leftover += 1
	check(leftover == 0, "E 阶段跑完不留「新生」标记（第 7 步排在第 9 步之前）")


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
	g.round_no = 3   ## 不设成世界事件回合的话，下面的 0 转化是被回合门挡掉的，测不出【增殖抑制】
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
	g2.round_no = 3
	g2.tiles[Vector2i(0, 0)]["tissue"] = CWData.Tissue.CANCER
	_install(g2, "异常增殖", 1, 2)
	g2.world._proliferate()
	var all6 := true
	for c in CWData.neighbors(Vector2i(0, 0)):
		if g2.tiles[c]["tissue"] != CWData.Tissue.CANCER:
			all6 = false
	check(all6, "异常增殖：增生概率翻倍（单邻 50% → 100% 必中）")
	## 【增生】**每个世界回合都结算**（2026-09-01 撤回了短命的「只在世界事件回合」，
	## 改成把单格概率从 4% 降到 3%）。非事件回合照样要增生，这一条正着反着都钉。
	check(CWData.PROLIFERATE_PER_ADJ == 30, "每相邻癌性组织 3%（千分率 30）")
	var g3 := _fx_game(2)
	g3.tune.proliferate_per_adjacent = 1000   ## 必中，隔离概率因素
	g3.tiles[Vector2i(0, 0)]["tissue"] = CWData.Tissue.CANCER
	g3.round_no = 1                            ## 不是世界事件回合
	g3.world._proliferate()
	var grew := 0
	for c in CWData.neighbors(Vector2i(0, 0)):
		if g3.tiles[c]["tissue"] == CWData.Tissue.CANCER:
			grew += 1
	check(grew == 6, "非世界事件回合（第 1 回合）照常增生")
	g3.dispose()


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
	g.events["pool"] = ["抗原引导"]
	await g.world_fx.trigger()
	check(g.event_stacks("抗原引导") == 1 and g.events["active"][0]["left"] == 4,
		"开关类持续事件：一份强度接力 4 回合（定案 #49 修订版）")
	check(not g.events["double_next"], "双重触发：标记已消耗")


func t_ev_lifecycle() -> void:
	print("[世界事件·生命周期]")
	var g := _fx_game(2)
	## 样本：一个持续事件 + 一个「本回合」类事件。后者原来用【抗原丢失】，
	## 它 2026-09-08 随 PRD 删了，换成同为「本回合」类的【营养缺乏】
	_install(g, "抗原引导", 1, 2)
	_install(g, "营养缺乏", 1, 1)
	g.world_fx.tick_durations()
	check(g.event_stacks("抗原引导") == 1 and g.event_stacks("营养缺乏") == 0,
		"回合末：本回合事件到期，持续事件余 1 回合")
	g.world_fx.tick_durations()
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
	g.world_fx.tick_durations()
	check(g.event_stacks("增殖抑制") == 1, "回合末仍在场（余 1 回合）")
	await g.world_fx.on_round_start()
	check(imm["energy"] == 90, "第二回合开头完整重演（再 −0.5）")
	g.world_fx.tick_durations()
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

## 手牌悬停详情（团队 2026-09-01 要的第三条）。只测纯函数：
## 折行、按阵营换措辞、摆位不越界。真渲染那部分靠 screenshot.gd 用眼睛看。
func t_card_info() -> void:
	print("[手牌悬停详情]")
	var max_w := CWCardInfo.W - CWCardInfo.PAD_H * 2.0
	## PRD 自己的换行要保住：列表项各占一行，不能被并进上一行
	var pd := CWCardInfo.wrap_text(
		CWCardData.effect_of("PD-L1表达", CWData.Faction.CANCER), max_w)
	check(pd.size() >= 4, "【PD-L1表达】折成 %d 行（含三个列表项）" % pd.size())
	var bullets := 0
	for l in pd:
		if l.begins_with("·"):
			bullets += 1
	check(bullets == 3, "三个列表项各占一行（实为 %d）" % bullets)
	## 每一行都得放得进框
	var toolong: Array = []
	for n in CWCardData.CARDS:
		for f in [CWData.Faction.IMMUNE, CWData.Faction.CANCER]:
			for l in CWCardInfo.wrap_text(CWCardData.effect_of(n, f), max_w):
				if CWStyle.FONT.get_string_size(l, HORIZONTAL_ALIGNMENT_LEFT, -1,
						CWStyle.SIZE_LABEL).x > max_w:
					toolong.append("%s：%s" % [n, l])
	check(toolong.is_empty(), "66 张卡折行后没有一行超宽（超的：%s）" % str(toolong.slice(0, 3)))
	## 标点不该跑到行首（贪心折行最容易犯的毛病）
	var badstart: Array = []
	for n in CWCardData.CARDS:
		var ls := CWCardInfo.wrap_text(CWCardData.effect_of(n, CWData.Faction.IMMUNE), max_w)
		for i in range(1, ls.size()):
			if ls[i] != "" and CWCardInfo.NO_LINE_START.contains(ls[i][0]) 					and not ls[i].begins_with("·"):
				badstart.append("%s：%s" % [n, ls[i]])
	check(badstart.is_empty(), "没有行以标点开头（犯规的：%s）" % str(badstart.slice(0, 3)))
	## 按阵营换措辞只影响【代谢耦联】
	var d_i := CWCardInfo.describe("代谢耦联", CWData.Faction.IMMUNE)
	var d_c := CWCardInfo.describe("代谢耦联", CWData.Faction.CANCER)
	check(d_i["lines"] != d_c["lines"] and d_i["name"] == "代谢耦联",
		"【代谢耦联】详情按阵营给不同正文")
	check(d_i["kind"] == "【即时】", "类别取自卡池数据（%s）" % d_i["kind"])
	## 不认识的卡名不能崩（手牌里塞了还没实现的卡时会走到）
	var d_x := CWCardInfo.describe("不存在的卡", CWData.Faction.IMMUNE)
	check(d_x["lines"].is_empty() and d_x["kind"] == "", "不认识的卡名给空详情，不崩")
	## 摆位：框底压在抬起后的卡顶（428）上方，且不越出画布上沿
	var screen := Vector2(960, 540)
	var lo := CWCardInfo.place(Vector2(CWCardInfo.W, 100), screen)
	check(lo.x == CWHand.LEFT and lo.y + 100 <= CWHand.REST_TOP - CWHand.LIFT,
		"矮框贴着卡顶往上长（y=%.0f）" % lo.y)
	var hi := CWCardInfo.place(Vector2(CWCardInfo.W, 900), screen)
	check(hi.y >= 8.0, "正文特别长时顶到画布上沿也不跑出去（y=%.0f）" % hi.y)



## 卡面分档写法「a / b / c」里当前生效的那一档高亮（Kevin 2026-09-06）；自由选择类（【代谢耦联】）不高亮。
## 找档是纯函数（describe / tier_marks），画法查子节点：那一档单独一个亮字标签 + 底下一块色板，x = 前文实测宽。
func t_tier_highlight() -> void:
	print("[卡面分档高亮]")
	var CAN := CWData.Faction.CANCER
	var d1 := CWCardInfo.describe("GLUT1高表达", CAN, 1)
	check(_marked(d1) == ["0.8"], "中期：GLUT1 高亮 0.8（%s）" % str(_marked(d1)))
	check(_marked(CWCardInfo.describe("GLUT1高表达", CAN, 0)) == ["0.5"], "前期：0.5")
	check(_marked(CWCardInfo.describe("GLUT1高表达", CAN, 2)) == ["1"], "后期：1（后面的「能量」不带上）")
	check(_marked(CWCardInfo.describe("GLUT1高表达", CAN)) == [], "不给分期 → 不高亮")
	check(_marked(CWCardInfo.describe("基质硬化", CAN, 0)) == ["+1"], "正号连着一起高亮")
	check(_marked(CWCardInfo.describe("肿瘤血管生成", CAN, 2)) == ["2.5"], "两边带空格的写法、小数档")
	check(_marked(CWCardInfo.describe("肿瘤细胞募集", CAN, 2)) == ["2"], "第三档")
	check(_marked(CWCardInfo.describe("代谢耦联", CAN, 1)) == []
		and _marked(CWCardInfo.describe("代谢耦联", CWData.Faction.IMMUNE, 1)) == [],
		"【代谢耦联】那三档是玩家自己挑的，不高亮")
	check(_marked(CWCardInfo.describe("免疫突触成熟", CWData.Faction.IMMUNE, 1)) == [], "「1/6 概率」这种分数不是分档")
	check(_marked(CWCardInfo.describe("CXCR3趋化", CWData.Faction.IMMUNE, 1)) == [], "没有分档写法的卡不高亮")
	check(d1["accent"] == CWStyle.CANCER
		and CWCardInfo.describe("CXCR3趋化", CWData.Faction.IMMUNE, 1)["accent"] == CWStyle.IMMUNE,
		"色板按卡属于哪一方")
	## 全覆盖：带「a / b / c」的卡（除自由选择）三期各恰好高亮到一档，高亮的正是拆开后的第 n 个
	var n_cards := 0
	var wrong: Array = []
	for name in CWCardData.CARDS:
		var eff: String = CWCardData.effect_of(name, CAN)
		if not eff.contains(" / ") or name in CWCardInfo.FREE_CHOICE:
			continue
		n_cards += 1
		var group: String = ""
		var re := RegEx.new()
		re.compile("[+\\-]?\\d+(?:\\.\\d+)?(?: / [+\\-]?\\d+(?:\\.\\d+)?)+")
		var m := re.search(eff)
		group = m.get_string() if m != null else ""
		var parts: PackedStringArray = group.split(" / ")
		for ph in 3:
			var got := _marked(CWCardInfo.describe(name, CAN, ph))
			if got != [parts[mini(ph, parts.size() - 1)]]:
				wrong.append("%s@%d=%s" % [name, ph, str(got)])
	## 66 张里带「a / b / c」的是 12 张（【免疫突触成熟】的「1/6 概率」没有空格，不算），去掉自由选择的【代谢耦联】剩 11
	check(n_cards == 11 and wrong.is_empty(), "11 张分档卡三期各高亮到正确的一档（%d 张；错的：%s）" % [n_cards, str(wrong)])
	## 折行把一组拆到两行：两行各标各的那一段
	var m2 := CWCardInfo.tier_marks("x 1 / 1.5 / 2 y", PackedStringArray(["x 1 / 1", ".5 / 2 y"]), 1)
	check(m2[0] == [Vector2i(6, 1)] and m2[1] == [Vector2i(0, 2)], "跨行的一档两行各标一段（%s）" % str(m2))
	check(CWCardInfo.tier_marks("x 1 / 1.5 / 2 y", PackedStringArray(["x 1 / 1.5 / 2 y"]), -1) == [[]], "tier=-1 → 全空")
	## 真渲染
	var box := CWCardInfo.new()
	root.add_child(box)
	await process_frame
	box.on_hover("GLUT1高表达")
	box.sync(0.3, CAN, false, 1)
	var seg: Label = null
	var n_seg := 0
	for c in box.get_children():
		if c is Label and (c as Label).text == "0.8":
			seg = c
			n_seg += 1
	check(box.visible and n_seg == 1, "中期：0.8 单独成一个亮字标签（%d 个）" % n_seg)
	if seg != null:
		var prefix := ""
		for i in d1["lines"].size():
			if not d1["marks"][i].is_empty():
				prefix = String(d1["lines"][i]).substr(0, d1["marks"][i][0].x)
		var want_x: float = CWCardInfo.PAD_H + CWStyle.FONT.get_string_size(prefix,
			HORIZONTAL_ALIGNMENT_LEFT, -1, CWStyle.SIZE_LABEL).x
		check(is_equal_approx(seg.position.x, want_x), "亮字的 x = 前文实测宽（%.0f / %.0f）" % [seg.position.x, want_x])
		check(seg.get_theme_color("font_color") == CWStyle.TEXT_HI, "那一档用亮色")
		var chip: ColorRect = null
		for c in box.get_children():
			if c is ColorRect and is_equal_approx((c as ColorRect).position.x, seg.position.x - CWCardInfo.HL_PAD):
				chip = c
		check(chip != null and is_equal_approx(chip.color.a, CWCardInfo.HL_ALPHA) and chip.color.a < 1.0
			and chip.get_index() < seg.get_index(),
			"底下一块半透明色板，压在亮字之下")
		check(chip != null and chip.color.r == CWStyle.CANCER.r and chip.color.g == CWStyle.CANCER.g, "色板是癌方色")
	## 跨期：框开着也要换档
	box.sync(0.0, CAN, false, 2)
	var texts: Array = []
	for c in box.get_children():
		if c is Label:
			texts.append((c as Label).text)
	check(texts.has("1") and not texts.has("0.8"), "换到后期 → 重搭，高亮挪到 1（%s）" % str(texts))
	box.queue_free()
	## 右栏技能详情同一套：装备着 GLUT1 的癌细胞在第 12 回合，条目详情里高亮 0.8；跨期时框的键要变
	var g := _fx_game(2)
	## tip_rows 按 pid 查 cells：免疫 pid 0 先进去，癌 pid 1 才排得上
	g.cells.append(CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(3, 0), CWData.ImmuneType.BASIC, -1))
	var can := CWSetup.make_cell(1, 1, CAN, Vector2i.ZERO, -1, CWData.CancerType.MELANOMA)
	can["energy"] = 50
	can["equipped"] = ["GLUT1高表达"]
	g.cells.append(can)
	g.round_no = 8
	var info := {}
	for r in CWMatchPanel.tip_rows(g, 1, true):
		if r.get("text", "") == "GLUT1高表达":
			info = r["info"]
	check(not info.is_empty() and _marked(info) == ["0.8"], "右栏装备条目的详情按当前分期高亮（%s）" % str(_marked(info)))
	g.dispose()


## 队友 2026-09-06 的出牌表现层（合并自 Cell-War-main-0906-20.18 快照）：引擎 card_played 信号、右栏本回合历史小卡、
## 详情框 show_info 立刻显示。合并时把小卡改摆行底手牌方块左边 —— 行首插 60px 会把玩家名推到能量数上，这里钉住「行首没动」。
func t_card_history() -> void:
	print("[出牌表现层：历史小卡]")
	var g := _fx_game(4)
	var got: Array = []
	g.card_played.connect(func(cell_id: int, pid: int, pos: Vector2i, faction: int, card: String, _data: Dictionary) -> void:
		got.append([cell_id, pid, pos, faction, card]))
	var imm := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.BASIC, -1)
	imm["energy"] = 100
	g.cells.append(imm)
	var can := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(3, 0), -1, CWData.CancerType.MELANOMA)
	can["energy"] = 100
	can["hand"] = ["GLUT1高表达"]
	g.cells.append(can)
	g.round_no = 1
	await g.card_fx.play(can, { "act": "play", "card": "GLUT1高表达" })
	check(got == [[1, 1, Vector2i(3, 0), CWData.Faction.CANCER, "GLUT1高表达"]],
		"打出卡 → 引擎发 card_played 信号（细胞 / 席位 / 位置 / 阵营 / 卡名）：%s" % str(got))
	## 右栏：小卡摆在行底手牌方块左边，行首那一段一个像素没动
	var p := CWMatchPanel.new()
	root.add_child(p)
	await process_frame
	p.refresh(g)
	var row: Dictionary = p._rows[1]
	var hist: Control = row["history"]
	check(not hist.visible, "没打过牌：历史框藏着")
	p.note_played_card(g, 1, CWData.Faction.CANCER, "GLUT1高表达")
	check(hist.visible and hist.get_child_count() == 1, "打出一张 → 一张小卡")
	p.note_played_card(g, 1, CWData.Faction.CANCER, "上皮—间质转化")
	check(hist.get_child_count() == 2 and hist.get_child(1).position.x > hist.get_child(0).position.x,
		"第二张叠在右边（最新在最右）")
	## 叠放只露 2px（Kevin 2026-09-06）：1px 不透明主色边框 + 1px 卡面，被压住的那张不画图标
	check(is_equal_approx(hist.get_child(1).position.x - hist.get_child(0).position.x, 2.0)
		and not (hist.get_child(0).get_child(0) as Control).visible and (hist.get_child(1).get_child(0) as Control).visible,
		"底下那张只露 2px、图标藏起；最上面那张画图标")
	var sb: StyleBoxFlat = hist.get_child(0).get_theme_stylebox("panel")
	check(is_equal_approx(sb.border_color.a, 1.0) and sb.border_color == CWStyle.LINE and sb.border_width_left == 1,
		"边框不透明、主色、1px（露出来的 2px 才是一线边框一线卡面）")
	## 悬停整叠摊开（Kevin 2026-09-07 照手牌区）：每张完整露出、紧挨着排，停着的那张抬 2px 白边，两张都画图标
	var under: Control = hist.get_child(0)
	var top: Control = hist.get_child(1)
	under.mouse_entered.emit()
	check(bool(hist.get_meta("expanded", false)) and is_equal_approx(top.position.x - under.position.x, CWMatchPanel.HISTORY_ICON + 2.0),
		"停上去 → 整叠摊开成每张 %.0fpx 紧挨着排（%.0f / %.0f）" % [CWMatchPanel.HISTORY_ICON + 2.0, under.position.x, top.position.x])
	check(is_equal_approx(under.position.y, 0.0) and is_equal_approx(top.position.y, 2.0) and under.z_index > top.z_index,
		"停着的那张抬 2px、压在最上层")
	check((under.get_child(0) as Control).visible and (top.get_child(0) as Control).visible
		and (under.get_theme_stylebox("panel") as StyleBoxFlat).border_color == Color.WHITE,
		"摊开后每张都画图标，停着的那张白边")
	under.mouse_exited.emit()
	top.mouse_entered.emit()
	check(bool(hist.get_meta("expanded", false)) and is_equal_approx(top.position.y, 0.0), "划到相邻那张：仍摊开，抬起的换成它")
	top.mouse_exited.emit()
	await process_frame
	check(not bool(hist.get_meta("expanded", false)) and is_equal_approx(top.position.x - under.position.x, 2.0)
		and not (under.get_child(0) as Control).visible,
		"离开整叠 → 下一帧收回 2px 叠放、底下那张图标藏起")
	var pip0: ColorRect = row["pips"][0]
	check(hist.position.x + hist.size.x <= pip0.position.x - 2.0,
		"小卡框在手牌方块左边（%.0f..%.0f，方块 %.0f）" % [hist.position.x, hist.position.x + hist.size.x, pip0.position.x])
	## 种类文字让到小卡左边，一个像素都不压（Kevin 2026-09-07 拍到的重叠）。
	## 拿最长的那种癌症名 + 联机的「· 离线代打」凑最坏情况
	var ty2: Label = row["type"]
	p.net_seats = [{ "kind": "human", "online": true }, { "kind": "human", "online": false }]
	p.refresh(g)
	var left_chip: float = hist.position.x + hist.size.x - ((CWMatchPanel.HISTORY_ICON + 2.0) + float(hist.get_child_count() - 1) * CWMatchPanel.HISTORY_STEP)
	check(ty2.clip_text and ty2.position.x + ty2.size.x <= left_chip,
		"种类文字裁切、且右缘让到最左那张小卡之前（%.0f ≤ %.0f，文本「%s」）" % [ty2.position.x + ty2.size.x, left_chip, ty2.text])
	var wide_enough: bool = ty2.size.x >= 40.0
	p.net_seats = []
	p.refresh(g)
	check(wide_enough and ty2.position.x + ty2.size.x <= pip0.position.x,
		"让归让，至少还留得下 4 个字；没小卡时一直铺到方块左边")
	check(hist.position.y + hist.size.y <= row["bg"].position.y + CWMatchPanel.ROW_H, "小卡框不出行底")
	check(row["name"].position.x == row["icon"].position.x + CWMatchPanel.ICON / 2.0 + 8.0, "玩家名还在头像右边 8px，没被推开")
	var rows: Dictionary = hist.get_child(0).get_meta("rows")
	check(_marked(rows) == ["0.5"], "小卡的详情按当前分期（前期）高亮（%s）" % str(_marked(rows)))
	## 换回合清空（历史只属于本回合的显示层）
	g.round_no = 2
	p.refresh(g)
	await process_frame
	check(not hist.visible and hist.get_child_count() == 0, "换回合 → 小卡清空、框藏起")
	p.queue_free()
	## 详情框 show_info：点小卡不等 0.25s 延时
	var box := CWCardInfo.new()
	root.add_child(box)
	await process_frame
	box.show_info(rows, 500.0)
	check(box.visible and box.position.x <= 500.0, "show_info 立刻显示（x=%.0f）" % box.position.x)
	box.show_info({}, 0.0)
	check(not box.visible, "空字典 → 收起")
	## 带 y 的锚点（2026-09-07 Kevin：详情有时跑到窗口下方）：框顶对齐到被悬停那一行；不带 y 照旧压在行动栏提示条上方
	box.show_info(rows, 900.0, 120.0)
	check(is_equal_approx(box.position.y, 120.0) and box.position.x + CWCardInfo.W <= CWView.screen_size().x - CWMatchPanel.RECT.size.x - 8.0,
		"带 y：框顶对齐到那一行、往左让出右栏（%.0f, %.0f）" % [box.position.x, box.position.y])
	box.show_info(rows, 900.0, 530.0)
	check(box.position.y + box.size.y <= CWView.screen_size().y - 8.0, "行在底部时框往上顶、不出屏")
	box.on_hover_info({}, 0.0, -1.0)   ## 先离开：同一份 rows 再悬停会被当成没换目标、锚点不更新
	box.on_hover_info(rows, 300.0, 200.0)
	box.sync(0.3, CWData.Faction.CANCER, false)
	check(box.visible and is_equal_approx(box.position.y, 200.0), "悬停路也认 y（%.0f）" % box.position.y)
	box.on_hover_info({}, 0.0, -1.0)
	box.on_hover_info(rows, 300.0)
	box.sync(0.3, CWData.Faction.CANCER, false)
	check(box.position.y + box.size.y <= CWActionBar.PROMPT_RECT.position.y, "不带 y（分化按钮那条路）照旧压在行动栏提示条上方")
	box.queue_free()
	## 右栏两条路都带 y：技能行悬停 = 那一行的画布 y；历史小卡点击 = 小卡的画布 y
	var p2 := CWMatchPanel.new()
	root.add_child(p2)
	await process_frame
	var heard: Array = []
	p2.skill_hovered.connect(func(r: Dictionary, ax: float, ay: float) -> void: heard.append(["skill", r.get("name", ""), ax, ay]))
	p2.played_card_pressed.connect(func(r: Dictionary, ax: float, ay: float) -> void: heard.append(["chip", r.get("name", ""), ax, ay]))
	p2.refresh(g)
	p2._tip_pinned = 1
	p2.refresh(g)
	var first_item: Label = null
	for c in p2._tip.get_children():
		if c is Label and c.mouse_filter == Control.MOUSE_FILTER_STOP and first_item == null:
			first_item = c
	check(first_item != null, "固定态技能框里有可悬停的条目")
	if first_item != null:
		first_item.mouse_entered.emit()
		check(heard.size() == 1 and heard[0][0] == "skill" and is_equal_approx(heard[0][3], first_item.get_global_rect().position.y)
			and is_equal_approx(heard[0][2], p2._tip.global_position.x - CWCardInfo.W - 8.0),
			"技能行悬停：锚点 = 框左侧 + 那一行的 y（%s）" % str(heard))
	p2._tip_pinned = -1
	p2.refresh(g)
	p2.note_played_card(g, 1, CWData.Faction.CANCER, "GLUT1高表达")
	var chip2: Control = (p2._rows[1]["history"] as Control).get_child(0)
	var click := InputEventMouseButton.new()
	click.pressed = true
	click.button_index = MOUSE_BUTTON_LEFT
	chip2.gui_input.emit(click)
	check(heard.size() >= 1 and heard[-1][0] == "chip" and heard[-1][1] == "GLUT1高表达"
		and is_equal_approx(heard[-1][3], chip2.get_global_rect().position.y),
		"历史小卡点击：锚点带小卡自己的 y（%s）" % str(heard[-1]))
	p2.queue_free()
	g.dispose()


## 抽到即结算的事件卡记进右栏「回合数」那一栏（Kevin 2026-09-07 拍板方案乙）：与世界事件同一行、右侧横排，
## 悬停摊开 / 点击看卡面复用玩家行那套。这里钉三样：引擎的两路出口、右栏的摆位与清空、和玩家行那排分得开。
func t_event_strip() -> void:
	print("[事件卡进回合数栏]")
	var g := _fx_game(4)
	## ① 引擎：抽到事件卡 → 发 event_drawn 信号 + 广播到桥；抽到技能卡不发
	var rec := CardPlayRecorder.new()
	rec.game = g
	for pid in g.order:
		g.bridges[pid] = rec
	var heard: Array = []
	g.event_drawn.connect(func(cell_id: int, pid: int, pos: Vector2i, faction: int, card: String) -> void:
		heard.append([cell_id, pid, pos, faction, card]))
	var imm := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(0, 0), CWData.ImmuneType.BASIC, -1)
	imm["energy"] = 500
	g.cells.append(imm)
	## 把这一档池子里的技能全塞进手牌 → 剩下的合法候选只有事件卡（同 t_card_pool 那条的做法）
	for c in CWCardData.pool_of(CWData.Faction.IMMUNE, g.immune_level, g.round_no):
		if CWCardData.CARDS[c["name"]]["kind"] != CWCardData.Kind.EVENT:
			imm["hand"].append(c["name"])
	var hand_before: int = imm["hand"].size()
	await g.cards.draw(imm, "基因表达")
	check(heard.size() == 1 and heard[0][0] == 0 and heard[0][3] == CWData.Faction.IMMUNE
		and CWCardData.CARDS[heard[0][4]]["kind"] == CWCardData.Kind.EVENT,
		"抽到事件卡：发 event_drawn（细胞 / 席位 / 位置 / 阵营 / 卡名）：%s" % str(heard))
	check(rec.events.size() == 1 and rec.events[0][0] == 0 and rec.events[0][1] == heard[0][4],
		"同时广播给桥（联机据此发报文）：%s" % str(rec.events))
	check(imm["hand"].size() == hand_before, "事件卡不进手牌（PRD：抽取后立即结算并弃置）")
	var drew: String = heard[0][4]
	## 技能卡那条路不发 event_drawn（它进手牌，之后打出才算「打出的卡」）
	imm["hand"].clear()
	heard.clear()
	rec.events.clear()
	for k in 12:
		if not heard.is_empty():
			break
		await g.cards.draw(imm, "基因表达")
	var skill_only := true
	for h in heard:
		if CWCardData.CARDS[h[4]]["kind"] != CWCardData.Kind.EVENT:
			skill_only = false
	check(skill_only, "只有事件卡会发 event_drawn（抽到的技能卡不发）")

	## ② 右栏：摆在世界事件那一行右侧、右缘对齐；世界事件文字给它让宽
	var p := CWMatchPanel.new()
	root.add_child(p)
	await process_frame
	g.round_no = 12
	g.events["active"].append({ "name": "基质阻隔", "left": 2, "stacks": 1, "data": {} })
	p.refresh(g)
	var strip: Control = p._event_strip
	var full_w: float = p._events.size.x
	check(not strip.visible and is_equal_approx(full_w, CWMatchPanel.W), "还没抽到事件卡：横排藏着，世界事件文字占满整行")
	p.note_event_card(g, CWData.Faction.IMMUNE, drew)
	p.note_event_card(g, CWData.Faction.CANCER, "糖酵解爆发")
	check(strip.visible and strip.get_child_count() == 2, "抽到两张 → 两张小卡")
	var chip_w: float = CWMatchPanel.HISTORY_ICON + 2.0
	var last: Control = strip.get_child(1)
	check(is_equal_approx(strip.position.x + last.position.x + chip_w, CWMatchPanel.PAD + CWMatchPanel.W),
		"最新那张贴面板内容右缘（%.0f）" % (strip.position.x + last.position.x + chip_w))
	check(strip.position.y + last.position.y >= CWMatchPanel.PAD + 36.0
		and strip.position.y + last.position.y + chip_w <= CWMatchPanel.PAD + CWMatchPanel.ROUND_H + CWMatchPanel.GAP,
		"落在世界事件那一行、不压到分数块（%.0f..%.0f）" % [strip.position.y + last.position.y, strip.position.y + last.position.y + chip_w])
	check(p._events.size.x < full_w and p._events.size.x + chip_w + 2.0 <= CWMatchPanel.W,
		"世界事件文字裁到小卡左边（%.0f → %.0f）" % [full_w, p._events.size.x])
	## 边色按阵营，和玩家行那排（主色）分得开
	var sb0: StyleBoxFlat = strip.get_child(0).get_theme_stylebox("panel")
	var sb1: StyleBoxFlat = last.get_theme_stylebox("panel")
	check(sb0.border_color == CWStyle.IMMUNE and sb1.border_color == CWStyle.CANCER, "边色按抽到它的阵营：青 / 橙")
	p.note_played_card(g, 1, CWData.Faction.CANCER, "GLUT1高表达")
	var row_chip: Control = (p._rows[1]["history"] as Control).get_child(0)
	check((row_chip.get_theme_stylebox("panel") as StyleBoxFlat).border_color == CWStyle.LINE,
		"玩家行那排（自己打出的卡）仍是主色边，两排分得开")
	check(strip.get_child_count() == 2, "打出的卡不进回合栏")

	## ③ 行为照抄玩家行：悬停整叠摊开、点击发信号（带那张小卡的 y）
	strip.get_child(0).mouse_entered.emit()
	check(is_equal_approx(last.position.x - strip.get_child(0).position.x, chip_w), "悬停 → 整叠摊开，一张挨一张")
	var clicked: Array = []
	p.played_card_pressed.connect(func(r: Dictionary, ax: float, ay: float) -> void: clicked.append([r.get("name", ""), ax, ay]))
	var ev := InputEventMouseButton.new()
	ev.pressed = true
	ev.button_index = MOUSE_BUTTON_LEFT
	last.gui_input.emit(ev)
	check(clicked.size() == 1 and clicked[0][0] == "糖酵解爆发"
		and is_equal_approx(clicked[0][2], last.get_global_rect().position.y),
		"点小卡 → 和玩家行同一条信号，锚点带自己的 y（%s）" % str(clicked))

	## ④ 上限 8，超了丢最旧；换回合清空（和玩家行同一把尺）
	for k in 8:
		p.note_event_card(g, CWData.Faction.IMMUNE, "急性炎症反应")
	check(strip.get_child_count() == CWMatchPanel.EVENT_STRIP_MAX, "最多留 %d 张" % CWMatchPanel.EVENT_STRIP_MAX)
	check(String(strip.get_child(0).get_meta("card_name")) == "急性炎症反应", "超了丢最旧的那张")
	g.round_no = 13
	p.refresh(g)
	check(not strip.visible and strip.get_child_count() == 0 and is_equal_approx(p._events.size.x, CWMatchPanel.W),
		"换回合 → 清空、文字重新占满整行")
	p.queue_free()
	g.dispose()


## 抽卡的头顶演出（Kevin 2026-09-07：「把出牌那段倒放」）+ 三拍节奏（「上浮 - 停顿 - 继续上浮消失」）。
func t_card_draw_fx() -> void:
	print("[抽卡演出与三拍]")
	## ① 三拍：中间那拍位移最小（那是「停顿」），总时长比原来的 0.42 秒长得多
	check(CWMatch.CARD_FX_RISE.size() == 3 and CWMatch.CARD_FX_TIME.size() == 3, "三拍")
	check(CWMatch.CARD_FX_RISE[1] < CWMatch.CARD_FX_RISE[0] and CWMatch.CARD_FX_RISE[1] < CWMatch.CARD_FX_RISE[2],
		"第②拍位移最小 = 停顿那一下（%s）" % str(CWMatch.CARD_FX_RISE))
	## 总时长要**把整套拍子都数上**：2026-09-07 细化节奏时在三拍前后各加了「蓄力」与「留拍」，
	## 三拍自身反而缩短了 —— 只数三拍会把这条断言测红（当天就红过一次）。
	## 钉的是原本的意图：整套比最早那版 0.42 秒长一倍以上。
	var beats: float = CWMatch.CARD_FX_TIME[0] + CWMatch.CARD_FX_TIME[1] + CWMatch.CARD_FX_TIME[2]
	## 复活图腾与抽卡同长（Kevin 2026-09-07）：两个都是「头顶冒出个东西」，
	## 对不齐时同屏出现一个赶一个拖。钉住这条关系，别让谁单独被调走
	check(is_equal_approx(CWMatch.REVIVE_FX_TIME,
		CWMatch.CARD_FX_WINDUP + beats + CWMatch.CARD_FX_HOLD),
		"复活图腾 %.2f s = 抽卡那套的总时长" % CWMatch.REVIVE_FX_TIME)
	var total_t: float = CWMatch.CARD_FX_WINDUP + beats + CWMatch.CARD_FX_HOLD
	check(total_t > 0.42 * 2.0 and CWMatch.CARD_FX_TIME[1] >= CWMatch.CARD_FX_TIME[0] * 1.5,
		"整套时长 %.2f 秒（最早 0.42），停顿那拍不比第一拍短" % total_t)

	## ② 引擎：每次抽到卡都发 card_drawn（带来源），抽空不发；同时广播给桥
	var g := _fx_game(4)
	var rec := CardPlayRecorder.new()
	rec.game = g
	for pid in g.order:
		g.bridges[pid] = rec
	var heard: Array = []
	g.card_drawn.connect(func(cell_id: int, pid: int, pos: Vector2i, source: String) -> void:
		heard.append([cell_id, pid, pos, source]))
	var imm := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(2, 0), CWData.ImmuneType.BASIC, -1)
	imm["energy"] = 500
	g.cells.append(imm)
	await g.cards.draw(imm, "基因表达")
	check(heard.size() == 1 and heard[0][0] == 0 and heard[0][2] == Vector2i(2, 0) and heard[0][3] == "基因表达",
		"抽到卡：发 card_drawn（细胞 / 席位 / 位置 / 来源）：%s" % str(heard))
	check(rec.draws == [[0, "基因表达"]], "同时广播给桥（联机据此发报文）：%s" % str(rec.draws))
	await g.cards.draw(imm, "骨髓")
	check(heard.size() == 2 and heard[1][3] == "骨髓", "骨髓那条路也演（来源随信号带走）")
	## 抽空（把这一档的技能全塞手上、事件卡又都抽不到时）不发：直接钉 pick 返回空的那条路
	var lonely := _fx_game(2)
	var l2 := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i.ZERO, CWData.ImmuneType.BASIC, -1)
	lonely.cells.append(l2)
	var heard2: Array = []
	lonely.card_drawn.connect(func(_a: int, _b: int, _c: Vector2i, _d: String) -> void: heard2.append(1))
	for c in CWCardData.pool_of(CWData.Faction.IMMUNE, lonely.immune_level, lonely.round_no):
		l2["hand"].append(c["name"])   ## 事件卡也塞进去，pick 的候选就真空了（事件卡不受同名限制，但它只看 hand/equipped）
	var picked: String = lonely.cards.pick(l2)
	if picked == "":
		await lonely.cards.draw(l2, "基因表达")
		check(heard2.is_empty(), "抽卡落空 → 不演")
	else:
		check(true, "这一档抽得出卡，落空那条路由 t_card_pool 盯着")
	lonely.dispose()

	## ③ 界面：打出 = 从头顶起、看得见；抽到 = 从三拍终点（上方）起、全透明（就是倒放）
	var main_scene: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main_scene)
	await process_frame
	var m: CWMatch = main_scene.match_node
	## **不碰 CWSettings.ai_delay_ms**：那是全局的，改了不还原会把后面「设置页拨值」那条带偏（本次踩到）。
	## 这里只走一帧就拆局，AI 节奏是多少都无所谓
	m.start()
	await process_frame
	var at := Vector2i.ZERO
	var head: float = m.board.tile_center(at).y - CWMatch.CARD_FX_HEAD
	var rise: float = CWMatch.CARD_FX_RISE[0] + CWMatch.CARD_FX_RISE[1] + CWMatch.CARD_FX_RISE[2]
	m._play_card_fx(-1, at, false)
	var played: Sprite2D = m._played_card_fx[m._played_card_fx.size() - 1]
	check(is_equal_approx(played.position.y, head) and is_equal_approx(played.modulate.a, 1.0),
		"打出：从头顶起、满不透明（y=%.0f）" % played.position.y)
	m._play_card_fx(-1, at, true)
	var drawn: Sprite2D = m._played_card_fx[m._played_card_fx.size() - 1]
	check(is_equal_approx(drawn.position.y, head - rise) and is_equal_approx(drawn.modulate.a, 0.0),
		"抽到：从三拍终点（上方 %.0fpx）起、全透明，正是倒放（y=%.0f）" % [rise, drawn.position.y])
	check(m._played_card_fx.size() == 2, "两只都记在案，拆局时一并清掉")
	m.teardown()
	await process_frame
	check(m._played_card_fx.is_empty(), "拆局清空")
	root.remove_child(main_scene)
	main_scene.free()
	g.dispose()


## 联机的当前延时（Kevin 2026-09-07）：数字来自已有的心跳往返，HUD 只负责显示。
## 客户端那半用 `_apply` 直接喂报文（不必真连服务器）；HUD 那半是纯函数。
func t_net_ping() -> void:
	print("[联机延时显示]")
	var c := CWNetClient.new()
	check(c.ping_ms == -1, "还没量到：-1，不是 0")
	## 没发过 ping 就收到 pong（服务器乱回）→ 不记
	c._apply({ "t": "pong" })
	check(c.ping_ms == -1, "没发过 ping 的 pong 不记")
	c._ping_sent = Time.get_ticks_msec() - 40
	c._apply({ "t": "pong" })
	check(c.ping_ms >= 40 and c.ping_ms < 4000, "pong 回来 → 记下这一个往返（%d ms）" % c.ping_ms)
	c.forget_ping()
	check(c.ping_ms == -1, "断线后读数作废（重连前那个数字没意义）")
	## CWNetClient 是 RefCounted，不能 free()（本次踩到：SCRIPT ERROR「Attempted to free a RefCounted object」）

	## 文案与配色：没量到写「--」，超过门槛转暖橙
	check(CWNetHud.ping_text(-1) == "延迟 --" and CWNetHud.ping_text(42) == "延迟 42 ms",
		"文案：没量到写 --，量到写毫秒（%s）" % CWNetHud.ping_text(42))
	check(CWNetHud.ping_color(-1) == CWStyle.TEXT_OFF
		and CWNetHud.ping_color(CWNetHud.PING_WARN_MS - 1) == CWStyle.TEXT_DIM
		and CWNetHud.ping_color(CWNetHud.PING_WARN_MS) == CWStyle.CANCER,
		"配色：未知灰、正常暗、超 %d ms 转暖橙" % CWNetHud.PING_WARN_MS)

	## 摆位：跟倒计时同一列、压在它下面，且不出棋盘区
	var hud := CWNetHud.new()
	root.add_child(hud)
	await process_frame
	hud.start_countdown(30000)
	hud.set_ping(42)
	check(hud._ping.visible and hud._ping.position.y > hud._count.position.y,
		"延时压在倒计时下面（%.0f > %.0f）" % [hud._ping.position.y, hud._count.position.y])
	check(is_equal_approx(hud._ping.position.x + hud._ping.size.x, CWNetHud.COUNT_RIGHT)
		and hud._ping.position.x + hud._ping.size.x <= CWView.screen_size().x - CWView.PANEL_WIDTH,
		"右缘和倒计时同一列、不进右栏（右缘 %.0f）" % (hud._ping.position.x + hud._ping.size.x))
	hud.hide_ping()
	check(not hud._ping.visible, "单机 / 拆局：收起")
	hud.queue_free()

	## 点日志空白处收起（Kevin 2026-09-07）
	var lp := CWLogPanel.new()
	root.add_child(lp)
	await process_frame
	lp.active = true
	lp.toggle()
	check(lp.visible, "L 开")
	var click := InputEventMouseButton.new()
	click.pressed = true
	click.button_index = MOUSE_BUTTON_LEFT
	click.position = Vector2(CWLogPanel.RECT.size.x / 2.0, CWLogPanel.RECT.size.y / 2.0)
	lp._gui_input(click)
	check(not lp.visible, "点面板空白处 → 收起")
	lp.toggle()
	var wheel := InputEventMouseButton.new()
	wheel.pressed = true
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.position = click.position
	lp._gui_input(wheel)
	check(lp.visible, "滚轮照旧翻页，不会把面板关掉")
	## 点面板外面也收（Kevin 2026-09-07），且这一下被吃掉：不该顺手把细胞走过去
	var outside := InputEventMouseButton.new()
	outside.pressed = true
	outside.button_index = MOUSE_BUTTON_LEFT
	outside.position = Vector2(CWLogPanel.RECT.end.x + 80.0, CWLogPanel.RECT.end.y + 80.0)
	check(not lp.get_rect().has_point(outside.position), "这个点确实在面板外")
	lp._unhandled_input(outside)
	check(not lp.visible, "点面板外面 → 收起")
	lp.visible = false
	lp.queue_free()

	## 细胞信息栏（右栏固定态）：点外面取消固定，但**不吃**那一下
	var g2 := _fx_game(4)
	for pid in 4:
		var f: int = g2.players[pid]["faction"]
		g2.cells.append(CWSetup.make_cell(pid, pid, f, Vector2i(pid - 1, 2),
			CWData.ImmuneType.BASIC if f == CWData.Faction.IMMUNE else -1,
			-1 if f == CWData.Faction.IMMUNE else CWData.CancerType.MELANOMA))
	var mp := CWMatchPanel.new()
	root.add_child(mp)
	await process_frame
	mp.refresh(g2)
	var closed: Array = []
	mp.skill_hovered.connect(func(r: Dictionary, _x: float, _y: float) -> void:
		if r.is_empty():
			closed.append(1))
	mp._tip_pinned = 1
	mp.refresh(g2)
	check(mp._tip != null and mp._tip.visible, "固定住细胞信息栏")
	mp._unhandled_input(outside)
	check(mp._tip_pinned == -1 and closed.size() == 1, "点外面 → 取消固定，并收掉旁边那张卡面")
	mp.refresh(g2)
	check(mp._tip == null or not mp._tip.visible, "重画后信息栏确实收了")
	mp.queue_free()
	g2.dispose()


## 骨样硬化的价签（Kevin 2026-09-07：按钮上没写要花多少能量）+ 点开的详情框收得掉。
func t_ossify_cost_and_pin() -> void:
	print("[骨样硬化价签 / 详情框收起]")
	var g := _fx_game(2)
	var ub := CWUIBridge.new()
	ub.game = g
	var ost := CWSetup.make_cell(g.cells.size(), 1, CWData.Faction.CANCER, Vector2i.ZERO, -1,
		CWData.CancerType.OSTEO)
	ost["energy"] = 100
	g.cells.append(ost)
	g.tiles[Vector2i.ZERO]["tissue"] = CWData.Tissue.CANCER
	check(ub._cost_text(ost, "ossify") == CWData.fmt(g.tune.osteo_ossify_cost),
		"骨样硬化按钮写明费用，且现读旋钮（%s）" % ub._cost_text(ost, "ossify"))
	g.tune.osteo_ossify_cost = 35
	check(ub._cost_text(ost, "ossify") == CWData.fmt(35), "改旋钮价签跟着变，没写死")
	g.tune.osteo_ossify_cost = CWData.OSTEO_OSSIFY_COST
	## 这个癌种的主动技能一个都不许缺价签（骨样硬化就是这么漏的）
	var blank: Array = []
	for act in g.actions.action_kinds(ost):
		if act != "move" and ub._cost_text(ost, act) == "":
			blank.append(act)
	check(blank.is_empty(), "骨肉瘤的主动技能都有价签（缺的：%s；「移动」2026-09-08 起不带价签，价看格子详情）" % str(blank))

	## 点小卡固定住的详情框：再点同一张 → 收；点别处 → 收；去停手牌 → 让位
	var box := CWCardInfo.new()
	root.add_child(box)
	await process_frame
	var rows: Dictionary = CWCardInfo.describe("GLUT1高表达", CWData.Faction.CANCER, 1)
	box.show_info(rows, 300.0, 120.0)
	check(box.visible, "点小卡 → 立刻显示")
	box.sync(0.5, CWData.Faction.CANCER, false)
	check(box.visible, "自己不会消失（这正是 Kevin 报的「卡在那里」的前提）")
	box.show_info(rows, 300.0, 120.0)
	check(not box.visible, "再点同一张 → 收起")
	box.show_info(rows, 300.0, 120.0)
	check(box.visible, "再点一下又开（开关式）")
	var click := InputEventMouseButton.new()
	click.pressed = true
	click.button_index = MOUSE_BUTTON_LEFT
	box._unhandled_input(click)
	check(not box.visible, "点别处（棋盘 / 空处）→ 收起")
	box.show_info(rows, 300.0, 120.0)
	box.on_hover("补体调理")
	box.sync(0.5, CWData.Faction.IMMUNE, false)
	check(box.visible and box._card == "补体调理", "去停一张手牌 → 固定的让位，浮出那张卡的详情")
	box.on_hover("")
	box.hide_now()
	## 悬停那种照旧：鼠标一走就收，不受固定那套影响
	box.on_hover_info(CWCardInfo.describe_type(CWData.ImmuneType.T_CELL), 300.0, 100.0)
	box.sync(0.5, CWData.Faction.IMMUNE, false)
	check(box.visible, "悬停技能行照常浮出")
	box._unhandled_input(click)
	check(box.visible, "悬停那种不吃「点别处就收」那条（它自己会随鼠标离开收起）")
	box.on_hover_info({}, 0.0, -1.0)
	check(not box.visible, "离开 → 收起")
	## 详情框要算「最上面的图层」（Kevin 2026-09-07 截图：停在框上，底下那一格的地图信息还浮出来）——
	## 棋盘按 gui_get_hovered_control() 判，IGNORE 的控件它看不见
	check(box.mouse_filter == Control.MOUSE_FILTER_STOP, "详情框挡鼠标：格子详情不会从它底下钻出来，也点不穿到棋盘")
	box.queue_free()
	g.dispose()


## 卡牌引发的净化不积累抗原记忆（Kevin 2026-09-07：先定抽卡，当天又补上打出的即时卡）。
## 开关是 CWGame.card_resolve_depth，两条给记忆的路（净化本身、局部吞噬）都认它；自己走进去净化照常给。
func t_draw_purify_memory() -> void:
	print("[抽卡造成的净化不给记忆]")
	var g := _fx_game(2)
	var imm := put_immune(g, Vector2i.ZERO)
	var at := Vector2i(1, 0)
	## ① 自己走进去净化：照常 +1
	g.tiles[at]["tissue"] = CWData.Tissue.CANCER
	var m0: int = g.memory
	await g.actions.purify_here(imm, at, -1)
	check(g.memory == m0 + 1, "自己净化：+1 抗原记忆")
	## ② 抽卡结算期间：不给，且日志说得出为什么
	g.tiles[at]["tissue"] = CWData.Tissue.CANCER
	g.card_resolve_depth += 1
	var n0: int = g.logs.size()
	await g.actions.purify_here(imm, at, -1)
	var said := "\n".join(g.logs.slice(n0))
	check(g.memory == m0 + 1 and said.contains("卡牌造成"),
		"卡牌引发的净化：不给记忆，日志写明原因（%s）" % said.strip_edges())
	check(g.tiles[at]["tissue"] == CWData.Tissue.HEALTHY, "该净化的还是净化了，只是不给记忆")
	## ③ 【局部吞噬】同一把尺：卡面也不再写「+1 抗原记忆」
	g.tiles[at]["tissue"] = CWData.Tissue.CANCER
	var m1: int = g.memory
	## 2026-09-08 起它是即时技能，走「打出」这条路 —— 而 play() 里 card_resolve_depth 照样 +1，
	## 也就是说**打出的即时卡引发的净化同样不给记忆**。这条断言因此更值钱了：
	## 在「不给记忆」的开关开着的情况下，卡面明写的那 1 点仍要给。
	imm["hand"] = ["局部吞噬"]
	await g.card_fx.play(imm, { "act": "play", "card": "局部吞噬" })
	## 2026-09-07 线上版 PRD 把「并获得1抗原记忆」写回了卡面 → 照给。
	## Kevin 的口径：**卡面写明的算，没写明的净化不算** —— 与 purify_gives_memory 那条开关互不干涉。
	check(g.memory == m1 + 1, "【局部吞噬】卡面明写「获得1抗原记忆」→ 打出结算里照样给")
	check(CWCardData.effect_of("局部吞噬", CWData.Faction.IMMUNE).contains("并获得1抗原记忆"),
		"卡面与 PRD 一致：%s" % CWCardData.effect_of("局部吞噬", CWData.Faction.IMMUNE))
	g.card_resolve_depth -= 1
	## ④ 开关归零：抽完一张卡不能把它留在开着的状态
	check(g.purify_gives_memory(), "结算完开关归零，之后自己净化照常给")
	## ⑤ 真走一遍 draw()：结算期间开着、抽完归零
	var depth_seen: Array = []
	g.event_drawn.connect(func(_a: int, _b: int, _c: Vector2i, _d: int, _e: String) -> void:
		depth_seen.append(g.card_resolve_depth))
	for c in CWCardData.pool_of(CWData.Faction.IMMUNE, g.immune_level, g.round_no):
		if CWCardData.CARDS[c["name"]]["kind"] != CWCardData.Kind.EVENT:
			imm["hand"].append(c["name"])   ## 技能全塞手上 → 只抽得到事件卡
	await g.cards.draw(imm, "基因表达")
	check(depth_seen == [1], "抽到事件卡：结算期间开关开着（%s）" % str(depth_seen))
	check(g.card_resolve_depth == 0 and g.purify_gives_memory(), "结算完归零")
	## ⑤b 打出的即时卡同样（Kevin 2026-09-07 补）：【炎症性趋化】的每一步走进癌组织都会净化
	imm["hand"] = ["补体调理"]
	imm["energy"] = 100
	await g.card_fx.play(imm, { "act": "play", "card": "补体调理" })
	check(g.card_resolve_depth == 0 and g.purify_gives_memory(), "打完一张卡开关也归零")
	var seen_play: Array = []
	var probe := Vector2i(0, 1)
	g.tiles[probe]["tissue"] = CWData.Tissue.CANCER
	var m3: int = g.memory
	g.card_resolve_depth += 1          ## 模拟「正在结算一张打出的卡」
	await g.actions.purify_here(imm, probe, -1)
	g.card_resolve_depth -= 1
	check(g.memory == m3, "打出的卡引发的净化：同样不给记忆")
	seen_play.append(1)
	## ⑥ 抗原记忆类的卡不受影响：它们的正业就是送记忆
	var m2: int = g.memory
	g.card_resolve_depth += 1
	await g.card_fx.resolve_event(imm, "抗原呈递增强")
	g.card_resolve_depth -= 1
	check(g.memory == m2 + 3, "【抗原呈递增强】照给 +3（挡的只是净化那一份）")
	g.dispose()


## describe() 结果里被高亮的那几段文字，按行序排
static func _marked(d: Dictionary) -> Array:
	var out: Array = []
	var marks: Array = d.get("marks", [])
	for i in marks.size():
		for sp in marks[i]:
			out.append(String(d["lines"][i]).substr(sp.x, sp.y))
	return out



## 记录 card_played 与 announce 的 linger（2026-09-06 别人打牌弹窗 / 非骰子说明另一档）
class CardPlayRecorder extends CWHeuristicBridge:
	var got: Array = []
	var results: Array = []
	func show_card_played(pid: int, text: String, _info := {}) -> void:
		got.append([pid, text])
	var events: Array = []
	func show_event_drawn(pid: int, info := {}) -> void:
		events.append([pid, info.get("card", ""), info.get("faction", -1)])
	var draws: Array = []
	func show_card_drawn(pid: int, info := {}) -> void:
		draws.append([pid, info.get("source", "")])
	func show_result(text: String, _at: Vector2i, linger := false) -> void:
		results.append([text, linger])


## 模拟一次拖拽：在卡上按下 → 移动 → 在 to 处松手。
## 按下要走卡自己的 gui_input（拖是从那儿起的），移动和松手走 hand._input ——
## 光标一离开卡面，Control 就收不到 gui_input 了，这正是拖拽要在 hand 层收事件的原因。
##
## ⚠ **两段事件的坐标空间不一样，这正是 2026-09-01「拖动中卡牌消失」的根因**：
##   `gui_input` 的 position 是**卡的局部坐标**（0..72, 0..112），Godot 已经换算过；
##   `_input` 的 position 是**画布坐标**。
## 头一版这个辅助函数给按下也喂画布坐标，于是测试和实现「一起错」、绿得很稳，
## 真跑起来卡直接飞出画布。所以 grab_local 必须是卡内的点，别图省事传画布坐标。
func _drag_card(hand: CWHand, index: int, grab_local: Vector2, to: Vector2) -> void:
	var down := InputEventMouseButton.new()
	down.pressed = true
	down.button_index = MOUSE_BUTTON_LEFT
	down.position = grab_local
	hand._cards[index].gui_input.emit(down)
	var move := InputEventMouseMotion.new()
	move.position = to
	hand._input(move)
	var up := InputEventMouseButton.new()
	up.pressed = false
	up.button_index = MOUSE_BUTTON_LEFT
	up.position = to
	hand._input(up)


## 离场动画（团队 2026-09-01）：拖拽打出=原地淡出、双击打出=向上、弃置=向下。
func t_hand_exit() -> void:
	print("[手牌离场动画]")
	## ① 走的是**真正离开的那一张**，不是队尾那张。
	##    这条是三个动画的地基：卡的身份是位置性的（名字由 _layout 按下标重贴），
	##    老的 pop_back 在没动画时看着对，一做动画就会让错的卡飞走
	check(CWHand.leaving_indices(PackedStringArray(["甲", "乙", "丙"]),
		PackedStringArray(["乙", "丙"])) == [0], "打出第 0 张 → 走的是第 0 张")
	check(CWHand.leaving_indices(PackedStringArray(["甲", "乙", "丙"]),
		PackedStringArray(["甲", "丙"])) == [1], "打出中间那张 → 走的是中间那张")
	check(CWHand.leaving_indices(PackedStringArray(["甲", "乙"]),
		PackedStringArray(["甲", "乙"])) == [], "没少牌 → 没有卡离场")
	check(CWHand.leaving_indices(PackedStringArray(["甲", "乙", "丙"]),
		PackedStringArray(["乙"])) == [0, 2], "一次少两张 → 两张都认出来")

	var hand := CWHand.new()
	root.add_child(hand)
	var names := PackedStringArray(["交叉呈递", "乳酸酸化", "免疫增援"])
	hand.sync(3, Vector2.INF, names)
	var y0: float = hand._cards[1].position.y

	## ② 双击打出 → 向上淡出
	hand._hint_exit("乳酸酸化", CWHand.Exit.UP)
	var going: Control = hand._cards[1]
	hand.sync(2, Vector2.INF, PackedStringArray(["交叉呈递", "免疫增援"]))
	check(hand._flying.has(going) and hand._cards.size() == 2,
		"打出的那张离开 _cards、进入飞出队列")
	finish_exit(hand, going)
	check(going.position.y < y0 - CWHand.EXIT_RISE + 1.0 and going.modulate.a < 0.02,
		"双击打出：向上 %.0f 并淡到透明（y %.0f→%.0f）" % [
			CWHand.EXIT_RISE, y0, going.position.y])

	## ③ 弃置 → 向下淡出
	hand.sync(3, Vector2.INF, names)
	var y1: float = hand._cards[1].position.y
	hand._hint_exit("乳酸酸化", CWHand.Exit.DOWN)
	var dumped: Control = hand._cards[1]
	hand.sync(2, Vector2.INF, PackedStringArray(["交叉呈递", "免疫增援"]))
	finish_exit(hand, dumped)
	check(dumped.position.y > y1 + CWHand.EXIT_FALL - 1.0 and dumped.modulate.a < 0.02,
		"弃置：向下 %.0f 并淡到透明（y %.0f→%.0f）" % [
			CWHand.EXIT_FALL, y1, dumped.position.y])

	## ④ 拖拽打出 → **原地**淡出（不位移），且从松手的地方开始淡、不是从槽位
	hand.sync(3, Vector2.INF, names)
	var dropped: Control = hand._cards[1]
	dropped.position = Vector2(500, 150)      ## 假装被拖到棋盘中间松手了
	hand._hint_exit("乳酸酸化", CWHand.Exit.FADE)
	hand.sync(2, Vector2.INF, PackedStringArray(["交叉呈递", "免疫增援"]))
	finish_exit(hand, dropped)
	check(dropped.position == Vector2(500, 150) and dropped.modulate.a < 0.02,
		"拖拽打出：停在松手处原地淡出（位置 %s 没动）" % str(dropped.position))

	## ⑤ 没有手势提示时（AI 打的、抽满弃牌等）退回原地淡出，不乱飞
	hand.sync(3, Vector2.INF, names)
	var y2: float = hand._cards[0].position.y
	var silent: Control = hand._cards[0]
	hand.sync(2, Vector2.INF, PackedStringArray(["乳酸酸化", "免疫增援"]))
	finish_exit(hand, silent)
	check(is_equal_approx(silent.position.y, y2), "没有手势提示 → 原地淡出，不上不下")

	## ⑥ 拆局时正在飞的卡也要收掉 —— 它们不在 _cards 里，clear() 那圈捞不着
	##    （细胞层踩过：补间活过拆局，跑进下一局继续把 alpha 拉回 0）
	hand.sync(3, Vector2.INF, names)
	hand._hint_exit("乳酸酸化", CWHand.Exit.UP)
	hand.sync(2, Vector2.INF, PackedStringArray(["交叉呈递", "免疫增援"]))
	check(not hand._flying.is_empty(), "确实有卡在飞")
	hand.clear()
	check(hand._flying.is_empty(), "clear() 把正在飞的卡也收干净了")
	hand.free()


## 把某张卡的离场补间一口气推到底。
## **不等真实时间**：无头下每帧 delta 不确定，靠 await 帧数会时绿时红。
## custom_step 推完后回调也跑了（queue_free 是延迟的，本帧内节点仍然可读）。
## 卡离开后剩下的卡下标前移，卡上的悬停 / 双击必须按「此刻的下标」找卡。
## 2026-09-03 队友报「鼠标放在最右侧卡牌上不会突出显示」：旧代码的闭包记着创建时的下标，
## 第 0 张打出后，最后一张拿越界下标去 _hover()，谁也不抬；中间的卡则抬起右边的邻居。
func t_hand_index_after_exit() -> void:
	print("[手牌下标：卡离开之后]")
	var hand := CWHand.new()
	root.add_child(hand)
	hand.sync(3, Vector2.INF, PackedStringArray(["交叉呈递", "乳酸酸化", "免疫增援"]))
	hand.sync(2, Vector2.INF, PackedStringArray(["乳酸酸化", "免疫增援"]))   ## 第 0 张走了，剩下两张各前移一位
	var last: Control = hand._cards[1]
	last.mouse_entered.emit()
	check(hand._hovered == 1 and last.z_index == 100, "最右那张悬停：按现在的下标 1 抬起（旧代码用创建时的 2 → 越界、不抬）")
	last.mouse_exited.emit()
	check(hand._hovered == -1, "移开：复位")
	hand._cards[0].mouse_entered.emit()
	check(hand._hovered == 0 and hand._cards[0].z_index == 100, "左边那张悬停：下标 0 抬起、不再抬邻居")
	hand._cards[0].mouse_exited.emit()
	var got := [""]
	hand.play_requested.connect(func(n: String) -> void: got[0] = n)
	var dc := InputEventMouseButton.new()
	dc.button_index = MOUSE_BUTTON_LEFT
	dc.pressed = true
	dc.double_click = true
	last.gui_input.emit(dc)
	check(got[0] == "免疫增援", "双击最右那张：打出的是它自己（得「%s」）" % got[0])
	## 悬停着的那张被打出：离场的节点不再发 mouse_exited，得替它报一次空串，
	## 否则详情框一直挂在屏幕上（2026-09-04 Kevin 截图）
	var hovers: Array = []
	hand.card_hovered.connect(func(n: String) -> void: hovers.append(n))
	hand._cards[0].mouse_entered.emit()
	check(hand._hovered == 0 and hovers == ["乳酸酸化"], "悬停第 0 张：报卡名")
	hand.sync(1, Vector2.INF, PackedStringArray(["免疫增援"]))   ## 停着的那张走了
	check(hand._hovered == -1 and hovers == ["乳酸酸化", ""], "它离场：报空串，详情框收起")
	hand._cards[0].mouse_entered.emit()
	hand.clear()
	check(hand._hovered == -1, "clear() 也复位悬停下标")
	hand.queue_free()


func finish_exit(hand: CWHand, card: Control) -> void:
	var tw: Tween = hand._tweens.get(card)
	if tw == null or not tw.is_valid():
		return
	tw.pause()
	tw.custom_step(CWHand.EXIT + 0.05)


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

	# ① 双击卡 → 高亮目标细胞所在格 → 点格 → 还原为对应选项下标
	var r1 := [-99]
	var run1 := func() -> void: r1[0] = await b.ask(areq)
	run1.call()
	hand.play_requested.emit("交叉呈递")
	await process_frame
	check(b.marks.size() == 1 and b.marks.has(tpos), "双击卡后高亮目标细胞所在格")
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

	# ② 目标态中途改双击另一张卡 → 换卡；无目标卡直接打出（2026-09-01 起没有确认拍了）
	var r2 := [-99]
	var run2 := func() -> void: r2[0] = await b.ask(areq)
	run2.call()
	hand.play_requested.emit("交叉呈递")
	await process_frame
	check(b.marks.has(tpos), "先双击有目标卡：进选目标态")
	hand.play_requested.emit("溶酶体强化")
	await process_frame
	check(b.marks.is_empty(), "换到无目标卡：不再高亮格子")
	check(r2[0] == 2, "无目标卡直接打出，不再补「确认打出」一拍")

	# ③ 右键双击 → 直接弃，不再走确认条（团队 2026-09-01）
	var r3 := [-99]
	var run3 := func() -> void: r3[0] = await b.ask(areq)
	run3.call()
	hand.discard_requested.emit("乳酸酸化")
	await process_frame
	check(r3[0] == 4, "右键双击 → 直接还原成那张卡的弃置选项下标")

	# ④ 打不出的卡：给解释，可就地弃置
	var r4 := [-99]
	var run4 := func() -> void: r4[0] = await b.ask(areq)
	run4.call()
	hand.play_requested.emit("永久样例")
	await process_frame
	await process_frame
	var last: Control = bar._row.get_child(bar._row.get_child_count() - 1)
	check(last.position.x + last.size.x <= 674.0,
		"让位形态下按钮不越过底条右缘（不会藏进右侧竖条底下）")
	bar.chosen.emit(0)                        ## 「弃置它」→ 和右键弃置同一条路 = 直接弃
	await process_frame
	check(r4[0] == 5, "「弃置它」直接弃（那条路 2026-09-01 起没有确认拍）")

	# ⑤ 取消回按钮栏，这一问还没答；手牌手势只在行动询问期间生效
	var r5 := [-99]
	var run5 := func() -> void: r5[0] = await b.ask(areq)
	run5.call()
	hand.play_requested.emit("交叉呈递")
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
	hand.play_requested.emit("交叉呈递")
	await process_frame
	hand.discard_requested.emit("乳酸酸化")
	await process_frame
	check(r5b[0] == -99 and b.marks.is_empty(), "目标态里右键双击卡 = 取消，不是弃那张")
	bar.chosen.emit(_buttons(bar) - 1)
	await process_frame
	check(r5b[0] == 6, "取消后仍能正常结束回合")

	## 原⑦⑧（双击打出 / 双击有目标卡）已被①②覆盖：双击成了唯一的打出手势之后，
	## 它们和①②是同一条路的同一组断言，留着只是把绿灯数灌水。2026-09-01 删。

	# ⑥ 卡控件的鼠标事件映射：**单击一律不发信号**，只有双击才发（团队 2026-09-01）
	var seen: Array = []
	hand.play_requested.connect(func(n: String) -> void: seen.append(["打出", n]))
	hand.discard_requested.connect(func(n: String) -> void: seen.append(["弃置", n]))
	var single_l := InputEventMouseButton.new()
	single_l.pressed = true
	single_l.button_index = MOUSE_BUTTON_LEFT
	hand._cards[0].gui_input.emit(single_l)
	var single_r := InputEventMouseButton.new()
	single_r.pressed = true
	single_r.button_index = MOUSE_BUTTON_RIGHT
	hand._cards[1].gui_input.emit(single_r)
	## 这一条是本次改动的**核心断言**：单击必须是彻底的哑火。
	## 如果哪天有人「顺手」把单击接回去，误触就会带着不可逆的弃牌一起回来
	check(seen.is_empty(), "左键单击、右键单击都不发任何手势信号")
	var double_l := InputEventMouseButton.new()
	double_l.pressed = true
	double_l.button_index = MOUSE_BUTTON_LEFT
	double_l.double_click = true
	hand._cards[0].gui_input.emit(double_l)
	var double_r := InputEventMouseButton.new()
	double_r.pressed = true
	double_r.button_index = MOUSE_BUTTON_RIGHT
	double_r.double_click = true
	hand._cards[1].gui_input.emit(double_r)
	check(seen == [["打出", "交叉呈递"], ["弃置", "乳酸酸化"]],
		"左键双击=打出、右键双击=弃置")

	# ⑨ 卡底那两行提示放得进 72px 的卡（2026-08-29 试玩报过「右键弃置」被裁掉）
	var note_w := 0.0
	for n in hand._cards[0].get_children():
		if n is Label and (n as Label).text.contains("双击"):
			note_w = maxf(note_w, CWHand.NAME_PAD + CWStyle.FONT.get_string_size(
				(n as Label).text, HORIZONTAL_ALIGNMENT_LEFT, -1, CWStyle.SIZE_LABEL).x)
	check(note_w > 0.0 and note_w <= CWHand.CARD.x,
		"操作提示不超出卡宽 72（实测 %.0f）" % note_w)

	# ⑩ 抽屉矩形：卡抬起后的顶边 428 就是上沿；左边到 0，往左拖出画布不算打出
	var dr := CWHand.drawer_rect(Vector2(960, 540))
	check(dr.position == Vector2(0, CWHand.REST_TOP - CWHand.LIFT) \
		and dr.end == Vector2(CWHand.LEFT + CWHand.SPAN, 540),
		"抽屉矩形 = %s" % str(dr))
	check(dr.has_point(Vector2(100, 500)) and not dr.has_point(Vector2(400, 200)) \
		and not dr.has_point(Vector2(500, 500)),
		"抽屉内外判定：手牌区内算内，棋盘上与行动栏都算外")

	# ⑪ 拖出抽屉松手 = 打出（团队 2026-09-01）。落点那格**不算**选中的目标，
	#    所以有目标的卡照旧要进选目标态、在棋盘上再点一次
	var r10 := [-99]
	var run10 := func() -> void: r10[0] = await b.ask(areq)
	run10.call()
	## 抓在卡面 (30,20) 处——**卡的局部坐标**，Godot 的 gui_input 就是这么给的
	_drag_card(hand, 0, Vector2(30, 20), Vector2(400, 200))
	await process_frame
	check(b.marks.has(tpos), "拖出抽屉 = 打出（有目标卡进选目标态，落点不算目标）")
	board.tile_clicked.emit(tpos)
	await process_frame
	check(r10[0] == 1, "再点目标格才结算")

	# ⑫ 拖出去又拖回来 = 反悔。判定在松手那一刻，所以这是白送的
	var r11 := [-99]
	var run11 := func() -> void: r11[0] = await b.ask(areq)
	run11.call()
	_drag_card(hand, 0, Vector2(30, 20), Vector2(90, 500))
	await process_frame
	check(r11[0] == -99 and b.marks.is_empty(), "拖回抽屉内松手：什么都没发生")
	bar.chosen.emit(_buttons(bar) - 1)        ## 结束回合，把这一问收掉
	await process_frame

	# ⑬ 拖动中卡要**跟在光标下**，而且不能跑出画布
	#    （2026-09-01 队友报的「拖动中卡牌消失」：按下走 gui_input 给的是卡局部坐标，
	#     移动走 _input 给的是画布坐标，头一版把两者当成同一个空间，卡被摆到 y=608）
	var grab := Vector2(30, 20)
	var down13 := InputEventMouseButton.new()
	down13.pressed = true
	down13.button_index = MOUSE_BUTTON_LEFT
	down13.position = grab                    ## 卡局部坐标
	hand._cards[0].gui_input.emit(down13)
	var seen_pos: Array = []
	for m in [Vector2(400, 200), Vector2(600, 80), Vector2(60, 500)]:
		var mv := InputEventMouseMotion.new()
		mv.position = m                       ## 画布坐标
		hand._input(mv)
		seen_pos.append(hand._cards[0].position)
	var want_pos: Array = [Vector2(370, 180), Vector2(570, 60), Vector2(30, 480)]
	check(seen_pos == want_pos, "卡精确跟在光标下（抓点保持不变）：%s" % str(seen_pos))
	var canvas := Rect2(Vector2.ZERO, CWView.screen_size())
	var outside: Array = []
	for p in seen_pos:
		if not canvas.has_point(p):
			outside.append(p)
	check(outside.is_empty(), "拖动中卡始终在画布内，不会消失（跑出去的：%s）" % str(outside))
	var up13 := InputEventMouseButton.new()
	up13.pressed = false
	up13.button_index = MOUSE_BUTTON_LEFT
	up13.position = Vector2(60, 500)          ## 收在抽屉内，别把这一问答掉
	hand._input(up13)
	await process_frame
	bar.chosen.emit(_buttons(bar) - 1)
	await process_frame

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
# ---- 团队 2026-09-05 第二批定案：有氧均分 / 坏死新效果 / 黏液加费 / 无氧回合末 / 骨肉瘤重做 ----
##
## 五条各自独立，但都是同一天拍的板、同一个提交落地，放一起好对照 PRD diff。
## 每条都钉**正反两面**（旋钮开 = 新规则、旋钮关 = 旧行为）：只钉一边的话，
## 把读取点删干净也照样绿。
func t_batch2_rules() -> void:
	print("[09-05 第二批：均分/坏死/黏液/回合末无氧/骨样硬化]")
	## ① 有氧按免疫细胞数均分（默认开）
	var g := bare_game()
	check(not g.tune.aerobic_split, "有氧不均分是默认（2026-09-05 方案 f：人数不对称改由分档基数补）")
	check(CWData.aerobic_level_base(4) == 20 and CWData.aerobic_level_base(6) == 18
		and CWData.aerobic_level_base(2) == 20 and CWData.aerobic_level_base(5) == CWData.AEROBIC_LEVEL_BASE,
		"有氧基数按人数分档：二人/四人 2.0、六人 1.8、表外人数回退")
	check(g.tune.aerobic_level_base == CWData.AEROBIC_LEVEL_BASE,
		"旋钮默认 = 固定基数 %s（Kevin 2026-09-07 换公式后不再按人数分档；-1 仍可扫回方案 f）"
			% CWData.fmt(CWData.AEROBIC_LEVEL_BASE))
	## 六人局引擎实算：默认已不按人数分档（2026-09-07），拨回 -1 才是方案 f 的 1.8
	var g6 := make_game(6, 1)
	g6.setup.build_board()
	var i6 := CWSetup.make_cell(g6.cells.size(), 0, CWData.Faction.IMMUNE, Vector2i.ZERO, CWData.ImmuneType.BASIC, -1)
	i6["energy"] = 0
	g6.cells.append(i6)
	g6.world._aerobic()
	check(i6["energy"] == CWData.AEROBIC_LEVEL_BASE,
		"六人局 I 级有氧 = 固定基数 %s（实得 %s）" % [CWData.fmt(CWData.AEROBIC_LEVEL_BASE), CWData.fmt(i6["energy"])])
	g6.tune.aerobic_level_base = -1
	i6["energy"] = 0
	g6.world._aerobic()
	check(i6["energy"] == 18, "abase=-1 扫回方案 f：六人局 1.8（实得 %s）" % CWData.fmt(i6["energy"]))
	g6.tune.aerobic_level_base = 25
	i6["energy"] = 0
	g6.world._aerobic()
	check(i6["energy"] == 25, "abase=25 整体覆盖 → 2.5")
	g6.dispose()
	var imms: Array = []
	for i in 3:
		var c := CWSetup.make_cell(g.cells.size(), 0, CWData.Faction.IMMUNE, Vector2i(i, 0),
			CWData.ImmuneType.BASIC, -1)
		c["energy"] = 0
		g.cells.append(c)
		imms.append(c)
	g.tune.aerobic_split = true      ## 验机制本身，不管默认值是开是关
	g.world._aerobic()
	## 按 ref 个免疫细胞的量标定：3 个人分 ref 份，四舍五入。**按常量算**，基数改了这里不用跟。
	## 低保夹在基准上而不是每人份额上 —— 反过来这里会被低保顶回去（09-05 抓到的 bug）
	var B: int = CWData.AEROBIC_LEVEL_BASE
	var ref: int = CWData.AEROBIC_SPLIT_REF
	var three: int = (2 * B * ref + 3) / (2 * 3)
	check(imms[0]["energy"] == three and imms[2]["energy"] == three,
		"3 个免疫：%s×%d ÷ 3 = %s（实得 %s；低保没把它顶回去）" % [
			CWData.fmt(B), ref, CWData.fmt(three), CWData.fmt(imms[0]["energy"])])
	check(g.world._split_aerobic(B, 2) == B and g.world._split_aerobic(B, 1) == B,
		"≤%d 个免疫：每人全额 %s（二人/四人局手感不变）" % [ref, CWData.fmt(B)])
	g.tune.aerobic_split_ref = 0
	check(g.world._split_aerobic(B, 3) == (2 * B + 3) / (2 * 3),
		"asplitref=0：纯 %s ÷ 3 = %s（甲读法，数据上已排除）" % [CWData.fmt(B), CWData.fmt((2 * B + 3) / 6)])
	g.tune.aerobic_split_ref = CWData.AEROBIC_SPLIT_REF
	g.tune.aerobic_split = false
	for c in imms:
		c["energy"] = 0
	g.world._aerobic()
	check(imms[0]["energy"] == B, "asplit=0：每人全额 %s" % CWData.fmt(B))
	g.dispose()

	## ② 坏死：站在坏死格上的免疫这一回合有氧打折（Kevin 2026-09-07 两次改口，最终是**减半**）
	g = bare_game()
	var im := put_immune(g, Vector2i.ZERO)
	im["energy"] = 0
	g.tiles[Vector2i.ZERO]["necrosis"] = CWData.NECROSIS_TOXIN
	g.world._aerobic()
	var cut: int = CWData.AEROBIC_LEVEL_BASE * CWData.NECROSIS_AEROBIC_PCT / 100
	check(im["energy"] == cut, "站在坏死格上：只拿 %d%%（%s）" % [CWData.NECROSIS_AEROBIC_PCT, CWData.fmt(cut)])
	check(CWData.NECROSIS_AEROBIC_PCT == 50, "现行是五折（线上版 PRD：坏死格有氧减半）")
	im["energy"] = 0
	g.tune.necrosis_aerobic_pct = 0
	g.world._aerobic()
	check(im["energy"] == 0, "necro=0：扫回「一份不给」（09-05~09-07 的行为）")
	im["energy"] = 0
	g.tune.necrosis_aerobic_pct = 100
	g.world._aerobic()
	check(im["energy"] == CWData.AEROBIC_LEVEL_BASE, "necro=100：坏死无影响，照拿 %s" % CWData.fmt(CWData.AEROBIC_LEVEL_BASE))
	g.dispose()

	## ③ 黏液：免疫踏进黏液格迁移 +0.5；癌细胞不受影响；旋钮 0 关
	g = bare_game()
	var im2 := put_immune(g, Vector2i.ZERO)
	var to := Vector2i(1, 0)
	var base: int = g.actions._move_base_cost(im2, to)
	var plain: int = g.actions._move_cost_mod(im2, to, base)
	g.tiles[to]["mucus"] = true
	check(g.actions._move_cost_mod(im2, to, base) == plain + CWData.MUCUS_MOVE_SURCHARGE,
		"免疫踏进黏液格：迁移 %s → %s（+0.5）" % [CWData.fmt(plain), CWData.fmt(plain + CWData.MUCUS_MOVE_SURCHARGE)])
	g.tune.mucus_move_surcharge = 0
	check(g.actions._move_cost_mod(im2, to, base) == plain, "mucusfee=0：不加费")
	g.tune.mucus_move_surcharge = CWData.MUCUS_MOVE_SURCHARGE
	var ca := CWSetup.make_cell(g.cells.size(), 1, CWData.Faction.CANCER, Vector2i(2, 0), -1,
		CWData.CancerType.MELANOMA)
	g.cells.append(ca)
	var cb: int = g.actions._move_base_cost(ca, to)
	var with_mucus: int = g.actions._move_cost_mod(ca, to, cb)
	g.tiles[to]["mucus"] = false
	check(g.actions._move_cost_mod(ca, to, cb) == with_mucus, "癌细胞进黏液格：不加费（只罚免疫）")
	g.dispose()

	## ④ 无氧的结算时机：默认 E 阶段统一算（Kevin 2026-09-06 改回）；拨 eturn=1 改在癌细胞自己的回合末、E 阶段不再重复算
	g = bare_game()
	var ca2 := CWSetup.make_cell(g.cells.size(), 1, CWData.Faction.CANCER, Vector2i.ZERO, -1,
		CWData.CancerType.MELANOMA)
	ca2["energy"] = 0
	g.cells.append(ca2)
	g.tiles[Vector2i.ZERO]["tissue"] = CWData.Tissue.CANCER
	for d in CWData.DIRS:
		g.tiles[Vector2i.ZERO + d]["tissue"] = CWData.Tissue.CANCER
	var expect: int = g.world.anaerobic_gain_for(ca2)
	check(expect == _share(_pool_of(7, 0), 1), "7 格块独占：%.1f 十分（实得 %s）" % [_pool_of(7, 0), CWData.fmt(expect)])
	check(not g.tune.anaerobic_on_turn_end, "默认 E 阶段统一结算（Kevin 2026-09-06 改回；09-05 曾默认回合末）")
	g._end_turn(1, ca2)
	check(ca2["energy"] == 0, "默认：回合末不进账")
	await g.world.e_phase()
	## E 阶段第 2~3 步的【增生】【侵蚀】可能先把块铺大，第 4 步按铺大后的块算 —— 拿结算后的块大小对
	## （盘上只有这一块，增生 / 侵蚀出来的格都贴着它）
	var n_after: int = g.count_tissue(CWData.Tissue.CANCER) + g.count_tissue(CWData.Tissue.SOLID)
	check(ca2["energy"] > 0 and ca2["energy"] == _share(_pool_of(n_after, 0), 1),
		"默认：E 阶段一次算，进账 %.1f 十分（实得 %s）" % [_pool_of(n_after, 0), CWData.fmt(ca2["energy"])])
	g.tune.anaerobic_on_turn_end = true
	ca2["energy"] = 0
	var expect_turn: int = g.world.anaerobic_gain_for(ca2)
	g._end_turn(1, ca2)
	check(expect_turn > 0 and ca2["energy"] == expect_turn, "eturn=1：癌细胞回合末进账 %s" % CWData.fmt(expect_turn))
	ca2["energy"] = 0
	await g.world.e_phase()
	check(ca2["energy"] == 0, "eturn=1：E 阶段不再算第二遍")
	g.dispose()

	## ⑤ 骨肉瘤【骨样硬化】重做：花 2.0 标记脚下，2 回合后固化
	g = bare_game()
	g.round_no = 3
	var ost := CWSetup.make_cell(g.cells.size(), 1, CWData.Faction.CANCER, Vector2i.ZERO, -1,
		CWData.CancerType.OSTEO)
	ost["energy"] = 50
	g.cells.append(ost)
	g.tiles[Vector2i.ZERO]["tissue"] = CWData.Tissue.CANCER
	check("ossify" in g.actions.action_kinds(ost), "骨肉瘤的行动栏有【骨样硬化】")
	var mel := CWSetup.make_cell(g.cells.size(), 1, CWData.Faction.CANCER, Vector2i(3, 0), -1,
		CWData.CancerType.MELANOMA)
	g.cells.append(mel)
	check(not "ossify" in g.actions.action_kinds(mel), "别的癌种没有")
	check(_has_act(g.actions.build_options(ost), "ossify"), "脚下是普通癌组织、能付 2.0 → 选项出现")
	await g.actions.execute(ost, { "act": "ossify" })
	check(ost["energy"] == 50 - CWData.OSTEO_OSSIFY_COST, "花了 2.0")
	check(int(g.tiles[Vector2i.ZERO]["ossify_at"]) == 5, "标记：第 3 + 2 = 5 回合固化")
	check(not _has_act(g.actions.build_options(ost), "ossify"), "已标记的格不能再标")
	g.round_no = 4
	g.world._ossify()
	check(g.tiles[Vector2i.ZERO]["tissue"] == CWData.Tissue.CANCER, "第 4 回合：还没到期")
	g.round_no = 5
	g.world._ossify()
	check(g.tiles[Vector2i.ZERO]["tissue"] == CWData.Tissue.SOLID, "第 5 回合 E 阶段：转为固化癌组织")
	check(int(g.tiles[Vector2i.ZERO]["ossify_at"]) == 0, "转化后标记清掉")
	g.dispose()

	## ⑥ 免疫蹲守：踏进标记格不立刻净化，下一回合 S 阶段兑现；挪窝作废；到期回合才进来就晚了
	g = bare_game()
	g.round_no = 3
	var z := Vector2i.ZERO
	g.tiles[z]["tissue"] = CWData.Tissue.CANCER
	g.tiles[z]["ossify_at"] = 5
	var imm := put_immune(g, Vector2i(1, 0))
	var mem0: int = g.memory
	await g.actions.enter_tile(imm, z)
	check(g.tiles[z]["tissue"] == CWData.Tissue.CANCER, "踏进标记格：没有立刻净化")
	check(int(imm["camp_round"]) == 3 and imm["camp_pos"] == z, "登记蹲守")
	g.round_no = 4
	await g.world._resolve_camping()
	check(g.tiles[z]["tissue"] == CWData.Tissue.HEALTHY, "下一回合 S 阶段：蹲满一回合，净化完成")
	check(g.memory == mem0 + 1, "净化照常 +1 抗原记忆")
	check(int(g.tiles[z]["ossify_at"]) == 0 and int(imm["camp_round"]) == -1, "标记随净化取消、蹲守清零")
	g.round_no = 5
	g.world._ossify()
	check(g.tiles[z]["tissue"] == CWData.Tissue.HEALTHY, "到期时已被净化：不再固化")
	## 挪窝作废
	g.tiles[z]["tissue"] = CWData.Tissue.CANCER
	g.tiles[z]["ossify_at"] = 7
	await g.actions.enter_tile(imm, z)
	await g.actions.enter_tile(imm, Vector2i(1, 0))
	check(int(imm["camp_round"]) == -1, "挪窝：蹲守作废")
	await g.world._resolve_camping()
	check(g.tiles[z]["tissue"] == CWData.Tissue.CANCER, "没蹲满：不净化")
	## 到期那一回合才进来：E 阶段照样固化，蹲守落空
	g.round_no = 7
	await g.actions.enter_tile(imm, z)
	g.world._ossify()
	check(g.tiles[z]["tissue"] == CWData.Tissue.SOLID, "到期回合才进来：E 阶段照样固化")
	g.round_no = 8
	await g.world._resolve_camping()
	check(g.tiles[z]["tissue"] == CWData.Tissue.SOLID and int(imm["camp_round"]) == -1,
		"已固化：蹲守作废、不净化（窗口只有标记后的那一整轮）")
	g.dispose()


## 无氧的供能池（十分能量，浮点；口径同 CWWorld._anaerobic_pool，按当前默认值算）。
## 测试**不许**把结果写死成数字 —— 三个数都是旋钮，改一次不该让十几条断言跟着改。
## `n_players` 不能省：系数 2026-09-07 起**按人数分档**（四人 2.0 / 六人 2.8），
## 拿默认的 2 人去算四人局的期望值会差 40%（当天就这么红过一次）。
static func _pool_of(plain: int, solid_all: int, n_players := 2) -> float:
	var term := pow(float(plain), CWData.ANAEROBIC_BLOCK_EXP / 100.0) if plain > 0 else 0.0
	var solid_part := float(solid_all * CWData.ANAEROBIC_SOLID_BONUS)
	return term * float(CWData.anaerobic_block_coef(n_players)) + solid_part


## 池子按 k 个癌细胞均分，四舍五入到十分位（口径同 CWWorld._split_share）
static func _share(pool: float, k: int) -> int:
	return int(round(pool / float(k)))


## 选项里有没有指向某一格的目标（卡牌选项把目标放在 data["to"]）
static func _has_target(opts: Array, at: Vector2i) -> bool:
	for o in opts:
		if o["data"].get("to") == at:
			return true
	return false


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

	## ① 语义阶段下，「改为 X」（阶段③）恒在「-X」（阶段⑤）之前 —— 打出顺序不再影响结果
	for order in [["组织巡航_先", "炎症趋化_后"], ["炎症趋化_先", "组织巡航_后"]]:
		var g := bare_game()
		g.tiles[canc]["tissue"] = CWData.Tissue.CANCER
		var cell := put_immune(g, Vector2i.ZERO)
		if order[0].begins_with("组织巡航"):
			put_skill(cell, "组织巡航")
			g.add_mod(cell, "炎症趋化", 1, "turn")
		else:
			g.add_mod(cell, "炎症趋化", 1, "turn")
			put_skill(cell, "组织巡航")
		check(g.actions._move_cost_mod(cell, canc, 10) == 0,
			"语义阶段：免费豁免（阶段⑨）盖过「改为 0.5」（阶段③），%s → 0" % order[0])
		g.dispose()

	## ② 「改为」不再能抬价：它只看基准值，抬不动已经更便宜的价钱
	##（这一条正是旧定案 A 的立意，随语义阶段一并作废）
	var g2 := bare_game()
	g2.tiles[canc]["tissue"] = CWData.Tissue.CANCER
	var c2 := put_immune(g2, Vector2i.ZERO)
	g2.add_mod(c2, "炎症趋化", 1, "turn")
	g2.add_mod(c2, "CXCR3趋化", 2, "turn")
	check(g2.actions._move_cost_mod(c2, canc, 10) == CWData.MOVE_CUT_MIN,
		"改为 0.5 → −0.5 → 踩下限 0.2（改为恒在减费之前）")
	g2.dispose()

	## ③ ON_BENEFIT：基准价本来就是 0.5 时，「改为 0.5」什么也没干 → 不消耗
	## 2026-09-03 定案 ② 后 X 级默认 0.7，没有哪一档天然是 0.5 了 —— 显式把 X 级拨回 PRD 的 0.5，测的仍是同一条语义
	var g3 := bare_game()
	g3.immune_level = 3
	g3.tune.immune_move_cancerous[3] = 5      ## X 级向癌性组织的基准价拨成 0.5
	g3.tiles[canc]["tissue"] = CWData.Tissue.CANCER
	var c3 := put_immune(g3, Vector2i.ZERO)
	g3.add_mod(c3, "炎症趋化", 1, "turn")
	check(g3.actions._move_cost_mod(c3, canc, g3.actions._move_base_cost(c3, canc))
		== CWData.INFLAM_CHEMO_COST, "X 级：改为 0.5 = 没变")
	await g3.actions._do_move(c3, canc, CWData.INFLAM_CHEMO_COST)
	check(g3.mods_of(c3, "炎症趋化").size() == 1,
		"ON_BENEFIT：没改变费用就不消耗（设计 §七.3）")
	g3.dispose()

	## ④ 不适用就更不消耗：【炎症趋化】只管向癌性组织的迁移
	var g4 := bare_game()
	var c4 := put_immune(g4, Vector2i.ZERO)
	g4.add_mod(c4, "炎症趋化", 1, "turn")
	await g4.actions._do_move(c4, Vector2i(1, 0), 5)   ## (1,0) 是健康组织
	check(g4.mods_of(c4, "炎症趋化").size() == 1, "目的地不对 → 不适用 → 不消耗")
	g4.dispose()


## 定案 D（乙案，Kevin 2026-08-30）：**免费额度省，限次折扣不省**。
## 把费用变 0 的那几条（组织巡航首移 / 组织驻留 / 癌症干性 / 迁移激活）在这一次
## 本来就免费时不消耗；限次折扣与改写类照旧按目的地谓词消耗，哪怕一分钱没减到。
func _t_ruling_d_keep_allowance() -> void:
	var base_h: int = 5      ## 免疫向健康组织的基准价 0.5
	var canc := Vector2i(1, 0)

	## ① 一次移动最多消耗一个免费额度；谁先被选中按**打出/装备先后**
	##（队友 2026-08-30 答复 c：「按方便记忆可沿用打出先后顺序」，
	## 覆盖了设计 §九「适用范围更窄者优先」的原文）
	var g := bare_game()
	var cell := put_immune(g, Vector2i.ZERO)
	put_skill(cell, "组织驻留")     ## 先装的先用
	put_skill(cell, "组织巡航")
	check(g.actions._move_cost_mod(cell, Vector2i(1, 0), base_h) == 0, "首移→健康免费")
	await g.actions._do_move(cell, Vector2i(1, 0), 0)
	check(cell["fx_turn"].has("组织驻留"), "先装的【组织驻留】先被豁免")
	check(not cell["fx_turn"].has("组织巡航"), "一次只消耗一个额度，【组织巡航】保留")

	## ② 【组织驻留】2026-09-01 起是**前两次**，所以第二次仍然由它出，巡航还没轮到
	check(g.actions._move_cost_mod(cell, Vector2i(2, 0), base_h) == 0, "第二次仍免费")
	await g.actions._do_move(cell, Vector2i(2, 0), 0)
	check(cell["fx_turn"]["组织驻留"] == 2, "两次都记在【组织驻留】头上")
	check(not cell["fx_turn"].has("组织巡航"), "驻留额度没用完，【组织巡航】不动")

	## ③ 驻留两次用尽，第三次才轮到巡航
	check(g.actions._move_cost_mod(cell, Vector2i(3, 0), base_h) == 0, "第三次仍免费（轮到巡航）")
	await g.actions._do_move(cell, Vector2i(3, 0), 0)
	check(cell["fx_turn"].has("组织巡航"), "这一次才轮到【组织巡航】")

	## ④ 巡航的「后续 −0.2」只在它的免费额度**用掉之后**才开始（设计 §九.2）
	check(g.actions._move_cost_mod(cell, Vector2i(4, 0), base_h)
		== maxi(base_h - CWData.CRUISE_CUT, CWData.MOVE_CUT_MIN),
		"三个额度都用尽后，只剩【组织巡航】的 −0.2")
	g.dispose()

	## ④ 向**非健康**组织时【组织驻留】不适用，直接由【组织巡航】豁免（设计 §九.2）
	var g2 := bare_game()
	g2.tiles[canc]["tissue"] = CWData.Tissue.CANCER
	var c2 := put_immune(g2, Vector2i.ZERO)
	put_skill(c2, "组织巡航")
	put_skill(c2, "组织驻留")
	await g2.actions._do_move(c2, canc, 0)
	check(c2["fx_turn"].has("组织巡航"), "向癌性组织：巡航豁免")
	check(not c2["fx_turn"].has("组织驻留"), "向癌性组织：驻留不适用，额度仍在")
	g2.dispose()

	## ⑤ 【迁移激活】适用范围最宽，排在细胞自己的额度之后（spec=0）
	var g3 := bare_game()
	var c3 := put_immune(g3, Vector2i.ZERO)
	put_skill(c3, "组织巡航")
	g3.events["active"].append({ "name": "迁移激活", "left": 2, "stacks": 1, "data": {} })
	await g3.actions._do_move(c3, Vector2i(1, 0), 0)
	check(c3["fx_turn"].has("组织巡航"), "细胞自己的额度先用")
	check(g3.world_fx.free_move_available(c3), "【迁移激活】的额度保留，记为适用但未消耗")
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
	## 【免疫抑制因子】2026-09-08 随 PRD 删除后，**眼下没有任何世界事件伤害癌细胞**，
	## 这条于是从「守一条活路径」变成「守一条契约」：减免不限来源，
	## 下一个这类事件加进来时不该再踩一次「只挂 immune_hit」的坑（2026-08-30 那次审查）。
	check(g.cancer_hit(sig, 5, "世界事件") == 0,
		"B：非 immune_hit 来路的 0.5 也被【囊性护甲】挡下（旧版挡不住）")
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
	## 2026-09-04：树突【各司其职】改成「不能移向癌细胞占据的格」，攻不了了 ——
	## 这条回归查的是「打死目标也算攻过、额度照扣」的**演出与额度**，与细胞种类无关，
	## 所以换成巨噬来攻，【抗原呈递强化】的额度逻辑照旧
	var dc := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i.ZERO,
		CWData.ImmuneType.MACRO, -1, 200)
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


# ---- 2026-08-30 审查问题 2 / 3 的回归 ----
## 两条都是**纯工程缺陷**（不含规则内容），也都是「不写断言就会悄悄回退」的类型。
func t_review_fixes() -> void:
	print("[审查问题 2/3 回归]")
	_t_hash_knows_play_order()
	await _t_no_fake_double_trigger()


## 问题 2：state_hash 必须认得出「打出先后」。
## #73 之后 seq / equip_seq 是规则相关数据（移动费链按它排序），
## 少了它，两个**结算结果不同**的局面会算出同一个哈希 —— 确定性回放校验就漏判了。
func _t_hash_knows_play_order() -> void:
	var canc := Vector2i(1, 0)

	## 语义阶段落地后，打出先后**不再改变移动费**（见 _t_ruling_a_rewrite），
	## 但 applied_seq 仍是对局状态的一部分，设计 §六 明写它必须进快照与 state_hash()。
	## 少了它，「先装巡航后打趋化」和反过来会被认成同一个局面 ——
	## 将来任何按 applied_seq 平局的效果（同阶段同来源）都会失去确定性保障。
	var a := bare_game()
	a.tiles[canc]["tissue"] = CWData.Tissue.CANCER
	var ca := put_immune(a, Vector2i.ZERO)
	put_skill(ca, "组织巡航")
	a.add_mod(ca, "炎症趋化", 1, "turn")

	var b := bare_game()
	b.tiles[canc]["tissue"] = CWData.Tissue.CANCER
	var cb := put_immune(b, Vector2i.ZERO)
	b.add_mod(cb, "炎症趋化", 1, "turn")
	put_skill(cb, "组织巡航")

	check(a.actions._move_cost_mod(ca, canc, 10) == b.actions._move_cost_mod(cb, canc, 10),
		"语义阶段：只差打出顺序的两个局面，移动费相同")
	check(a.state_hash() != b.state_hash(),
		"但 applied_seq 进了 state_hash，两个局面仍可区分（设计 §六）")
	a.dispose()
	b.dispose()

	## 反面：完全一样的两个局面，哈希还是得一样（别把哈希写成每次都不同）
	var c := bare_game()
	c.tiles[canc]["tissue"] = CWData.Tissue.CANCER
	var cc := put_immune(c, Vector2i.ZERO)
	put_skill(cc, "组织巡航")
	c.add_mod(cc, "炎症趋化", 1, "turn")
	check(a_hash_of(c) == a_hash_of(c), "同一局面两次取哈希一致")
	c.dispose()


func a_hash_of(g: CWGame) -> String:
	return g.state_hash()


## 问题 3：卡牌挂到 events["active"] 的全局条目，不能被当成「本回合类世界事件」重演。
## 【TGF-β释放】left=2（要活到下个 S 阶段的有氧结算）、不在 DURATION 表里，
## 旧版每次都会喊一句根本没发生过的「双重触发」。
func _t_no_fake_double_trigger() -> void:
	var g := bare_game()
	g.install_event("TGF-β释放", 2)
	var n0: int = g.logs.size()
	await g.world_fx.on_round_start()
	var faked := false
	for i in range(n0, g.logs.size()):
		if "双重触发" in g.logs[i]:
			faked = true
	check(not faked, "问题 3：打出【TGF-β释放】后，下个回合开头不得出现「双重触发」")
	check(not g.world_fx.is_world_event({ "name": "TGF-β释放" }),
		"卡牌挂的条目不算世界事件")
	check(g.world_fx.is_world_event({ "name": "基质阻隔" }), "世界事件仍认得出来")
	g.dispose()

	## 真被【双重触发】加倍的本回合类**世界事件**，仍要照常重演
	var g2 := bare_game()
	g2.events["active"].append({ "name": "增殖抑制", "left": 2, "stacks": 1, "data": {} })
	var n1: int = g2.logs.size()
	await g2.world_fx.on_round_start()
	var replayed := false
	for i in range(n1, g2.logs.size()):
		if "双重触发" in g2.logs[i]:
			replayed = true
	check(replayed, "真的世界事件被加倍时，第二回合仍照常重演（别把修复做过头）")
	g2.dispose()


# ---- 伤害结算系统（按队友《攻击与伤害结算系统设计》，口径 #80）----
## 这一组盯的是**事件化管线本身**：actual 与理论伤害的区别、ON_BENEFIT、
## 整批同时结算、UNPREVENTABLE 不绕过死亡检查、斩杀走 LethalEvent。
func t_damage_pipeline() -> void:
	print("[伤害结算系统]")
	_t_dmg_actual_not_theoretical()
	_t_dmg_shield_on_benefit()
	await _t_dmg_execute_needs_real_damage()
	await _t_dmg_unpreventable_still_dies()


## 设计 §4.2 / §6.1：吸血与「造成 X 伤害后」读 `actual`（目标**实际失去**多少），
## 不读理论伤害。2026-08-30 的全量审查漏掉了这条，是队友的设计文档抓出来的。
func _t_dmg_actual_not_theoretical() -> void:
	var g := bare_game()
	var mac := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i.ZERO,
		CWData.ImmuneType.MACRO, -1, 100)
	g.cells.append(mac)
	var t := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(1, 0),
		-1, CWData.CancerType.SCLC, 5)      ## 结算前只剩 0.5
	t["marked"] = true
	t["mark_left"] = 1
	g.cells.append(t)
	var before: int = mac["energy"]
	## 理论伤害 = 2.0 ×2(标记) = 4.0，但目标只有 0.5 可失去
	check(g.immune_hit(t, 20, mac, true) == 5, "immune_hit 返回实际损失 0.5，不是理论的 4.0")
	check(mac["energy"] - before == 10,
		"巨噬【吞噬】按实际损失回 ⌈0.5÷2⌉ = 1.0（旧版按理论伤害回 2.0）")
	g.dispose()


## 设计 §5.4：一组减免没把伤害压低就不消耗。**与定案 #57 正交** ——
## #57 管的是「同名多条一起算」，这里管的是「这一组有没有起作用」。
func _t_dmg_shield_on_benefit() -> void:
	var g := bare_game()
	var imm := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(2, 0),
		CWData.ImmuneType.BASIC, -1, 100)
	g.cells.append(imm)
	g.add_mod(imm, "细胞膜修复", 1, "")        ## −1.5，一张就够挡下 0.5
	g.add_mod(imm, "I型干扰素", 1, "round")    ## −1.0，这一次没有可挡的了
	check(g.cancer_hit(imm, 5, "微环境压迫") == 0, "0.5 的压迫被完全挡下")
	check(g.mods_of(imm, "细胞膜修复").is_empty(), "起了作用的那面盾照常消耗")
	check(not g.mods_of(imm, "I型干扰素").is_empty(),
		"ON_BENEFIT：没起作用的盾留着（旧版会一起烧掉）")

	## 同名多条仍然一起算、一起消耗（定案 #57 不受影响）
	var g2 := bare_game()
	var i2 := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(2, 0),
		CWData.ImmuneType.BASIC, -1, 100)
	g2.cells.append(i2)
	g2.add_mod(i2, "细胞膜修复", 1, "")
	g2.add_mod(i2, "细胞膜修复", 1, "")
	check(g2.cancer_hit(i2, 40, "微环境压迫") == 10, "两张 −1.5 在同一次损失上减 3.0（#57）")
	check(g2.mods_of(i2, "细胞膜修复").is_empty(), "同名两条一起消耗（#57）")
	g.dispose()
	g2.dispose()


## 设计 §5.6：【吞噬体成熟】是**伤害后**斩杀 —— 本次**实际**造成损失才成立。
##
## 原来走的是【抗原丢失】把整个事件免疫掉那条路，那个世界事件 2026-09-08 随 PRD 删了。
## 换成**零伤害的攻击事件**：同样落在 `_queue_triggers` 的 `actual <= 0` 那道闸上，
## 而且是活路径 —— 减伤把伤害扣没、残血目标实际损失为 0 都会走到这里。
func _t_dmg_execute_needs_real_damage() -> void:
	var g := bare_game()
	var atk := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i.ZERO,
		CWData.ImmuneType.BASIC, -1, 200)
	atk["equipped"] = ["吞噬体成熟"]
	g.cells.append(atk)
	var v := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(1, 0),
		-1, CWData.CancerType.SCLC, 3)      ## 余 0.3，本来必被处决
	g.cells.append(v)
	g.tiles[Vector2i(1, 0)]["tissue"] = CWData.Tissue.CANCER
	var r: Array = g.damage.submit([g.damage.event(atk, v, 0, CWDamage.Kind.ATTACK,
		[CWDamage.Tag.IMMUNE, CWDamage.Tag.ATTACK], "攻击")])
	check(int(r[0]["actual"]) == 0, "场景：这一下实际造成 0 损失")
	check(v["alive"], "本次零伤害 → 不触发【吞噬体成熟】的斩杀（残血目标本该必死）")
	g.dispose()


## 设计 §6.4：「无视减伤」是带 UNPREVENTABLE 的伤害事件，只跳过数值减免，
## **不**跳过日志、BCL-2 与死亡检查。旧版直接扣能量，容易在重构中丢掉这条链。
func _t_dmg_unpreventable_still_dies() -> void:
	var g := bare_game()
	g.round_no = 1
	var tc := CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i.ZERO,
		CWData.ImmuneType.T_CELL, -1, 200)
	tc["equipped"] = ["细胞毒性增强"]
	g.cells.append(tc)
	var bv := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(1, 0),
		-1, CWData.CancerType.SCLC, 5)
	bv["equipped"] = ["BCL-2抗凋亡"]
	g.cells.append(bv)
	g.tiles[Vector2i(1, 0)]["tissue"] = CWData.Tissue.CANCER
	await g.actions._do_move(tc, Vector2i(1, 0), 0)
	check(not bv["equipped"].has("BCL-2抗凋亡"),
		"UNPREVENTABLE 的次级伤害仍然走死亡替代：BCL-2 被触发并弃置")
	g.dispose()


# ---- 2026-08-31 队友审查的两个问题 ----
## 问题 1：CWCost.commit() 要先复验行动合法性，失败时**什么都不能动**。
## 问题 2：范围伤害的 simultaneous_group 必须正确且真的参与调度。
func t_review_0831() -> void:
	print("[8-31 审查：提交复验 + 批次号]")
	await _t_commit_revalidates()
	await _t_damage_batching()


## 报告 §3.6：六条拒绝分支，每条都不许扣费/烧修饰/占闸门
func _t_commit_revalidates() -> void:
	var canc := Vector2i(1, 0)

	## ① 报价后行动者位置变了 → 上下文作废
	var g := bare_game()
	var cell := put_immune(g, Vector2i.ZERO)
	var ctx := CWCost.context(cell, CWCost.Action.MOVE, 5, Vector2i(1, 0), 0,
		func() -> bool: return g.actions._is_move_legal_now(cell, Vector2i(1, 0)))
	cell["pos"] = Vector2i(3, 0)          ## 别的效果把它挪走了
	var e0: int = cell["energy"]
	check(g.cost.commit(ctx).is_empty(), "①报价后位置变了：提交被拒")
	check(cell["energy"] == e0, "①被拒时不扣费")
	g.dispose()

	## ② 报价后目标格被占
	var g2 := bare_game()
	var c2 := put_immune(g2, Vector2i.ZERO)
	var ctx2 := CWCost.context(c2, CWCost.Action.MOVE, 5, Vector2i(1, 0), 0,
		func() -> bool: return g2.actions._is_move_legal_now(c2, Vector2i(1, 0)))
	put_immune(g2, Vector2i(1, 0))        ## 队友挤了进来
	var e2: int = c2["energy"]
	check(g2.cost.commit(ctx2).is_empty(), "②目标格被占：提交被拒")
	check(c2["energy"] == e2, "②被拒时不扣费")
	g2.dispose()

	## ③ 报价后攻击次数用尽（【刚性屏障】2026-09-01 改成减伤后，这是剩下的攻击合法性闸门）
	var g3 := bare_game()
	g3.tiles[canc]["tissue"] = CWData.Tissue.CANCER
	var c3 := put_immune(g3, Vector2i.ZERO)
	var osteo := CWSetup.make_cell(g3.cells.size(), 1, CWData.Faction.CANCER, canc,
		-1, CWData.CancerType.OSTEO, 100)
	g3.cells.append(osteo)
	check(g3.actions._is_move_legal_now(c3, canc), "③次数没用完时可以打")
	c3["attacks_used"] = g3.tune.attack_max_per_turn   ## 报价之后才用尽
	check(not g3.actions._is_move_legal_now(c3, canc), "③攻击次数用尽后不可攻击")
	var ctx3 := CWCost.context(c3, CWCost.Action.MOVE, 5, canc, 0,
		func() -> bool: return g3.actions._is_move_legal_now(c3, canc))
	var e3: int = c3["energy"]
	check(g3.cost.commit(ctx3).is_empty(), "③次数用尽：提交被拒")
	check(c3["energy"] == e3, "③被拒时不扣费")
	g3.dispose()

	## ④ 被拒时一次性额度与闸门都不能动
	var g4 := bare_game()
	var c4 := put_immune(g4, Vector2i.ZERO)
	put_skill(c4, "组织巡航")                 ## 首移免费的额度
	g4.add_mod(c4, "炎症趋化", 1, "turn")
	put_immune(g4, Vector2i(1, 0))           ## 目标格被占，这一步注定失败
	await g4.actions._do_move(c4, Vector2i(1, 0), 0)
	check(not c4["fx_turn"].has("组织巡航"), "④被拒时不占回合闸门")
	check(g4.mods_of(c4, "炎症趋化").size() == 1, "④被拒时不烧修饰")
	g4.dispose()

	## ⑤ 同一个旧选项重复提交：第二次必须被拒（位置已经变了）
	var g5 := bare_game()
	var c5 := put_immune(g5, Vector2i.ZERO)
	var to5 := Vector2i(1, 0)
	var mk := func() -> Dictionary:
		return CWCost.context(c5, CWCost.Action.MOVE, 5, to5, 0,
			func() -> bool: return g5.actions._is_move_legal_now(c5, to5))
	check(not g5.cost.commit(mk.call()).is_empty(), "⑤第一次提交成功")
	c5["pos"] = to5                          ## 动作层把它挪过去了
	var e5: int = c5["energy"]
	check(g5.cost.commit(mk.call()).is_empty(), "⑤同一旧选项重复提交被拒")
	check(c5["energy"] == e5, "⑤第二次不扣费")
	g5.dispose()

	## ⑥ 死了就什么都提交不了
	var g6 := bare_game()
	var c6 := put_immune(g6, Vector2i.ZERO)
	c6["alive"] = false
	check(g6.cost.commit(CWCost.context(c6, CWCost.Action.MOVE, 5, Vector2i(1, 0))).is_empty(),
		"⑥行动者已死：提交被拒")
	g6.dispose()


## 报告 §4.6：批次号正确、真的参与调度、且结果不依赖目标数组顺序
func _t_damage_batching() -> void:
	## ① 一次范围伤害的全部事件共享同一个**非零** group
	var g := bare_game()
	var atk := put_immune(g, Vector2i.ZERO)
	var victims: Array = []
	for i in 3:
		var v := CWSetup.make_cell(g.cells.size(), 1, CWData.Faction.CANCER,
			Vector2i(2 + i, 0), -1, CWData.CancerType.SCLC, 100)
		g.cells.append(v)
		victims.append(v)
	var res: Array = g.immune_hit_area(victims, 10, atk, "IFN-γ")
	var groups := {}
	for r in res:
		groups[int(r["event"]["simultaneous_group"])] = true
	check(groups.size() == 1, "①同一次范围伤害只有一个批次号")
	check(not groups.has(0), "①范围伤害的批次号非零")

	## ② 两次范围伤害拿到不同的 group
	var first: int = int(res[0]["event"]["simultaneous_group"])
	var res2: Array = g.immune_hit_area(victims, 10, atk, "IFN-γ")
	check(int(res2[0]["event"]["simultaneous_group"]) != first, "②两次范围伤害批次号不同")
	g.dispose()

	## ③ 同批目标数组倒序，最终状态与 state_hash() 必须一致
	var h_forward := _area_hash(false)
	var h_reverse := _area_hash(true)
	check(h_forward == h_reverse, "③同批目标数组倒序不改变 state_hash()")

	## ④ 单体伤害（group==0）各自独立成批：两条打同一目标时，
	##    第二条看得到第一条结算完的能量
	var g4 := bare_game()
	var a4 := put_immune(g4, Vector2i.ZERO)
	var t4 := CWSetup.make_cell(g4.cells.size(), 1, CWData.Faction.CANCER,
		Vector2i(2, 0), -1, CWData.CancerType.SCLC, 30)
	g4.cells.append(t4)
	var out: Array = g4.damage.submit([
		g4.damage.event(a4, t4, 10, CWDamage.Kind.CARD, [CWDamage.Tag.IMMUNE], "技能"),
		g4.damage.event(a4, t4, 10, CWDamage.Kind.CARD, [CWDamage.Tag.IMMUNE], "技能"),
	])
	check(int(out[0]["energy_before"]) == 30, "④未编组事件各自成批：第一条看到 3.0")
	check(int(out[1]["energy_before"]) == 20, "④第二条看到第一条扣完的 2.0")
	g4.dispose()


## 同一批范围伤害，正序与倒序打同一组目标，跑完后的全状态哈希应当一致
func _area_hash(reverse: bool) -> String:
	var g := bare_game()
	var atk := put_immune(g, Vector2i.ZERO)
	var victims: Array = []
	for i in 3:
		var v := CWSetup.make_cell(g.cells.size(), 1, CWData.Faction.CANCER,
			Vector2i(2 + i, 0), -1, CWData.CancerType.SCLC, 15 + i * 10)
		g.cells.append(v)
		victims.append(v)
	if reverse:
		victims.reverse()
	g.immune_hit_area(victims, 20, atk, "IFN-γ")
	var h := g.state_hash()
	g.dispose()
	return h


## 报告 §六.3：批量死亡分三遍走 + 伤后触发进稳定队列
## 免疫每行动回合的攻击次数上限（sug 2 的实验旋钮）。默认 0 = 不限，本测试自己开。
## 三条都要钉：**用完就没有攻击选项**、**别的迁移不受影响**、**回合开始重置**。
## 只钉第一条的话，把上限实现成「用完就一个选项都不给」也会绿 —— 那是另一个 bug。
func t_attack_cap() -> void:
	print("[攻击次数上限]")
	## 口径 #88：默认 3。这条单独钉住**默认值**——下面的用例自己开旋钮，
	## 不钉这一条的话把默认改回 0（无限攻击）也全绿。
	check(CWData.ATTACK_MAX_PER_TURN == 3, "默认每行动回合最多攻击 3 次")
	check(CWTuning.new().attack_max_per_turn == CWData.ATTACK_MAX_PER_TURN,
		"旋钮默认值 = 常量")
	var g := bare_game()
	g.tune.attack_max_per_turn = 1
	var imm := put_immune(g, Vector2i(0, 0))
	var can := _put_cancer(g, Vector2i(1, 0), 200)
	## (0,1) 留空做对照：攻击用完之后它必须还在
	var has_atk := func() -> bool:
		for o in g.actions.immune_move_options(imm):
			if o["data"]["to"] == Vector2i(1, 0):
				return true
		return false
	var has_move := func() -> bool:
		for o in g.actions.immune_move_options(imm):
			if o["data"]["to"] == Vector2i(0, 1):
				return true
		return false
	check(has_atk.call() and has_move.call(), "开局：攻击与普通迁移都在（前提成立）")
	var n0: int = g.logs.size()
	await g.actions._do_move(imm, Vector2i(1, 0), 0)
	check(imm["attacks_used"] == 1, "攻击发动即计数（不看判定结果，口径 #70）")
	## 用尽的那一刻必须报一声 —— 否则玩家只看到「刚才还能打的格子突然点不了了」
	check("
".join(g.logs.slice(n0)).contains("攻击次数已用尽"),
		"次数用尽时给出提示")
	check(not has_atk.call(), "用完次数：攻击选项消失")
	check(has_move.call(), "用完次数：普通迁移不受影响")
	## 合法性谓词是选项生成与提交复验共用的那一份（口径 #81），所以复验也该拒
	check(not g.actions._is_move_legal_now(imm, Vector2i(1, 0)),
		"用完次数：提交复验同样拒绝（与选项生成共用谓词）")
	g.turn.begin_turn(0, imm)
	check(imm["attacks_used"] == 0 and has_atk.call(), "新的行动回合重置，攻击又可选")
	## 0 = 不限：同一局面下连攻不该被挡
	g.tune.attack_max_per_turn = 0
	imm["attacks_used"] = 99
	check(has_atk.call(), "上限 0 = 不限，计数再高也不挡")
	## 不限时不该冒出「已用尽」这句话（提示自己也要吃旋钮）
	var n1: int = g.logs.size()
	await g.actions._do_move(imm, Vector2i(1, 0), 0)
	check(not "
".join(g.logs.slice(n1)).contains("攻击次数已用尽"),
		"上限 0 时不报「已用尽」")
	## 点不动的时候要说得出理由（团队 2026-09-01 要的弹窗，文案由引擎给，界面只负责弹）
	g.tune.attack_max_per_turn = 1
	imm["attacks_used"] = 1
	## 合法但付不起的一格：说清价钱与修正（2026-09-02 Kevin：「有能量为什么不能走癌组织」）
	var e0: int = imm["energy"]
	var far_c := Vector2i(0, 1)
	var far_was: int = g.tiles[far_c]["tissue"]
	g.tiles[far_c]["tissue"] = CWData.Tissue.CANCER
	imm["energy"] = g.tune.immune_move_cancerous[g.immune_level]   ## 正好等于价钱 → 付完剩 0，不合规
	var poor: String = g.actions.move_block_reason(imm, far_c)
	check(poor.contains("要 %s" % CWData.fmt(imm["energy"])) and poor.contains("留 0.1"),
		"账上正好等于价钱 → 解释「要 X，账上 X，付完至少留 0.1」：%s" % poor)
	## 2026-09-06 起【基质阻隔】只翻癌细胞：免疫的解释里不再出现它、价也不变；
	## 「点名修正与新价」这条路 2026-09-08 改拿【黏液侵染】（免疫踏进黏液格 +0.5）——
	## 原来用的【免疫抑制因子】随 PRD 删了，而删掉之后**没有任何世界事件抬高免疫的迁移费**，
	## 所以这条只能换成非世界事件的加价。要钉的意图没变：解释里点名修正、报出新价。
	g.events["active"].append({ "name": "基质阻隔", "left": 2, "stacks": 1, "data": {} })
	var same: String = g.actions.move_block_reason(imm, far_c)
	check(not same.contains("【基质阻隔】") and same.contains("要 %s" % CWData.fmt(imm["energy"])),
		"【基质阻隔】不翻免疫：解释不点名它、价照旧：%s" % same)
	g.events["active"].pop_back()
	g.tiles[far_c]["mucus"] = true
	var taxed: String = g.actions.move_block_reason(imm, far_c)
	check(taxed.contains("【黏液侵染】")
			and taxed.contains("要 %s" % CWData.fmt(imm["energy"] + g.tune.mucus_move_surcharge)),
		"【黏液侵染】加价后解释里点名修正与新价：%s" % taxed)
	g.tiles[far_c]["mucus"] = false
	imm["energy"] = e0
	g.tiles[far_c]["tissue"] = far_was
	var why: String = g.actions.move_block_reason(imm, Vector2i(1, 0))
	check(why.contains("攻击次数已用尽") and why.contains("1/1"), "点敌人格：说得出「次数用尽」")
	check(g.actions.move_block_reason(imm, Vector2i(0, 1)) == "",
		"点空地：本来就走得动，没什么可解释的")
	check(g.actions.move_block_reason(imm, Vector2i(4, 4)) == "",
		"点不相邻的格：不解释（一眼看得出）")
	imm["attacks_used"] = 0
	check(g.actions.move_block_reason(imm, Vector2i(1, 0)) == "",
		"次数还有：点敌人格不该弹理由")
	check(g.actions.move_block_reason(can, Vector2i(0, 0)) == "",
		"癌细胞没有攻击，不走这条解释")
	## 上限 3 时，第 2 次要报进度而不是报用尽
	g.tune.attack_max_per_turn = 3
	imm["attacks_used"] = 1
	var n2: int = g.logs.size()
	await g.actions._do_move(imm, Vector2i(1, 0), 0)
	var said: String = "
".join(g.logs.slice(n2))
	check(said.contains("第 2/3 次") and not said.contains("已用尽"),
		"没到上限时报进度「第 2/3 次」")
	g.dispose()


## 同阵营「可以穿过，但不能停留在这一格」（团队 2026-09-01 定案）。
## 一步一格的模型下，「穿过」= 一次【迁移】落在**正后方第二格**，收**两格之和**。
## 几何前提：A 和它正后方那格只有一个公共邻格（就是中间那格），所以友军堵住时
## 绕路要 3 步 —— 穿过收 2 格的钱仍然省一步，这是这条规则的价值所在。
func t_pass_through_ally() -> void:
	print("[穿过友军]")
	var g := bare_game()
	var me := put_immune(g, Vector2i(0, 0))
	var ally := put_immune(g, Vector2i(1, 0))
	var far := Vector2i(2, 0)
	var dests := func() -> Dictionary:
		var out := {}
		for o in g.actions.immune_move_options(me):
			out[o["data"]["to"]] = o
		return out

	## 前提：正后方那格与自己不相邻，且和自己只有「中间那格」一个公共邻格
	check(not (far in CWData.neighbors(Vector2i(0, 0))), "正后方第二格与自己不相邻")
	var shared := 0
	for n in CWData.neighbors(Vector2i(0, 0)):
		if n in CWData.neighbors(far):
			shared += 1
	check(shared == 1, "A 与正后方那格只有一个公共邻格（绕路要 3 步的由来）")

	var d: Dictionary = dests.call()
	check(not d.has(Vector2i(1, 0)), "友军所在格：仍然不能停留")
	check(d.has(far), "友军正后方那格：可以穿过去")
	check(d[far]["label"].begins_with("穿过"), "标签标成「穿过」，让玩家看得出为什么贵")
	## 两格都是健康组织 → 费用是单格的两倍
	var one: int = g.tune.immune_move_healthy[g.immune_level]
	check(d[far]["data"]["cost"] == one * 2, "费用 = 两格之和")
	check(g.actions.pass_through_mid(me, far) == Vector2i(1, 0), "中间格就是友军那格")
	## 落点是队友**周围一圈**，不限正后方（2026-09-01 Kevin 修订）。
	## 一个贴身友军实际开放 3 格：另外三格里一格是我自己、两格本来就和我相邻。
	var ring: Array = CWData.neighbors(Vector2i(1, 0))
	var opened := 0
	for c in ring:
		if c == Vector2i(0, 0):
			check(not d.has(c) or true, "队友环里有我自己那格")
			continue
		if c in CWData.neighbors(Vector2i(0, 0)):
			## 本来就相邻 → 走普通迁移，**不该**再出一个「穿过」选项（同一落点两个价）
			check(d.has(c) and not d[c]["label"].begins_with("穿过"),
				"%s 本来就相邻：仍是普通迁移，不重复出「穿过」" % str(c))
			continue
		check(d.has(c) and d[c]["label"].begins_with("穿过"), "%s 可以绕过去" % str(c))
		opened += 1
	check(opened == 3, "一个贴身友军开放 3 个新落点")
	## 绕到侧后方也照两格之和收费
	var side: Vector2i = Vector2i(2, -1)
	check(d[side]["data"]["cost"] == one * 2, "绕到侧后方：同样是两格之和")
	## 点了队友那格没反应时，要告诉玩家「该点它正后方那一格」—— 新规则得教一次
	var why: String = g.actions.move_block_reason(me, Vector2i(1, 0))
	check(why.contains("不能停留") and why.contains("穿过"), "点友军格：说清楚不能停但能穿")
	check(g.actions.move_block_reason(me, far) == "", "正后方那格本来就走得动，不解释")

	## 中间没人 → 不是「穿过」，正后方那格照旧到不了
	ally["pos"] = Vector2i(-1, 0)
	check(not dests.call().has(far), "中间空着：正后方那格到不了（穿过不是普通远程移动）")

	## 中间站的是**敌人** → 不能穿（那是攻击目标，攻击只能从相邻格发起）
	ally["alive"] = false
	var foe := _put_cancer(g, Vector2i(1, 0), 200)
	check(not dests.call().has(far), "中间是敌人：不能穿过去")
	check(g.actions.pass_through_mid(me, far) == Vector2i.MAX, "敌人不构成「穿过」的中间格")

	## 落点被占（哪怕是友军）→ 不能停
	foe["alive"] = false
	ally["alive"] = true
	ally["pos"] = Vector2i(1, 0)
	var third := put_immune(g, far)
	check(not dests.call().has(far), "落点站着人：不能停，所以也不能穿")
	third["alive"] = false

	## 落点出界 → 不可
	me["pos"] = Vector2i(5, 0)
	ally["pos"] = Vector2i(6, 0)
	check(not dests.call().has(Vector2i(7, 0)), "落点出界：不可")

	## 癌方同样适用（同阵营是对称的），且费用按各自组织类型分别计
	var g2 := bare_game()
	var c1 := _put_cancer(g2, Vector2i(0, 0), 200)
	_put_cancer(g2, Vector2i(1, 0), 200)
	g2.tiles[Vector2i(1, 0)]["tissue"] = CWData.Tissue.CANCER   ## 中间是癌组织（便宜）
	var opts2 := {}
	var tmp: Array = []
	g2.actions._cancer_options(c1, tmp)
	for o in tmp:
		if o["data"].get("act", "") == "move":
			opts2[o["data"]["to"]] = o
	check(opts2.has(far) and opts2[far]["label"].begins_with("穿过"), "癌方也能穿过同伴")
	## 小细胞肺癌走健康组织吃【极简胞浆】的折后价 —— 正好顺带钉住
	## 「两格各自走完整定价链」，而不是拿落点的价格 ×2
	check(opts2[far]["data"]["cost"]
			== g2.tune.cancer_move_cancerous + g2.tune.sclc_move_healthy,
		"癌方费用：中间癌组织 0.2 + 落点健康组织 0.7（极简胞浆），各按自己的类型算")
	g.dispose()
	g2.dispose()


func t_batch_death_and_triggers() -> void:
	print("[批量死亡与伤后触发队列]")

	## ① 同一批里两个目标同时被打死，BCL-2 在**批量宣死之前**统一替代
	var g := bare_game()
	var atk := put_immune(g, Vector2i.ZERO)
	var a := CWSetup.make_cell(g.cells.size(), 1, CWData.Faction.CANCER,
		Vector2i(2, 0), -1, CWData.CancerType.SCLC, 5)
	g.cells.append(a)
	## pid 只能取 0/1：bare_game() 是两人局，cell_name() 会拿它去索引 players
	var b := CWSetup.make_cell(g.cells.size(), 1, CWData.Faction.CANCER,
		Vector2i(3, 0), -1, CWData.CancerType.SCLC, 5)
	b["equipped"] = ["BCL-2抗凋亡"]
	g.cells.append(b)
	g.round_no = 1
	g.immune_hit_area([a, b], 30, atk, "IFN-γ")
	check(not a["alive"], "①没有免死的当场死亡")
	check(b["alive"] and b["energy"] == CWData.BCL2_ENERGY[0],
		"①带 BCL-2 的在批量宣死之前被替代救回")
	check(not ("BCL-2抗凋亡" in b["equipped"]), "①BCL-2 触发后本牌弃置")
	g.dispose()

	## ② 同一目标在一批里挨两下（主攻击 + 无视减伤的次级伤害）只死一次
	var g2 := bare_game()
	var s2 := put_immune(g2, Vector2i.ZERO)
	var t2 := CWSetup.make_cell(g2.cells.size(), 1, CWData.Faction.CANCER,
		Vector2i(2, 0), -1, CWData.CancerType.SCLC, 10)
	g2.cells.append(t2)
	var grp: int = g2.damage.next_group()
	var out: Array = g2.damage.submit([
		g2.damage.event(s2, t2, 30, CWDamage.Kind.ATTACK,
			[CWDamage.Tag.IMMUNE, CWDamage.Tag.ATTACK], "攻击", 0, grp),
		g2.damage.event(s2, t2, 10, CWDamage.Kind.ATTACK,
			[CWDamage.Tag.IMMUNE, CWDamage.Tag.ATTACK, CWDamage.Tag.UNPREVENTABLE],
			"细胞毒性增强", 0, grp),
	])
	var kills := 0
	for r in out:
		if r["killed"]:
			kills += 1
	check(not t2["alive"], "②目标死亡")
	check(kills == 1, "②同一目标在一批里只被宣死一次")
	g2.dispose()

	## ③ 触发队列顺序：【吞噬体成熟】的斩杀（造成伤害后）排在巨噬【吞噬】的吸血之前
	var g3 := bare_game()
	g3.tiles[Vector2i(1, 0)]["tissue"] = CWData.Tissue.CANCER
	var mac := CWSetup.make_cell(g3.cells.size(), 0, CWData.Faction.IMMUNE,
		Vector2i.ZERO, CWData.ImmuneType.MACRO, -1, 200)
	mac["equipped"] = ["吞噬体成熟"]
	g3.cells.append(mac)
	var prey := CWSetup.make_cell(g3.cells.size(), 1, CWData.Faction.CANCER,
		Vector2i(1, 0), -1, CWData.CancerType.SCLC,
		g3.tune.attack_dmg_success + 12)      ## 打完剩 1.2 ≤ 巨噬阈值 1.5
	g3.cells.append(prey)
	var n0: int = g3.logs.size()
	_rig_roll(g3, 6, [3])
	await g3.actions._do_move(mac, Vector2i(1, 0), 0)
	check(not prey["alive"], "③吞噬体成熟：余量过低，斩杀成立")
	var i_exec := -1
	var i_heal := -1
	for i in range(n0, g3.logs.size()):
		if "吞噬体成熟" in g3.logs[i] and i_exec < 0:
			i_exec = i
		if "吞噬" in g3.logs[i] and "恢复" in g3.logs[i] and "吞噬体成熟" not in g3.logs[i]:
			i_heal = i
	check(i_exec >= 0 and i_heal >= 0, "③两条触发都发生了")
	check(i_exec < i_heal, "③「造成伤害后」的斩杀排在「吸血」之前（设计 §5.7 的类别顺序）")
	g3.dispose()

	## ④ 攻击被完全减免时不该发生斩杀（本批 actual 为 0）
	var g4 := bare_game()
	g4.tiles[Vector2i(1, 0)]["tissue"] = CWData.Tissue.CANCER
	var m4 := CWSetup.make_cell(g4.cells.size(), 0, CWData.Faction.IMMUNE,
		Vector2i.ZERO, CWData.ImmuneType.MACRO, -1, 200)
	m4["equipped"] = ["吞噬体成熟"]
	g4.cells.append(m4)
	var p4 := CWSetup.make_cell(g4.cells.size(), 1, CWData.Faction.CANCER,
		Vector2i(1, 0), -1, CWData.CancerType.SCLC, 5)   ## 只剩 0.5，低于阈值
	g4.cells.append(p4)
	g4.damage.submit([g4.damage.event(m4, p4, 0, CWDamage.Kind.CARD,
		[CWDamage.Tag.IMMUNE], "技能")])
	check(p4["alive"], "④没造成实际伤害就不斩杀，哪怕余量早已低于阈值")
	g4.dispose()


## 两份设计文档自己列的「必要测试」里，此前只被间接覆盖或完全没写的那几条。
## 补齐的理由很简单：**没有断言盯着的行为，等于随时可以被下一次重构悄悄改掉**。
func t_design_required_checks() -> void:
	print("[设计文档要求的必要测试]")
	_t_cost_required()
	await _t_damage_required()


func _put_cancer(g: CWGame, at: Vector2i, energy: int,
		ctype: int = CWData.CancerType.SCLC) -> Dictionary:
	var c := CWSetup.make_cell(g.cells.size(), 1, CWData.Faction.CANCER, at, -1, ctype, energy)
	g.cells.append(c)
	return c


## 费用设计 §十一 的 1 / 4 / 5 / 10 / 11
func _t_cost_required() -> void:
	var canc := Vector2i(1, 0)

	## §十一.1 反复报价不改变快照与 state_hash（quote() 必须是纯查询）
	var g := bare_game()
	g.tiles[canc]["tissue"] = CWData.Tissue.CANCER
	var cell := put_immune(g, Vector2i.ZERO)
	put_skill(cell, "组织巡航")
	g.add_mod(cell, "炎症趋化", 1, "turn")
	var h0 := g.state_hash()
	var rng0 := g.rng.state
	var logs0: int = g.logs.size()
	for i in 50:
		g.actions._move_cost_mod(cell, canc, 10)
		g.actions._move_cost_mod(cell, Vector2i(0, 1), 5)
	check(g.state_hash() == h0, "§11.1 报价 100 次，state_hash 不变")
	check(g.rng.state == rng0, "§11.1 报价不消耗 rng")
	check(g.logs.size() == logs0, "§11.1 报价不写日志")
	check(g.mods_of(cell, "炎症趋化").size() == 1, "§11.1 报价不消耗修饰")
	check(not cell["fx_turn"].has("组织巡航"), "§11.1 报价不占回合闸门")
	g.dispose()

	## §十一.4 局部减费下限**可被免费覆盖**；行动硬下限**不可**
	var g2 := bare_game()
	g2.immune_level = 3                      ## X 级向癌性组织基准 0.8（2026-09-09 起与 III 级同值）
	g2.tiles[canc]["tissue"] = CWData.Tissue.CANCER
	var c2 := put_immune(g2, Vector2i.ZERO)
	## **两条**减免：0.8 − 0.5 − 0.5 = −0.2，被局部下限抬回 0.2。
	## 原来一条就够（X 级基准还是 0.5 时 0.5−0.5=0），2026-09-09 删掉 X 级的额外减免之后，
	## 癌性组织各档基准都 ≥ 0.8，单条 −0.5 落在 0.3 上、压根碰不到下限，这条断言就名不副实了。
	## 【CXCR3趋化】只对癌性组织生效（`to_cancerous`），所以不能改用健康组织来凑小基准。
	g2.add_mod(c2, "CXCR3趋化", 2, "turn")
	g2.add_mod(c2, "CXCR3趋化", 2, "turn")
	var base2: int = g2.actions._move_base_cost(c2, canc)
	check(g2.cost.quote(CWCost.context(c2, CWCost.Action.MOVE, base2, canc))["final"]
		== CWData.MOVE_CUT_MIN, "§11.4 只有减费时踩在局部下限 0.2 上")
	put_skill(c2, "组织巡航")                 ## 免费豁免在阶段⑨，排在减费之后
	check(g2.cost.quote(CWCost.context(c2, CWCost.Action.MOVE, base2, canc))["final"] == 0,
		"§11.4 免费可以把局部下限一路压到 0")
	## 行动硬下限压在免费之后，免费压不下去
	var q_hard := g2.cost.quote(CWCost.context(c2, CWCost.Action.MOVE, base2, canc, 3))
	check(int(q_hard["final"]) == 3, "§11.4 行动硬下限免费也豁免不掉")
	g2.dispose()

	## §十一.5「免费不豁免明写的附加支付」这一组 2026-09-08 删掉了：它唯一的数据来源是
	## 【免疫抑制因子】的净化费，那个世界事件随 PRD 删了，于是 Phase.SURCHARGE 层**一个条目都没有**，
	## 没法再用数据驱动地验它。管线那一层没拆（见 CWCost 世界事件段的注释），
	## **下一个用 SURCHARGE 的效果加进来时，把这一组按 git 历史补回来**（HEAD~ 的这个位置）。

	## §十一.10 同阶段同优先级：先按**来源**分层（卡牌 → 技能），再按 applied_seq。
	## 装备/打出顺序反过来，结果必须一样。
	var costs: Array = []
	for order in [0, 1]:
		var g4 := bare_game()
		g4.immune_level = 3
		g4.tiles[canc]["tissue"] = CWData.Tissue.CANCER
		var c4 := put_immune(g4, Vector2i.ZERO)
		if order == 0:
			g4.add_mod(c4, "CXCR3趋化", 2, "turn")   ## 卡牌
			put_skill(c4, "组织浸润")                 ## 技能
		else:
			put_skill(c4, "组织浸润")
			g4.add_mod(c4, "CXCR3趋化", 2, "turn")
		costs.append(g4.actions._move_cost_mod(c4, canc, g4.actions._move_base_cost(c4, canc)))
		g4.dispose()
	check(costs[0] == costs[1], "§11.10 同阶段的两条修饰，换顺序结果不变（来源分层在前）")

	## §十一.11 payment_floor 边界：能量正好等于费用时**付不起**（要留 0.1）
	var g5 := bare_game()
	var c5 := put_immune(g5, Vector2i.ZERO)
	c5["energy"] = 5
	check(not g5.cost.quote(CWCost.context(c5, CWCost.Action.MOVE, 5, Vector2i(1, 0)))["affordable"],
		"§11.11 能量 = 费用：付不起（支付后不得降至 0）")
	c5["energy"] = 6
	check(g5.cost.quote(CWCost.context(c5, CWCost.Action.MOVE, 5, Vector2i(1, 0)))["affordable"],
		"§11.11 能量 = 费用 + 0.1：付得起")
	g5.dispose()


## 攻击设计 §九 的 2 / 3 / 5 / 9
func _t_damage_required() -> void:
	var canc := Vector2i(1, 0)

	## §九.2 攻击成功但最终 0 伤害：「攻击成功后」照常触发，「造成伤害后」不触发
	var g := bare_game()
	g.tiles[canc]["tissue"] = CWData.Tissue.CANCER
	g.tiles[Vector2i(2, 0)]["tissue"] = CWData.Tissue.CANCER   ## 给补体级联留个可转化的格
	var mac := CWSetup.make_cell(g.cells.size(), 0, CWData.Faction.IMMUNE, Vector2i.ZERO,
		CWData.ImmuneType.MACRO, -1, 200)
	mac["equipped"] = ["吞噬体成熟"]
	g.cells.append(mac)
	var prey := _put_cancer(g, canc, 5)                 ## 余量早已低于斩杀阈值
	g.add_mod(prey, "细胞膜修复", 1, "")                 ## −1.5，足够把 1.0 的攻击全挡掉
	g.add_mod(mac, "补体级联", 1, "turn")                ## 「攻击成功后」的代表
	## 期望能量：只扣迁移费，一分吸血都不该有。写成 <= 是弱断言（移动本来就扣钱），
	## 必须钉死等号才拦得住「悄悄吸了血」
	var fee: int = g.actions._move_cost_mod(mac, canc, g.actions._move_base_cost(mac, canc))
	var e0: int = mac["energy"]
	_rig_roll(g, 6, [3])
	await g.actions._do_move(mac, canc, 0)
	check(prey["energy"] == 5, "§9.2 伤害被完全减免，目标一点没掉")
	check(g.tiles[Vector2i(2, 0)]["tissue"] == CWData.Tissue.HEALTHY,
		"§9.2 「攻击成功后」的【补体级联】照常触发")
	check(prey["alive"], "§9.2 「造成伤害后」的斩杀不触发（本次 actual 为 0）")
	check(mac["energy"] == e0 - fee, "§9.2 「造成伤害后」的吸血不触发（只扣了迁移费）")
	g.dispose()

	## §九.3 0 伤害时，标记与护甲都不许被骗掉。
	##
	## **原来这里还有一半**：用【抗原丢失】把整个事件免疫掉，验同样两条保护。
	## 那个世界事件随 PRD 2026-09-08 云端修订版删了，「替代/免疫」层**再没有活的触发者** ——
	## 那半路径已经走不到，删掉。保护本身没有失去覆盖：0 伤害这一半验的是同两条，
	## 只是换了条路进来。将来有卡牌住进免疫层时，请把那半照着 git 历史加回来。
	var g2 := bare_game()
	var atk2 := put_immune(g2, Vector2i(5, 0))
	var sig := _put_cancer(g2, Vector2i(2, 0), 100, CWData.CancerType.SIGNET)
	sig["marked"] = true
	sig["mark_left"] = 1
	check(not g2.damage._immune_to(g2.damage.event(atk2, sig, 10, CWDamage.Kind.ATTACK,
			[CWDamage.Tag.IMMUNE, CWDamage.Tag.ATTACK], "攻击")),
		"§9.3 免疫层现在恒为 false（唯一触发者已随 PRD 删除，这一层保留成契约）")
	g2.damage.submit([g2.damage.event(atk2, sig, 0, CWDamage.Kind.CARD,
		[CWDamage.Tag.IMMUNE], "技能")])
	check(sig["marked"], "§9.3 0 点事件不能骗掉【标记】")
	check(not sig["armor_used"], "§9.3 0 点事件不能骗掉【囊性护甲】")
	g2.dispose()

	## §九.5 T 细胞的无视减伤那一下仍要经过 BCL-2 与死亡检查
	var g3 := bare_game()
	g3.round_no = 1
	g3.tiles[canc]["tissue"] = CWData.Tissue.CANCER
	var tc := CWSetup.make_cell(g3.cells.size(), 0, CWData.Faction.IMMUNE, Vector2i.ZERO,
		CWData.ImmuneType.T_CELL, -1, 200)
	tc["equipped"] = ["细胞毒性增强"]
	g3.cells.append(tc)
	var bcl := _put_cancer(g3, canc, 5)                 ## 主伤害就能打死
	bcl["equipped"] = ["BCL-2抗凋亡"]
	var n0: int = g3.logs.size()
	_rig_roll(g3, 6, [3])
	await g3.actions._do_move(tc, canc, 0)
	check(bcl["alive"] and bcl["energy"] == CWData.BCL2_ENERGY[0],
		"§9.5 无视减伤与主伤害同批，BCL-2 看到完整伤害后统一免死")
	var told := false
	for i in range(n0, g3.logs.size()):
		if "细胞毒性增强" in g3.logs[i]:
			told = true
	check(told, "§9.5 无视减伤那一下照样写日志")
	g3.dispose()

	## §九.9 卡牌伤害不触发只认 ATTACK 的被动，但对应来源的护盾认得出它
	var g4 := bare_game()
	var mac4 := CWSetup.make_cell(g4.cells.size(), 0, CWData.Faction.IMMUNE, Vector2i.ZERO,
		CWData.ImmuneType.MACRO, -1, 100)
	g4.cells.append(mac4)
	var t4 := _put_cancer(g4, Vector2i(2, 0), 100)
	var m0: int = mac4["energy"]
	check(g4.immune_hit(t4, 10, mac4, false) == 10, "§9.9 卡牌伤害不吃树突/巨噬那两条")
	check(mac4["energy"] == m0, "§9.9 巨噬【吞噬】不吸卡牌伤害的血")
	## 树突用卡牌伤害同样不减半。摆在 (5,0)：离目标 3 格，避开【I-标记】的 2 格光环
	## （2026-09-06 光环改 2 格时它原本在 (4,0)，目标被标记、伤害翻倍，下面护盾那条就红了——这里不测标记）
	var den := CWSetup.make_cell(g4.cells.size(), 0, CWData.Faction.IMMUNE, Vector2i(5, 0),
		CWData.ImmuneType.DENDRITIC, -1, 100)
	g4.cells.append(den)
	check(g4.immune_hit(t4, 10, den, false) == 10, "§9.9 树突【各司其职】只减普通攻击")
	## 但【DNA损伤修复】明写挡「免疫方事件/技能」，必须认得出卡牌伤害
	g4.round_no = 1
	g4.add_mod(t4, "DNA损伤修复", 1, "")
	check(g4.immune_hit(t4, 10, den, false) == 0, "§9.9 对应来源的护盾认得出卡牌伤害")
	g4.dispose()


# ============ 联机（M1 通路：协议 / 大厅 / 对局 / 重连 / 计时 / 排空）============
## 服务器与客户端都在本进程里、走 127.0.0.1 真实 WebSocket，靠 _net_pump 每帧轮转。
## 无头主循环约 145 帧/秒（2026-09-02 实测），一次往返 2~3 帧。

const NET_HOST := "127.0.0.1"


func _net_server() -> CWNetServer:
	var s := CWNetServer.new()
	s.quiet = true
	for p in range(18611, 18660):
		if s.start(p, NET_HOST) == OK:
			return s
	return null


func _net_client(nick: String, bot: bool = true) -> CWNetClient:
	var c := CWNetClient.new()
	c.nick = nick
	if bot:
		c.autoplay = CWHeuristicBridge.new()
	return c


## 服务器和客户端一起转，直到 until 成立；返回是否成立
func _net_pump(srv: CWNetServer, clients: Array, until: Callable, max_frames := 9000) -> bool:
	for i in max_frames:
		srv.poll()
		for c in clients:
			await c.poll()
		if until.call():
			return true
		await process_frame
	return false


func _net_pump_ms(srv: CWNetServer, clients: Array, ms: int) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < ms:
		srv.poll()
		for c in clients:
			await c.poll()
		await process_frame


func _net_count(c: CWNetClient, t: String) -> int:
	var n := 0
	for m in c.inbox:
		if m["t"] == t:
			n += 1
	return n


func _net_last(c: CWNetClient, t: String) -> Dictionary:
	for i in range(c.inbox.size() - 1, -1, -1):
		if c.inbox[i]["t"] == t:
			return c.inbox[i]
	return {}


## 两个客户端连上、拿到 welcome
func _net_pair(srv: CWNetServer, a: CWNetClient, b: CWNetClient) -> bool:
	var url := "ws://%s:%d" % [NET_HOST, srv.port]
	a.connect_to(url, a.nick)
	b.connect_to(url, b.nick)
	return await _net_pump(srv, [a, b], func() -> bool: return a.client_id >= 0 and b.client_id >= 0)


## 甲建房、乙加入、各坐 0/1 号席并准备
func _net_room(srv: CWNetServer, a: CWNetClient, b: CWNetClient, players: int, timer: int, seed_value: int) -> bool:
	a.create_room(players, timer, true, seed_value)
	if not await _net_pump(srv, [a, b], func() -> bool: return a.code != ""):
		return false
	b.join(a.code)
	if not await _net_pump(srv, [a, b], func() -> bool: return b.code == a.code):
		return false
	a.sit(0)
	b.sit(1)
	if not await _net_pump(srv, [a, b], func() -> bool: return a.my_seat == 0 and b.my_seat == 1):
		return false
	a.ready()
	b.ready()
	return await _net_pump(srv, [a, b],
		func() -> bool: return a.room["seats"][0]["ready"] and a.room["seats"][1]["ready"])


func t_net_protocol() -> void:
	## 编解码往返：Vector2i 键、嵌套字典、PackedStringArray
	var msg := { "t": "state", "tiles": { Vector2i(1, -2): { "a": 1 } },
		"logs": PackedStringArray(["甲", "乙"]), "at": Vector2i(3, 4) }
	var bytes := CWNet.encode(msg)
	check(CWNet.decode(bytes) == msg, "报文编解码往返一致（含 Vector2i 键）")
	check(CWNet.decode(PackedByteArray([1, 2, 3])).is_empty(), "残报文解成空字典")
	var junk := bytes.duplicate()
	junk.encode_u32(0, 99999999)
	check(CWNet.decode(junk).is_empty(), "原长超上限拒收")
	check(CWNet.decode(CWNet.encode({ "x": 1 })).is_empty(), "没有 t 的报文拒收")
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var code := CWNet.make_code(rng)
	check(code.length() == 6 and not ("0" in code or "O" in code or "1" in code or "I" in code), "房间码 6 位、无 0/O/1/I")
	check(CWNet.clean_nick("  ") == "玩家" and CWNet.clean_nick("一二三四五六七八九十一二三").length() == CWNet.NICK_MAX, "昵称清洗")

	## 视角快照：rng 去掉、他人手牌占位、他人的待决选项去掉；影子对局 restore 后能用
	var g := make_game(2, 5)
	await run_setup(g)
	g.cell_of(0)["hand"] = ["炎症趋化", "细胞毒性增强"]
	g.cell_of(1)["hand"] = ["BCL-2抗凋亡"]
	g._pending = { "kind": "action", "pid": 1, "prompt": "选择行动", "options": [{ "label": "打出【BCL-2抗凋亡】", "data": {} }] }
	var v0 := CWNet.view_for(g, 0)
	var v1 := CWNet.view_for(g, 1)
	check(v0["rng"] == 0 and v1["rng"] == 0, "视角快照不带 rng")
	check(v0["cells"][0]["hand"] == ["炎症趋化", "细胞毒性增强"] and v0["cells"][1]["hand"] == [CWNet.HIDDEN_CARD],
		"自己的手牌可见，别人的只剩同长度占位")
	check(v1["cells"][0]["hand"] == [CWNet.HIDDEN_CARD, CWNet.HIDDEN_CARD] and v1["cells"][1]["hand"] == ["BCL-2抗凋亡"],
		"换到另一席看也一样")
	check(v0["pending"]["options"].is_empty() and v1["pending"]["options"].size() == 1, "别人的待决选项（会写出他的牌名）不发")
	check(CWNet.view_for(g, -1)["cells"][0]["hand"] == [CWNet.HIDDEN_CARD, CWNet.HIDDEN_CARD], "没坐下的人什么手牌都看不到")
	var sh := CWGame.new()
	sh.init(CWData.FACTION_ORDER[2], 0)
	sh.restore(v0)
	check(sh.tiles == g.tiles and sh.round_no == g.round_no and sh.cell_of(0)["pos"] == g.cell_of(0)["pos"],
		"影子对局 restore 视角快照后棋盘一致")
	check(CWNet.encode(v0).size() < 6000, "一份视角快照压缩后不到 6 KB（实测约 2 KB）")
	sh.dispose()
	## 日志替身
	var n0: int = g.logs.size()
	g.log_msg("　癌症A 经由「基因表达」抽到【技能】BCL-2抗凋亡（手牌 1）", 1, "　癌症A 经由「基因表达」抽到 1 张卡（手牌 1）")
	g.log_msg("大家都看得到")
	check(CWNet.logs_for(g, 0, n0) == PackedStringArray(["　癌症A 经由「基因表达」抽到 1 张卡（手牌 1）", "大家都看得到"]),
		"别的席位看到替身")
	check(CWNet.logs_for(g, 1, n0)[0].contains("BCL-2抗凋亡"), "本人看到原文")
	check(g.log_secret.size() == g.logs.size() and g.log_public.size() == g.logs.size(), "三列日志始终平行")
	g.dispose()


func t_net_lobby() -> void:
	var srv := _net_server()
	check(srv != null, "联机：本机起服务器")
	if srv == null:
		return
	var url := "ws://%s:%d" % [NET_HOST, srv.port]
	var a := _net_client("甲")
	var b := _net_client("乙")
	check(await _net_pair(srv, a, b), "两个客户端握手拿到 welcome")
	## 版本不符
	var old := _net_client("旧")
	old.hello_version = 999
	old.connect_to(url, "旧")
	var ok := await _net_pump(srv, [a, b, old],
		func() -> bool: return old.last_error.get("code", "") == "version" and old.status == "closed")
	check(ok, "旧版本客户端收到 version 错误并被断开")
	## 建房 / 大厅 / 加入
	a.create_room(4, 60, true, 0)
	ok = await _net_pump(srv, [a, b], func() -> bool: return a.code != "" and a.room.get("you_host", false))
	check(ok and a.code.length() == 6, "建房拿到 6 位房间码，建房者是房主")
	b.list_rooms()
	ok = await _net_pump(srv, [a, b], func() -> bool: return _net_count(b, "lobby") > 0)
	var lobby := _net_last(b, "lobby")
	check(ok and lobby["rooms"].size() == 1 and lobby["rooms"][0]["code"] == a.code and lobby["rooms"][0]["host"] == "甲",
		"公开房进大厅列表")
	b.join("nope")
	ok = await _net_pump(srv, [a, b], func() -> bool: return b.last_error.get("code", "") == "no_room")
	check(ok, "加入不存在的房间：no_room")
	b.join(a.code.to_lower())
	ok = await _net_pump(srv, [a, b], func() -> bool: return b.code == a.code)
	check(ok, "房间码不分大小写，加入后拿到 room 视图")
	check(b.room["members"].size() == 2 and not b.room["you_host"] and b.room["host"] == "甲", "成员两人，加入者不是房主")
	## 坐席
	a.sit(0)
	b.sit(0)
	ok = await _net_pump(srv, [a, b], func() -> bool: return a.my_seat == 0 and b.last_error.get("code", "") == "seat_taken")
	check(ok, "同一席位第二个人坐不下：seat_taken")
	check(a.token != "" and b.token == "", "坐下的人拿到重连令牌，没坐的没有")
	b.sit(3)
	ok = await _net_pump(srv, [a, b], func() -> bool: return b.my_seat == 3)
	check(ok, "乙坐 3 号席")
	b.sit(1)
	ok = await _net_pump(srv, [a, b], func() -> bool: return b.my_seat == 1 and a.room["seats"][3]["kind"] == "")
	check(ok, "换席：旧席位空出来")
	check(a.room["seats"][1]["faction"] == CWData.Faction.CANCER and a.room["seats"][0]["faction"] == CWData.Faction.IMMUNE,
		"席位视图带阵营")
	## 开局条件
	b.start()
	ok = await _net_pump(srv, [a, b], func() -> bool: return b.last_error.get("code", "") == "not_host")
	check(ok, "非房主不能开局")
	a.start()
	ok = await _net_pump(srv, [a, b], func() -> bool: return a.last_error.get("code", "") == "seat_empty")
	check(ok, "有空席不能开局")
	b.set_ai(2, "heur")
	ok = await _net_pump(srv, [a, b], func() -> bool: return b.last_error.get("code", "") == "not_host")
	check(ok, "非房主不能放 AI")
	a.set_ai(2, "heur")
	a.set_ai(3, "mc")
	ok = await _net_pump(srv, [a, b],
		func() -> bool: return a.room["seats"][2]["kind"] == "ai" and a.room["seats"][3]["tier"] == "mc")
	check(ok and a.room["seats"][3]["nick"] == "AI·专家", "房主给两个空席放新手/专家 AI")
	a.set_ai(1, "heur")
	ok = await _net_pump(srv, [a, b], func() -> bool: return a.last_error.get("code", "") == "seat_taken")
	check(ok, "有人坐着的席位不能放 AI")
	a.set_ai(3, "")
	ok = await _net_pump(srv, [a, b], func() -> bool: return a.room["seats"][3]["kind"] == "")
	check(ok, "AI 席可以撤掉")
	a.set_ai(3, "mc")
	a.start()
	ok = await _net_pump(srv, [a, b], func() -> bool: return a.last_error.get("code", "") == "not_ready")
	check(ok, "有人没准备不能开局")
	## 踢人 + 房主转移 + 空房
	a.kick(1)
	ok = await _net_pump(srv, [a, b],
		func() -> bool: return b.last_error.get("code", "") == "kicked" and a.room["seats"][1]["kind"] == "")
	check(ok and b.code == "", "房主踢人：被踢者出房、席位空出")
	b.join(a.code)
	ok = await _net_pump(srv, [a, b], func() -> bool: return b.code == a.code)
	a.leave()
	ok = await _net_pump(srv, [a, b], func() -> bool: return a.code == "" and b.room.get("you_host", false))
	check(ok and b.room["seats"][0]["kind"] == "", "房主离开：房主转给下一位，离开者席位空出")
	b.leave()
	ok = await _net_pump(srv, [a, b], func() -> bool: return b.code == "")
	check(ok and srv.rooms.size() == 1 and srv.rooms.values()[0].empty_since > 0, "空房先保留")
	srv.idle_ms = 0
	await _net_pump_ms(srv, [a, b], 30)
	check(srv.rooms.is_empty(), "空房超过限时自动关")
	srv.idle_ms = CWNet.ROOM_IDLE_MS
	## 频率限制
	for i in 40:
		a.list_rooms()
	ok = await _net_pump(srv, [a, b], func() -> bool: return a.status == "closed")
	check(ok, "一秒 40 条非作答报文被断开")
	## 握手超时：连一个不应答的保留地址（TEST-NET-3），WebSocketPeer 会一直 CONNECTING，客户端自己到点报断
	var hole := CWNetClient.new()
	hole.connect_timeout_ms = 400
	var dropped: Array = []
	hole.disconnected.connect(func(code: int, reason: String) -> void: dropped.append([code, reason]))
	hole.connect_to("ws://203.0.113.1:8611", "黑洞")
	ok = await _net_pump(srv, [hole], func() -> bool: return hole.status == "closed")
	check(ok and dropped.size() == 1 and dropped[0][1] == "connect timeout", "握手 0.4 秒没通 → 客户端自己判连接失败（%s）" % str(dropped))
	hole.dispose()
	b.dispose()
	old.dispose()
	srv.stop()


func t_net_game() -> void:
	var srv := _net_server()
	if srv == null:
		return
	var a := _net_client("甲")
	var b := _net_client("乙")
	await _net_pair(srv, a, b)
	a.create_room(4, 0, false, 20260902)
	await _net_pump(srv, [a, b], func() -> bool: return a.code != "")
	b.list_rooms()
	await _net_pump(srv, [a, b], func() -> bool: return _net_count(b, "lobby") > 0)
	check(_net_last(b, "lobby")["rooms"].is_empty(), "私密房不进大厅列表")
	b.join(a.code)
	await _net_pump(srv, [a, b], func() -> bool: return b.code == a.code)
	a.sit(0)
	b.sit(1)
	await _net_pump(srv, [a, b], func() -> bool: return a.my_seat == 0 and b.my_seat == 1)
	a.set_ai(2, "heur")
	a.set_ai(3, "mc")
	a.ready()
	b.ready()
	var ok := await _net_pump(srv, [a, b], func() -> bool:
		return a.room["seats"][3]["kind"] == "ai" and a.room["seats"][0]["ready"] and a.room["seats"][1]["ready"])
	check(ok, "4 人房：两位真人 + 新手 AI + 专家 AI 就绪")
	## 每收到一份 state 都核：restore 后再 snapshot 与原文一致、别人的手牌只见占位
	var tally := { "states": 0, "view_bad": 0, "leak": 0 }
	var audit := func(m: Dictionary) -> void:
		if m["t"] != "state":
			return
		tally["states"] += 1
		var snap := a.shadow.snapshot()
		for k in m["view"]:
			if k != "rng" and snap[k] != m["view"][k]:
				tally["view_bad"] += 1
		for c in m["view"]["cells"]:
			if c["pid"] != 0:
				for card in c["hand"]:
					if card != CWNet.HIDDEN_CARD:
						tally["leak"] += 1
	a.message.connect(audit)
	a.start()
	ok = await _net_pump(srv, [a, b], func() -> bool: return a.room.get("state", "") == "playing")
	check(ok, "开局：房间进入 playing")
	var room: CWRoom = srv.rooms[a.code]
	room.bridge.mc.rollouts = 1     ## 专家席只要走到 MC 那条路，别在测试里烧时间
	room.bridge.mc.horizon = 3
	ok = await _net_pump(srv, [a, b], func() -> bool: return not a.game_over.is_empty() and not b.game_over.is_empty(), 20000)
	check(ok, "两个机器人客户端 + 两个 AI 席打完整局（%d 份状态）" % tally["states"])
	check(tally["view_bad"] == 0, "每份视角快照 restore 后再 snapshot 与原文一致")
	check(tally["leak"] == 0, "别人的手牌只见占位")
	check(a.game_over.get("winner", -9) == b.game_over.get("winner", -8), "双方收到同一个胜方")
	check(a.shadow.winner == a.game_over["winner"] and a.shadow.round_no == a.game_over["round"], "终局快照与 game_over 一致")
	check(room.state == CWRoom.State.WAITING and room.games_played == 1 and room.game == null, "局末房间回到等待中、对局已释放")
	check(a.room["state"] == "waiting" and not a.room["seats"][0]["ready"], "局末准备状态清零")
	## 日志：己方牌名可见，对方的被替换
	var mine := 0
	var leak := 0
	var stand_in := 0
	for line in a.logs:
		if "抽到 1 张卡" in line:
			stand_in += 1
		elif "抽到【" in line and not ("【事件】" in line or "世界事件" in line):
			## 联机局里细胞名 = 玩家昵称（Kevin 2026-09-07），不再是引擎默认的「免疫A」
			if (a.nick + "(") in line:
				mine += 1
			else:
				leak += 1
	check(leak == 0 and stand_in > 0, "对局日志：别人抽到的牌名被隐去（%d 行替身）" % stand_in)
	check(mine > 0, "自己抽到的牌名照常可见")
	check(String(a.shadow.player(0)["name"]) == a.nick
		and String(a.shadow.player(1)["name"]) == b.nick,
		"联机局的细胞名换成玩家昵称（%s / %s）"
		% [a.shadow.player(0)["name"], a.shadow.player(1)["name"]])
	check(a.logs.size() > 100 and b.logs.size() == a.logs.size(), "双方日志行数一致（%d 行）" % a.logs.size())
	check(_net_count(a, "roll") > 0 and _net_count(a, "roll") == _net_count(b, "roll"), "掷骰演出广播给双方各一次")
	## 同一房间再开一局
	a.ready()
	b.ready()
	await _net_pump(srv, [a, b], func() -> bool: return a.room["seats"][1]["ready"] and a.room["seats"][0]["ready"])
	a.start()
	ok = await _net_pump(srv, [a, b], func() -> bool: return room.games_played == 2, 20000)
	check(ok, "同一房间连开第二局")
	## 对局中所有人离开 → 中止、关房
	a.ready()
	b.ready()
	await _net_pump(srv, [a, b], func() -> bool: return a.room["seats"][1]["ready"] and a.room["seats"][0]["ready"])
	a.start()
	await _net_pump(srv, [a, b], func() -> bool: return room.state == CWRoom.State.PLAYING)
	a.leave()
	b.leave()
	ok = await _net_pump(srv, [a, b], func() -> bool: return srv.rooms.is_empty() and a.code == "" and b.code == "")
	check(ok and room.game == null, "对局中所有人离开 → 中止对局、关房、释放")
	a.message.disconnect(audit)     ## lambda 捕获了 a：不断开就成环
	a.dispose()
	b.dispose()
	srv.stop()


func t_net_reconnect() -> void:
	var srv := _net_server()
	if srv == null:
		return
	var url := "ws://%s:%d" % [NET_HOST, srv.port]
	var a := _net_client("甲")
	var b := _net_client("乙", false)      ## 乙手动作答，好卡在询问上
	await _net_pair(srv, a, b)
	check(await _net_room(srv, a, b, 2, 30, 777), "重连场景：2 人房、30 秒计时")
	a.start()
	var ok := await _net_pump(srv, [a, b], func() -> bool: return not b.pending_ask.is_empty())
	check(ok, "乙收到自己的询问")
	if not ok:
		b.dispose(); srv.stop(); return       ## 泵超时（压满时的握手慢）：别在空询问上级联崩
	var room: CWRoom = srv.rooms[a.code]
	var ask_id: int = b.pending_ask["ask_id"]
	var token: String = b.token
	var code: String = b.code
	check(b.pending_ask["left_ms"] > 25000 and b.pending_ask["left_ms"] <= 30000, "询问带剩余时间")
	b.dispose()
	ok = await _net_pump(srv, [a, b], func() -> bool: return not room.seats[1]["online"])
	check(ok, "乙断线：席位标离线、昵称保留（%s）" % room.seats[1]["nick"])
	check(room.state == CWRoom.State.PLAYING and not room._ask.is_empty() and room._ask["ask_id"] == ask_id,
		"有计时的房间：询问悬着等他回来")
	var bad := _net_client("丙", false)
	bad.connect_to(url, "丙", code, "deadbeef")
	ok = await _net_pump(srv, [a, bad], func() -> bool: return bad.last_error.get("code", "") == "bad_token")
	check(ok, "错误令牌：bad_token")
	var b2 := _net_client("乙", false)
	b2.connect_to(url, "乙", code, token)
	ok = await _net_pump(srv, [a, b2], func() -> bool: return not b2.pending_ask.is_empty())
	check(ok and b2.pending_ask["ask_id"] == ask_id and b2.my_seat == 1, "凭令牌重连：席位接回、同一次询问重发")
	check(room.seats[1]["online"] and b2.shadow != null and b2.logs.size() > 0 and b2.token == token,
		"重连拿到完整日志与当前状态")
	b2.autoplay = CWHeuristicBridge.new()
	ok = await _net_pump(srv, [a, b2], func() -> bool: return not a.game_over.is_empty() and not b2.game_over.is_empty(), 20000)
	check(ok, "重连后打完整局")
	## 无计时的房间：断线的询问立刻代打；对方一直不回来也能打完
	var c := _net_client("丁", false)
	c.connect_to(url, "丁")
	await _net_pump(srv, [a, c], func() -> bool: return c.client_id >= 0)
	check(await _net_room(srv, a, c, 2, 0, 778), "第二个房间：不计时")
	a.start()
	await _net_pump(srv, [a, c], func() -> bool: return not c.pending_ask.is_empty())
	var room2: CWRoom = srv.rooms[a.code]
	var id2: int = c.pending_ask["ask_id"]
	c.dispose()
	ok = await _net_pump(srv, [a, c], func() -> bool: return not room2.seats[1]["online"])
	check(ok and (room2._ask.is_empty() or room2._ask["ask_id"] != id2), "无计时：断线的询问立刻由启发式代打")
	ok = await _net_pump(srv, [a], func() -> bool: return room2.games_played == 1, 20000)
	check(ok and not a.game_over.is_empty(), "对方一直离线，甲一个人也能把这局打完（离线席位由 AI 代打）")
	a.dispose()
	b2.dispose()
	bad.dispose()
	c.dispose()
	srv.stop()


func t_net_timeout() -> void:
	var srv := _net_server()
	if srv == null:
		return
	var a := _net_client("甲")
	var b := _net_client("乙", false)
	await _net_pair(srv, a, b)
	check(await _net_room(srv, a, b, 2, 1, 55), "计时场景：2 人房、1 秒计时")
	a.start()
	var ok := await _net_pump(srv, [a, b], func() -> bool: return not b.pending_ask.is_empty())
	var room: CWRoom = srv.rooms[a.code]
	var id0: int = b.pending_ask["ask_id"]
	check(ok and b.pending_ask["left_ms"] <= 1000, "1 秒计时的询问")
	await _net_pump_ms(srv, [a, b], 1500)
	check(room.timeouts >= 1 and (b.pending_ask.is_empty() or b.pending_ask["ask_id"] != id0),
		"到点：服务器按启发式代打，对局继续（代打 %d 次）" % room.timeouts)
	b.autoplay = CWHeuristicBridge.new()
	ok = await _net_pump(srv, [a, b], func() -> bool: return room.games_played == 1, 20000)
	check(ok, "之后正常作答打完")
	a.dispose()
	b.dispose()
	srv.stop()


## 投降投票（联机，Kevin 2026-09-09）。**服务器是唯一裁判**，所以这条走真 socket：
## 4 人房、两个真人同坐免疫（pid 0 与 2，FACTION_ORDER[4] = 免/癌/免/癌），癌方两席交给 AI。
## 一个真人发起 → 票不够 → 队友补票 → 才认输。
func t_net_surrender() -> void:
	var srv := _net_server()
	if srv == null:
		return
	var a := _net_client("甲")
	var b := _net_client("乙", false)
	await _net_pair(srv, a, b)
	a.create_room(4, 0, true, 77)
	var ok := await _net_pump(srv, [a, b], func() -> bool: return a.code != "")
	b.join(a.code)
	ok = ok and await _net_pump(srv, [a, b], func() -> bool: return b.code == a.code)
	a.sit(0)
	b.sit(2)                       ## 0 与 2 同为免疫席
	a.set_ai(1, "heur")
	a.set_ai(3, "heur")
	ok = ok and await _net_pump(srv, [a, b], func() -> bool: return a.my_seat == 0 and b.my_seat == 2)
	a.ready()
	b.ready()
	ok = ok and await _net_pump(srv, [a, b],
		func() -> bool: return a.room["seats"][0]["ready"] and a.room["seats"][2]["ready"])
	check(ok, "4 人房：两个真人同坐免疫，癌方两席 AI")
	a.start()
	var room: CWRoom = srv.rooms[a.code]
	ok = await _net_pump(srv, [a, b], func() -> bool: return room.state == CWRoom.State.PLAYING)
	check(ok, "开局")

	## ---- 发起：一票不够 ----
	a.surrender(true)
	ok = await _net_pump(srv, [a, b], func() -> bool: return not b.surrender_vote.is_empty())
	check(ok and room.game.winner < 0, "一个人点了投降**还没有**认输（要全票）")
	var v: Dictionary = b.surrender_vote
	check(Array(v["need"]) == [0, 2] and Array(v["agreed"]) == [0],
		"要投的是同阵营两席、已同意只有发起人（need=%s agreed=%s）" % [str(v["need"]), str(v["agreed"])])
	check(int(v["left_ms"]) > 0 and int(v["left_ms"]) <= CWNet.SURRENDER_VOTE_MS, "带倒计时")

	## ---- 反对：当场结束，并进冷却 ----
	b.surrender(false)
	ok = await _net_pump(srv, [a, b], func() -> bool: return b.surrender_vote.is_empty())
	check(ok and room.game.winner < 0, "队友反对 → 投票作废，没有认输")
	a.surrender(true)
	ok = await _net_pump(srv, [a, b], func() -> bool: return a.last_error.get("code", "") == "vote_cooldown")
	check(ok, "刚被否掉，同一个世界回合里不许再发起（冷却）")
	## **拒绝要让人看得见**：对局中联机面板是隐藏的，`_set_status()` 写进的是看不见的标签，
	## 于是「被冷却挡住」表现为点了没反应 —— Kevin 2026-09-09 就是这么以为「只能发起一次」的。
	check(a.error_seq > 0, "拒绝理由带序号发回客户端（对局界面据此弹气泡）")

	## ---- 冷却**只隔一个世界回合**（原来写成 >= 拖成了两轮）----
	var blocked_at: int = int(room._vote_block[CWData.Faction.IMMUNE])
	check(blocked_at == room.game.round_no + CWNet.SURRENDER_COOLDOWN_ROUNDS,
		"冷却到第 %d 个世界回合为止" % blocked_at)
	room.game.round_no = blocked_at - 1
	check(room.surrender(a.client_id, true) == "vote_cooldown", "还差一轮：仍挡着")
	room.game.round_no = blocked_at
	room._vote = {}
	check(room.surrender(a.client_id, true) == "",
		"到了第 %d 轮就能再发起（不是两轮）" % blocked_at)

	## ---- 全票 → 认输 ----
	room._vote = {}
	room._vote_block.clear()
	a.surrender(true)
	ok = await _net_pump(srv, [a, b], func() -> bool: return not b.surrender_vote.is_empty())
	b.surrender(true)
	ok = ok and await _net_pump(srv, [a, b], func() -> bool: return not b.game_over.is_empty())
	check(ok, "两票齐 → 认输")
	var over: Dictionary = b.game_over
	check(int(over["winner"]) == CWData.Faction.CANCER and over["kind"] == "surrender_cancer",
		"免疫投降 → 癌方胜（kind=%s）" % over.get("kind", ""))
	check(b.surrender_vote.is_empty(), "终局把票面收掉")
	a.dispose()
	b.dispose()
	srv.stop()


## 「主动离开」与「网络断开」在投票里算得不一样（Kevin 2026-09-09）。
## 这条**不走 socket**：要验的是 CWRoom 的席位分支，用真连接反而更难摆出「掉线但没离开」。
func t_surrender_seats() -> void:
	print("[投降：离开 vs 掉线]")
	var srv := _net_server()
	if srv == null:
		return
	var r := CWRoom.new()
	r.configure(srv, "TESTAA", 4, 0, true, true)
	for pid in 4:
		r.seats[pid] = { "kind": "human", "client": 100 + pid, "nick": "P%d" % pid,
			"ready": true, "tier": "", "token": "t%d" % pid, "online": true,
			"left": false, "off_at": 0 }
	check(Array(r._voters(CWData.Faction.IMMUNE)) == [0, 2],
		"免疫方要投的是 pid 0 与 2（FACTION_ORDER[4] 交替）")

	## AI 席位不在名单里 = 自动同意。否则「带 AI 队友」永远投不了降。
	r.seats[2] = CWRoom.ai_seat("heur")
	check(Array(r._voters(CWData.Faction.IMMUNE)) == [0], "AI 席位不计入（视同意）")

	## 主动离开 → 不计入；网络断开 → 仍要计入
	r.seats[2] = { "kind": "human", "client": -1, "nick": "P2", "ready": false, "tier": "",
		"token": "t2", "online": false, "left": true, "off_at": 1 }
	check(Array(r._voters(CWData.Faction.IMMUNE)) == [0], "主动离开的不计入")
	r.seats[2]["left"] = false
	check(Array(r._voters(CWData.Faction.IMMUNE)) == [0, 2],
		"网络断开的**仍要计入**（他可能马上回来，不该替他做决定）")

	## 断够久自动转「已离开」—— 没有这条，一个再也不回来的人能把队友永远锁在局里
	r.state = CWRoom.State.PLAYING
	r.seats[2]["off_at"] = 1000
	r.tick(1000 + CWNet.DROP_TO_LEFT_MS - 1)
	check(not r.seats[2]["left"], "断线还没到 %d ms：仍计入" % CWNet.DROP_TO_LEFT_MS)
	r.tick(1000 + CWNet.DROP_TO_LEFT_MS)
	check(r.seats[2]["left"] and Array(r._voters(CWData.Faction.IMMUNE)) == [0],
		"断满 %.1f 分钟 → 视同已离开，不再计入" % (CWNet.DROP_TO_LEFT_MS / 60000.0))
	srv.stop()

	## 倒计时（Kevin 2026-09-09 报「没有倒数的效果」）。病根是服务器**只在票况变化时**广播，
	## `left_ms` 是那一刻的快照 —— 界面照着画就永远停在 30 秒。改成客户端按收到时刻自己走表。
	var d := CWSurrenderVote.deadline_of(1000, CWNet.SURRENDER_VOTE_MS)
	check(d == 1000 + CWNet.SURRENDER_VOTE_MS, "截止时刻 = 收到时刻 + 剩余")
	check(CWSurrenderVote.seconds_left(d, 1000) == 30, "刚收到 → 30 秒")
	check(CWSurrenderVote.seconds_left(d, 1000 + 5000) == 25, "过了 5 秒 → 25 秒（真的在减）")
	check(CWSurrenderVote.seconds_left(d, 1000 + 29500) == 1, "剩 0.5 秒 → 向上取整成 1，不跳过 1")
	check(CWSurrenderVote.seconds_left(d, 1000 + 999999) == 0, "过了截止 → 0，不出现负数")


func t_net_drain() -> void:
	var srv := _net_server()
	if srv == null:
		return
	var url := "ws://%s:%d" % [NET_HOST, srv.port]
	var a := _net_client("甲")
	var b := _net_client("乙")
	await _net_pair(srv, a, b)
	check(await _net_room(srv, a, b, 2, 0, 99), "排空场景：2 人房")
	srv.drain = true
	a.start()
	var ok := await _net_pump(srv, [a, b], func() -> bool: return a.last_error.get("code", "") == "maintenance")
	check(ok, "维护中不能开局")
	srv.drain = false
	a.start()
	var room: CWRoom = srv.rooms[a.code]
	await _net_pump(srv, [a, b], func() -> bool: return room.state == CWRoom.State.PLAYING)
	srv.drain = true
	var fired := [false]
	srv.drained.connect(func() -> void: fired[0] = true)
	var c := _net_client("丙")
	c.connect_to(url, "丙")
	ok = await _net_pump(srv, [a, b, c], func() -> bool: return c.client_id >= 0)
	check(ok and _net_last(c, "welcome")["maintenance"], "握手就告诉新来的：维护中")
	c.create_room(2, 0, true)
	ok = await _net_pump(srv, [a, b, c], func() -> bool: return c.last_error.get("code", "") == "maintenance")
	check(ok, "维护中不能建房")
	c.list_rooms()
	ok = await _net_pump(srv, [a, b, c], func() -> bool: return _net_count(c, "lobby") > 0)
	check(ok and _net_last(c, "lobby")["maintenance"], "大厅列表带维护标记")
	check(not fired[0], "有对局在打，排空不结束")
	ok = await _net_pump(srv, [a, b, c], func() -> bool: return room.games_played == 1, 20000)
	srv.poll()
	check(ok and fired[0], "最后一局打完 → drained")
	a.dispose()
	b.dispose()
	c.dispose()
	srv.stop()


# ============ 联机界面（M2）：联机面板四页、影子对局驱动的对局界面 ============

## 自定义对局（2026-09-03 Kevin）：同一张配置面板多出癌种行，取值进 cfg["cancer_types"]
func t_config_custom() -> void:
	print("[自定义对局：自选癌种]")
	var p := CWConfigPanel.new()
	root.add_child(p)
	await process_frame
	p.open()
	## **行下标一律从 `N_ROWS` 推，别写死** —— 2026-09-08 加「世界事件」行时，
	## 这一组因为把 4 当成「第一个癌种行」而整片变红。
	var first_cancer: int = CWConfigPanel.N_ROWS
	check(p.config()["cancer_types"].is_empty() and p._n_rows() == CWConfigPanel.N_ROWS
		and p._btn.position.y == CWConfigPanel.BTN_Y
		and not p._name_labels[first_cancer].visible,
		"普通对局：不带癌种、%d 行、按钮在 %.0f、癌种行收起"
			% [CWConfigPanel.N_ROWS, CWConfigPanel.BTN_Y])
	p.custom = true
	p.open()
	check(p._title.text == "自定义对局" and p._eyebrow.text == "CUSTOM", "自定义：眉题 / 标题换了")
	check(p._n_rows() == CWConfigPanel.N_ROWS + 2
			and p._name_labels[first_cancer].visible and p._name_labels[first_cancer + 1].visible
			and not p._name_labels[first_cancer + 2].visible
			and p._name_labels[first_cancer].text == "癌症A 种类", "4 人：多出癌症A / 癌症B 两行")
	check(p.config()["cancer_types"] == [-1, -1], "默认都是随机")
	var down := InputEventAction.new()
	down.action = "ui_down"
	down.pressed = true
	var right := InputEventAction.new()
	right.action = "ui_right"
	right.pressed = true
	for i in CWConfigPanel.N_ROWS:
		p.handle_input(down)   ## 从第一行一路走到癌症A（步数 = 左栏行数）
	p.handle_input(right)
	check(p.config()["cancer_types"][0] == CWData.CancerType.MELANOMA
			and p._value_labels[first_cancer].text == "恶性黑色素瘤",
		"癌症A 拨一格：随机 → 恶性黑色素瘤")
	p.handle_input(down)
	p.handle_input(right)
	check(p.config()["cancer_types"][1] == CWData.CancerType.SIGNET, "癌症B 拨值跳过 A 已选走的黑色素瘤 → 印戒（同局不重复）")
	var left := InputEventAction.new()
	left.action = "ui_left"
	left.pressed = true
	p.handle_input(left)
	check(p.config()["cancer_types"][1] == -1, "往回拨：印戒 → 随机（不落到被占的黑色素瘤上）")
	p._players = 6
	p._repaint()
	## **最挤的一档**：6 人自定义 = 左栏 N_ROWS 行 + 3 个癌席。
	## 「按钮不出屏」这条是行距 ROW_H_CUSTOM 的唯一约束 —— 2026-09-08 加行之后
	## 32 的行距会让按钮底落到 563（屏高 540），因此收到了 28。
	var last_row: int = CWConfigPanel.N_ROWS + 2
	check(p._n_rows() == CWConfigPanel.N_ROWS + 3 and p._name_labels[last_row].visible
			and p._name_labels[last_row].text == "癌症C 种类"
			and p._btn.position.y + CWConfigPanel.BTN_H <= 540
			and p._btn.position.y > p._row_y(last_row) + 20,
		"6 人：%d 行 + 按钮跟在最后一行下面、不出屏（按钮底 %.0f ≤ 540）"
			% [CWConfigPanel.N_ROWS + 3, p._btn.position.y + CWConfigPanel.BTN_H])
	p._players = 2
	p._sel = last_row
	p._repaint()
	check(p._n_rows() == CWConfigPanel.N_ROWS + 1
			and not p._name_labels[first_cancer + 1].visible
			and p._sel == CWConfigPanel.N_ROWS + 1,
		"2 人：只剩癌症A 一行，焦点收回到按钮")
	var got: Array = []
	p.confirmed.connect(func(c: Dictionary) -> void: got.append(c))
	var accept := InputEventAction.new()
	accept.action = "ui_accept"
	accept.pressed = true
	p.handle_input(accept)
	check(got.size() == 1 and got[0]["cancer_types"] == [CWData.CancerType.MELANOMA],
		"按钮上回车开局：cfg 只带露出来的那几席（%s）" % str(got[0]["cancer_types"] if not got.is_empty() else []))
	p.queue_free()


## 联机面板的辉光 / 悬停 / 切页动画（2026-09-03 Kevin：和开始游戏的面板一样）
func t_online_glow() -> void:
	print("[联机面板：辉光与动画]")
	var p := CWOnlinePanel.new()
	root.add_child(p)
	await process_frame
	p.visible = true
	p._show_page(CWOnlinePanel.Page.CREATE)
	check(p._create_glow.visible and (p._create_glow.get_child(0) as Label).text == "人数"
		and p._create_glow.position.y == CWOnlinePanel.ROW_Y0, "建房页：焦点行标题有辉光，跟着第一行")
	var arrow: Label = p._create_arrows[0][1]
	arrow.mouse_entered.emit()
	check(p._hot_arrow == arrow and arrow.get_theme_constant("outline_size") == 8
		and arrow.get_theme_color("font_color") == Color.WHITE, "悬停拨值箭头：转白 + 白光描边 8")
	arrow.mouse_exited.emit()
	check(p._hot_arrow == null and arrow.get_theme_constant("outline_size") == 0
		and arrow.get_theme_color("font_color") == CWStyle.IMMUNE, "移开：描边收掉、回青色")
	p._create_sel = CWOnlinePanel.N_CREATE_ROWS
	p._repaint_create()
	check(not p._create_glow.visible and p._create_btn.get_theme_stylebox("panel") == p._create_btn.get_meta("hot"),
		"焦点到「建房」按钮：辉光收起、按钮变白")
	## 文字链接：悬停变白发光、移开还原成自己的静止色
	p._stand_link.mouse_entered.emit()
	check(p._stand_link.get_theme_color("font_color") == Color.WHITE and p._stand_link.get_theme_constant("outline_size") == 8,
		"链接悬停：白字 + 白光")
	p._stand_link.mouse_exited.emit()
	check(p._stand_link.get_theme_color("font_color") == CWStyle.TEXT_HI and p._stand_link.get_theme_constant("outline_size") == 0,
		"链接移开：还原")
	## 切页：新页从透明淡入（面板开着才淡）
	p._show_page(CWOnlinePanel.Page.LOBBY)
	check(p._roots[CWOnlinePanel.Page.LOBBY].modulate.a < 1.0 and p._roots[CWOnlinePanel.Page.LOBBY].visible,
		"切到大厅：新页从透明淡入")
	p.queue_free()


func t_online_panel() -> void:
	print("[联机面板]")
	var p := CWOnlinePanel.new()
	root.add_child(p)
	await process_frame
	var fired: Array = []
	p.cancelled.connect(func() -> void: fired.append("cancel"))
	p.open()
	check(p.visible and p.page == CWOnlinePanel.Page.CONNECT, "open() 落在连接页")
	check(p._addr.text.contains(":"), "服务器地址默认填好（%s）" % p._addr.text)
	var esc := InputEventAction.new()
	esc.action = "ui_cancel"
	esc.pressed = true
	p.handle_input(esc)
	check(fired == ["cancel"] and not p.visible, "连接页 Esc 退回主菜单")
	## 「返回主菜单」链接（2026-09-03 Kevin 要的）：与 Esc 同一条路
	p.open()
	var back: Label = null
	for n in p.find_children("*", "Label", true, false):
		if (n as Label).text == "返回主菜单" and n.is_visible_in_tree():
			back = n
	check(back != null, "连接页有「返回主菜单」链接")
	if back != null:
		check(is_equal_approx(back.position.y, CWOnlinePanel.BTN_Y + 5) and back.position.x > CWOnlinePanel.SLOT_X + 182,
			"链接在「进入大厅」按钮右侧、与建房页「返回大厅」同一行")
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = true
		back.gui_input.emit(click)
		check(fired == ["cancel", "cancel"] and not p.visible, "点链接：面板隐藏、主菜单淡回（同 Esc）")
	## 建房页拨值（键盘模型同配置面板）
	p.visible = true
	p._show_page(CWOnlinePanel.Page.CREATE)
	check(p._title.text == "建房" and p._create["players"] == 4 and p._create["timer"] == 60 and p._create["public"],
		"建房页默认 4 人 · 60 秒 · 公开")
	p._cycle_create(0, 1)
	p._cycle_create(1, 1)
	p._cycle_create(2, 1)
	check(p._create["players"] == 6 and p._create["timer"] == 90 and not p._create["public"], "三行各拨一格：6 人 · 90 秒 · 私密")
	check(p._create_value_text(2).contains("私密") and p._create_value_text(1) == "90 秒", "值文案跟着走")
	p._cycle_create(1, 1)
	check(p._create["timer"] == 0 and p._create_value_text(1) == "不限", "计时拨到头是「不限」")
	## 大厅列表渲染（不连服务器：直接喂视图）
	p.client = CWNetClient.new()
	p._show_page(CWOnlinePanel.Page.LOBBY)
	check(p._lobby_labels[0].text.contains("暂无"), "没有公开房时第一行写「暂无」")
	p._lobby_rooms = [{ "code": "ABCDEF", "host": "甲", "players": 4, "seated": 2, "humans": 1, "timer": 60, "state": "waiting" }]
	p._lobby_sel = 0
	p._repaint_lobby()
	check(p._lobby_labels[0].text.begins_with("ABCDEF") and p._lobby_labels[0].text.contains("2/4"),
		"大厅一行：房间码 · 人数 · 计时 · 房主（%s）" % p._lobby_labels[0].text)
	check(p._lobby_labels[1].text == "", "多余的行留空")
	## 长昵称（12 字）不能把行撑出面板：定宽 400 + 省略号，房主名在最后、被截的只是它（2026-09-03 排版体检）
	p._lobby_rooms = [{ "code": "ABCDEF", "host": "十二个字的昵称一二三四五", "players": 6, "seated": 6, "humans": 1, "timer": 90, "state": "waiting" }]
	p._repaint_lobby()
	check(p._lobby_labels[0].clip_text and p._lobby_labels[0].size.x == CWOnlinePanel.LIST_W
		and p._lobby_labels[0].text.ends_with("的房间") and p._lobby_labels[0].text.begins_with("ABCDEF  6 人局 6/6  90 秒"),
		"长昵称的房间行：定宽 %d + 省略号，房间码 / 人数 / 计时在前（%s）" % [int(CWOnlinePanel.LIST_W), p._lobby_labels[0].text])
	## 等待室渲染：喂一份 room 视图
	var seats := []
	for i in 4:
		seats.append({ "kind": "", "nick": "", "ready": false, "tier": "", "online": false, "faction": CWData.FACTION_ORDER[4][i] })
	seats[0] = { "kind": "human", "nick": "甲", "ready": true, "tier": "", "online": true, "faction": CWData.Faction.IMMUNE }
	seats[1] = { "kind": "human", "nick": "十二个字的昵称一二三四五", "ready": false, "tier": "", "online": false, "faction": CWData.Faction.CANCER }
	seats[3] = { "kind": "ai", "nick": "AI·专家", "ready": false, "tier": "mc", "online": false, "faction": CWData.Faction.CANCER }
	p.client.room = { "t": "room", "code": "ABCDEF", "public": true, "timer": 60, "players": 4, "state": "waiting",
		"host": "甲", "you_host": true, "you_seat": 0, "token": "x", "seats": seats, "members": ["甲", "乙", "丙"], "games": 0 }
	p.client.code = "ABCDEF"
	p.client.my_seat = 0
	p._show_page(CWOnlinePanel.Page.ROOM)
	check(p._title.text == "房间 ABCDEF" and p._sub.text.contains("公开") and p._sub.text.contains("60 秒"), "等待室标题与副标题")
	check(p._ready_text.text == "取消准备" and p._start_btn.visible and p._stand_link.visible, "已准备的房主：按钮是「取消准备」，「开局」可见")
	check(p._status.text.contains("空席"), "有空席时状态行提示（%s）" % p._status.text)
	check(p._members_label.text.contains("丙") and not p._members_label.text.contains("甲"), "未入座的人单列")
	var texts: Array = []
	for c in p._seat_root.get_children():
		if c is Label:
			texts.append((c as Label).text)
	check("甲（你）" in texts and "十二个字的昵称一二三四五" in texts and "AI·专家" in texts and "离线" in texts, "席位行：昵称 / AI / 离线都画出来了")
	## 12 字昵称的席位名：定宽 + 省略号，别压到状态列（2026-09-03 排版体检）
	var long_seat: Label = null
	for c in p._seat_root.get_children():
		if c is Label and (c as Label).text == "十二个字的昵称一二三四五":
			long_seat = c
	check(long_seat != null and long_seat.clip_text and long_seat.size.x == CWOnlinePanel.SEAT_NAME_W
		and long_seat.text_overrun_behavior == TextServer.OVERRUN_TRIM_ELLIPSIS, "长昵称席位名：定宽 %d + 省略号" % int(CWOnlinePanel.SEAT_NAME_W))
	check("新手AI" in texts and "专家AI" in texts and "撤掉" in texts and "踢出" in texts, "房主看得到放 AI / 撤掉 / 踢出")
	p.client.room["you_host"] = false
	p._repaint_room()
	texts = []
	for c in p._seat_root.get_children():
		if c is Label:
			texts.append((c as Label).text)
	check(not ("踢出" in texts) and not p._start_btn.visible, "非房主没有踢人和开局")
	check(CWOnlinePanel.seat_label(0, CWData.Faction.IMMUNE) == "免疫A" and CWOnlinePanel.seat_label(3, CWData.Faction.CANCER) == "癌症B"
		and CWOnlinePanel.seat_label(4, CWData.Faction.IMMUNE) == "免疫C", "席位名按阵营各自编号")
	## 开局 → 顺序播放模式 → 第一份状态到了才 match_started
	var started: Array = []
	p.match_started.connect(func(_c: CWNetClient) -> void: started.append(true))
	p.client.room["state"] = "playing"
	p.client.room["you_seat"] = 0
	p._on_message(p.client.room)
	check(p.client.sequenced and started.is_empty(), "房间进入 playing：对局流开始排队，但还没进棋盘")
	p._on_message({ "t": "state", "view": {}, "logs": [], "turn": 0, "hash": "", "game": 0 })
	check(started.size() == 1 and not p.visible and p.in_match, "第一份状态到了：面板藏起来、通知 main.gd 进棋盘")
	p.client.dispose()
	p.client = null
	p.queue_free()


## 影子对局驱动的对局界面：真服务器 + 界面客户端，第一问（落子）通过现有的桥弹出来、点格子作答
func t_match_online() -> void:
	print("[联机对局界面]")
	var srv := _net_server()
	if srv == null:
		return
	var a := _net_client("甲", false)
	var b := _net_client("乙")
	await _net_pair(srv, a, b)
	check(await _net_room(srv, a, b, 2, 0, 20260903), "2 人房就绪")
	var main_scene: Node = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main_scene)
	await process_frame
	var m: CWMatch = main_scene.get_node("Match")
	var bar: CWActionBar = main_scene.get_node("Match/UI/ActionBar")
	var board: Node2D = main_scene.get_node("Board")
	a.sequenced = true           ## CWOnlinePanel 在收到 room(playing) 时做的事
	a.start()
	var ok := await _net_pump(srv, [a, b], func() -> bool:
		return not a.stream.is_empty() and a.stream[0]["t"] == "state")
	check(ok, "开局后第一份状态排进了 stream")
	m.start_online(a)
	check(m.online and m.game == a.shadow and m.bridge.human_pids == [0] and not m.bridge.enabled,
		"联机模式：影子对局 + 只服务我这一席的界面桥")
	check(m.settle.online and m.pause_menu.online, "结算屏与暂停菜单切到联机文案")
	check(not m.can_save_now(), "联机局不能存档")
	ok = await _net_pump(srv, [a, b], func() -> bool: return bar.visible and not m.bridge.marks.is_empty())
	check(ok, "第一问（落子）通过界面桥弹出：提示栏出现、候选格高亮 %d 格" % m.bridge.marks.size())
	check(m.net_hud.seconds_left() == -1, "不计时的房间不显示倒计时")

	## ---- 左侧出牌列：**状态的投影**（方案甲，2026-09-07）----
	## 影子对局不跑 card_fx，这一列原先靠一次性广播吃饭 —— 断线重连期间那几条就永久错过了。
	## 现在它随快照走，所以这里从**服务器**那边记流水、推状态，验的是
	## 服务器 → 快照 → 影子对局 → 出牌列 这条完整的链。
	check(m._feed != null and is_instance_valid(m._feed), "联机局也建了出牌列")
	var room: CWRoom = srv.rooms.values()[0]
	check(room.game != null, "服务器上有对局")
	var feed_n: int = m._feed._rows.size()
	room.game.note_feed("play", 0, CWData.Faction.IMMUNE, "炎症趋化")
	room.push_state(-1)
	ok = await _net_pump(srv, [a, b], func() -> bool: return m._feed._rows.size() > feed_n)
	check(ok, "服务器记了一条流水 → 推状态 → 这一列长出一张")
	var who0: String = String(m._feed._rows[m._feed._rows.size() - 1]["who"]) if ok else ""
	check(who0.begins_with("甲"), "卡面底行写的是**昵称**而不是「免疫A」（%s）" % who0)

	feed_n = m._feed._rows.size()
	room.game.note_feed("event", 1, CWData.Faction.CANCER, "克隆增殖")
	room.push_state(-1)
	ok = await _net_pump(srv, [a, b], func() -> bool: return m._feed._rows.size() > feed_n)
	check(ok, "别人抽到的事件卡也进这一列")
	var who1: String = String(m._feed._rows[m._feed._rows.size() - 1]["who"]) if ok else ""
	check(who1.ends_with(CWFeed.EVENT_SUFFIX), "事件卡底行是「<抽到者> 事件卡」（%s）" % who1)

	feed_n = m._feed._rows.size()
	room.game.note_feed("world", -1, -1, "基质阻隔", 2)
	room.push_state(-1)
	ok = await _net_pump(srv, [a, b], func() -> bool: return m._feed._rows.size() > feed_n)
	check(ok, "世界事件也进这一列")
	if ok:
		var wbox: Control = m._feed._rows[m._feed._rows.size() - 1]["box"]
		check(not wbox.gui_input.get_connections().is_empty(),
			"世界事件那张卡点得开（2026-09-07 漏接过 gui_input）")

	## **断线重连补齐**（方案甲要解决的正主）：把列清空、游标归零 = 模拟「这几条广播我没收到」，
	## 再照常推一次状态 —— 那一列必须自己长回来。这正是重连时走的路。
	var had: int = m._feed._rows.size()
	m._feed.clear_all()
	m._feed_seq = 0
	room.push_state(-1)
	ok = await _net_pump(srv, [a, b], func() -> bool: return m._feed._rows.size() >= had)
	check(ok and had > 0, "清空后靠状态里的流水自己补齐了 %d 条（重连走的就是这条路）"
		% m._feed._rows.size())
	var wbox: Control = m._feed._rows[m._feed._rows.size() - 1]["box"]
	check(not wbox.gui_input.get_connections().is_empty(),
		"联机收到的世界事件那张卡点得开（2026-09-07 漏接过 gui_input）")
	var pick: Vector2i = m.bridge.marks.keys()[0]
	var states0: int = _net_count(a, "state")
	board.tile_clicked.emit(pick)
	ok = await _net_pump(srv, [a, b], func() -> bool:
		return _net_count(a, "state") > states0 and a.shadow.cells.size() >= 1)
	check(ok and a.shadow.cells.size() >= 1 and a.shadow.cells[0]["pos"] == pick,
		"点格子 → 答案发到服务器 → 新状态回来，细胞落在点的那格")
	check(m.panel.net_seats.size() == 2, "右侧竖条拿到席位表")
	m.teardown()
	check(not m.online and m.game == null and a.shadow != null, "拆局：退出联机模式，影子对局留给客户端")
	main_scene.queue_free()
	a.dispose()
	b.dispose()
	srv.stop()
