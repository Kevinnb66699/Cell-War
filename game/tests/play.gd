## play.gd —— 把一个席位交给「场外的人」实时操作，用来自己上手打一局
##
## **为什么要有它。** 平衡数字全是 AI 互搏跑出来的，可「这局玩起来什么感觉」——
## 选项够不够多、能量紧不紧、有没有一眼可见的必胜手 —— 只有真坐下来打一局才知道。
## 真人试玩要占团队的时间，这个脚本让开发过程里随时能自己打一局，
## 也让不在电脑前的人（远程协作、脚本、我）能通过文件把手伸进对局里。
##
## 走的是 `CWBridge.ask()` 这**唯一一个口**，和界面上的行动栏、AI 桥完全同源：
## 引擎给什么选项这里就原样列什么。所以它试的是**真规则**，不是简化模型——
## 这也意味着它只能测规则和手感，测不出界面（那得靠 screenshot.gd）。
##
## 运行（可以加 --headless，本脚本不渲染）：
##   godot --headless --path game --script res://tests/play.gd -- \
##       dir=C:/tmp/play me=0 order=ICIC seed=20260831 ai=heur
##
## 参数（全部可省）：
##   dir=<目录>   通信目录，**必须已存在**。默认 user://play
##   me=0,2       我坐哪几个席位，逗号分隔。默认 0
##   order=ICIC   席位与顺序，I=免疫 C=癌症，长度即人数
##   seed=0       0 = 用当前时间；填非 0 可复现同一局
##   ai=heur      其余席位的 AI：heur=启发式｜mc=蒙特卡洛
##   tiles=24     初始癌组织格数（不传则按人数取：4 人 15 / 6 人 21）
##   solid=10 cwin=110   固化门槛 / 癌方加权占地胜利门槛（节奏配置用）
##   chold=2     癌方占地胜利要连续几个回合末达标（提案 B，现值 1）
##   agrow / agrow2 / upkeep / amem   四条平衡候选，名字与 balance_scan.gd 一致
## ⚠ 两个脚本的旋钮**必须同步加**。2026-09-01 手打第 5 局就栽在这儿：
##   solid/cwin 只加进了 balance_scan.gd，play.gd 照单全收却不赋值，
##   开局那句 _applied() 回显只打出 prolif=45 —— 幸好有它，否则整局白打。
##
## 协议（dir 下三个文件，外面用 shell 就能操作）：
##   ask.txt    引擎问什么：局面 + 编号选项。**首行 `#序号`**，序号变了才是新的一问。
##              ⚠ 「只剩结束回合」时引擎不问、直接收摊（CWGame.advance）——
##                所以别预先排好一串答案、末尾再补一个「结束回合」：
##                那一下会落到**下一位玩家**头上，把人家整个回合白白结束掉。
##   reply.txt  我答什么：一个数字（选项下标）。引擎读完即删。
##   log.txt    整局流水，追加。
##
## 落到文件而不是 stdin：无头进程挂后台跑时 stdin 不好喂，而文件谁都能写——
## 人用 `echo 3 > reply.txt`，脚本用重定向，两边都不用改。
extends SceneTree

var dir := "user://play"
var me: Array[int] = [0]
var order_str := "ICIC"
var seed_no := 0
var ai := "heur"
## 平衡旋钮。参数名与 balance_scan.gd **完全一致**，两个脚本不许各说各话 ——
## 手打验证的必须是仿真跑出来的那一档，名字对不上就会打成另一个配置。
## 哨兵用 -9999：负系数是合法值（反方向），-1 会把它吃掉。
var tiles := -1
var agrow := -9999
var agrow2 := -9999
var upkeep := -9999
var amem := -9999
var prolif := -1
var solid := -1
var cwin := -1
var chold := -1


func _initialize() -> void:
	_run()


func _run() -> void:
	_parse()
	if not DirAccess.dir_exists_absolute(dir):
		printerr("通信目录不存在：%s" % dir)
		quit(1)
		return
	for f in ["ask.txt", "reply.txt", "log.txt"]:
		DirAccess.remove_absolute(dir.path_join(f))

	var g := CWGame.new()
	g.tune = _tune()          ## 必须在 init() 之前 —— 开局落子就要读旋钮
	g.init(_order(), seed_no if seed_no != 0 else int(Time.get_unix_time_from_system()))
	print("旋钮：%s" % _applied(g.tune))
	var mine := CWFileBridge.new()
	mine.game = g
	mine.dir = dir
	mine.seats = me
	for pid in g.order:
		g.bridges[pid] = mine if pid in me else _ai_bridge(g)
	await g.run_game()

	var tail := "=== 对局结束：%s（%s）===\n" % [
		"癌症方胜" if g.winner == CWData.Faction.CANCER else "免疫方胜", g.win_kind]
	tail += "回合 %d｜癌组织 %d｜固化 %d｜健康 %d｜抗原记忆 %d\n" % [
		g.round_no, g.count_tissue(CWData.Tissue.CANCER),
		g.count_tissue(CWData.Tissue.SOLID), g.count_tissue(CWData.Tissue.HEALTHY), g.memory]
	mine.flush_logs()
	mine.append_log(tail)
	mine.write_text("ask.txt", "#END\n" + tail)
	print(tail)
	g.dispose()
	quit(0)


func _parse() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() != 2:
			continue
		match kv[0]:
			"dir": dir = kv[1]
			"me":
				me = []
				for s in kv[1].split(",", false):
					me.append(int(s))
			"order": order_str = kv[1].to_upper()
			"seed": seed_no = int(kv[1])
			"ai": ai = kv[1]
			"tiles": tiles = int(kv[1])
			"agrow": agrow = int(kv[1])
			"agrow2": agrow2 = int(kv[1])
			"upkeep": upkeep = int(kv[1])
			"amem": amem = int(kv[1])
			"prolif": prolif = int(kv[1])
			"solid": solid = int(kv[1])
			"cwin": cwin = int(kv[1])
			"chold": chold = int(kv[1])


## 只接手打验证真正需要的那几个旋钮（推荐档 + 四条候选），不做全量镜像 ——
## 全量镜像意味着 balance_scan 每加一个旋钮这里都要跟，迟早忘一个、而且忘了不会报错。
func _tune() -> CWTuning:
	var t := CWTuning.new()
	if tiles >= 0:
		t.init_cancer_tiles = tiles
	if prolif >= 0:
		t.proliferate_per_adjacent = prolif
	if solid >= 0:
		t.solidify_threshold = solid
	if cwin >= 0:
		t.cancer_win_weighted = cwin
	if chold >= 1:
		t.cancer_win_hold_rounds = chold
	if agrow != -9999:
		t.aerobic_mult_growth = agrow
	if agrow2 != -9999:
		t.immune_attack_pct_growth = agrow2
	if upkeep != -9999:
		t.cancer_upkeep_pct = upkeep
	if amem != -9999:
		t.immune_attack_pct_per_memory = amem
	return t


## 开局回显真正生效的旋钮。理由同 balance_scan._applied()：
## **旋钮静默失效比没有旋钮更坏** —— 手打一局要花掉几十分钟，
## 打完才发现打的是默认配置，那几十分钟就白扔了。
func _applied(t: CWTuning) -> String:
	var d := CWTuning.new()
	var out: Array = []
	for pair in [["tiles", t.init_cancer_tiles, d.init_cancer_tiles],
			["prolif", t.proliferate_per_adjacent, d.proliferate_per_adjacent],
			["solid", t.solidify_threshold, d.solidify_threshold],
			["cwin", t.cancer_win_weighted, d.cancer_win_weighted],
			["chold", t.cancer_win_hold_rounds, d.cancer_win_hold_rounds],
			["agrow", t.aerobic_mult_growth, d.aerobic_mult_growth],
			["agrow2", t.immune_attack_pct_growth, d.immune_attack_pct_growth],
			["upkeep", t.cancer_upkeep_pct, d.cancer_upkeep_pct],
			["amem", t.immune_attack_pct_per_memory, d.immune_attack_pct_per_memory]]:
		if pair[1] != pair[2]:
			out.append("%s=%s" % [pair[0], str(pair[1])])
	return "默认值" if out.is_empty() else " ".join(out)


func _order() -> Array[int]:
	var out: Array[int] = []
	for i in order_str.length():
		out.append(CWData.Faction.IMMUNE if order_str[i] == "I" else CWData.Faction.CANCER)
	return out


func _ai_bridge(g: CWGame) -> CWBridge:
	if ai == "mc":
		var m := CWMonteCarloBridge.new()
		m.game = g
		return m
	var h := CWHeuristicBridge.new()
	h.game = g
	return h


## 通过文件作答的桥。**同步阻塞**：无头脚本里没有别的东西要跑，
## 与其绕一圈用 process_frame 挂起协程，不如直接 delay + 轮文件，少一半出错面。
class CWFileBridge:
	extends CWBridge

	const POLL_MS := 120           ## 轮询 reply.txt 的间隔
	const IDLE_TIMEOUT_S := 1800.0 ## 这么久没人作答就自己退出，别让无头进程永远挂着

	var dir := ""
	var seats: Array[int] = []

	var _n := 0          ## 问题序号，写进 ask.txt 首行，让外面能分辨「这是不是新的一问」
	var _logged := 0     ## game.logs 已经导出到 log.txt 的行数
	var _rolls: Array[String] = []   ## 上一问之后掷了哪些骰（logs 里没有点数）

	func ask(req: Dictionary) -> int:
		_n += 1
		## 问之前先把上一问残留的作答删掉。**「作答」只对当前这一问有效** ——
		## 外面要是抢跑写了一个（或者上一问的作答没被吃掉就被覆盖），
		## 留着它会被下一问当成答案吃掉，于是从此每一问都错位一格：
		## 表现是「某个玩家的回合莫名其妙被跳过」。删掉 = 抢跑的一律作废。
		DirAccess.remove_absolute(dir.path_join("reply.txt"))
		var body := "#%d\n%s\n" % [_n, _board_text()]
		if not _rolls.is_empty():
			body += "—— 掷骰 ——\n" + "\n".join(_rolls) + "\n"
			_rolls.clear()
		body += _new_logs()
		body += "—— 问（%s%s）——\n%s\n" % [req["kind"],
			"·" + str(req.get("tag", "")) if req.has("tag") else "", req["prompt"]]
		var opts: Array = req["options"]
		for i in opts.size():
			body += "  %2d) %s%s\n" % [i, opts[i]["label"], _pressure_hint(req, opts[i])]
		write_text("ask.txt", body)
		append_log(body)
		return _wait_reply(opts.size())

	## 迁移/攻击类选项后面挂一句「落点的回合末压迫」。
	##
	## 真 UI 是靠**悬停格子详情框**给这个数的，文件协议没有悬停，只能挂在选项上。
	## 两边显示的是**同一个** `CWWorld.pressure_at()` —— 算式只有一份。
	##
	## 只给免疫方挂：压迫只打免疫细胞，给癌方标是噪音。
	func _pressure_hint(req: Dictionary, opt: Dictionary) -> String:
		if int(game.player(req["pid"])["faction"]) != CWData.Faction.IMMUNE:
			return ""
		var d: Dictionary = opt.get("data", {})
		if not d.has("to"):
			return ""
		var pr: int = game.world.pressure_at(d["to"])
		return "" if pr <= 0 else "  ⚠压迫 至少 %s" % CWData.fmt(pr)


	## 掷骰是引擎先算好再广播给所有桥的（架构约定 #11），我只负责记下来给人看。
	func show_roll(reason: String, value: int, sides: int, pid: int, at: Vector2i) -> void:
		_rolls.append("  P%d %s：d%d = %d @%s" % [pid, reason, sides, value, str(at)])

	func show_result(text: String, at: Vector2i) -> void:
		_rolls.append("  → %s @%s" % [text, str(at)])

	func _wait_reply(n_opts: int) -> int:
		var path := dir.path_join("reply.txt")
		var waited := 0.0
		while waited < IDLE_TIMEOUT_S:
			var f := FileAccess.open(path, FileAccess.READ)
			if f != null:
				var s := f.get_as_text().strip_edges()
				f.close()
				DirAccess.remove_absolute(path)
				if s.is_valid_int():
					return clampi(int(s), 0, n_opts - 1)
				append_log("  ⚠ 看不懂的作答「%s」，继续等\n" % s)
			OS.delay_msec(POLL_MS)
			waited += POLL_MS / 1000.0
		append_log("  ⚠ 等作答超时，按下标 0 走\n")
		return 0

	## 引擎自己的流水（谁做了什么、结算成什么样），只导没导过的那几行
	func _new_logs() -> String:
		var out := ""
		while _logged < game.logs.size():
			out += "  " + game.logs[_logged] + "\n"
			_logged += 1
		return "—— 日志 ——\n" + out if out != "" else ""

	func flush_logs() -> void:
		var s := _new_logs()
		if s != "":
			append_log(s)

	## 13×13 的坐标网格，而不是排成六边形的样子 ——
	## 选项标签里的坐标是 `(q, r)` 原样打印的，网格能按行列直接查到，
	## 摆成六边形好看，但要数着缩进去找坐标，反而容易看错。
	func _board_text() -> String:
		var cell_at := {}
		for c in game.cells:
			if c["alive"]:
				cell_at[c["pos"]] = c["pid"] if not cell_at.has(c["pos"]) else -1
		var out := "—— 棋盘（组织 . 健康 + 癌 # 固化｜特殊 o 核 m 髓 v 管｜数字=玩家）——\n"
		out += "    q="
		for q in range(-CWData.BOARD_RADIUS, CWData.BOARD_RADIUS + 1):
			out += "%3d" % q
		out += "\n"
		for r in range(-CWData.BOARD_RADIUS, CWData.BOARD_RADIUS + 1):
			out += "r=%3d " % r
			for q in range(-CWData.BOARD_RADIUS, CWData.BOARD_RADIUS + 1):
				var c := Vector2i(q, r)
				if not game.tiles.has(c):
					out += "   "
					continue
				var t: Dictionary = game.tiles[c]
				var base: String = [".", "+", "#"][t["tissue"]]
				var over := " "
				if cell_at.has(c):
					over = "*" if cell_at[c] < 0 else str(cell_at[c])
				elif t["special"] != CWData.Special.NONE:
					over = [" ", "o", "m", "v"][t["special"]]
				out += " " + base + over
			out += "\n"
		out += _notable_tiles()
		out += "—— 细胞 ——\n"
		for c in game.cells:
			out += "  %sP%d %s @%s 能量 %s%s%s%s\n" % [
				"➤" if c["pid"] in seats else " ", c["pid"], game.cell_name(c), str(c["pos"]),
				CWData.fmt(c["energy"]),
				## 癌细胞的 respawn_round 恒为 -1：它不按回合复活，而是要有固化癌组织当据点，
				## 照着免疫的写法打印会变成「可复活回合 -1」这种看不懂的话
				"" if c["alive"] else ("（死亡，可复活回合 %d）" % c["respawn_round"]
					if c["respawn_round"] >= 0 else "（死亡，等固化癌组织复活）"),
				"｜攻 %d 抽 %d" % [c["attacks_used"], c["draws_used"]] if c["pid"] in seats else "",
				"｜手牌 %s" % ("、".join(c["hand"]) if not c["hand"].is_empty() else "无")
					if c["pid"] in seats else "｜手牌 %d 张" % c["hand"].size()]
			## 真 UI 靠悬停格子详情框给这个数（CWTileInfo 的「回合末压迫」行），
			## 文件协议没有悬停，所以直接摊在细胞行下面。
			## **工具必须和真 UI 给一样多的信息** —— 否则手打出来的「人类打不过 AI」
			## 里会混进一截是工具造成的（2026-09-01 那五局就是在没有这一行的界面上打的）。
			if c["alive"] and c["faction"] == CWData.Faction.IMMUNE:
				var pr: int = game.world.pressure_at(c["pos"])
				out += "      回合末压迫 %s\n" % ("无" if pr <= 0 else "至少 " + CWData.fmt(pr))
			if c["pid"] in seats and not c["equipped"].is_empty():
				out += "      已装备：%s\n" % "、".join(c["equipped"])
			if c["pid"] in seats and not c["mods"].is_empty():
				var ms: Array[String] = []
				for m in c["mods"]:
					ms.append("%s×%d" % [m["name"], m["uses"]])
				out += "      修饰：%s\n" % "、".join(ms)
		var evs: Array[String] = []
		for e in game.events["active"]:
			evs.append(str(e["name"]))
		out += "—— 全局 —— 第 %d 世界回合｜健康 %d 癌 %d 固化 %d｜抗原记忆 %d｜事件 %s\n" % [
			game.round_no, game.count_tissue(CWData.Tissue.HEALTHY),
			game.count_tissue(CWData.Tissue.CANCER), game.count_tissue(CWData.Tissue.SOLID),
			game.memory, "、".join(evs) if not evs.is_empty() else "无"]
		return out

	## 黏液、坏死、存储这些是**会影响下一步怎么走**的格子状态，
	## 但一格只有两个字符，塞不进网格里，所以单列一行。没有就不打印。
	func _notable_tiles() -> String:
		var parts: Array[String] = []
		for c in game.tiles:
			var t: Dictionary = game.tiles[c]
			var tags: Array[String] = []
			if t["mucus"]:
				tags.append("黏液")
			if t["necrosis"] > 0:
				tags.append("坏死%d" % t["necrosis"])
			if t["newborn"]:
				tags.append("新生")
			if t["store"] > 0:
				tags.append("存能%s" % CWData.fmt(t["store"]))
			if t["cards"] > 0:
				tags.append("存卡%d" % t["cards"])
			if not tags.is_empty():
				parts.append("%s%s" % [str(c), "/".join(tags)])
		return "  值得注意：%s\n" % " ".join(parts) if not parts.is_empty() else ""

	## 先写临时文件再改名。外面是靠「ask.txt 首行的序号变了没有」判断新问题的，
	## 而直接覆写有一瞬间文件是空的 —— 那一瞬被读到就会被当成新问题，读到半截内容。
	func write_text(name: String, text: String) -> void:
		var tmp := dir.path_join(name + ".tmp")
		var f := FileAccess.open(tmp, FileAccess.WRITE)
		if f == null:
			return
		f.store_string(text)
		f.close()
		DirAccess.remove_absolute(dir.path_join(name))
		DirAccess.rename_absolute(tmp, dir.path_join(name))

	func append_log(text: String) -> void:
		var path := dir.path_join("log.txt")
		var f := FileAccess.open(path, FileAccess.READ_WRITE) \
			if FileAccess.file_exists(path) else FileAccess.open(path, FileAccess.WRITE)
		if f != null:
			f.seek_end()
			f.store_string(text)
			f.close()
