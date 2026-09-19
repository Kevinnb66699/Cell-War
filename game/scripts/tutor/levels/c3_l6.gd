## levels/c3_l6.gd —— **第六关的关卡钩子**（PRD:437-528 的 25 步摆拍里「数据表达不了」的那三条；
## docs/新手引导v2_实现方案.md §3.7 / §4 第六关那几行，S11，2026-09-19）
##
## 三支（剧本 `{"do":"hook","call":"X"}` 点名）：
##   · `encircle`            PRD:467 第 3 步「引导玩家迁移将临近免疫细胞围一圈癌组织」
##     —— **下一格是运行期算的**：巨噬六邻里还没癌化、且与玩家相邻的那一格，`point` + `allow` 只放它。
##   · `immune_turn`         PRD:477-481 第 7 步「所有免疫向靠近癌细胞的方向移动一格，邻接则攻击」
##     —— 逐席一份 `npc.plan`（`approach` / `attack_if_adjacent` 走 `cw_tutorial_npc.POLICIES`）；
##        B 细胞的三次抗体是 plan 里点名三条 `k=action|act=antibody`；巨噬净化由**内核**自己演。
##   · `repeat_until_last_t` PRD:483 第 8 步「重复 3、4、7 直到剩余最后一个 T 细胞」
##     —— **终止条件是运行期的**（`ctx.read("alive_count", "immune")`）。
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
## PRD:483 最多再重复几轮。**世界回合 ≤ 5 恒癌 I 期**（增生 / 固化的分档下标不漂）：
## 关首 1 轮 + 这里 3 轮 + 黏液复活那轮 = 5
const ROUNDS_CAP := 3
## 一份 plan 里把「一轮的块」重复几遍（见文件头「memo 不清零」那一条）
const NPC_REPEAT := 8


# =====================================================================
# PRD:467 第 3 步 —— 围一圈
# =====================================================================

## 每次只亮**一格**：巨噬六邻里还没癌化、且与玩家此刻相邻的那一格（DIRS 顺序 ⇒ 正好是
## 开发日志那张表的 6 步走法 (0,0)→(-1,0)→(-1,-1)→(-2,-1)→(-3,0)→(-3,1)→(-2,1)）。
## 玩家走上去 ⇒ 内核把健康格染成癌组织（【定殖】）⇒ 下一次再算就换到下一格；六格走完这一支自己退出。
func encircle(ctx) -> void:
	await _arm_immune(ctx)          ## 免疫的 plan 要赶在第一次「结束回合」之前装上
	var guard := 0
	while ctx.alive() and guard < RING_GUARD:
		guard += 1
		var step: Vector2i = _next_ring_tile(ctx)
		if step == NO_TILE:
			break
		var at := _at_text(step)
		await ctx.beat({ "do": "point", "prd": 467, "hex": [at], "mode": "soft" })
		await ctx.beat({ "do": "player", "prd": 467,
			"hint": "顺着闪的那一格走 —— 把巨噬细胞围成一圈癌组织",
			"hex": [at], "allow": ["k=action|act=move|to=" + at],
			"until": { "state": "cell_at", "arg": [0, at] } })
		ctx.log("围一圈：玩家走到 %s" % at)
	ctx.log("围一圈结束（走了 %d 格）" % (guard - 1))


## 下一格：巨噬（席 1，`type` 给中文名）的六邻里，**还是健康组织、没人站、且与玩家相邻**的第一格。
## 三个条件缺一不可：健康 ⇒ 还没围过；没人站 ⇒ 迁上去不是攻击；相邻 ⇒ 这一步内核真给得出选项
func _next_ring_tile(ctx) -> Vector2i:
	var me := NO_TILE
	var mac := NO_TILE
	var taken := {}
	for c in ctx.read("cells"):
		var row: Dictionary = c
		if not bool(row["alive"]):
			continue
		taken[Vector2i(row["at"])] = true
		if int(row["seat"]) == 0:
			me = Vector2i(row["at"])
		elif str(row["type"]) == "巨噬细胞":
			mac = Vector2i(row["at"])
	if me == NO_TILE or mac == NO_TILE:
		return NO_TILE
	for d in CWData.DIRS:
		var n: Vector2i = mac + d
		if taken.has(n) or CWData.hex_dist(n, me) != 1:
			continue
		var t: Dictionary = ctx.read("tile", n)
		if t.is_empty() or int(t["state"]) != CWData.Tissue.HEALTHY:
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
	var hit: bool = await ctx.until({ "delta": "round" }, 12.0)
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
## 每轮 = 围一圈（第 3 步）+ 结束回合（第 4 步）+ 免疫回合（第 7 步）；
## 每轮末玩家都站在围圈终点 (-2,1)（`encircle` 六格走完的落点），第 10 步起的两轮击退从那儿起算。
##
## **轮数封顶 `ROUNDS_CAP`**：世界回合 ≤ 5 才恒在癌 I 期。封顶之后仍有免疫活着的话
## **不 `fail`** —— 第 11 步的 `state.load: knock1` 本来就把 1/2/3 席钉成阵亡、把一环钉成癌组织，
## 那一份重装就是这条路的纠偏（记一笔账，别静默）
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
		ctx.log("封顶 %d 轮之后仍有 %d 只免疫 —— 交给第 11 步的 knock1 重装纠偏（PRD:493）"
			% [ROUNDS_CAP, left])


# =====================================================================
# 小工具
# =====================================================================

## `Vector2i` → 数据里那种 `"q,r"`（`allow` 的 `to=` 与 `hex` 都要这一种写法）
func _at_text(v: Vector2i) -> String:
	return "%d,%d" % [v.x, v.y]
