## levels/c3_l6.gd —— **第六关的关卡钩子**（PRD:437-528 的 25 步摆拍里「数据表达不了」的那三条；
## docs/新手引导v2_实现方案.md §3.7 / §4 第六关那几行，S11，2026-09-19；09-24 两次改口见下）
##
## 三支（剧本 `{"do":"hook","call":"X"}` 点名）：
##   · `encircle`            PRD:467 第 3 步「引导玩家迁移将临近免疫细胞围一圈癌组织」
##     —— **下一格是运行期算的**。关首那一轮目标是隔 2 格的巨噬：先走一格挨上去，再绕它六邻一圈
##        （PRD 那张 6 步走法表，落点 (-2,1)）；之后几轮（PRD:483 的重复）目标是**自己走到玩家身边**的
##        B / 树突：绕它一圈**回到出发那一格** —— 走完最后一步正好回到起点（Kevin 2026-09-24），
##        没有免疫挨着就这一轮不围、只结束回合。`point` + `allow` 每步只放一格。
##   · `immune_turn`         PRD:477-481 第 7 步「所有免疫向靠近癌细胞的方向移动一格，邻接则攻击」
##     —— 逐席一份 `npc.plan`：巨噬 `approach`（挨着就打）；**B / 树突走写死的路线**（`k=action|act=move|to=`）：
##        `approach` 挑的是「离目标最近的可付格」，不保证比现在更近，挨着又打不了人的树突还会绕着玩家转圈、
##        踩到环上的癌组织顺手净化（09-24 无头推演），路线写死才走得到 (-2,1) 身边、站定不动；
##        B 第一轮点名三条 `k=action|act=antibody`（PRD:479）；巨噬净化由**内核**自己演；
##        T 全程不动（它是第 9 步起那条直射线的发点）。
##   · `repeat_until_last_t` PRD:483 第 8 步「重复 3、4、7 直到剩余最后一个 T 细胞」
##     —— **终止条件是运行期的**（`ctx.read("alive_count", "immune")`）；收口那一刻玩家就站在 (-2,1)，
##        第 9 步的效应应答紧接着来，第 10 步起的两轮击退按 (-2,1) 起算（09-24 之前多一段「走回起点」，Kevin 打回）。
##
## **免疫真的会被压死，靠的是关卡数据不是钩子**（2026-09-24 Kevin「第六关无法结束」）：
## 整盘一环的【微环境压迫】只有 1.5/回合（癌 I 期），而免疫默认每回合 +3～5 有氧收入、死了下一回合还在骨髓复活 ——
## 原数据（三只都 3.0 能量）下第 8 步永远收不了口。c3_l6.json 的 base 把有氧收入六个旋钮拧 0、
## `immune_respawn_delay: 99`，能量 巨噬 1.0 / B 7.5 / 树突 2.5（迁移：健康格 0.5、癌组织 0.8 且顺手净化；
## 付费门槛是「能量 > 费用」；攻击 0.8、掷骰无效再被【反弹】扣 0.5）：
## · 巨噬：第 1 回合被围、打玩家一下（0.8，吞噬回 0.5）剩 0.7，结算 1.5 压死；
## · 树突：第 1 回合沿 (-5,4)(-4,3)(-3,3)(-2,2) 走四格（各 0.5）到玩家身边剩 0.5，第 2 回合被围，结算压死；
## · B：第 1 回合走到 (-4,0)（0.5）发三发抗体（3.0）剩 4.0，第 2 回合踩着一环走进死巨噬那格 (-2,0)（两步各 0.8，
##   顺手把 (-3,0)(-2,0) 净化掉）剩 2.4，结算时五癌一健（(5−1)×10/4 = 1.0）剩 1.4；第 3 回合玩家把一环重新踩满
##   （(-3,0) 再【定殖】），B 打玩家一下（0.8）剩 0.6，结算 1.5 压死（掷骰无效被【反弹】0.5 也一样死）。
## 压迫公式一个字没动；数字都是无头探针 / `t_tutor_c3_drive` 实测的。
##
## 三条纪律（护栏 `t_tutor_hooks` 逐条扫，写钩子的人照抄 `levels/demo.gd`）：
## ① **零成员变量** —— 状态只能进 `ctx.state()`（那只字典随代际一起清空）；
## ② **每个 `while` 的条件都含 `ctx.alive()`** —— 代际一换，钩子自己从循环里退出来；
## ③ 只经 `ctx` 的九个方法（`beat` / `until` / `read` / `alive` / `frame` / `rng` / `state` / `log` / `fail`）。
##    钩子够不着 kernel / mirror / game / view / stage —— 要说话就 `ctx.beat({"do":"say", …})`。
##
## **`npc.plan` 的一条实装账**（`cw_tutorial_npc.Decider`）：换 plan 时 `memo` **不清零**
## （`match.gd::_tutor_set_npc` 只写 `plan`）。所以这里每次都喂**同一张**长表：游标一路往下走，反复登记是幂等的。
## 路线走完之后的块全是「结束回合」，喂「一轮的量」会让第二轮起整张表越界 ⇒ 三级兜底
## 「结束回合」⇒ 免疫全程不动，真机上只表现为「怎么没人过来打我」。
## 点名的键这一问里没有（付不起 / 落点站了人）时 `decide()` 跳过那一行看下一行（09-24），
## 路线不会因为一格走不了就整轮报废。
##
## **不带 class_name**（方案 §1.5）：钩子是天天在改的东西，要能走热更。
extends RefCounted

## 「没有这一格」的哨兵（同 `cw_tutor_beats.NONE`，这里不 preload 它只为了一个常量）
const NO_TILE := Vector2i(9999, 9999)
## 围一圈最多走几格：六邻 + 回到出发格 + 冗余。`while` 的第二道闸（第一道永远是 `ctx.alive()`）
const RING_GUARD := 12
## 关首那一轮走到巨噬身边最多几步（隔 2 格 ⇒ 1 步；留冗余）。同样是 `while` 的第二道闸
const APPROACH_GUARD := 4
## PRD:483 最多再重复几轮。**世界回合 ≤ 5 恒癌 I 期**（增生 / 固化的分档下标不漂）：
## 关首 1 轮 + 这里 3 轮 + 黏液复活那轮 = 5。剧本路线上 2 轮就收口（树突第 2 回合、B 第 3 回合）
const ROUNDS_CAP := 3
## 一份 plan 里把「一轮的块」重复几遍（见文件头「memo 不清零」那一条）
const NPC_REPEAT := 8
## 免疫回合最多等几帧「世界回合前进」（≈ 15 s）：B 攻击那一下带掷骰演出、免疫回合能拖两三秒，
## 等不到就记一笔往下走（剧本写歪 / 盘面提前打完时是「等不到」而不是无声卡死）
const ROUND_WAIT_FRAMES := 900


# =====================================================================
# PRD:467 第 3 步 —— 围一圈
# =====================================================================

## 每次只亮**一格**（`_next_step`）。关首那一轮（`l6_round` 还没记）目标是隔 2 格的巨噬：先走一格挨上去，
## 再绕六邻（DIRS 顺序 ⇒ 正好是开发日志那张表的 6 步走法 (0,0)→(-1,0)→(-1,-1)→(-2,-1)→(-3,0)→(-3,1)→(-2,1)）。
## 重复那几轮目标是走到身边的 B / 树突：从此刻站的格出发绕一圈、**最后一步回到出发格**；没有挨着的就不走。
## 玩家走上去 ⇒ 内核把健康格染成癌组织（【定殖】）⇒ 下一次再算就换到下一格；绕完这一支自己退出。
## 走过的痕迹（第 10 步前的全部癌组织）已烘进 knock1 —— 第 11 步那次重装才不会把它们抹回健康。
func encircle(ctx) -> void:
	await _arm_immune(ctx)          ## 免疫的 plan 要赶在第一次「结束回合」之前装上
	var st: Dictionary = ctx.state()
	var first: bool = int(st.get("l6_round", 0)) == 0
	st["ring_seen"] = {}            ## 这一轮绕环踩过的格：绕圈时不回头
	st["ring_home"] = NO_TILE       ## 重复那几轮的出发格：最后一步回它
	st["ringed"] = false
	var guard := 0
	while ctx.alive() and guard < RING_GUARD + APPROACH_GUARD:
		guard += 1
		var step: Vector2i = _next_step(ctx, first)
		if step == NO_TILE:
			break
		var at := _at_text(step)
		await ctx.beat({ "do": "point", "prd": 467, "hex": [at], "mode": "soft" })
		await ctx.beat({ "do": "player", "prd": 467,
			"hint": "顺着闪的那一格走 —— 把免疫细胞围成一圈癌组织",
			"hex": [at], "allow": ["k=action|act=move|to=" + at],
			"until": { "state": "cell_at", "arg": [0, at] } })
		(st["ring_seen"] as Dictionary)[step] = true
		st["ringed"] = true
		ctx.log("围一圈：玩家走到 %s" % at)
	if bool(st["ringed"]):
		ctx.log("围一圈结束（走了 %d 格）" % (guard - 1))
	else:
		ctx.log("这一轮没有免疫挨着玩家：不围，先结束回合")
	st["round_before_end"] = int(ctx.read("round"))   ## 免疫回合要等的就是它 +1（见 immune_turn）


## 下一格。目标 = **离玩家最近的活着的免疫（T 除外）**。
## 没挨着：关首那一轮（`may_approach`）朝它走一格；重复那几轮给 NO_TILE —— 免疫自己会走过来，玩家原地等。
## 挨着了，按三档挑：
## ① 目标六邻里**还是健康组织、没人站、且与玩家相邻**的第一格 —— 健康 ⇒ 还没围过；没人站 ⇒ 迁上去不是攻击；
##    相邻 ⇒ 这一步内核真给得出选项；
## ② 挨着的环格都已是癌组织：沿环再走一格（踩已癌化的环格）去够剩下的健康格，这一轮不回头、出发格留到最后；
## ③ 环上别的格都走过了：最后一步回到出发格（重复那几轮才有出发格；关首那一轮按 PRD 的表停在 (-2,1)）。
## 自己站的那一格不算「有人站」—— 绕完要回来。六格围完 / 走不动了给 NO_TILE
func _next_step(ctx, may_approach: bool) -> Vector2i:
	var st: Dictionary = ctx.state()
	var me := NO_TILE
	var target := NO_TILE
	var best := 1 << 30
	var taken := {}
	var cells: Array = ctx.read("cells")
	for c in cells:
		var row: Dictionary = c
		if not bool(row["alive"]):
			continue
		if int(row["seat"]) == 0:
			me = Vector2i(row["at"])
		else:
			taken[Vector2i(row["at"])] = true
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
		if not may_approach:
			return NO_TILE
		for d in CWData.DIRS:
			var n: Vector2i = me + d
			if taken.has(n) or CWData.hex_dist(n, target) >= best or ctx.read("tile", n).is_empty():
				continue
			return n
		return NO_TILE
	var home: Vector2i = st.get("ring_home", NO_TILE)
	if home == NO_TILE and not may_approach:
		home = me
		st["ring_home"] = home
	var seen: Dictionary = st.get("ring_seen", {})
	for d in CWData.DIRS:
		var n: Vector2i = target + d
		if taken.has(n) or n == me or CWData.hex_dist(n, me) != 1:
			continue
		var t: Dictionary = ctx.read("tile", n)
		if t.is_empty() or int(t["state"]) != CWData.Tissue.HEALTHY:
			continue
		return n
	for d in CWData.DIRS:
		var n: Vector2i = target + d
		if taken.has(n) or n == me or n == home or seen.has(n) or CWData.hex_dist(n, me) != 1:
			continue
		if ctx.read("tile", n).is_empty():
			continue
		return n
	if home != NO_TILE and home != me and not seen.has(home) and CWData.hex_dist(home, me) == 1:
		return home
	return NO_TILE


# =====================================================================
# PRD:477-481 第 7 步 —— 免疫回合
# =====================================================================

## 逐席登记 plan（幂等，见文件头），再等**世界回合真的前进**（镜像的 `round` 超过围圈那一刻记下的数）。
## 不能用 `ctx.until({"delta": "round"})`：玩家一按「结束回合」，内核有时**同步**把免疫席与 E 阶段走完
## （钩子醒来时回合已经前进，delta 永远等不到、只能靠超时），有时又拖两三秒（B 攻击那一下带掷骰演出）——
## 09-24 上午把超时从 12 s 缩到 1.5 s 之后，后一种情形下钩子提前醒来、`alive_count` 读到的还是没结算的盘面，
## 多跑一轮重复、玩家走离了 (-2,1)，第 10 步「走到 (-3,1)」当场卡死。按回合号等两种情形都对。
## 等不到（`ROUND_WAIT_FRAMES`）就记一笔往下走，不无声卡死；真正的同步点仍是下一条 `player`。
func immune_turn(ctx) -> void:
	await _arm_immune(ctx)
	var st: Dictionary = ctx.state()
	var n := int(ctx.read("alive_count", "immune"))
	ctx.log("免疫回合：盘上 %d 只免疫按各自的 plan 走（巨噬 approach、B / 树突写死路线；巨噬净化由内核演）" % n)
	var r0 := int(st.get("round_before_end", int(ctx.read("round")) - 1))
	var frames := 0
	while ctx.alive() and int(ctx.read("round")) <= r0 and frames < ROUND_WAIT_FRAMES:
		frames += 1
		await ctx.frame()
	st.erase("round_before_end")
	ctx.log("免疫回合走完（世界回合 %d → %d，等了 %d 帧%s）"
		% [r0, int(ctx.read("round")), frames, "，没等到" if frames >= ROUND_WAIT_FRAMES else ""])


## 给每一只**活着的**免疫席喂一份 plan。种类名走 `CWData.IMMUNE_TYPE_NAMES`
## （`ctx.read("cells")` 的 `type` 给的就是它），钩子不认识内核的枚举下标
func _arm_immune(ctx) -> void:
	for c in ctx.read("cells"):
		var row: Dictionary = c
		var seat := int(row["seat"])
		if seat == 0 or not bool(row["alive"]):
			continue
		await ctx.beat({ "do": "npc", "prd": 477, "seat": seat, "plan": _plan_of(str(row["type"])) })


## 一席的 plan（一回合一块；见文件头「免疫真的会被压死」那段的路线）：
## · B 细胞（PRD:479）：第 1 回合走到 (-4,0) 再**点名三条**【抗体】—— 次数靠 plan，不靠旋钮；
##   「无视邻接健康组织的限制」靠**盘面**（目标集合写死在规则里，没有旋钮）；
##   第 2 回合两步走进死巨噬那格 (-2,0)；之后每回合挨着就打玩家一下（`attack_if_adjacent`）。
## · 树突：第 1 回合四步走到 (-2,2)（玩家 (-2,1) 身边），之后站着不动 —— 它打不了癌细胞，`approach` 会让它绕圈。
## · T 细胞（§7.3 Q7-3 默认）：**全程不动** —— 它是第 9 步起那条直射线的发点。
## · 其余（巨噬）：`approach` 一步；`approach` 自带「邻接就打」（`cw_tutorial_npc._by_policy`）。
## 路线之后的块全是「结束回合」，块数 `NPC_REPEAT` 遍：游标越界会落三级兜底，同样是「结束回合」
func _plan_of(kind: String) -> Array:
	var blocks: Array = []
	match kind:
		"B细胞":
			blocks.append([_mv("-4,0"), _ab(), _ab(), _ab(), { "policy": "end_turn" }])
			blocks.append([_mv("-3,0"), _mv("-2,0"), { "policy": "end_turn" }])
			for _i in NPC_REPEAT:
				blocks.append([{ "policy": "attack_if_adjacent", "target_seat": 0 }, { "policy": "end_turn" }])
		"树突状细胞":
			blocks.append([_mv("-5,4"), _mv("-4,3"), _mv("-3,3"), _mv("-2,2"), { "policy": "end_turn" }])
			for _i in NPC_REPEAT:
				blocks.append([{ "policy": "end_turn" }])
		"T细胞":
			for _i in NPC_REPEAT:
				blocks.append([{ "policy": "end_turn" }])
		_:
			for _i in NPC_REPEAT:
				blocks.append([{ "policy": "approach", "target_seat": 0 }, { "policy": "end_turn" }])
	var out: Array = []
	for b in blocks:
		out.append_array(b)
	return out


func _mv(at: String) -> Dictionary:
	return { "key": "k=action|act=move|to=" + at }


func _ab() -> Dictionary:
	return { "key": "k=action|act=antibody" }


# =====================================================================
# PRD:483 第 8 步 —— 重复 3、4、7 直到剩最后一个 T
# =====================================================================

## 终止条件是**运行期**的：盘上只剩一只免疫（那只就是 T —— 它全程不动、也没人打得到它）。
## 每轮 = 围一圈（第 3 步）+ 结束回合（第 4 步）+ 免疫回合（第 7 步）。
## 关首那一轮围巨噬；第 1 次重复围走到 (-2,2) 的树突；第 2 次重复围走进 (-2,0) 的 B（一环重新踩满）；
## 每一圈都从 (-2,1) 出发、回到 (-2,1)，收口那一刻玩家就站在第 9 步要的那一格（Kevin 09-24：
## 「走完最后一步正好回到起点，然后 T 细胞放大招」）。免疫还没挨过来的那一轮只结束回合。
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
		var ringed := bool(st.get("ringed", false))
		var tip := "点击结算【微环境压迫】" if ringed else "免疫细胞正在逼近，先结束回合"
		var hint := "点右边的「结束回合」，把这一轮结算掉" if ringed \
			else "没有免疫挨着你 —— 点右边的「结束回合」，等它们走过来"
		await ctx.beat({ "do": "point", "prd": 483, "ui": ["panel:end"], "mode": "fullscreen", "tip": tip })
		## `mode` / `tip` 要在**这一条**上再写一遍：`player` 自己也会调一次提亮，
		## 不写就把上一条 `point` 的全屏提示与按钮小气泡覆写成默认的 soft + 空 tip
		await ctx.beat({ "do": "player", "prd": 483, "hint": hint,
			"ui": ["panel:end"], "mode": "fullscreen", "tip": tip,
			"allow": ["k=action|act=end"], "until": { "delta": "ended" } })
		await immune_turn(ctx)
	var left := int(ctx.read("alive_count", "immune"))
	var me := NO_TILE
	for c in ctx.read("cells"):
		if int((c as Dictionary)["seat"]) == 0 and bool((c as Dictionary)["alive"]):
			me = Vector2i((c as Dictionary)["at"])
	ctx.log("重复结束：走了 %d 轮，盘上还剩 %d 只免疫，玩家站 %s" % [n, left, _at_text(me)])
	if left > 1 or me != Vector2i(-2, 1):
		## 保险：封顶之后仍有免疫活着 / 玩家没停在 (-2,1)（走位异常、免疫没按剧本站位），装一份「已被压死、
		## 玩家在围圈终点」的盘面再进第 9 步 —— 不装的话第 10 步「走到 (-3,1)」会撞上站着的免疫或根本不相邻，
		## 整关卡死（2026-09-24 真机）
		ctx.log("剧本路线走歪（剩 %d 只免疫 / 玩家在 %s）—— 装 pressed 盘面纠偏（1/2/3 席阵亡、玩家回 (-2,1)）"
			% [left, _at_text(me)])
		await ctx.beat({ "do": "state", "prd": 483, "load": "pressed" })


# =====================================================================
# 小工具
# =====================================================================

## `Vector2i` → 数据里那种 `"q,r"`（`allow` 的 `to=` 与 `hex` 都要这一种写法）
func _at_text(v: Vector2i) -> String:
	return "%d,%d" % [v.x, v.y]
