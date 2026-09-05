## heuristic_bridge.gd —— 启发式 AI 桥：给免疫/癌症双方提供基础决策，用于平衡模拟与人机对战
##
## 策略只依赖对局状态、不使用任何随机数 → 同一种子的对局完全可复现（确定性测试依赖这一点）。
## （分化种类按「此刻 rng 状态」的 hash 选，仍是状态的函数、不消耗 rng，见 _pick_differentiation_option。）
## 数值阈值都是「十分能量」。观战模式设置 delay_ms>0 + delay_node 可放慢节奏。
##
## 会用卡（2026-08-29 起）：出牌免费，所以打牌决策只回答「时机对不对」——
## 直接效果类有目标就打（选项存在即目标合法），增益类看马上用不用得上（_score_play）。
## 抽卡在能量宽裕时进行。这是「最起码会用卡」的版本：让平衡模拟测的是有卡版对局，
## 不追求最优 —— 更强的选牌交给蒙特卡洛层。
class_name CWHeuristicBridge
extends CWBridge

## 陪练 / 平衡标尺的版本号。**改任何 AI 行为（本桥、MC 桥、CWEval）都要升号**：所有用它量出来的平衡数字随之作废，
## 表格要标明是哪一版量的。balance_scan 的结果行会打出来。
## v1：2026-08 ~ 09-01 —— 分化拿选项列表第一个（固定 B→T→巨噬→树突）、死亡在估值里免费。
## v2：2026-09-02（Kevin 与团队定「以浅层 MC 为标尺，先让 AI 惜命」）—— 分化按种子随机、
##     免疫不走进会被压死的格、癌细胞贴着免疫时留 3.0 储备、CWEval 罚死亡。
## v4：2026-09-04 —— 「别蹲在自己刚铺的格子上」从**规则**改成**策略**（`_worth_solidifying` 只看
##     `newborn` 标记，不看 `newborn_protect` 旋钮）。**`newborn_protect = true` 时 v4 与 v3 逐位相同**，
##     所以机制还在时量的那些表（§9、§10.1~10.6）不作废；只有旋钮关掉时两者才分道扬镳。
## v5：2026-09-04 —— 按新 PRD 重做树突之后学会新技能：会建【I-趋化源】（只要付得起就建、
##     位置挑癌区最密的一格），`chemo_target` 有了专门的挑法。**树突不能攻击**之后
##     攻击类选项自然从清单里消失，不必改策略（选项驱动的好处）。
## v6：2026-09-04 —— 学会**回据点**（`_base_return`）：本回合铺完之后退到固化计数最高的那一格
##     结束回合。Kevin 指出真人会「占完周围再回到原来那格给队友蹲固化」，而【E-固化】只看回合末
##     站在哪、不管走了多远 —— v5 之前把蹲固化当成移动的替代项，AI 永远拿不到复活据点。
## v7：2026-09-04 —— 修 `CWEval.SOLID_TICK` 30→5。旧值下「进度 1.0 的癌组织(400)」比
##     「修成的固化格(200)」还值钱，**MC 会主动避免把固化修完**、到处留半成品，
##     癌方因此几乎拿不到复活据点。与 v6 的 `_base_return` 是同一个病的两个病灶。
const AI_VERSION := "v9"   ## v9（2026-09-05）：会用骨肉瘤重做后的【骨样硬化】；规则侧同日改了有氧均分/无氧回合末
## 每个桥实例可以单独退回 v1 的行为（set_version("v1")）：分化拿选项列表第一个、不惜命。
## 用途是**验证 AI 升级**：新版本必须在两边都不比旧版弱（balance_scan 的 aiver_immune= / aiver_cancer= 交叉对局），
## 否则标尺一换读数就漂、还分不清是规则变了还是量具变了（2026-09-02 v2 基线 6 人 24→10 就是这么查的）。对局里别拨。
var fixed_lineup := false
var lifecare := true

var delay_ms := 0
var delay_node: Node = null


## 把这个桥拨到某个 AI 版本的行为（"v1" / "v2"）。MC 桥重写它以连带估值的死亡罚分。
func set_version(v: String) -> void:
	var base: String = v.split("-")[0]   ## "v2-nodc" 这类带修饰的串，修饰只有 MC 桥认
	fixed_lineup = base == "v1"
	lifecare = base != "v1"


func version_tag() -> String:
	return "v1" if fixed_lineup and not lifecare else AI_VERSION


func ask(req: Dictionary) -> int:
	if delay_ms > 0 and delay_node != null:
		await delay_node.get_tree().create_timer(delay_ms / 1000.0).timeout
	var pid: int = req["pid"]
	var options: Array = req["options"]
	match req["kind"]:
		"setup_place":
			return _setup_place(pid, options)
		"action":
			if game.player(pid)["faction"] == CWData.Faction.IMMUNE:
				return _immune_action(pid, options)
			return _cancer_action(pid, options)
		"attack_target":
			return _pick_weakest(options)
		"differentiate":
			return _pick_differentiation(options)
		"revive":
			return _pick_revive(options)
		"free_move":
			return _pick_free_move(pid, options)
		"pick_cell":
			return _pick_storm_center(req.get("tag", ""), options)
		"pick_tile":
			return _pick_tile_take(options)
		"chemo_target":
			return _pick_chemo_spot(options)
		"pick":
			match req.get("tag", ""):
				"基因组不稳定":
					return _pick_mutation_result(pid, options)
				"代谢耦联":
					return _pick_couple(options)
			return 0
		"confirm":
			if req.get("tag", "") == "remutate":
				return 0 if game.cell_of(pid)["energy"] >= 20 else 1
			return 0  # lyse_purge：总是立刻净化
	return 0


# ============ 开局落子 ============

func _setup_place(pid: int, options: Array) -> int:
	var faction: int = game.player(pid)["faction"]
	var best := 0
	var best_score := -999999
	for i in options.size():
		var c: Vector2i = options[i]["data"]["to"]
		var score: int
		if faction == CWData.Faction.CANCER:
			# 远离已落子的免疫细胞是第一要务（开局 3.0 能量扛不住围攻），其次靠中心、独占一格
			var safety := 99
			for other in game.living_cells(CWData.Faction.IMMUNE):
				safety = mini(safety, CWData.hex_dist(c, other["pos"]))
			score = mini(safety, 6) * 5 - CWData.hex_dist(c, Vector2i.ZERO) * 2 \
				- game.cells_at(c).size() * 3
		else:
			# 距最近癌性组织 2 格最理想（首回合可接敌但不至于立刻被围），并与队友拉开距离
			var d := _dist_to_nearest_cancerous(c)
			var spread := 99
			for other in game.living_cells(CWData.Faction.IMMUNE):
				spread = mini(spread, CWData.hex_dist(c, other["pos"]))
			score = -absi(d - 2) * 10 + mini(spread, 6)
		if score > best_score:
			best_score = score
			best = i
	return best


# ============ 免疫回合 ============

func _immune_action(pid: int, options: Array) -> int:
	var me: Dictionary = game.cell_of(pid)
	var e: int = me["energy"]
	# 1. 分化免费，永远优先；选哪一种按种子随机（v2，见 _pick_differentiation_option）
	var i := _pick_differentiation_option(pid, options)
	if i >= 0:
		return i
	# 1.5 惜命（v2）：脚下这格回合末的【微环境压迫】会把自己压死 → 先挪到活得下去的格
	if lifecare and game.world.pressure_at(me["pos"]) >= e:
		i = _best_escape(options, me)
		if i >= 0:
			return i
	# 2. 打牌（出牌免费；攻击增益要赶在攻击之前打出，所以排在这里）
	i = _best_play(pid, options)
	if i >= 0:
		return i
	# 3. T 细胞站在固化格上 → 裂解+净化
	i = _find(options, "lyse")
	if i >= 0 and e >= 20:
		return i
	# 4. B 细胞抗体：目标够多才划算。
	#    v8 起还要看**这一发**打多少 —— 团队 2026-09-04 把抗体改成同回合递减
	#    （1.5 / 0.7 / 0.3 / 0.1 / 0），照旧只看目标数会在第 4 发之后
	#    继续花 1.0 能量打 0 伤害。这不是平衡问题，是 AI 在做无效动作。
	i = _find(options, "antibody")
	if i >= 0 and game.actions.antibody_damage(me) >= 5:
		var n := _antibody_target_count()
		if (n >= 2 and e >= 25) or (n >= 1 and e >= 40):
			return i
	# 5. T 细胞毒素：一次至少清 2 格
	i = _find(options, "toxin")
	if i >= 0 and e >= 25 and game.actions._toxin_targets(me).size() >= 2:
		return i
	# 5.5 树突【I-趋化源】：2.0 建一个，场上仅一个、持续 2 回合（2026-09-04 新 PRD）。
	#     树突自己不能攻击（【各司其职】），光环就是它全部的输出，所以**只要建得起就建**，
	#     只留一步迁移的钱（1.0）。过期了下回合再建 —— 这也是它唯一的能量出口。
	i = _find(options, "chemo")
	if i >= 0 and e >= CWData.CHEMO_COST + 10:
		return i
	# 6. 攻击相邻癌细胞。留足「攻击费 + 反弹反击」的储备避免自杀式进攻——
	# 这正是免疫方能主动规避反击威胁的原因（团队 2026-08-26 已确认此问题）。
	var atk_reserve: int = game.tune.immune_move_cancerous[game.immune_level] \
		+ game.tune.counter_dmg_on_fail + 10
	if e >= maxi(25, atk_reserve):
		var atk := _best_attack(options)
		if atk >= 0:
			return atk
	# 7. 净化：进入相邻的无人癌组织
	var purge_cost: int = game.tune.immune_move_cancerous[game.immune_level]
	if e >= purge_cost + 10:
		var purge := _best_purge_move(options, me)
		if purge >= 0:
			return purge
	# 8. 手上余粮多就抽卡（0.5/张，每回合至多 3 次；手牌满时选项不出现）——
	# 排在净化之后：转地是即时收益，卡是期货
	i = _find(options, "draw")
	if i >= 0 and e >= 30:
		return i
	# 9. 接近最近的癌性组织
	if e >= 20:
		var approach := _best_approach(options, me)
		if approach >= 0:
			return approach
	return _find(options, "end")


func _antibody_target_count() -> int:
	var n := 0
	for c in game.living_cells(CWData.Faction.CANCER):
		for nb in CWData.neighbors(c["pos"]):
			if game.tile(nb)["tissue"] == CWData.Tissue.HEALTHY:
				n += 1
				break
	return n


## 攻击目标格里能量最低的敌人所在选项
func _best_attack(options: Array) -> int:
	var best := -1
	var best_energy := 999999
	for i in options.size():
		var d: Dictionary = options[i]["data"]
		if d["act"] != "move":
			continue
		var enemies: Array = game.cells_at(d["to"], CWData.Faction.CANCER)
		if enemies.is_empty():
			continue
		for en in enemies:
			if en["energy"] < best_energy:
				best_energy = en["energy"]
				best = i
	return best


## 可净化的相邻癌组织（无人、非固化），优先癌性邻格多的（顺着癌区推进）——
## 但走进去之后得活过回合末的【微环境压迫】（_survives_at，v2 惜命）
func _best_purge_move(options: Array, me: Dictionary) -> int:
	var best := -1
	var best_score := -1
	for i in options.size():
		var d: Dictionary = options[i]["data"]
		if d["act"] != "move":
			continue
		var to: Vector2i = d["to"]
		if game.tile(to)["tissue"] != CWData.Tissue.CANCER:
			continue
		if not game.cells_at(to, CWData.Faction.CANCER).is_empty():
			continue
		if lifecare and not _survives_at(me, to, int(d.get("cost", 0))):
			continue
		var score := 0
		for n in CWData.neighbors(to):
			if game.is_cancerous(n):
				score += 1
		if score > best_score:
			best_score = score
			best = i
	return best


func _best_approach(options: Array, me: Dictionary) -> int:
	# 目标：无人癌性组织（树突：癌细胞的相邻格——它只能靠光环输出）
	var targets: Array[Vector2i] = []
	if me["itype"] == CWData.ImmuneType.DENDRITIC:
		for c in game.living_cells(CWData.Faction.CANCER):
			for n in CWData.neighbors(c["pos"]):
				if game.cells_at(n, CWData.Faction.CANCER).is_empty():
					targets.append(n)
	else:
		for c in game.tiles.keys():
			if game.is_cancerous(c) and game.cells_at(c, CWData.Faction.CANCER).is_empty():
				targets.append(c)
	if targets.is_empty():
		return -1
	var dist := _dist_map(targets, func(c: Vector2i) -> bool:
		return not game.cells_at(c, CWData.Faction.CANCER).is_empty())
	var now: int = dist.get(me["pos"], 9999)
	var best := -1
	var best_d := now  # 必须严格变近，否则原地攒能量
	for i in options.size():
		var d: Dictionary = options[i]["data"]
		if d["act"] != "move":
			continue
		if not game.cells_at(d["to"], CWData.Faction.CANCER).is_empty():
			continue  # 接近阶段不打架
		if lifecare and not _survives_at(me, d["to"], int(d.get("cost", 0))):
			continue  # v2 惜命：别为了靠近一步把自己送进压迫区
		var nd: int = dist.get(d["to"], 9999)
		if nd < best_d:
			best_d = nd
			best = i
	return best


## 惜命（v2，2026-09-02 Kevin 定「让 AI 惜命」）：E 阶段【微环境压迫】按「相邻癌性组织数 − 2」× 0.5 扣能量，扣到 0 就死。
## 此前净化选格偏好癌性邻格最多的格，能量见底时一头扎进去、回合末被压迫打死 —— 启发式免疫每局死 3~5 次，
## 复活免费所以看不出代价；复活罚停旋钮一加就雪崩（第二张表 ④），全是这条造成的伪影。
## 规则：走进一格之后账上剩的能量必须**高于**那一格此刻的压迫损失（留 0.1 活命线）。
## 只看此刻的邻格：后面行动的癌细胞还可能把它围上，但那是对手的功劳，不是自己送的。
func _survives_at(me: Dictionary, to: Vector2i, cost: int) -> bool:
	return me["energy"] - cost > game.world.pressure_at(to)


## 脚下会被压死时的逃生：付得起、活得下去的迁移里，优先能顺手净化的，其次压迫最轻的
func _best_escape(options: Array, me: Dictionary) -> int:
	var best := -1
	var best_score := -999999
	for i in options.size():
		var d: Dictionary = options[i]["data"]
		if d["act"] != "move":
			continue
		var to: Vector2i = d["to"]
		if not game.cells_at(to, CWData.Faction.CANCER).is_empty():
			continue
		var cost: int = int(d.get("cost", 0))
		if not _survives_at(me, to, cost):
			continue
		var score: int = -game.world.pressure_at(to) - cost / 5
		if game.tile(to)["tissue"] == CWData.Tissue.CANCER:
			score += 20
		if score > best_score:
			best_score = score
			best = i
	return best


## 分化选哪一种：在可选种类里**按种子随机**选（v2，2026-09-02 Kevin 定）。
## 此前永远拿选项列表的第一个，也就是 _diff_choices 的固定顺序 B→T→巨噬→树突：4 人局两席免疫到 T 就没了，
## 巨噬、树突在 4 人局的平衡网格里从未出现过，6 人局树突也从未出现。随机之后每种细胞 4 人局约一半对局出现、6 人局四分之三。
## 不消耗 game.rng（本桥不引入随机数的约定不变，见文件头）：用「此刻的 rng 状态 + 席位」的 hash 选，
## 同种子同局面同答案，也不扰动之后所有人的骰子。MC 推演里的陪练同样走这里，推演流由快照派生，选法自洽。
## （kind="differentiate" 那条 _pick_differentiation 是死代码 —— 引擎从不发那种询问，留着没动。）
func _pick_differentiation_option(pid: int, options: Array) -> int:
	var idx: Array[int] = []
	for i in options.size():
		if options[i]["data"].get("act", "") == "differentiate":
			idx.append(i)
	if idx.is_empty():
		return -1
	if fixed_lineup:
		return idx[0]
	return idx[posmod(hash([game.rng.state, pid]), idx.size())]


# ============ 癌症回合 ============

func _cancer_action(pid: int, options: Array) -> int:
	var me: Dictionary = game.cell_of(pid)
	var e: int = me["energy"]
	var threat := _dist_to_nearest_immune(me["pos"])
	# 0. 打牌（出牌免费；EMT 这类移动折扣要赶在移动之前打出，所以排最前）
	var pi := _best_play(pid, options)
	if pi >= 0:
		return pi
	# 1. 印戒【黏液破裂】：一次能染一大片、且有复活据点时才引爆（自毁技能）
	var i := _find(options, "mucus")
	if i >= 0 and game.count_tissue(CWData.Tissue.SOLID) >= 1:
		var n := 0
		for c in game.tiles.keys():
			if CWData.hex_dist(c, me["pos"]) <= CWData.MUCUS_RADIUS 					and game.tiles[c]["tissue"] == CWData.Tissue.HEALTHY:
				n += 1
		if n >= 6:
			return i
	# 2. 黑色素瘤【早期血行转移】：站在血管上就是白捡一格地盘
	i = _find(options, "homing")
	if i >= 0 and e >= 20:
		return i
	# 2.5 骨肉瘤【骨样硬化】（v9）：还没有复活据点、且不是贴脸时，花 2.0 把脚下标记成两回合后的固化，
	# 然后就能走开继续铺 —— 这正是重做的意义（旧版得蹲着）
	i = _find(options, "ossify")
	if i >= 0 and e >= 35 and threat >= 2 and game.count_tissue(CWData.Tissue.SOLID) == 0:
		return i
	# 3. 小细胞肺癌【转移】：远离威胁时用来抢空地，不做复杂评估
	i = _find(options, "jump")
	if i >= 0 and e >= 25 and threat <= 2:
		return i
	# 4. 突变：免疫方有记忆可削时才赌
	i = _find(options, "mutate")
	if i >= 0 and e >= 30 and game.memory >= 2:
		return i
	# 4.5 攒够了就抽卡（1.0/张）：贴脸时别停下抽卡送头
	i = _find(options, "draw")
	if i >= 0 and e >= 45 and threat >= 2:
		return i
	# 4. 蹲点固化：安全时停在原地，把脚下癌组织熬成固化癌组织（复活据点+高供能）
	if threat >= 3 and _worth_solidifying(me):
		return _find(options, "end")
	# 5. 移动：安全 / 占地 / 前景 / 成本 统一打分
	var mv := _best_cancer_move(options, me, threat)
	if mv >= 0:
		return mv
	# 6. 收尾**回据点**（Kevin 2026-09-04 指出的真人打法，v6 起）
	i = _base_return(options, me)
	if i >= 0:
		return i
	return _find(options, "end")


## 收尾回据点：真人打法是「先把周围的格子占掉，再回到原来那一格给队友蹲固化」。
##
## **为什么这不是「原地不动」**：【E-固化】只看**回合末站在哪**
## （`CWWorld._solidify()` 读 `cell["pos"]`），完全不管这一回合走了多远 ——
## 所以「占地」和「攒固化」**根本不是二选一**，绕一圈回到同一格，两样都吃到，
## 代价只有回程那 0.2。取消「新生」之后当回合铺的格也照样累计。
##
## v5 之前把「蹲固化」写成移动的**替代项**（`_worth_solidifying` 成立就原地不动），
## 于是 AI 要么占地、要么蹲点，永远拿不到复活据点 ——
## 前期一被打死就彻底出局。那量出来的不是规则的强度，是 AI 的短板。
## （同一类错误 2026-09-04 已经犯过一次：v3 把这条判断绑在旋钮上，量出癌胜 19%，见 §10.8。）
##
## 做法：本回合已经没有值得走的占地步了，就退到**固化计数最高的那一格**结束回合。
## 只认癌组织（健康格这一步会变成新格，攒不到已有进度），且要留够安全储备。
func _base_return(options: Array, me: Dictionary) -> int:
	var best := -1
	var best_solid: int = game.tile(me["pos"])["solid"]
	for i in options.size():
		var d: Dictionary = options[i]["data"]
		if d["act"] != "move":
			continue
		var t: Dictionary = game.tile(d["to"])
		if t["tissue"] != CWData.Tissue.CANCER or int(t["solid"]) <= best_solid:
			continue
		if me["energy"] < int(d["cost"]) + 5:
			continue          ## 回据点不该把自己走到濒死
		best_solid = int(t["solid"])
		best = i
	return best


func _dist_to_nearest_immune(from: Vector2i) -> int:
	var best := 99
	for c in game.living_cells(CWData.Faction.IMMUNE):
		best = mini(best, CWData.hex_dist(from, c["pos"]))
	return best


## 脚下这格值不值得蹲：癌组织，且**不是本回合自己刚铺出来的那一格**。
##
## 「新生」这一条 2026-09-04 起是**策略**，不再只是规则（`newborn_protect` 关掉之后规则允许当回合就攒）。
## 两件事必须分开看：
## · 规则允不允许 —— 旋钮说了算；
## · 值不值得这么打 —— **一直都不值得**。蹲两个回合把一格熬成固化换 +1 加权（固化记 2、癌组织记 1），
##   而继续【定殖】0.2 能量就换 +1，还顺带把免疫推远。刚铺完就停下，等于用两回合买一格。
##
## 规则一取消就把这道判断也跟着关掉，是 v3 的错：全场癌细胞同时蹲下来，
## 6 人局每局【定殖】从 157.7 掉到 93.7、癌胜从 43% 掉到 19%（§10.7 量到的就是这个）。
## 所以这里**只看标记本身**，不看旋钮 —— 标记照常打、照常清，规则关掉也还在。
func _worth_solidifying(me: Dictionary) -> bool:
	var t: Dictionary = game.tile(me["pos"])
	if t["tissue"] != CWData.Tissue.CANCER or t["newborn"]:
		return false
	if t["solid"] >= game.tune.solidify_threshold - 1:
		return true  # 差最后一轮就固化，值得停
	# 场上还没有任何复活据点时，值得从头熬一个
	return game.count_tissue(CWData.Tissue.SOLID) == 0


## 趋化源建在哪：**癌区最密的那一格**。
##
## 两个效果都指向同一个位置：免疫**朝它**走 -30%（把免疫往癌区里拉），
## 癌方**背它**走 +40%（癌方扩张就是在背离癌区中心，所以正好收它的过路费）。
## 于是「癌性邻格最多的格」同时最大化两边收益。
##
## 只遍历存活癌细胞脚下那几格（不是全盘 127 格）：既便宜，又天然落在战线上。
## 同分取坐标小的那个 —— 本桥不引入随机数，必须确定性（见文件头）。
func _pick_chemo_spot(options: Array) -> int:
	var best := -1
	var best_score := -1
	for i in options.size():
		var c: Vector2i = options[i]["data"]["to"]
		var score := 0
		for n in CWData.neighbors(c):
			if game.is_cancerous(n):
				score += 1
		if game.is_cancerous(c):
			score += 1
		if not game.cells_at(c, CWData.Faction.CANCER).is_empty():
			score += 2      ## 有癌细胞站着的格更值：它下一步一定要动，一动就交钱
		if score > best_score:
			best_score = score
			best = i
	return maxi(best, 0)


## 距免疫细胞不同距离的安全分。免疫每回合能连打 3 次（每次期望 0.83 伤害），
## 而癌细胞只有 3.0 能量：停在免疫身边基本等于送死，所以 1 格处是断崖式惩罚。
const SAFETY_BY_DIST := [-999, -40, -5, 6, 12]
## 惜命（v2）：停在免疫 2 格内时账上要留的储备 3.0 —— 免疫一回合能连打 3 次、每次期望 0.83。
## 此前一律只留 0.5：癌细胞沿着免疫的正面一路铺到花光，紧接着行动的免疫两三刀打死 ——
## 手打四局里 AI 癌方几乎都是这么死的（真人癌方不会这么停），MC 癌也一样（第二张表 8.5 第 2 点）。
const CANCER_RESERVE_NEAR := 30


## 癌细胞移动打分：安全（保命）+ 定殖健康组织（占地=收入=胜利条件）+ 扩张前景 - 能量成本
## threat = 当前距最近免疫细胞的距离，贴脸时连「原地不动」都要重新估值。
func _best_cancer_move(options: Array, me: Dictionary, _threat: int) -> int:
	var best := -1
	var best_score := -999999
	for i in options.size():
		var d: Dictionary = options[i]["data"]
		if d["act"] != "move":
			continue
		var to: Vector2i = d["to"]
		var threat_to := _dist_to_nearest_immune(to)
		## 远离威胁只留 0.5 别把自己走到濒死；停到免疫 2 格内要留 3.0（CANCER_RESERVE_NEAR）。
		## 退到安全格只要 0.5，所以贴脸低血时「撤」永远是可选项。
		var reserve: int = CANCER_RESERVE_NEAR if lifecare and threat_to <= 2 else 5
		if me["energy"] < d["cost"] + reserve:
			continue
		var score: int = SAFETY_BY_DIST[mini(threat_to, 4)]
		if not game.is_cancerous(to):
			score += 15  # 定殖：永久 +1 格地盘，是癌方的核心收益
		for n in CWData.neighbors(to):
			if game.tile(n)["tissue"] == CWData.Tissue.HEALTHY:
				score += 2  # 前景：周围还有多少可扩张空间
		score -= d["cost"]
		if score > best_score:
			best_score = score
			best = i
	# 原地不动的价值（不花能量，但也不占地）；比它差的移动一律不做
	var stay_score: int = SAFETY_BY_DIST[mini(_dist_to_nearest_immune(me["pos"]), 4)]
	return best if best_score > stay_score else -1


# ============ 打牌 ============

## 手牌里此刻值得打的最高分选项；没有正分的返回 -1（分数只用于排序与「>0 才打」）。
func _best_play(pid: int, options: Array) -> int:
	var best := -1
	var best_score := 0
	for i in options.size():
		var d: Dictionary = options[i]["data"]
		if d.get("act", "") != "play":
			continue
		var score := _score_play(pid, d, options)
		if score > best_score:
			best_score = score
			best = i
	return best


## 出牌免费（PRD 没有出牌费），所以打分只回答「现在打时机对不对」：
## 打了用不上的增益等于把卡扔掉，宁可压在手里等时机。
## 同名多目标的选项拿一样的分，并列取第一个（选项顺序引擎侧固定，可复现）。
func _score_play(pid: int, d: Dictionary, options: Array) -> int:
	var me: Dictionary = game.cell_of(pid)
	var card: String = d["card"]
	## 永久技能：免费、永久生效、还腾出手牌位，永远第一时间装上
	if CWCardData.CARDS[card]["kind"] == CWCardData.Kind.PERMANENT:
		return 100
	match card:
		## —— 有目标就是白赚的直接效果（选项存在 = 目标合法）——
		"抗体依赖细胞毒作用", "放疗", "IFN-γ高峰", "溶酶体强化", "基质降解", \
		"基质重塑", "乳酸酸化", "TNF-α局部炎症":
			return 90
		"交叉呈递":
			return 80   ## 白给的【标记】：下次命中翻倍
		"基质硬化":
			return 55   ## 加速固化据点：现在打比晚打多熬一轮
		"代谢耦联":
			return 40   ## 付 1.0 对面得 1.2……阵营内净赚的转账（方向/数额见 pick 分支）
		"免疫增援":
			## 传送到队友附近：离战线远才值得烧这张卡（近处自己走更省）
			return 35 if _dist_to_nearest_cancerous(me["pos"]) >= 3 else 0
		"肿瘤细胞募集":
			## 当救援用：把被免疫贴脸的队友拽回癌区腹地
			return 45 if _dist_to_nearest_immune(game.cells[d["cid"]]["pos"]) <= 1 else 0
		"炎症性趋化":
			## 付费连走（0.2/步）：第一步就踩进癌组织（净化）才划算
			return 55 if game.tile(d["to"])["tissue"] == CWData.Tissue.CANCER \
				and game.can_pay(me, int(d["cost"]) + 10) else 0
		"补体调理", "穿孔素-颗粒酶", "高亲和力克隆", "补体级联":
			## 攻击增益都是「本回合下一次攻击」：行动栏里就摆着打得起的攻击才不浪费
			return 60 if _attack_ready(me, options) else 0
		"炎症趋化", "CXCR3趋化":
			## 迁移折扣：旁边就有想进的癌性组织才预打
			return 30 if _step_target_exists(me, true) else 0
		"上皮—间质转化":
			return 30 if _step_target_exists(me, false) else 0
		"细胞膜修复", "缺氧适应", "PD-L1表达", "DNA损伤修复":
			## 防御卡：敌人贴近了才亮出来，太早打有的会过期、有的会被小伤耗掉
			return 50 if _dist_to_nearest_enemy(me) <= 2 else 0
	return 0   ## 没列到的卡此刻不打


## 「本回合下一次攻击」类增益的时机：行动栏里有攻击选项，且能量足以真打
## （攻击费 + 失败反击的储备，口径同 _immune_action 的攻击那一步）
func _attack_ready(me: Dictionary, options: Array) -> bool:
	if _best_attack(options) < 0:
		return false
	var reserve: int = game.tune.immune_move_cancerous[game.immune_level] \
		+ game.tune.counter_dmg_on_fail + 10
	return me["energy"] >= maxi(25, reserve)


## 相邻有没有「无细胞占据的癌性/健康组织」——迁移折扣卡值不值得预打
func _step_target_exists(me: Dictionary, want_cancerous: bool) -> bool:
	for n in CWData.neighbors(me["pos"]):
		if not game.cells_at(n).is_empty():
			continue
		if want_cancerous and game.is_cancerous(n):
			return true
		if not want_cancerous and game.tile(n)["tissue"] == CWData.Tissue.HEALTHY:
			return true
	return false


func _dist_to_nearest_enemy(me: Dictionary) -> int:
	var enemy: int = CWData.Faction.CANCER if me["faction"] == CWData.Faction.IMMUNE \
		else CWData.Faction.IMMUNE
	var best := 99
	for c in game.living_cells(enemy):
		best = mini(best, CWData.hex_dist(me["pos"], c["pos"]))
	return best


# ============ 子询问 ============

func _pick_weakest(options: Array) -> int:
	var best := 0
	var best_energy := 999999
	for i in options.size():
		var cell: Dictionary = game.cells[options[i]["data"]["cid"]]
		if cell["energy"] < best_energy:
			best_energy = cell["energy"]
			best = i
	return best


func _pick_differentiation(options: Array) -> int:
	# 优先级：T（拆固化+范围净化）> B（全场压制）> 巨噬（续航）> 树突（辅助）
	for want in [CWData.ImmuneType.T_CELL, CWData.ImmuneType.B_CELL,
			CWData.ImmuneType.MACRO, CWData.ImmuneType.DENDRITIC]:
		for i in options.size():
			if options[i]["data"]["type"] == want:
				return i
	return 0


func _pick_revive(options: Array) -> int:
	# options[0] 恒为「放弃」；有位置就复活，选癌性邻格最多的（回中心腹地）
	var best := 0
	var best_score := -1
	for i in range(1, options.size()):
		var c: Vector2i = options[i]["data"]["to"]
		var score := 0
		for n in CWData.neighbors(c):
			if game.is_cancerous(n):
				score += 1
		if score > best_score:
			best_score = score
			best = i
	return best


## 卡牌给的「走一步/停」（趋化募集、效应细胞浸润、全身免疫动员…）。
## options[0] 恒为停止（0 分）：没有正收益就不白走。给攻击选项的（动员）保守跳过 ——
## 免费机会用来占位和捡资源，打架的风险评估交给正常回合的行动逻辑。
func _pick_free_move(pid: int, options: Array) -> int:
	var me: Dictionary = game.cell_of(pid)
	var now_d := _dist_to_nearest_cancerous(me["pos"])
	var best := 0
	var best_score := 0
	for i in range(1, options.size()):
		var d: Dictionary = options[i]["data"]
		if not d.has("to"):
			continue
		var to: Vector2i = d["to"]
		if not game.cells_at(to, CWData.Faction.CANCER).is_empty():
			continue
		var t: Dictionary = game.tile(to)
		var score := 0
		if t["tissue"] == CWData.Tissue.CANCER:
			score += 15   # 净化：转地 + 记忆
		if t["special"] == CWData.Special.CORE and t["store"] > 0:
			score += 10
		if t["special"] == CWData.Special.MARROW and t["cards"] > 0 \
				and me["hand"].size() < CWData.HAND_MAX:
			score += 8
		if _dist_to_nearest_cancerous(to) < now_d:
			score += 4
		score -= int(d.get("cost", 0)) / 5   # 动员的迁移要付费，白走不划算
		if score > best_score:
			best_score = score
			best = i
	return best


## 风暴类「选 1 个免疫细胞」：选波及面最大的（范围内癌细胞×2 + 普通癌组织×1）
func _pick_storm_center(tag: String, options: Array) -> int:
	var r := 2 if tag == "免疫风暴" else 1
	var best := 0
	var best_score := -1
	for i in options.size():
		var center: Vector2i = options[i]["data"]["to"]
		var score := 0
		for c in game.tiles.keys():
			if CWData.hex_dist(center, c) > r:
				continue
			if game.tiles[c]["tissue"] == CWData.Tissue.CANCER:
				score += 1
			score += game.cells_at(c, CWData.Faction.CANCER).size() * 2
		if score > best_score:
			best_score = score
			best = i
	return best


## 卡牌递过来的「选一格」（基质重塑的再拆一格/转化格…）：递到眼前的都是纯收益，
## 有得选就不选「停止」；同类里挑癌性邻格最多的（顺着癌区腹地推进）
func _pick_tile_take(options: Array) -> int:
	var best := 0
	var best_score := 0
	for i in options.size():
		var d: Dictionary = options[i]["data"]
		if not d.has("to"):
			continue   ## 「停止/放弃」项不带 to，保持 0 分
		var score := 1
		for n in CWData.neighbors(d["to"]):
			if game.is_cancerous(n):
				score += 1
		if score > best_score:
			best_score = score
			best = i
	return best


## 【代谢耦联】的两连问共用一个 arm，靠选项数据区分：
## 方向问句带 from —— 选转出方能量高的一侧（富济贫，转移本身还净赚）；
## 数额问句带 pay —— 直接拉满（净赚随档位涨，付不起的档位引擎已剔除）
func _pick_couple(options: Array) -> int:
	if options[0]["data"].has("from"):
		var best := 0
		var best_e := -1
		for i in options.size():
			var payer: Dictionary = game.cells[options[i]["data"]["from"]]
			if payer["energy"] > best_e:
				best_e = payer["energy"]
				best = i
		return best
	return options.size() - 1


## 【基因组不稳定】的二择：抽卡那档几乎总是最优；记忆厚、能量足时 -3 记忆更值
func _pick_mutation_result(pid: int, options: Array) -> int:
	var me: Dictionary = game.cell_of(pid)
	var best := 0
	var best_score := -99
	for i in options.size():
		var r: int = options[i]["data"]["r"]
		var score := 0
		match r:
			2:
				score = 5 + (3 if game.memory > 0 else 0)
			3:
				score = (8 if game.memory >= 3 else -2) - (5 if me["energy"] <= 20 else 0)
		if score > best_score:
			best_score = score
			best = i
	return best


# ============ 工具 ============

func _find(options: Array, act: String) -> int:
	for i in options.size():
		if options[i]["data"].get("act", "") == act:
			return i
	return -1


func _dist_to_nearest_cancerous(from: Vector2i) -> int:
	var best := 99
	for c in game.tiles.keys():
		if game.is_cancerous(c):
			best = mini(best, CWData.hex_dist(from, c))
	return best


## 多源 BFS：返回 每格→到最近目标的步数；blocked(c) 为 true 的格不可通行（目标本身除外）
func _dist_map(targets: Array[Vector2i], blocked: Callable) -> Dictionary:
	var dist := {}
	var queue: Array[Vector2i] = []
	for t in targets:
		if not dist.has(t):
			dist[t] = 0
			queue.append(t)
	var head := 0
	while head < queue.size():
		var cur: Vector2i = queue[head]
		head += 1
		for n in CWData.neighbors(cur):
			if dist.has(n) or blocked.call(n):
				continue
			dist[n] = dist[cur] + 1
			queue.append(n)
	return dist
