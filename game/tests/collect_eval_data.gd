extends SceneTree
## collect_eval_data.gd —— 导出「局面特征 → 最终胜负」的自对弈数据，喂给权重回归。
##
## 为什么要它：`CWEval` 的二十来个权重全是手调的。估值本来就是个线性组合
## （见 `CWEval.features()` / `WEIGHTS`），所以「学一组更好的权重」退化成一次逻辑回归 ——
## 不必动树搜索、不必引入任何运行时依赖。这是 RL 路线上最便宜的第一步。
##
## 跑（`--` 之后是参数）：
##   godot --headless --path game --script res://tests/collect_eval_data.gd -- games=2000 out=<路径.csv>
##
## 参数：
##   games=2000   自对弈局数        seed=20260907  起始种子
##   order=ICIC   席位组成（同 balance_scan）
##   every=3      每隔几个决策点采一个样（相邻局面高度相关，全采只是把同一份信息抄很多遍）
##   out=…        输出 CSV 路径；缺省写到 user://eval_data.csv
##
## 输出：表头 = `CWEval.FEATURE_NAMES` + `round` + `cancer_won`。
## **特征一律取「癌方优势」视角**（同 `CWEval.features`），标签是这局最后癌方赢没赢。
##
## 采样口径两点说明：
## - **只在决策点采**：那是 AI 真正要比较局面的时刻，和估值的使用场景一致。
## - **带上 round**：早期局面和终局局面的信息量差很多，回归时可以按回合加权或分段。
const DEFAULT_OUT := "user://eval_data.csv"

var games := 2000
var seed_value := 20260907
var order := "ICIC"
var every := 3
var out_path := DEFAULT_OUT


## 每个决策点抄一份特征；胜负要等这局打完才知道，所以先攒着，局末统一落盘。
class Sampler:
	extends CWHeuristicBridge
	var rows: Array = []
	var every := 3
	var _n := 0

	func ask(req: Dictionary) -> int:
		_n += 1
		if _n % every == 0:
			var f: Array[int] = CWEval.features(game)
			var row: Array = []
			row.append_array(f)
			row.append(game.round_no)
			rows.append(row)
		return await super.ask(req)


func _initialize() -> void:
	_parse_args()
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		print("打不开输出文件：%s" % out_path)
		quit(1)
		return
	var head: Array = []
	head.append_array(CWEval.FEATURE_NAMES)
	head.append("round")
	head.append("cancer_won")
	f.store_line(",".join(head))

	var t0 := Time.get_ticks_msec()
	var rows_out := 0
	var cancer_wins := 0
	var factions: Array = []
	for ch in order:
		factions.append(CWData.Faction.IMMUNE if ch == "I" else CWData.Faction.CANCER)
	for gi in games:
		var g := CWGame.new()
		g.init(factions, seed_value + gi)
		g.sim_quiet = true          ## 不写日志：几千局的日志既没人看又拖速度
		var sampler := Sampler.new()
		sampler.game = g
		sampler.every = every
		for pid in g.order:
			g.bridges[pid] = sampler
		var winner: int = await g.run_game()
		var won := 1 if winner == CWData.Faction.CANCER else 0
		cancer_wins += won
		for row in sampler.rows:
			f.store_line(",".join(PackedStringArray(row.map(func(v: Variant) -> String:
				return str(v)))) + "," + str(won))
			rows_out += 1
		g.dispose()
		if gi % 200 == 199:
			print("  %d/%d 局，%d 行" % [gi + 1, games, rows_out])
	f.close()
	var secs := (Time.get_ticks_msec() - t0) / 1000.0
	print("写出 %d 行 / %d 局（癌胜 %.0f%%），耗时 %.1f s → %s" % [
		rows_out, games, cancer_wins * 100.0 / maxi(games, 1), secs,
		ProjectSettings.globalize_path(out_path) if out_path.begins_with("user://") else out_path])
	quit(0)


func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=")
		if kv.size() != 2:
			continue
		match kv[0]:
			"games": games = maxi(int(kv[1]), 1)
			"seed": seed_value = int(kv[1])
			"order": order = kv[1]
			"every": every = maxi(int(kv[1]), 1)
			"out": out_path = kv[1]
