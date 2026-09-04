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
##   tiles=32     初始癌组织格数。**不传则按人数取**（现值 4 人 15 / 6 人 24，PRD 是固定 15）
##   amult=60     有氧呼吸系数（PRD 是 30 = 公式里的「×3」）
##   cwin=100     癌方加权占地胜利门槛（现值 90 = 癌组织×1 + 固化×2；2026-09-01 定案乙之前是 85）。
##                注意固化在这条式子里**算 2 格**，所以「让固化更容易」会同时
##                加速癌方的占地胜利 —— 想拉长对局必须两个数一起动。
##   chold=1      癌方占地胜利要**连续几个回合末**达标（现值 2 = 定案 B；1 = 旧规则「达标即胜」）。提案 B 的初衷：
##                给免疫方一个完整的回应回合，专治「末位癌细胞一口气铺到线、紧接着就判」。
##   solid=10     【固化】门槛，十分整数（现值 20 = 蹲满 2 个回合；2026-09-01 定案乙之前是 30）。
##                2026-09-01 手打发现：癌方最优打法是一直动、一直铺，
##                蹲 3 回合等于放弃 30 格扩张，所以**固化在实战中从不出现**
##                （三局手打 36 次盘面快照全是 0）。而固化是癌方唯一的复活据点，
##                于是「三个癌细胞被团灭」= 立刻结束 = 6 人局 66% 的对局。
##                这条是「对局太短」的主因，扫它要看的是**回合数**不只是胜率。
##   prolif=35    【E-增生】每个相邻癌性组织贡献的概率，千分率（现值 30 = 3%）。
##                9-01 二版 PRD 把它从 40 降到 30，当场实测 4 人局癌胜 64%→36%，
##                是全库杠杆最重的一个旋钮，此前竟然扫不了。
##   agrow=2      【候选①】有氧系数每个世界回合再涨多少（0=关，第 1 回合恒等于 amult）
##   upkeep=20    【候选③】癌细胞每回合按当前能量的百分之几自动损能（0=关）
##   agrow2=10    【候选②】免疫普攻倍率每回合再涨几个百分点（0=关，第 1 回合恒为 100%）
##   amem=5       【候选④】免疫普攻倍率每点抗原记忆涨几个百分点（0=关）
##   amemcap=100  【候选④】记忆加成封顶，百分点（0=不封）
##   cmh / cmc    癌方移动到健康／癌性组织的费用 —— 前者就是占地单价（现值 12 / 2，PRD 5 / 2）
##   sclc / pseu  【极简胞浆】与【伪足穿透】的折后价（现值 7 / 5，PRD 3 / 2）
##   lesion=on    开启【原发灶】（癌细胞出生格开局即固化）。**默认 off**
##                —— 口径 #85（2026-08-31）已把 SOLID_AT_CANCER_SPAWN 关掉。
##                这行原本写着「默认 on」，和 cw_data.gd:52 正好相反。
##                2026-09-01 对抗式复核抓到，是本项目同日第三次
##                「注释/测试与实现共享同一个错误前提」。
##   counter=0    攻击失败时攻击者的自损（现值 5 = PRD 的 0.5）
##   atkmax=3     免疫每行动回合最多攻击几次（现值 3）
##   ecancer=60   癌细胞初始能量，十分能量（现值 30 = 3.0，与免疫同）
##   —— 2026-09-02「免疫后期引擎」对比表的四根杠杆（手打 D 局暴露的后期雪球）——
##   mheal=0      巨噬【吞噬】每次净化回多少，十分能量（现值 3 = 0.3；0 = 吞噬回能不适用于净化）
##   mvx=7        免疫 **X 级**迁移到癌性组织的费用（现值 5；III 级是 7、I/II 级 10）。
##                只动 X 级那一档 —— 和 mv= 的「各等级统一」不是一回事
##   abmax=2      B 细胞【抗体】每世界回合上限（现值 0 = 不限；2 = 9-01 之前的旧 PRD）
##   rdelay=1     免疫死亡后**额外**罚停几个世界回合（现值 0 = 下一个 S 阶段就复活；-1 = 不再复活）
##   aiver=v1     两边 AI 都退回 v1 的行为（分化固定顺序、不惜命、估值不罚死亡）；aiver_immune= / aiver_cancer= 只拨一边。
##                用途：**验证 AI 升级** —— 新版本要在两边都不比旧版弱（同一对手下交叉对局），否则标尺换了读数就漂。
##                结果行 `AI mc·v3` 或 `AI mc·I:v3·C:v1` 标出两边版本 —— **标签取自桥的 version_tag()**（与 CWHeuristicBridge.AI_VERSION
##                一致；2026-09-03 之前打的是 aiver= 参数原文，线上把常量升到 v3 后曾出现「常量 v3、结果行 v2」的错位，Kevin 要求统一）。
##                两边不同版本的数只用来比较 AI，不进平衡表。
##   metamax=1    小细胞肺癌【转移】每世界回合上限（现值 0 = 不限；1 = 与黑色素瘤【早期血行转移】同款）；
##   metacost=15  【转移】每次费用，十分能量（现值 10）。2026-09-03 晚 Kevin 问「黑 + 小同场怎么治」，先量这两根。
##   renergy=5    免疫复活初始能量，十分能量（现值 10 = 1.0）。2026-09-03 Kevin 提出「能量见底时主动送死、复活回能」是战术：
##                复活没有罚停、回 1.0、免死压迫，扫它看这条战术值多少。
##   lineup=mel,sclc  癌种钉死：按癌席出场顺序给种类（mel=黑色素瘤 sig=印戒 ost=骨肉瘤 sclc=小细胞肺癌），
##                没钉到的席位照常随机抽。2026-09-03 队友手打报「黑色素瘤 + 小细胞肺癌」第 5 回合癌方占地胜，专项测组合用；
##                不钉的时候结果也另打一行「癌种组合」分解（随机抽的局里每种组合只有十几局，只看方向）。
##
## ⚠ 2026-08-31 口径 #82 之后，**不传旋钮 = 引擎现值，不是 PRD 原样**。
## 要跑 PRD 原样做对照得显式写全：`cmh=5 sclc=3 pseu=2 tiles=15`。
## 2026-09-03 定案 ①+② 进了默认值（mheal=0、mvx=7）：要复现乙基线得传 `mheal=3 mvx=5`。
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
var abhalf := -1
var cmh := -1
var cmc := -1
var sclc := -1
var pseu := -1
var agrow := -9999   ## 负值合法（反方向），哨兵不能用 -1
var upkeep := -9999   ## 负值合法（反方向），哨兵不能用 -1
var agrow2 := -9999   ## 负值合法（反方向），哨兵不能用 -1
var amem := -9999   ## 负值合法（反方向），哨兵不能用 -1
var amemcap := -1
var prolif := -1
var solid := -1
var cwin := -1
var chold := -1
var mheal := -1
var mvx := -1
var abmax := -1
var rdelay := -9999   ## -1 是合法值（不再复活），哨兵不能用 -1
var aiver_immune: String = CWHeuristicBridge.AI_VERSION
var aiver_cancer: String = CWHeuristicBridge.AI_VERSION
var renergy := -1
var metamax := -1
var metacost := -1
var newborn := -1
var lineup := ""

const LINEUP_CODES := { "mel": CWData.CancerType.MELANOMA, "sig": CWData.CancerType.SIGNET,
	"ost": CWData.CancerType.OSTEO, "sclc": CWData.CancerType.SCLC }


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
			"abhalf": abhalf = int(kv[1])
			"cmh": cmh = int(kv[1])
			"cmc": cmc = int(kv[1])
			"sclc": sclc = int(kv[1])
			"pseu": pseu = int(kv[1])
			"agrow": agrow = int(kv[1])
			"upkeep": upkeep = int(kv[1])
			"agrow2": agrow2 = int(kv[1])
			"amem": amem = int(kv[1])
			"amemcap": amemcap = int(kv[1])
			"prolif": prolif = int(kv[1])
			"solid": solid = int(kv[1])
			"cwin": cwin = int(kv[1])
			"chold": chold = int(kv[1])
			"mheal": mheal = int(kv[1])
			"mvx": mvx = int(kv[1])
			"abmax": abmax = int(kv[1])
			"rdelay": rdelay = int(kv[1])
			"aiver":
				aiver_immune = kv[1]
				aiver_cancer = kv[1]
			"aiver_immune": aiver_immune = kv[1]
			"aiver_cancer": aiver_cancer = kv[1]
			"renergy": renergy = int(kv[1])
			"metamax": metamax = int(kv[1])
			"metacost": metacost = int(kv[1])
			"newborn": newborn = int(kv[1])
			"lineup": lineup = kv[1]


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
	if abhalf >= 0:
		t.antibody_halve = abhalf != 0
	if agrow != -9999:
		t.aerobic_mult_growth = agrow
	if upkeep != -9999:
		t.cancer_upkeep_pct = upkeep
	if agrow2 != -9999:
		t.immune_attack_pct_growth = agrow2
	if amem != -9999:
		t.immune_attack_pct_per_memory = amem
	if amemcap >= 0:
		t.immune_attack_pct_memory_cap = amemcap
	if prolif >= 0:
		t.proliferate_per_adjacent = prolif
	if solid >= 0:
		t.solidify_threshold = solid
	if cwin >= 0:
		t.cancer_win_weighted = cwin
	if chold >= 1:
		t.cancer_win_hold_rounds = chold
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
	if mheal >= 0:
		t.macro_heal_purify = mheal
	if mvx >= 0:
		t.immune_move_cancerous[3] = mvx   ## 排在 mv= 之后：mv 铺满四档，mvx 再单独改 X 级
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
	if lineup != "":
		t.cancer_types = _lineup_types(lineup)
	return t


## `lineup=` 的代号 → 枚举值。不认识的代号打错、跳过 —— 结果行的回显会露出真正生效的钉死名单。
func _lineup_types(spec: String) -> Array:
	var out: Array = []
	for code in spec.split(",", false):
		if LINEUP_CODES.has(code):
			out.append(LINEUP_CODES[code])
		else:
			printerr("lineup= 不认识的癌种代号：%s（可用 mel / sig / ost / sclc）" % code)
	return out


## 把「本次真正改掉的旋钮」回读出来，打进结果行。
## 2026-08-31 加：`atkmax` / `counter` / `lesion` 三个曾经**接漏了**——
## 参数收下了、`_tune()` 里没赋值，于是整张网格跑出来一模一样，
## 而输出里看不出任何异常。旋钮静默失效比没有旋钮更坏，所以现在强制回显。
func _applied(t: CWTuning) -> String:
	var d := CWTuning.new()
	var out: Array = []
	if t.immune_move_cancerous != d.immune_move_cancerous:
		## 只动 X 级那一档时要打 mvx= —— 照旧打 [0] 会把 mvx=7 回显成「mv=10」，等于没回显
		var arr: Array = t.immune_move_cancerous
		if arr.slice(0, 3) == d.immune_move_cancerous.slice(0, 3):
			out.append("mvx=%d" % arr[3])
		elif arr.count(arr[0]) == arr.size():
			out.append("mv=%s" % str(arr[0]))
		else:
			out.append("mv=%s" % str(arr))
	for pair in [["emax", t.energy_cap, d.energy_cap],
			["ecap", t.anaerobic_cap, d.anaerobic_cap],
			["efloor", t.anaerobic_floor, d.anaerobic_floor],
			["acap", t.aerobic_cap, d.aerobic_cap],
			["afloor", t.aerobic_floor, d.aerobic_floor],
			["tiles", t.init_cancer_tiles, d.init_cancer_tiles],
			["amult", t.aerobic_mult, d.aerobic_mult],
			["agrow", t.aerobic_mult_growth, d.aerobic_mult_growth],
			["upkeep", t.cancer_upkeep_pct, d.cancer_upkeep_pct],
			["agrow2", t.immune_attack_pct_growth, d.immune_attack_pct_growth],
			["amem", t.immune_attack_pct_per_memory, d.immune_attack_pct_per_memory],
			["amemcap", t.immune_attack_pct_memory_cap, d.immune_attack_pct_memory_cap],
			["prolif", t.proliferate_per_adjacent, d.proliferate_per_adjacent],
			["solid", t.solidify_threshold, d.solidify_threshold],
			["cwin", t.cancer_win_weighted, d.cancer_win_weighted],
			["chold", t.cancer_win_hold_rounds, d.cancer_win_hold_rounds],
			["cmh", t.cancer_move_healthy, d.cancer_move_healthy],
			["cmc", t.cancer_move_cancerous, d.cancer_move_cancerous],
			["sclc", t.sclc_move_healthy, d.sclc_move_healthy],
			["pseu", t.pseudopod_cost, d.pseudopod_cost],
			["counter", t.counter_dmg_on_fail, d.counter_dmg_on_fail],
			["atkmax", t.attack_max_per_turn, d.attack_max_per_turn],
			["ecancer", t.init_energy_cancer, d.init_energy_cancer],
			["mheal", t.macro_heal_purify, d.macro_heal_purify],
			["abmax", t.antibody_max_per_round, d.antibody_max_per_round],
			["rdelay", t.immune_respawn_delay, d.immune_respawn_delay],
			["renergy", t.immune_respawn_energy, d.immune_respawn_energy],
			["metamax", t.metastasis_max_per_round, d.metastasis_max_per_round],
			["metacost", t.metastasis_cost, d.metastasis_cost],
			["newborn", int(t.newborn_protect), int(d.newborn_protect)]]:
		if pair[1] != pair[2]:
			out.append("%s=%s" % [pair[0], str(pair[1])])
	if t.solid_at_cancer_spawn != d.solid_at_cancer_spawn:
		out.append("lesion=%s" % ("on" if t.solid_at_cancer_spawn else "off"))
	if t.aerobic_split != d.aerobic_split:
		out.append("tune=split")
	if not t.cancer_types.is_empty():
		var names: Array = []
		for ct in t.cancer_types:
			names.append(CWData.CANCER_TYPE_NAMES[ct])
		out.append("lineup=%s" % "+".join(names))
	return "默认值" if out.is_empty() else " ".join(out)


## 某一边实际会打出的版本标签：造一个同款桥拨到该版本，问它 version_tag()
func _tag(ver: String, use_mc: bool) -> String:
	var b: CWHeuristicBridge = CWMonteCarloBridge.new() if use_mc else CWHeuristicBridge.new()
	b.set_version(ver)
	return b.version_tag()


func _bridge(g: CWGame, faction: int) -> Object:
	var use_mc := ai == "mc" \
		or (ai == "mc_immune" and faction == CWData.Faction.IMMUNE) \
		or (ai == "mc_cancer" and faction == CWData.Faction.CANCER)
	var ver: String = aiver_immune if faction == CWData.Faction.IMMUNE else aiver_cancer
	if not use_mc:
		var h := CWHeuristicBridge.new()
		h.game = g
		h.set_version(ver)
		return h
	var m := CWMonteCarloBridge.new()
	m.game = g
	m.rollouts = rollouts
	m.horizon = horizon
	m.set_version(ver)
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
	## 攻击相关的三个计数器。**此前一个都没有** —— 于是「免疫普攻倍率」这类候选
	## （2026-09-01 的候选②④）跑出来只有胜率一个数，看不出 AI 到底打没打架。
	## 对抗式复核当场指出：启发式的攻击闸门是纯能量阈值、选目标只看敌人能量最低
	## （heuristic_bridge.gd:115/149），**伤害倍率一个字都不进决策**；
	## 蒙特卡洛那边一次净化值 125 分、一次普攻只值 10 分（cw_eval.gd）。
	## 所以「加强普攻测不出差别」很可能测的是陪练不打架，而不是机制没杠杆。
	## 不数出来就永远分不清这两件事。
	var attacks := 0
	var atk_fail := 0
	var kills := 0
	var cancer_kills := 0   ## 死亡按阵营分开数（v2 惜命之后要看是谁在死）
	## 癌种组合（不分席位顺序）→ [局数, 癌胜, 回合和, 最快癌胜回合]。2026-09-03 队友报「黑色素瘤 + 小细胞肺癌」
	## 第 5 回合占地胜 —— 组合是不是真的偏强，先要能按组合分开数。
	var combos := {}
	var homing := 0   ## 黑色素瘤【早期血行转移】发动次数
	var meta := 0     ## 小细胞肺癌【转移】发动次数
	var mucus := 0    ## 印戒【黏液破裂】发动次数
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
		var types: Array = []
		for pid in g.order:
			if g.player(pid)["faction"] == CWData.Faction.CANCER:
				types.append(g.player(pid)["cancer_type"])
		types.sort()
		var cnames: Array = []
		for ct in types:
			cnames.append(CWData.CANCER_TYPE_NAMES[ct])
		var ckey := "+".join(cnames)
		var cs: Array = combos.get(ckey, [0, 0, 0, 0])
		cs[0] += 1
		cs[2] += g.round_no
		if w == CWData.Faction.CANCER:
			cs[1] += 1
			cs[3] = g.round_no if cs[3] == 0 else mini(cs[3], g.round_no)
		combos[ckey] = cs
		cancerous_sum += g.count_tissue(CWData.Tissue.CANCER) + g.count_tissue(CWData.Tissue.SOLID)
		## 蒙特卡洛试算期间 sim_quiet=true，推演里的行动不会进 logs，所以这里数的是真实盘面
		for line in g.logs:
			if line.contains("【定殖】"):
				colonize += 1
			elif line.contains("【净化】"):
				purify += 1
			elif line.contains("【增生】"):
				prolif_n += int(line.split("】")[1].split(" ")[0])
			elif line.contains("【攻击】第") or line.contains("的攻击次数已用尽"):
				attacks += 1     ## 攻击**发动**即计数（口径 #70：失败被反弹也算攻过）
			elif line.contains("攻击失败"):
				atk_fail += 1
			elif line.contains("自血管转移至"):
				homing += 1
			elif line.contains("跃进 5 格至"):
				meta += 1
			elif line.contains("【黏液破裂】") and line.contains("引爆"):
				mucus += 1
			elif line.contains("☠"):
				## 死亡日志是 `☠ X 死亡`（cw_game.gd:749），**不是**「被消灭」——
				## 第一版就是照着直觉写的「被消灭」，跑出来每局击杀 0.0，
				## 而同一批数据里免疫清场赢了一半以上的对局，自相矛盾。
				## 【吞噬体成熟】那句「被直接消灭」是**斩杀前**的播报，
				## 后面照样走 kill() 打 ☠，两个都数会重复计数。
				kills += 1
				for cname in CWData.CANCER_TYPE_NAMES.values():
					if line.contains("(%s)" % cname):
						cancer_kills += 1
						break
		g.dispose()
	var secs := (Time.get_ticks_msec() - t0) / 1000.0
	## AI 版本跟着结果走：不同版本量出来的数不能放进同一张表。标签问桥要（version_tag），不打 aiver= 的原文 ——
	## 否则常量升号后结果行还在打旧号（2026-09-03 线上升 v3 时就错位过）。
	var tag_i := _tag(aiver_immune, ai == "mc" or ai == "mc_immune")
	var tag_c := _tag(aiver_cancer, ai == "mc" or ai == "mc_cancer")
	print("%-24s 席位 %-8s AI %-9s | 癌胜 %3d%% (%d/%d) | 平均 %4.1f 回合 | 上限判定 %2d 局 | 终局癌性 %5.1f 格 | %.0fs" % [
		label if label != "" else order_str, order_str,
		"%s·%s" % [ai, tag_i if tag_i == tag_c else "I:%s·C:%s" % [tag_i, tag_c]],
		cancer_wins * 100 / games, cancer_wins, games,
		float(rounds_sum) / games, by_limit, float(cancerous_sum) / games, secs])
	print("        旋钮：%s" % _applied(_tune()))
	var ks: Array = kinds.keys()
	ks.sort()
	var parts: Array = []
	for k in ks:
		parts.append("%s %d" % [k, kinds[k]])
	print("        胜法：%s" % ", ".join(parts))
	print("        每局攻击：发动 %.1f 次（失败 %.1f）· 双方死亡 %.1f（免疫 %.1f / 癌 %.1f）—— 对比净化 %.1f 次" % [
		float(attacks) / games, float(atk_fail) / games,
		float(kills) / games, float(kills - cancer_kills) / games, float(cancer_kills) / games,
		float(purify) / games])
	print("        每局占地：癌【定殖】%.1f + 【增生】%.1f vs 免疫【净化】%.1f（转化比 %.1f:1）" % [
		float(colonize) / games, float(prolif_n) / games, float(purify) / games,
		float(colonize + prolif_n) / maxf(float(purify), 1.0)])
	var ckeys: Array = combos.keys()
	ckeys.sort_custom(func(a, b): return float(combos[a][1]) / combos[a][0] > float(combos[b][1]) / combos[b][0])
	var cparts: Array = []
	for k in ckeys:
		var cs: Array = combos[k]
		cparts.append("%s %d/%d=%d%% · %.1f 回合%s" % [k, cs[1], cs[0], cs[1] * 100 / cs[0], float(cs[2]) / cs[0],
			"" if cs[3] == 0 else " · 最快癌胜第 %d 回合" % cs[3]])
	print("        癌种组合：%s" % " | ".join(cparts))
	print("        癌种技能每局：早期血行转移 %.1f · 转移 %.1f · 黏液破裂 %.1f" % [
		float(homing) / games, float(meta) / games, float(mucus) / games])
	quit(0)
