## ai_agree_export.gd —— 录 AI 对拍语料：GD 三档当参照，C# CellWar.Ai 当被测（换内核 P3）
##
##   <godot> --headless --path game --script res://tests/ai_agree_export.gd -- \
##       players=4 seed=4242 tiers=search,normal,intent,normal rounds=6 out=/abs/path/agree_4p.jsonl
##
## 一局自对弈（每席按 tiers 轮流指定档位），**每一问**一行 JSONL（ai_agree_recorder.gd）：
##   · 三档各自的答案（语义键）、本席实际走的那一档、选项（引擎原序，带 GD 形状的 data）；
##   · 推演种子（这一问三档拿到的 rng 的初始状态）；
##   · 意图档的全部候选读数，搜索档的根候选读数 / 对手节点排序 / 叶值序列 / 根值；
##   · 顶层行动 / 落子问答另带世界（cwxworld/3）与真局 rng 状态 —— 这一段的起点，C# 从这里装回、按答案重放到下一个起点。
## 真局的 rng 也换成 SplitMix64（agree_rng.gd）：C# 装回世界之后用同一条流掷骰，两边才是同一局。
## 产物 gzip 之后进 game/tests/ai_agree/（语料冻结），C# 测试读那份。**规则或 AI 改了就得重录**。
##
## 排查一条不一致（C# 报「#91 search 读数：根 0 线值 …」）：同一组参数加 `debug=91 debug_tier=search debug_out=/abs/gd.jsonl`
## 重跑到第 91 问为止，把那一档的试走逐步记下来；C# 侧 `CW_AGREE_CORPUS=… CW_AGREE_DEBUG_ROW=91 CW_AGREE_TIERS=search
## dotnet test --filter 开发试走逐步` 出同形的 ai_agree_steps.jsonl，两份逐行比，第一处不同的那一步就是分叉点。
extends SceneTree

const AGREE := preload("res://scripts/ai/agree_rng.gd")
const Recorder := preload("res://tests/ai_agree_recorder.gd")

var players := 4
var seed_value := 4242
var tiers: PackedStringArray = ["search", "normal", "intent"]
var max_rounds := 0        ## 0 = 打到终局；>0 = 第 N 世界回合开始时收尾（搜索档每问要几百毫秒，整局太慢）
var out_path := "user://agree.jsonl"
var debug_target := -1
var debug_tier := "search"
var debug_out := "user://agree_debug.jsonl"


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.split("=")
		if kv.size() != 2:
			continue
		match kv[0]:
			"players": players = int(kv[1])
			"seed": seed_value = int(kv[1])
			"tiers": tiers = kv[1].split(",")
			"rounds": max_rounds = int(kv[1])
			"out": out_path = kv[1]
			"debug": debug_target = int(kv[1])
			"debug_tier": debug_tier = kv[1]
			"debug_out": debug_out = kv[1]
	await _run()


func _run() -> void:
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		printerr("无法写 ", out_path)
		quit(1)
		return
	AGREE.on = true
	var g := CWGame.new()
	g.rng = AGREE.new_rng(0)          ## 靠 cw_game.gd 那行 `var rng: Object`（t_rng_injectable 盯着）
	g.tune = CWTuning.new()
	g.init(CWData.FACTION_ORDER[players], seed_value)
	var rec = Recorder.new()
	rec.setup(g)
	rec.base_seed = seed_value
	rec.out = f
	rec.debug_target = debug_target
	rec.debug_tier = debug_tier
	rec.debug_out = debug_out
	for pid: int in g.order:
		rec.seat_tier[pid] = tiers[pid % tiers.size()]
		g.bridges[pid] = rec
	f.store_line(JSON.stringify({ "t": "header", "schema": "cwxagree/1", "players": players,
		"seed": seed_value, "tiers": Array(tiers), "rounds": max_rounds }, "", true, true))
	var t0 := Time.get_ticks_msec()
	while true:
		var req: Dictionary = await g.pending()
		if req.is_empty():
			break
		if max_rounds > 0 and int(g.round_no) > max_rounds:
			break
		if debug_target > 0 and rec.n >= debug_target:
			break   ## 排查模式：录到目标那一问就收
		rec.top_level = true
		var idx: int = await g.ask(int(req["pid"]), req)
		rec.top_level = false
		await g.step(idx)
	f.store_line(JSON.stringify({ "t": "footer", "asks": rec.n, "rounds": int(g.round_no),
		"winner": int(g.winner), "stats": rec.stats }, "", true, true))
	f.close()
	AGREE.on = false
	print("AGREE-EXPORT: OK %d 问（%d 段起点），%d 世界回合，胜方 %d，%.1f s" % [
		rec.n, rec.stats["worlds"], g.round_no, g.winner, (Time.get_ticks_msec() - t0) / 1000.0])
	g.dispose()
	quit(0)
