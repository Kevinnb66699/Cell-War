## levels/interlude.gd —— 间章「癌变」的关卡钩子（PRD:431/433/435，S9b，2026-09-19）
##
## 数据写不死的只有三件，所以这一关只有三支钩子：
##   ① 分镜 8（PRD:431）「周围免疫弹出文字提示」—— 说话人是运行期才知道的
##      （离玩家最近的那一只）；台词不在 PRD 里、已删净（2026-09-21），钩子只留流水账；
##   ② 分镜 9（PRD:433）「附近最近一个免疫细胞移动到癌细胞附近，攻击癌细胞三次」——
##      同上，而且要给那一席现喂一份 `npc` 计划；
##   ③ 分镜 10（PRD:435）「将一环内免疫细胞向外击退 1 格」—— 一环内有谁、被推到哪，
##      也得现算（**击退是重装不是规则**：盘面在 `solid` 那份里，这里只补那一下位移演出）。
##
## 三条纪律（照 `levels/demo.gd`，护栏 `t_tutor_hooks` 逐条扫）：
## ① **零成员变量** —— 状态只能进 `ctx.state()`（这一关一个都用不上，全是局部量）；
## ② **每个 `while` 的条件都含 `ctx.alive()`** —— 这一关没有 `while`，只有 `for`；
## ③ 只经 `ctx` 的九个方法：`beat` / `until` / `read` / `alive` / `frame` / `rng` / `state` / `log` / `fail`。
##
## **不带 class_name**（方案 §1.5）：钩子要能走热更。
extends RefCounted


## 分镜 8（PRD:431）：离玩家最近的那只免疫发现敌情。
## **不再说话**（2026-09-21 Kevin：非新手教程 PRD 的文案一律删净）——原先那句
## 「发现新的敌人，继续清除——」是钩子自己编的台词，PRD 里没有。钩子与拍位保留
## （流水账照记），PRD 若日后给出这句的正稿，把 `ctx.beat` 挂回来就是。
func alarm(ctx) -> void:
	var seat := _nearest_immune(ctx)
	if seat < 0:
		ctx.log("分镜 8：盘上一只活着的免疫细胞都没有，这一拍静默跳过")
		return
	ctx.log("分镜 8：离玩家最近的免疫是席位 %d" % seat)


## 分镜 9（PRD:433）：那一只走到玩家相邻格、攻击三次。
##
## **走内核规则**（方案 §4 的 409 那一行）：给那一席一份 `npc` 计划，再装 `act`
## （= `flip` 只改 `seat`）把行动权交过去。计划五条 = 靠近一格 + 攻击三次 + 显式结束回合；
## 「恰好三次」由数据钉死（`rolls` 三条 + 引擎 `ATTACK_MAX_PER_TURN = 3`），不靠这里数。
##
## 判据取 `{"delta": "ended"}`：计划的最后一条是显式的「结束回合」，所以
## **行动权一离开这一席 = 三下打完了**。不拿「掉没掉血」当判据：那是**第一下**
## 就成立的东西，后面两下会被分镜 10 的重装提前打断（带子就剩下一条没用完）。
##
## 超时只在「玩家一点血都没掉」时才算挖到坑：NPC 的 decider 是同步作答的，
## 换盘那一下引擎有可能在 `_enter_state` 里就把三下全跑完了——
## 那时候基线拍到的已经是「轮到别人」，差分判据永远不会再成立
func assault(ctx) -> void:
	var player := 0                       ## 间章的人类席恒为 0（`interlude.json` 的 human_seat，逐字照 c3_l6.base）
	var seat := _nearest_immune(ctx)
	if seat < 0:
		await ctx.fail("分镜 9：盘上一只活着的免疫细胞都没有，没人来打这三下")
		return
	var e0 := int(ctx.read("energy", player))
	ctx.log("分镜 9：席位 %d 上来打三下（玩家此刻能量 %d）" % [seat, e0])
	await ctx.beat({ "do": "npc", "seat": seat, "plan": [
		{ "policy": "approach", "target_seat": player },
		{ "policy": "attack_if_adjacent", "target_seat": player },
		{ "policy": "attack_if_adjacent", "target_seat": player },
		{ "policy": "attack_if_adjacent", "target_seat": player },
		{ "policy": "end_turn" },
	] })
	await ctx.beat({ "do": "state", "prd": 433, "load": "act" })
	var ok: bool = await ctx.until({ "delta": "ended" }, 8.0)
	if not ok and int(ctx.read("energy", player)) >= e0:
		await ctx.fail("分镜 9：等不到那三下落地（玩家能量一点没掉）")
		return
	ctx.log("分镜 9：三下打完，玩家能量 %d" % int(ctx.read("energy", player)))


## 分镜 10（PRD:435）：癌细胞原地再放一次冲击波 → 脚下生成固化癌组织 → 一环内免疫外推 1 格。
##
## 次序讲究：**先把「谁从哪被推到哪」记下来再换盘** —— `solid` 那份里免疫已经站在被推后的格上，
## 换完再算就什么都看不出来了。换盘之后再补 `knockback`，演出的起点是它**刚才**那一格。
func erupt(ctx) -> void:
	var player := 0
	await ctx.beat({ "do": "play", "prd": 435, "fx": "shockwave", "at": player,
		"secs": 0.2, "args": { "radius": 4 }, "await": true })
	var me := _at_of(ctx, player)
	var pushed: Array = []
	for c in ctx.read("cells"):
		var e: Dictionary = c
		if not bool(e["alive"]) or int(e["seat"]) == player:
			continue
		var from: Vector2i = e["at"]
		if int(ctx.read("dist", [me, from])) != 1:
			continue
		pushed.append([int(e["seat"]), from, from + (from - me)])   ## 沿着「背对玩家」那个方向再走一格
	ctx.log("分镜 10：一环内有 %d 只免疫要被推出去" % pushed.size())
	await ctx.beat({ "do": "state", "prd": 435, "load": "solid" })
	for p in pushed:
		var row: Array = p
		await ctx.beat({ "do": "play", "prd": 435, "fx": "knockback", "at": row[0],
			"args": { "actor": row[0], "from": row[1], "to": row[2] }, "await": true })


# ---- 私有小工具（不是 ctx 的一部分，只是把上面三支里重复的两句收在一处）----

## 离玩家最近的那只**活着的非玩家**细胞的席位；一只都没有给 -1。
## 翻转之后盘上除了玩家就只有免疫（`interlude.json` 的五席），所以「非玩家」= 免疫
func _nearest_immune(ctx) -> int:
	var player := 0
	var me := _at_of(ctx, player)
	var best := -1
	var best_d := 1 << 30
	for c in ctx.read("cells"):
		var e: Dictionary = c
		if not bool(e["alive"]) or int(e["seat"]) == player:
			continue
		var d := int(ctx.read("dist", [me, e["at"]]))
		if d < best_d:
			best_d = d
			best = int(e["seat"])
	return best


## 某一席此刻那格（查不到给盘心 —— 间章里玩家恒在 (0,0)，正好也是最保守的那个值）
func _at_of(ctx, seat: int) -> Vector2i:
	for c in ctx.read("cells"):
		var e: Dictionary = c
		if int(e["seat"]) == seat and bool(e["alive"]):
			return e["at"]
	return Vector2i.ZERO
