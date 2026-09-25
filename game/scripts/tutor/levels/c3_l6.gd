## levels/c3_l6.gd —— **第六关的关卡钩子**（PRD:437-528 的 25 步摆拍里「数据表达不了」的那三条；
## docs/新手引导v2_实现方案.md §3.7 / §4 第六关那几行，S11，2026-09-19）
##
## 三支（剧本 `{"do":"hook","call":"X"}` 点名）：
##   · `encircle`            PRD:467 第 3 步「引导玩家迁移将临近免疫细胞围一圈癌组织」
##     —— **下一格是运行期算的**：目标 = 离玩家最近的活着的免疫（T 除外；第一轮是巨噬，之后是走过来的 B / 树突），
##        没挨着先朝它走一格，挨着了就亮目标六邻里还没癌化、且与玩家相邻的那一格，`point` + `allow` 只放它。
##   · `immune_turn`         PRD:477-481 第 7 步「所有免疫向靠近癌细胞的方向移动一格，邻接则攻击」
##     —— 逐席一份 `npc.plan`（`approach` / `attack_if_adjacent` 走 `cw_tutorial_npc.POLICIES`）；
##        B 细胞的三次抗体是 plan 里点名三条 `k=action|act=antibody`；巨噬净化由**内核**自己演。
##   · `repeat_until_last_t` PRD:483 第 8 步「重复 3、4、7 直到剩余最后一个 T 细胞」
##     —— **终止条件是运行期的**（`ctx.read("alive_count", "immune")`）。围完 B / 树突走远了，
##        末尾再一步步走回围圈终点 (-2,1)（第 10 步起的两轮击退按那一格起算）。
##
## **免疫真的会被压死，靠的是关卡数据不是钩子**（2026-09-24 Kevin「第六关无法结束」）：
## 整盘一环的【微环境压迫】只有 1.5/回合（癌 I 期），而免疫默认每回合 +3～5 有氧收入、死了下一回合还在骨髓复活 ——
## 原数据（三只都 3.0 能量）下第 8 步永远收不了口。c3_l6.json 的 base 把有氧收入六个旋钮拧 0、
## `immune_respawn_delay: 99`、巨噬 / 树突 1.0、B 4.6（迁一步 0.5 + 三发抗体 3.0 之后余 1.1 < 1.5）：
## 围一圈 ⇒ 下一次结算就死。压迫公式一个字没动。
##
## 三条纪律（护栏 `t_tutor_hooks` 逐条扫，写钩子的人照抄 `levels/demo.gd`）：
## ① **零成员变量** —— 状态只能进 `ctx.state()`（那只字典随代际一起清空）；
## ② **每个 `while` 的条件都含 `ctx.alive()`** —— 代际一换，钩子自己从循环里退出来；
## ③ 只经 `ctx` 的九个方法（`beat` / `until` / `read` / `alive` / `frame` / `rng` / `state` / `log` / `fail`）。
##    钩子够不着 kernel / mirror / game / view / stage —— 要说话就 `ctx.beat({"do":"say", …})`。
##
## **`npc.plan` 的一条实装账**（`cw_tutorial_npc.Decider`）：换 plan 时 `memo` **不清零**
## （`match.gd::_tutor_set_npc` 只写 `plan`）。所以这里每次都喂**同一张按轮次重复 `NPC_REPEAT` 遍**
## 的长表：游标一路往下走，反复登记是幂等的。喂「一轮的量」会让第二轮起整张表越界 ⇒ 三级兜底
## 「结束回合」⇒ 免疫全程不动，真机上只表现为「怎么没人过来打我」。
##
## **不带 class_name**（方案 §1.5）：钩子是天天在改的东西，要能走热更。
extends RefCounted

## 「没有这一格」的哨兵（同 `cw_tutor_beats.NONE`，这里不 preload 它只为了一个常量）
const NO_TILE := Vector2i(9999, 9999)
## 围一圈最多走几格：六邻 + 冗余。`while` 的第二道闸（第一道永远是 `ctx.alive()`）
const RING_GUARD := 12
## 走到目标身边最多几步（树突离玩家 5～6 格）。同样是 `while` 的第二道闸
const APPROACH_GUARD := 12
## PRD:483 最多再重复几轮。**世界回合 ≤ 5 恒癌 I 期**（增生 / 固化的分档下标不漂）：
## 关首 1 轮 + 这里 3 轮 + 黏液复活那轮 = 5
const ROUNDS_CAP := 3
## 一份 plan 里把「一轮的块」重复几遍（见文件头「memo 不清零」那一条）
const NPC_REPEAT := 8


# =====================================================================
# PRD:467 第 3 步 —— 围一圈
# =====================================================================

## 每次只亮**一格**（`_next_step`）。第一轮目标是巨噬：六邻里还没癌化、且与玩家此刻相邻的那一格
## （DIRS 顺序 ⇒ 正好是开发日志那张表的 6 步走法 (0,0)→(-1,0)→(-1,-1)→(-2,-1)→(-3,0)→(-3,1)→(-2,1)）。
## 之后几轮目标是走过来的 B / 树突：先朝它走到相邻，再照样围。
## 玩家走上去 ⇒ 内核把健康格染成癌组织（【定殖】）⇒ 下一次再算就换到下一格；六格围完这一支自己退出。
## 走过的痕迹（第 10 步前共 22 格癌组织）已烘进 knock1 —— 第 11 步那次重装才不会把它们抹回健康。
func encircle(ctx) -> void:
	await _arm_immune(ctx)          ## 免疫的 plan 要赶在第一次「结束回合」之前装上
	ctx.state()["ring_seen"] = {}   ## 这一轮绕环踩过的格：绕圈时不回头
	var guard := 0
	while ctx.alive() and guard < RING_GUARD + APPROACH_GUARD:
		guard += 1
		var step: Vector2i = _next_step(ctx)
		if step == NO_TILE:
			break
		var at := _at_text(step)
		await ctx.beat({ "do": "point", "prd": 467, "hex": [at], "mode": "soft" })
		await ctx.beat({ "do": "player", "prd": 467,
			"hint": "顺着闪的那一格走 —— 把免疫细胞围成一圈癌组织",
			"hex": [at], "allow": ["k=action|act=move|to=" + at],
			"until": { "state": "cell_at", "arg": [0, at] } })
		(ctx.state()["ring_seen"] as Dictionary)[step] = true
		ctx.log("围一圈：玩家走到 %s" % at)
	ctx.log("围一圈结束（走了 %d 格）" % (guard - 1))


## 下一格。目标 = **离玩家最近的活着的免疫（T 除外）**：第一轮是巨噬（PRD:467），
## 之后几轮是走过来的 B / 树突（PRD:483「重复 3、4、7」）。
## 还没挨着目标：先朝它走一格（走过的健康格顺手【定殖】成癌组织）；挨着了：目标六邻里
## **还是健康组织、没人站、且与玩家相邻**的第一格 —— 健康 ⇒ 还没围过；没人站 ⇒ 迁上去不是攻击；
## 相邻 ⇒ 这一步内核真给得出选项。六格围完 / 走不动了给 NO_TILE
func _next_step(ctx) -> Vector2i:
	var me := NO_TILE
	var target := NO_TILE
	var best := 1 << 30
	var taken := {}
	var cells: Array = ctx.read("cells")
	for c in cells:
		var row: Dictionary = c
		if not bool(row["alive"]):
			continue
		taken[Vector2i(row["at"])] = true
		if int(row["seat"]) == 0:
			me = Vector2i(row["at"])
	if me == NO_TILE:
		return NO_TILE
	for c in cells:
		var row: Dictionary = c
		if int(row["seat"]) == 0 or not bool(row["alive"]) or str(row["type"]) == "T细胞":
			continue
		var dd := CWData.hex_dist(Vector2i(row["at"]), me)
		if dd < best:
			best = dd
			target = Vector2i(row["at"])
	if target == NO_TILE:
		return NO_TILE
	if best > 1:
		## 朝目标走：六邻里没人站、且离目标更近的第一格
		for d in CWData.DIRS:
			var n: Vector2i = me + d
			if taken.has(n) or CWData.hex_dist(n, target) >= best:
				continue
			if ctx.read("tile", n).is_empty():
				continue
			return n
		return NO_TILE
	for d in CWData.DIRS:
		var n: Vector2i = target + d
		if taken.has(n) or CWData.hex_dist(n, me) != 1:
			continue
		var t: Dictionary = ctx.read("tile", n)
		if t.is_empty() or int(t["state"]) != CWData.Tissue.HEALTHY:
			continue
		return n
	## 挨着的环格都已是癌组织 / 站着人：沿环再走一格（踩已癌化的环格）去够剩下的健康格，这一轮不回头
	var seen: Dictionary = ctx.state().get("ring_seen", {})
	for d in CWData.DIRS:
		var n: Vector2i = target + d
		if taken.has(n) or CWData.hex_dist(n, me) != 1 or seen.has(n):
			continue
		if ctx.read("tile", n).is_empty():
			continue
		return n
	return NO_TILE


# =====================================================================
# PRD:477-481 第 7 步 —— 免疫回合
# =====================================================================

## 逐席登记 plan（幂等，见文件头），再**软等**一个世界回合过去。
## 「等」用的是带超时的 `ctx.until` —— 剧本写歪 / 盘面提前打完时是「等不到」而不是无声卡死；
## 真正的同步点是下一条 `player`（闸把玩家的那一问按住，内核自己会先把免疫席走完）。
func immune_turn(ctx) -> void:
	await _arm_immune(ctx)
	var n := int(ctx.read("alive_count", "immune"))
	ctx.log("免疫回合：盘上 %d 只免疫按 approach / attack_if_adjacent 走（巨噬净化由内核演）" % n)
	## 玩家一按「结束回合」，内核就把免疫席与 E 阶段**同步**走完了 —— 钩子醒来时世界回合已经前进，
	## 这里的 `until` 只是给演出（抗体 / 净化 / 压迫飘字）留一口气；写 12 s 会让每一轮空等 12 s（2026-09-24 无头探针）
	var hit: bool = await ctx.until({ "delta": "round" }, 1.5)
	ctx.log("免疫回合走完（世界回合前进：%s）" % str(hit))


## 给每一只**活着的**免疫席喂一份 plan。种类名走 `CWData.IMMUNE_TYPE_NAMES`
## （`ctx.read("cells")` 的 `type` 给的就是它），钩子不认识内核的枚举下标
func _arm_immune(ctx) -> void:
	for c in ctx.read("cells"):
		var row: Dictionary = c
		var seat := int(row["seat"])
		if seat == 0 or not bool(row["alive"]):
			continue
		await ctx.beat({ "do": "npc", "prd": 477, "seat": seat, "plan": _plan_of(str(row["type"])) })


## 一席的 plan：一轮的块 × `NPC_REPEAT`。
## · B 细胞（PRD:479）：靠近之后**点名三条**【抗体】—— 次数靠 plan，不靠旋钮；
##   「无视邻接健康组织的限制」靠**盘面**（目标集合写死在规则里，没有旋钮）。
## · T 细胞（§7.3 Q7-3 默认）：**全程不动** —— 它是第 9 步起那条直射线的发点。
## · 其余（巨噬 / 树突）：`approach` 一步；`approach` 自带「邻接就打」（`cw_tutorial_npc._by_policy`）。
func _plan_of(kind: String) -> Array:
	var block: Array = [{ "policy": "approach", "target_seat": 0 }, { "policy": "end_turn" }]
	if kind == "B细胞":
		block = [{ "policy": "approach", "target_seat": 0 },
			{ "key": "k=action|act=antibody" }, { "key": "k=action|act=antibody" },
			{ "key": "k=action|act=antibody" }, { "policy": "end_turn" }]
	elif kind == "T细胞":
		block = [{ "policy": "end_turn" }]
	var out: Array = []
	for _i in NPC_REPEAT:
		out.append_array(block.duplicate(true))
	return out


# =====================================================================
# PRD:483 第 8 步 —— 重复 3、4、7 直到剩最后一个 T
# =====================================================================

## 终止条件是**运行期**的：盘上只剩一只免疫（那只就是 T —— 它全程不动、也没人打得到它）。
## 每轮 = 围一圈（第 3 步）+ 结束回合（第 4 步）+ 免疫回合（第 7 步）。
## 关首那一轮围巨噬；第 1 次重复围走过来的 B（它在 (-4,0)）；第 2 次重复去围只挪了一步就没能量的树突 (-5,4)；
## 各回合死一只（2026-09-24 无头探针：巨噬第 1 回合被压死、B 第 2 回合攻击玩家掷骰无效被【反弹】归零、
## 树突第 3 回合被压死，两轮重复就收口；带子空 ⇒ 种子恒 1 的兜底 rng，掷骰可复现）。
## 收口之后玩家一步步走回围圈终点 (-2,1)，第 10 步起的两轮击退从那儿起算。
##
## **轮数封顶 `ROUNDS_CAP`**：世界回合 ≤ 5 才恒在癌 I 期。封顶之后仍有免疫活着的话
## **不 `fail`**，装一份 `pressed`（= knock1 的盘面、玩家回 (-2,1)）纠偏再往下走 —— 不装的话
## 第 10 步「走到 (-3,1)」会撞上还站着的免疫，整关卡死（记一笔账，别静默）
func repeat_until_last_t(ctx) -> void:
	var st: Dictionary = ctx.state()
	var n := 0
	while ctx.alive() and n < ROUNDS_CAP and int(ctx.read("alive_count", "immune")) > 1:
		n += 1
		st["l6_round"] = n
		ctx.log("第 %d 次重复（PRD:483 的 3、4、7）" % n)
		await encircle(ctx)
		await ctx.beat({ "do": "point", "prd": 483, "ui": ["panel:end"], "mode": "fullscreen",
			"tip": "点击结算【微环境压迫】" })
		## `mode` / `tip` 要在**这一条**上再写一遍：`player` 自己也会调一次提亮，
		## 不写就把上一条 `point` 的全屏提示与按钮小气泡覆写成默认的 soft + 空 tip
		await ctx.beat({ "do": "player", "prd": 483,
			"hint": "点右边的「结束回合」，把这一轮结算掉",
			"ui": ["panel:end"], "mode": "fullscreen", "tip": "点击结算【微环境压迫】",
			"allow": ["k=action|act=end"], "until": { "delta": "ended" } })
		await immune_turn(ctx)
	var left := int(ctx.read("alive_count", "immune"))
	ctx.log("重复结束：走了 %d 轮，盘上还剩 %d 只免疫" % [n, left])
	if left > 1:
		## 保险：封顶之后仍有免疫活着（玩家走位异常 / 免疫没按剧本站位），装一份「已被压死」的盘面
		## 再进第 9 步 —— 不装的话第 10 步「走到 (-3,1)」会撞上站在那儿的 B 细胞，整关卡死（2026-09-24 真机）
		ctx.log("封顶 %d 轮之后仍有 %d 只免疫 —— 装 pressed 盘面纠偏（1/2/3 席阵亡、玩家回围圈终点）"
			% [ROUNDS_CAP, left])
		await ctx.beat({ "do": "state", "prd": 483, "load": "pressed" })
		return
	## 围 B / 树突时走远了：回到围圈终点 (-2,1) —— 第 10 步起的两轮击退（-3,1 → -1,1 → 0,1）都按这一格起算
	await _walk_to(ctx, Vector2i(-2, 1), "回到起点，T 细胞的效应应答要来了")


## 一步一步走到 `goal`（每步 = 六邻里没人站、离 goal 更近的第一格；玩家能量 Null，随便走）
func _walk_to(ctx, goal: Vector2i, hint: String) -> void:
	var guard := 0
	while ctx.alive() and guard < APPROACH_GUARD:
		guard += 1
		var me := NO_TILE
		var taken := {}
		for c in ctx.read("cells"):
			var row: Dictionary = c
			if not bool(row["alive"]):
				continue
			taken[Vector2i(row["at"])] = true
			if int(row["seat"]) == 0:
				me = Vector2i(row["at"])
		if me == NO_TILE or me == goal:
			break
		var step := NO_TILE
		var best := CWData.hex_dist(me, goal)
		for d in CWData.DIRS:
			var n: Vector2i = me + d
			if taken.has(n) or CWData.hex_dist(n, goal) >= best or ctx.read("tile", n).is_empty():
				continue
			step = n
			break
		if step == NO_TILE:
			break
		var at := _at_text(step)
		await ctx.beat({ "do": "point", "prd": 483, "hex": [at], "mode": "soft" })
		await ctx.beat({ "do": "player", "prd": 483, "hint": hint, "hex": [at],
			"allow": ["k=action|act=move|to=" + at], "until": { "state": "cell_at", "arg": [0, at] } })
	ctx.log("回到围圈终点（走了 %d 格）" % (guard - 1))


# =====================================================================
# 小工具
# =====================================================================

## `Vector2i` → 数据里那种 `"q,r"`（`allow` 的 `to=` 与 `hex` 都要这一种写法）
func _at_text(v: Vector2i) -> String:
	return "%d,%d" % [v.x, v.y]
