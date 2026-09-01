## balance_scan.gd —— 参数化平衡扫描：席位组成 / 基准 AI / 单个旋钮都从命令行给
##
## 运行（注意旋钮参数要写在 `--` 之后）：
##   godot --headless --path game --script res://tests/balance_scan.gd -- order=ICIC games=100 ai=heur
##   godot --headless --path game --script res://tests/balance_scan.gd -- order=ICIICI games=30 ai=mc mv=4
##
## 和另外两个平衡脚本的分工：
## - `balance_sim.gd`：一套固定配置跑详细报表（癌种表现、胜利方式），改配置要改常量。
## - `balance_variants.gd`：多套 CWTuning **预设** × 多种人数的矩阵，加方案要写代码。
## - 本脚本：**席位组成**和**单个旋钮**从命令行扫，不改代码就能跑网格。
##   2026-08-31 评估「6 人局改 4v2」时加的 —— 那个问题要扫的是席位，前两个脚本都做不到。
##
## 参数（全部可省）：
##   order=ICIC   席位与顺序，I=免疫 C=癌症，长度即人数
##   games=100    局数    seed=20260800  起始种子
##   ai=heur      heur=双方启发式｜mc=双方蒙特卡洛｜mc_immune／mc_cancer=只有一方用
##   rollouts=1 horizon=12   蒙特卡洛参数
##   tune=prd     prd=PRD 原样｜split=免疫收入也按细胞数均分（报告 #29 的修法）
##   mv=4         免疫迁移到癌性组织的费用，十分能量，**各等级统一**（PRD 是 [10,10,7,5]）
##   ecap / efloor / acap / afloor   无氧／有氧呼吸的每细胞**每回合进账**的封顶与低保，十分能量
##   emax=150   细胞账面能量上限（口径 #92，管的是存量不是流量）。0 = 不封
##   tiles=32     初始癌组织格数。**不传则按人数取**（现值 4 人 15 / 6 人 21，PRD 是固定 15）
##   amult=60     有氧呼吸系数（PRD 是 30 = 公式里的「×3」）
##   cmh / cmc    癌方移动到健康／癌性组织的费用 —— 前者就是占地单价（现值 12 / 2，PRD 5 / 2）
##   sclc / pseu  【极简胞浆】与【伪足穿透】的折后价（现值 7 / 5，PRD 3 / 2）
##   lesion=off   关掉【原发灶】（癌细胞出生格开局固化）。默认 on
##   counter=0    攻击失败时攻击者的自损（现值 5 = PRD 的 0.5）
##   atkmax=3     免疫每行动回合最多攻击几次（现值 3）
##   ecancer=60   癌细胞初始能量，十分能量（现值 30 = 3.0，与免疫同）
##
## ⚠ 2026-08-31 口径 #82 之后，**不传旋钮 = 引擎现值，不是 PRD 原样**。
## 要跑 PRD 原样做对照得显式写全：`cmh=5 sclc=3 pseu=2 tiles=15`。
extends SceneTree

var games := 100
var base_seed := 20260800
var order_str := "ICIC"
var ai := "heur"
var rollouts := 1
var horizon := 12
var label := ""
var tune_name := "prd"
var mv := -1        # -1 = 不改，下同
var ecap := -1
var emax := -1
var efloor := -1
var acap := -1
var afloor := -1
var tiles := -1
var counter := -1
var lesion := ""    # "off" = 关掉原发灶
var atkmax := -1
var ecancer := -1
var amult := -1
var cmh := -1
var cmc := -1
var sclc := -1
var pseu := -1


func _initialize() -> void:
	_run()


func _parse() -> void:
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.split("=", true, 1)
		if kv.size() != 2:
			continue
		match kv[0]:
			"order": order_str = kv[1]
			"games": games = int(kv[1])
			"seed": base_seed = int(kv[1])
			"ai": ai = kv[1]
			"rollouts": rollouts = int(kv[1])
			"horizon": horizon = int(kv[1])
			"label": label = kv[1]
			"tune": tune_name = kv[1]
			"mv": mv = int(kv[1])
			"ecap": ecap = int(kv[1])
			"emax": emax = int(kv[1])
			"efloor": efloor = int(kv[1])
			"acap": acap = int(kv[1])
			"afloor": afloor = int(kv[1])
			"tiles": tiles = int(kv[1])
			"counter": counter = int(kv[1])
			"lesion": lesion = kv[1]
			"atkmax": atkmax = int(kv[1])
			"ecancer": ecancer = int(kv[1])
			"amult": amult = int(kv[1])
			"cmh": cmh = int(kv[1])
			"cmc": cmc = int(kv[1])
			"sclc": sclc = int(kv[1])
			"pseu": pseu = int(kv[1])


func _order() -> Array:
	var out := []
	for ch in order_str:
		out.append(CWData.Faction.IMMUNE if ch == "I" else CWData.Faction.CANCER)
	return out


func _tune() -> CWTuning:
	var t: CWTuning = CWTuning.split_income() if tune_name == "split" else CWTuning.new()
	if mv >= 0:
		t.immune_move_cancerous = [mv, mv, mv, mv]
	if ecap >= 0:
		t.anaerobic_cap = ecap
	if emax >= 0:
		t.energy_cap = emax
	if efloor >= 0:
		t.anaerobic_floor = efloor
	if acap >= 0:
		t.aerobic_cap = acap
	if afloor >= 0:
		t.aerobic_floor = afloor
	if tiles >= 0:
		t.init_cancer_tiles = tiles
	if amult >= 0:
		t.aerobic_mult = amult
	if cmh >= 0:
		t.cancer_move_healthy = cmh
	if cmc >= 0:
		t.cancer_move_cancerous = cmc
	if sclc >= 0:
		t.sclc_move_healthy = sclc
	if pseu >= 0:
		t.pseudopod_cost = pseu
	if counter >= 0:
		t.counter_dmg_on_fail = counter
	if atkmax >= 0:
		t.attack_max_per_turn = atkmax
	if ecancer >= 0:
		t.init_energy_cancer = ecancer
	if lesion != "":
		t.solid_at_cancer_spawn = lesion != "off"
	return t


## 把「本次真正改掉的旋钮」回读出来，打进结果行。
## 2026-08-31 加：`atkmax` / `counter` / `lesion` 三个曾经**接漏了**——
## 参数收下了、`_tune()` 里没赋值，于是整张网格跑出来一模一样，
## 而输出里看不出任何异常。旋钮静默失效比没有旋钮更坏，所以现在强制回显。
func _applied(t: CWTuning) -> String:
	var d := CWTuning.new()
	var out: Array = []
	if t.immune_move_cancerous != d.immune_move_cancerous:
		out.append("mv=%s" % str(t.immune_move_cancerous[0]))
	for pair in [["emax", t.energy_cap, d.energy_cap],
			["ecap", t.anaerobic_cap, d.anaerobic_cap],
			["efloor", t.anaerobic_floor, d.anaerobic_floor],
			["acap", t.aerobic_cap, d.aerobic_cap],
			["afloor", t.aerobic_floor, d.aerobic_floor],
			["tiles", t.init_cancer_tiles, d.init_cancer_tiles],
			["amult", t.aerobic_mult, d.aerobic_mult],
			["cmh", t.cancer_move_healthy, d.cancer_move_healthy],
			["cmc", t.cancer_move_cancerous, d.cancer_move_cancerous],
			["sclc", t.sclc_move_healthy, d.sclc_move_healthy],
			["pseu", t.pseudopod_cost, d.pseudopod_cost],
			["counter", t.counter_dmg_on_fail, d.counter_dmg_on_fail],
			["atkmax", t.attack_max_per_turn, d.attack_max_per_turn],
			["ecancer", t.init_energy_cancer, d.init_energy_cancer]]:
		if pair[1] != pair[2]:
			out.append("%s=%s" % [pair[0], str(pair[1])])
	if t.solid_at_cancer_spawn != d.solid_at_cancer_spawn:
		out.append("lesion=%s" % ("on" if t.solid_at_cancer_spawn else "off"))
	if t.aerobic_split != d.aerobic_split:
		out.append("tune=split")
	return "默认值" if out.is_empty() else " ".join(out)


func _bridge(g: CWGame, faction: int) -> Object:
	var use_mc := ai == "mc" \
		or (ai == "mc_immune" and faction == CWData.Faction.IMMUNE) \
		or (ai == "mc_cancer" and faction == CWData.Faction.CANCER)
	if not use_mc:
		var h := CWHeuristicBridge.new()
		h.game = g
		return h
	var m := CWMonteCarloBridge.new()
	m.game = g
	m.rollouts = rollouts
	m.horizon = horizon
	return m


func _run() -> void:
	_parse()
	var order := _order()
	var cancer_wins := 0
	var rounds_sum := 0
	var by_limit := 0
	var cancerous_sum := 0
	var kinds := {}
	## 占地吞吐：转化比是判断「谁在抢地」的直接指标，比胜率更能指向根因
	var colonize := 0
	var prolif_n := 0
	var purify := 0
	var t0 := Time.get_ticks_msec()
	for gi in games:
		var g := CWGame.new()
		g.tune = _tune()
		g.init(order, base_seed + gi)
		for pid in g.order:
			g.bridges[pid] = _bridge(g, g.player(pid)["faction"])
		var w: int = await g.run_game()
		if w == CWData.Faction.CANCER:
			cancer_wins += 1
		if g.win_kind.begins_with("limit_"):
			by_limit += 1
		kinds[g.win_kind] = kinds.get(g.win_kind, 0) + 1
		rounds_sum += g.round_no
		cancerous_sum += g.count_tissue(CWData.Tissue.CANCER) + g.count_tissue(CWData.Tissue.SOLID)
		## 蒙特卡洛试算期间 sim_quiet=true，推演里的行动不会进 logs，所以这里数的是真实盘面
		for line in g.logs:
			if line.contains("【定殖】"):
				colonize += 1
			elif line.contains("【净化】"):
				purify += 1
			elif line.contains("【增生】"):
				prolif_n += int(line.split("】")[1].split(" ")[0])
		g.dispose()
	var secs := (Time.get_ticks_msec() - t0) / 1000.0
	print("%-24s 席位 %-8s AI %-9s | 癌胜 %3d%% (%d/%d) | 平均 %4.1f 回合 | 上限判定 %2d 局 | 终局癌性 %5.1f 格 | %.0fs" % [
		label if label != "" else order_str, order_str, ai,
		cancer_wins * 100 / games, cancer_wins, games,
		float(rounds_sum) / games, by_limit, float(cancerous_sum) / games, secs])
	print("        旋钮：%s" % _applied(_tune()))
	var ks: Array = kinds.keys()
	ks.sort()
	var parts: Array = []
	for k in ks:
		parts.append("%s %d" % [k, kinds[k]])
	print("        胜法：%s" % ", ".join(parts))
	print("        每局占地：癌【定殖】%.1f + 【增生】%.1f vs 免疫【净化】%.1f（转化比 %.1f:1）" % [
		float(colonize) / games, float(prolif_n) / games, float(purify) / games,
		float(colonize + prolif_n) / maxf(float(purify), 1.0)])
	quit(0)
