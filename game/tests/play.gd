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
##   logdir=<目录> 整局流水 log.txt 写到哪，默认 = dir。**几个人分别坐席时必须分开**：
##                log.txt 是各席视角的问题原样追加起来的，里面有全场的手牌 ——
##                和 ask.txt 放同一个目录，任谁想「补一下前情」cat 一下就是全场明牌
##   me=0,2       我坐哪几个席位，逗号分隔。默认 0
##   idle=14400   多久没人作答就替他按 0 号选项走（秒，默认 1800）。**这是个静默污染源**：
##                2026-09-05 四个智能体同时撞上额度上限、四局全停，30 分钟后引擎就开始
##                替他们代答，等我回来一看每局已经被代答了 3 步 —— 局面还在、数据废了。
##                所以智能体对弈一律把它调大（代价是真卡住时进程不会自己收摊，
##                但那本来就该我去查，而不是让它替我糊过去）。
##   hide=1       **多个席位由互不通气的几个人分别操作**时打开：手牌/装备/修饰这些私密信息
##                只对**当前被问到的那一席**显示，别席一律按对手的口径打印（只给张数）。
##                默认 0 = 老行为（`me=` 里全部席位的私密信息都摊开），因为原来的用法是
##                「一个人同时坐 me=0,2,4 三个免疫席」—— 那本来就是同一个人，藏没有意义。
##                2026-09-05 加：4 个 subagent 各坐一席对弈，不加这个就是四方明牌
##   order=ICIC   席位与顺序，I=免疫 C=癌症，长度即人数
##   seed=0       0 = 用当前时间；填非 0 可复现同一局
##   ai=heur      其余席位的 AI：heur=启发式｜mc=蒙特卡洛
##   tiles=24     初始癌组织格数（不传则按人数取：4 人 15 / 6 人 24）
##   solid=10 cwin=110   固化门槛 / 癌方加权占地胜利门槛（节奏配置用）
##   chold=1     癌方占地胜利要连续几个回合末达标（现值 2 = 定案 B；1 = 旧规则）
##   amult=36     有氧呼吸系数（PRD 是 30 = 公式里的「×3」），名字与 balance_scan.gd 一致；
##                2026-09-04 定的方向「加免疫收入」就是动它，2026-09-05 才发现 play.gd 一直没接
##   agrow / agrow2 / upkeep / amem   四条平衡候选，名字与 balance_scan.gd 一致
##   mheal / mvx / abmax / rdelay     2026-09-02「免疫后期引擎」四根杠杆，名字与 balance_scan.gd 一致
##   lineup=mel,sclc  癌种钉死，按癌席出场顺序（mel/sig/ost/sclc），与 balance_scan.gd 一致；2026-09-03 专项复现「黑色素瘤 + 小细胞肺癌」
##   renergy=5        免疫复活初始能量（十分能量，现值 10），与 balance_scan.gd 一致；2026-09-03「送死回血」战术
##   metamax / metacost  小细胞【转移】每世界回合上限 / 费用，与 balance_scan.gd 一致；2026-09-03 晚「黑 + 小同场」候选杠杆
##   lvl=2            开局就把免疫等级给到 III（0=I 1=II 2=III 3=X）。**只给手打验证用**：
##                    分化要 III 级解锁，正常得打十几回合，验证树突【趋化源】等不起。balance_scan 没有这个旋钮
## ⚠ 两个脚本的旋钮**必须同步加**。2026-09-01 手打第 5 局就栽在这儿：
##   solid/cwin 只加进了 balance_scan.gd，play.gd 照单全收却不赋值，
##   开局那句 _applied() 回显只打出 prolif=45 —— 幸好有它，否则整局白打。
##
## 协议（dir 下三个文件，外面用 shell 就能操作）：
##   ask.txt    引擎问什么：局面 + 编号选项。**首行 `#序号 P席位号`**，序号变了才是新的一问。
##              席位号是 2026-09-05 加的：多个人分别盯同一个 ask.txt 时，
##              得先认出「这一问是不是问我」，靠 prompt 里的「免疫A：」去猜太脆。
##              ⚠ 「只剩结束回合」时引擎不问、直接收摊（CWGame.advance）——
##                所以别预先排好一串答案、末尾再补一个「结束回合」：
##                那一下会落到**下一位玩家**头上，把人家整个回合白白结束掉。
##   reply.txt  我答什么：一个数字（选项下标）。引擎读完即删。
##              也可以写成 `序号:下标`（如 `47:3`）—— 序号对不上就**作废并继续等**。
##              多个人共用一个 reply.txt 时这是防串台的唯一手段：
##              没有它，甲慢一拍写下的作答会被乙的那一问吃掉，从此整局错位。
##   log.txt    整局流水，追加。
##
## 落到文件而不是 stdin：无头进程挂后台跑时 stdin 不好喂，而文件谁都能写——
## 人用 `echo 3 > reply.txt`，脚本用重定向，两边都不用改。
extends SceneTree

var dir := "user://play"
var logdir := ""          ## 空 = 跟 dir 同目录
var me: Array[int] = [0]
var order_str := "ICIC"
var seed_no := 0
var ai := "heur"
## 私密信息只给当前被问到的那一席看（见头注 hide=）
var hide_others := false
## 多久没人作答就代答（秒）。见头注 idle=
var idle_timeout := 1800
## 平衡旋钮。参数名与 balance_scan.gd **完全一致**，两个脚本不许各说各话 ——
## 手打验证的必须是仿真跑出来的那一档，名字对不上就会打成另一个配置。
## 哨兵用 -9999：负系数是合法值（反方向），-1 会把它吃掉。
var tiles := -1
## 开局免疫等级（0=I 1=II 2=III 3=X）。**只给手打验证用** ——
## 分化要 III 级解锁，正常要打十几回合才够抗原记忆，验证树突时等不起。
## 不进 balance_scan：平衡数字必须从正常开局跑出来，不能从半局开始。
var lvl := -1
var agrow := -9999
var agrow2 := -9999
var upkeep := -9999
var amem := -9999
var amult := -1
var abhalf := -1
var asqrt := -1
var prolif := -1
var solid := -1
var cwin := -1
var chold := -1
var mheal := -1
var mvx := -1
var abmax := -1
var rdelay := -9999   ## -1 是合法值（不再复活），哨兵不能用 -1
var lineup := ""
var renergy := -1
var metamax := -1
var metacost := -1
var newborn := -1

const LINEUP_CODES := { "mel": CWData.CancerType.MELANOMA, "sig": CWData.CancerType.SIGNET,
	"ost": CWData.CancerType.OSTEO, "sclc": CWData.CancerType.SCLC }


func _initialize() -> void:
	_run()


func _run() -> void:
	_parse()
	if logdir == "":
		logdir = dir
	for d in [dir, logdir]:
		if not DirAccess.dir_exists_absolute(d):
			printerr("目录不存在：%s" % d)
			quit(1)
			return
	DirAccess.remove_absolute(logdir.path_join("log.txt"))
	for f in ["ask.txt", "reply.txt"]:
		DirAccess.remove_absolute(dir.path_join(f))

	var g := CWGame.new()
	g.tune = _tune()          ## 必须在 init() 之前 —— 开局落子就要读旋钮
	g.init(_order(), seed_no if seed_no != 0 else int(Time.get_unix_time_from_system()))
	if lvl >= 0:
		g.immune_level = clampi(lvl, 0, CWData.LEVEL_NAMES.size() - 1)
		print("！手打验证：开局免疫等级直接给到 %s 级（lvl=%d）"
			% [CWData.LEVEL_NAMES[g.immune_level], lvl])
	print("旋钮：%s" % _applied(g.tune))
	var mine := CWFileBridge.new()
	mine.game = g
	mine.dir = dir
	mine.seats = me
	mine.hide_others = hide_others
	mine.logdir = logdir
	mine.idle_timeout = float(idle_timeout)
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
			"logdir": logdir = kv[1]
			"me":
				me = []
				for s in kv[1].split(",", false):
					me.append(int(s))
			"hide": hide_others = kv[1] != "0"
			"idle": idle_timeout = int(kv[1])
			"order": order_str = kv[1].to_upper()
			"seed": seed_no = int(kv[1])
			"ai": ai = kv[1]
			"tiles": tiles = int(kv[1])
			"lvl": lvl = int(kv[1])
			"amult": amult = int(kv[1])
			"abhalf": abhalf = int(kv[1])
			"asqrt": asqrt = int(kv[1])
			"agrow": agrow = int(kv[1])
			"agrow2": agrow2 = int(kv[1])
			"upkeep": upkeep = int(kv[1])
			"amem": amem = int(kv[1])
			"prolif": prolif = int(kv[1])
			"solid": solid = int(kv[1])
			"cwin": cwin = int(kv[1])
			"chold": chold = int(kv[1])
			"mheal": mheal = int(kv[1])
			"mvx": mvx = int(kv[1])
			"abmax": abmax = int(kv[1])
			"rdelay": rdelay = int(kv[1])
			"lineup": lineup = kv[1]
			"renergy": renergy = int(kv[1])
			"metamax": metamax = int(kv[1])
			"metacost": metacost = int(kv[1])
			"newborn": newborn = int(kv[1])
			## 认不出来的参数**必须报错**。头注里那条纪律（两个脚本的旋钮要同步加）
			## 靠自觉守了三次都漏了一次 —— 2026-09-01 手打第 5 局、2026-09-05 的 amult
			## 都是「传了、没接、静默按默认值打完一整局」。让它自己喊出来。
			_: printerr("不认识的参数「%s」—— balance_scan.gd 有而这里没接？整局会按默认值打" % kv[0])


## 只接手打验证真正需要的那几个旋钮（推荐档 + 四条候选），不做全量镜像 ——
## 全量镜像意味着 balance_scan 每加一个旋钮这里都要跟，迟早忘一个、而且忘了不会报错。
func _tune() -> CWTuning:
	var t := CWTuning.new()
	if tiles >= 0:
		t.init_cancer_tiles = tiles
	if amult >= 0:
		t.aerobic_mult = amult
	if abhalf >= 0:
		t.antibody_halve = abhalf != 0
	if asqrt >= 0:
		t.anaerobic_sqrt_coef = asqrt
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
	if mheal >= 0:
		t.macro_heal_purify = mheal
	if mvx >= 0:
		t.immune_move_cancerous[3] = mvx
	if abmax >= 0:
		t.antibody_max_per_round = abmax
	if rdelay != -9999:
		t.immune_respawn_delay = rdelay
	if renergy >= 0:
		t.immune_respawn_energy = renergy
	if metamax >= 0:
		t.metastasis_max_per_round = metamax
	if metacost >= 0:
		t.metastasis_cost = metacost
	if newborn >= 0:
		t.newborn_protect = newborn != 0
	for code in lineup.split(",", false):
		if LINEUP_CODES.has(code):
			t.cancer_types.append(LINEUP_CODES[code])
		else:
			printerr("lineup= 不认识的癌种代号：%s（可用 mel / sig / ost / sclc）" % code)
	return t


## 开局回显真正生效的旋钮。理由同 balance_scan._applied()：
## **旋钮静默失效比没有旋钮更坏** —— 手打一局要花掉几十分钟，
## 打完才发现打的是默认配置，那几十分钟就白扔了。
func _applied(t: CWTuning) -> String:
	var d := CWTuning.new()
	var out: Array = []
	for pair in [["tiles", t.init_cancer_tiles, d.init_cancer_tiles],
			["amult", t.aerobic_mult, d.aerobic_mult],
			["abhalf", int(t.antibody_halve), int(d.antibody_halve)],
			["asqrt", t.anaerobic_sqrt_coef, d.anaerobic_sqrt_coef],
			["prolif", t.proliferate_per_adjacent, d.proliferate_per_adjacent],
			["solid", t.solidify_threshold, d.solidify_threshold],
			["cwin", t.cancer_win_weighted, d.cancer_win_weighted],
			["chold", t.cancer_win_hold_rounds, d.cancer_win_hold_rounds],
			["agrow", t.aerobic_mult_growth, d.aerobic_mult_growth],
			["agrow2", t.immune_attack_pct_growth, d.immune_attack_pct_growth],
			["upkeep", t.cancer_upkeep_pct, d.cancer_upkeep_pct],
			["amem", t.immune_attack_pct_per_memory, d.immune_attack_pct_per_memory],
			["mheal", t.macro_heal_purify, d.macro_heal_purify],
			["mvx", t.immune_move_cancerous[3], d.immune_move_cancerous[3]],
			["abmax", t.antibody_max_per_round, d.antibody_max_per_round],
			["rdelay", t.immune_respawn_delay, d.immune_respawn_delay],
			["renergy", t.immune_respawn_energy, d.immune_respawn_energy],
			["metamax", t.metastasis_max_per_round, d.metastasis_max_per_round],
			["metacost", t.metastasis_cost, d.metastasis_cost],
			["newborn", int(t.newborn_protect), int(d.newborn_protect)]]:
		if pair[1] != pair[2]:
			out.append("%s=%s" % [pair[0], str(pair[1])])
	if not t.cancer_types.is_empty():
		var names: Array = []
		for ct in t.cancer_types:
			names.append(CWData.CANCER_TYPE_NAMES[ct])
		out.append("lineup=%s" % "+".join(names))
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

	const POLL_MS := 120          ## 轮询 reply.txt 的间隔
	## 这么久没人作答就按 0 号选项替他走，别让无头进程永远挂着。
	## **代答是静默的数据污染**（局面照走、数据已废），所以可以从命令行调大，见头注 idle=
	var idle_timeout := 1800.0

	var dir := ""
	var logdir := ""
	var seats: Array[int] = []
	var hide_others := false
	var _focus := -1     ## 当前被问到的席位；hide_others 打开时，只有它的私密信息露出来

	var _n := 0          ## 问题序号，写进 ask.txt 首行，让外面能分辨「这是不是新的一问」
	var _logged := 0     ## game.logs 已经导出到 log.txt 的行数
	var _rolls: Array[String] = []   ## 上一问之后掷了哪些骰（logs 里没有点数）

	func ask(req: Dictionary) -> int:
		_n += 1
		_focus = int(req["pid"])     ## 必须早于 _board_text()：棋盘要按这一席的视角打印
		## 问之前先把上一问残留的作答删掉。**「作答」只对当前这一问有效** ——
		## 外面要是抢跑写了一个（或者上一问的作答没被吃掉就被覆盖），
		## 留着它会被下一问当成答案吃掉，于是从此每一问都错位一格：
		## 表现是「某个玩家的回合莫名其妙被跳过」。删掉 = 抢跑的一律作废。
		DirAccess.remove_absolute(dir.path_join("reply.txt"))
		var body := "#%d P%d\n%s\n" % [_n, _focus, _board_text()]
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


	## 这一席的私密信息（手牌内容、装备、修饰、攻击/抽牌次数）该不该露出来。
	## hide_others 关着 = 老行为：`me=` 里的席位全露（一个人坐好几席，藏没意义）；
	## 打开 = 只露当前被问到的那一席（几个人分别坐，露了就是明牌）。
	func _open(pid: int) -> bool:
		return pid in seats and (not hide_others or pid == _focus)


	## 掷骰是引擎先算好再广播给所有桥的（架构约定 #11），我只负责记下来给人看。
	func show_roll(reason: String, value: int, sides: int, pid: int, at: Vector2i) -> void:
		_rolls.append("  P%d %s：d%d = %d @%s" % [pid, reason, sides, value, str(at)])

	func show_result(text: String, at: Vector2i) -> void:
		_rolls.append("  → %s @%s" % [text, str(at)])

	func _wait_reply(n_opts: int) -> int:
		var path := dir.path_join("reply.txt")
		var waited := 0.0
		while waited < idle_timeout:
			var f := FileAccess.open(path, FileAccess.READ)
			if f != null:
				var s := f.get_as_text().strip_edges()
				f.close()
				DirAccess.remove_absolute(path)
				## 作答可以写成 `序号:下标`。几个人共用一个 reply.txt 时，
				## 慢一拍的那个作答会正好落进下一问的窗口里被吃掉 ——
				## 带上问号就能认出来并作废，代价是那一位要重答。
				var seq := -1
				var pick := s
				if ":" in s:
					var kv := s.split(":", true, 1)
					if kv[0].strip_edges().is_valid_int():
						seq = int(kv[0])
						pick = kv[1].strip_edges()
				if seq >= 0 and seq != _n:
					append_log("  ⚠ 作答标的是第 %d 问，当前是第 %d 问，作废\n" % [seq, _n])
				elif pick.is_valid_int():
					return clampi(int(pick), 0, n_opts - 1)
				else:
					append_log("  ⚠ 看不懂的作答「%s」，继续等\n" % s)
			OS.delay_msec(POLL_MS)
			waited += POLL_MS / 1000.0
		append_log("  ⚠ 等作答超时（%ds），按下标 0 替他走 —— 这一步起数据已被污染\n"
			% int(idle_timeout))
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
		## 图例一律「符号 = 名字」写全。原来写的是「组织 . 健康 + 癌 # 固化」——
		## 本意是「. 健康、+ 癌、# 固化」，但读的人会顺着断成「组织 .」「健康 +」「癌 #」，
		## 整体错位一位，于是把**癌组织读成健康组织**。2026-09-05 一个智能体就是靠
		## 亲眼看着自己那格从「+」变「#」才纠过来的。
		var out := "—— 棋盘（底色 . 是健康、+ 是癌、# 是固化｜叠加 o 代谢核心、m 骨髓、v 血管、数字是玩家）——\n"
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
				"➤" if _open(c["pid"]) else " ", c["pid"], game.cell_name(c), str(c["pos"]),
				CWData.fmt(c["energy"]),
				## 癌细胞的 respawn_round 恒为 -1：它不按回合复活，而是要有固化癌组织当据点，
				## 照着免疫的写法打印会变成「可复活回合 -1」这种看不懂的话
				"" if c["alive"] else ("（死亡，可复活回合 %d）" % c["respawn_round"]
					if c["respawn_round"] >= 0 else "（死亡，等固化癌组织复活）"),
				"｜攻 %d 抽 %d" % [c["attacks_used"], c["draws_used"]] if _open(c["pid"]) else "",
				"｜手牌 %s" % ("、".join(c["hand"]) if not c["hand"].is_empty() else "无")
					if _open(c["pid"]) else "｜手牌 %d 张" % c["hand"].size()]
			## 真 UI 靠悬停格子详情框给这个数（CWTileInfo 的「回合末压迫」行），
			## 文件协议没有悬停，所以直接摊在细胞行下面。
			## **工具必须和真 UI 给一样多的信息** —— 否则手打出来的「人类打不过 AI」
			## 里会混进一截是工具造成的（2026-09-01 那五局就是在没有这一行的界面上打的）。
			if c["alive"] and c["faction"] == CWData.Faction.IMMUNE:
				var pr: int = game.world.pressure_at(c["pos"])
				out += "      回合末压迫 %s\n" % ("无" if pr <= 0 else "至少 " + CWData.fmt(pr))
			if _open(c["pid"]) and not c["equipped"].is_empty():
				out += "      已装备：%s\n" % "、".join(c["equipped"])
			if _open(c["pid"]) and not c["mods"].is_empty():
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
		var path := logdir.path_join("log.txt")
		var f := FileAccess.open(path, FileAccess.READ_WRITE) \
			if FileAccess.file_exists(path) else FileAccess.open(path, FileAccess.WRITE)
		if f != null:
			f.seek_end()
			f.store_string(text)
			f.close()
