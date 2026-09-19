## cw_tutor_director.gd —— 教程的**导演**：游标 + 装闸 + 意图分发 + 代际闸
## （docs/新手引导v2_实现方案.md §3，S1，2026-09-19）
##
## 它手里只有三样：`CWKernel`（句柄）、取镜像的一条线、`CWPlayQueue`（由调用方喂 `step_end`）。
## **`scripts/tutor/**` 里零 `CWGame` / `CWWorld` / `CWActions` / `CWSetup` / `game.`**（护栏 `t_no_engine_in_ui`）。
##
## **驱动只有三个源**（方案 §3.1）：
##   ① `queue.on_step` 的 `step_end` —— 装闸 / 判上一条 / 翻页的**正牌时机**；
##   ② 每帧 `_process` —— 镜像谓词、`say` 的节拍、`wait` 的计时；
##   ③ 玩家点「继续」—— 皮发 `advance_pressed`（只有 `say` 且 `auto:false` 时才理）。
##
## **装闸的唯一正确时机是 `step_end`**：内核的 decider 路逐行是
## `_close_step()`（推 step_end + sync）→ `await deciders[pid].ask(req)` → `_open_step()`（推 step_begin）
## —— **2026-09-19 按文件核准：`cw_kernel_inproc.gd:399 / :401 / :406`**（方案里三家给的 391/393/395
## 是错的）。所以 `step_begin` 标的是「这一问已经答了、动作开始演」，不是「要问了」。
## **关首再装一次**（`open()` 返回后、`kernel.run()` 之前）：关的第一帧在队列泵到那条 `step_end`
## 之前就画出来了，不提前装玩家会先看见一瞬间的全套界面。
## `install()` **幂等**，第三个调用点是「游标自己翻页那一下」—— 不当场换闸的话，
## 挂在旧闸上的下一问永远醒不来。
##
## **不带 class_name，调用方 preload**（方案 §1.5）：导演是会反复改的四件之一，要能走热更。
extends Node

const BEATS := preload("res://scripts/kernel/cw_tutor_beats.gd")
## 坐标解析只有数据门面一处（`parse_at`），导演不再抄一份
const SCRIPT_DATA := preload("res://scripts/kernel/cw_tutor_script.gd")

## 代际闸（搬方案 §3.7 / 乙的 epoch，`match.gd` 的换局代际号有先例）：
## GDScript 的协程**杀不掉，只能让它永挂**。`dead` 永不 emit —— 旧协程 `await` 在它上面，
## 随导演一起被回收。重置 / 目录跳关 / 换局各调一次 `invalidate()`
signal dead
## 这一关的 `flow` 走完了（`on_done` 指名的下一关；空串 = 全部通关）
signal level_done(next_id: String)
## 剧本要换一份 world（`flow[].state.load`）。**拆装次序不归导演管** ——
## 调用方走舞台的 `reload_world`（`abort → queue.stop → close → dispose`，次序一个字不能动）
signal want_load(world_id: String)
## 自动重置（`reset_when` 命中）/ 常驻「重置本关」
signal want_reset
## 给某席换脚本（`flow[].npc`）
signal want_npc(seat: int, plan: Array)

## 取「**此刻**那一份」镜像的一条线（`CWMatch` 给自己的 `mirror`）。
## **不存镜像、只存取法**：一关之内会换好几次局，存下来的那一份换局就过期了
var mirror_of: Callable = Callable()
## 闸桥（`cw_tutor_gate.gd`）。**不标类型**：它没有 class_name（要走热更）
var gate = null
var view: CWTutorView = null

var level := {}
var human_seat := 0
var active := false
var epoch := 0

## 游标（`flow` 下标）与「这一条的即时效果办过没有」
var _at := 0
var _entered := false
## 判据基线（`until` / `reset_when` / `advise_when` 三条读同一份）
var _base := {}
## 换局 / 重装之后**还欠一次**重取（见 `on_step_end`）：队列是异步消费的，
## 「新镜像刚落地」那一刻取到的可能还是上一局那一份
var _rebase_next := false
## `wait` / `play` 的倒计时
var _wait_left := 0.0
## `say` 还在念吗（皮的协程没回来）
var _saying := false
## 章节提示正在播（协程，播完才往下，PRD:35）
var _chapter_busy := false
## 上一次弹过的章节。比的是 **`(chapter_kind, chapter)` 二元组**，不是单个整数 ——
## 间章不是主章节的附属（Kevin 2026-09-19），它与主章节的 `chapter` 可能撞号
var _shown_chapter: Array = []
## 正劝着重置（`advise_when` 命中）：这时 `until` **不翻页** ——
## 第三关「站到相邻格」在能量算亏时照样成立，翻过去那句劝退当场消失
var _advising := false


# =====================================================================
# 生命周期
# =====================================================================

## 开一关。调用方的次序钉死：`stage.open_level()` → `_start_queue()` → **`install()`** → `kernel.run()`
func open(lv: Dictionary, seat: int) -> void:
	level = lv
	human_seat = seat
	_at = 0
	_entered = false
	_wait_left = 0.0
	_saying = false
	_advising = false
	active = true
	rebase_hard()
	## 章节提示（PRD:35）：`(chapter_kind, chapter)` 变了才弹，没变就静默切关（PRD:37）
	var key: Array = [str(lv.get("chapter_kind", "main")), int(lv.get("chapter", 1))]
	if key != _shown_chapter:
		_shown_chapter = key
		_chapter_busy = true
		_play_chapter(int(lv.get("chapter", 1)), str(lv.get("chapter_title", "")))
	if view != null and is_instance_valid(view):
		view.shell({ "chapter": key[1], "level": str(lv.get("id", "")), "can_reset": true })


## 退回关首（常驻「重置本关」与自动重置共用这一条）。
## 代际 +1：挂在旧闸 / 旧协程上的东西随导演一起被回收
func reset_level() -> void:
	invalidate()
	_at = 0
	_entered = false
	_wait_left = 0.0
	_saying = false
	_advising = false
	active = true
	rebase_hard()
	want_reset.emit()


## 取消语义：重置 / 目录跳关 / 换局各调一次。旧协程停在 `await dead` 上，永不返回
func invalidate() -> void:
	epoch += 1


## 这一代还活着吗（钩子层 S8 的 `ctx.alive()` 就是它）
func alive(ep: int) -> bool:
	return active and ep == epoch


func teardown() -> void:
	invalidate()
	active = false
	if view != null and is_instance_valid(view):
		view.teardown()


# =====================================================================
# 三个驱动源
# =====================================================================

## ① 行动边界：`CWPlayQueue.on_step` 的 `step_end`（装闸的正牌时机，见文件头）。
##
## **换局那一瞬间的脏基线**：两关免疫起点不同格，拿上一关的基线比 `delta:moved` 当场成立 ——
## 行动边界是「这一局已经换过了」的最早时刻，所以换局 / 重装之后要在这儿再取一次。
##
## ⚠ **只取那一次**（`_rebase_next`）。每个 step_end 都取的话，玩家刚走完的那一步会把
## `delta:moved` 的基线一并更新掉 —— 判据当场不成立、关卡卡死在这一步。而且它是**竞态**：
## 同一帧里队列先泵就卡住、导演先 tick 就翻页，09-19 真机上一次通一次不通，最难查的那种
func on_step_end() -> void:
	if not active:
		return
	if _rebase_next:
		_rebase_next = false
		rebase()
	install()


## ② 每帧
func _process(delta: float) -> void:
	if active:
		_tick(delta)


## ③ 玩家点「继续」：接皮的 `advance_pressed`（皮自己在 `say` 的协程里等，这里不用管）


## 重取判据基线。条目入口（`player`）与换局 / 重装两处调
func rebase() -> void:
	_base = BEATS.snap(_mirror(), human_seat)


## 换局 / 重装：现在取一次，**并且欠下一个 `step_end` 再取一次**（理由见 `on_step_end`）。
## 调用方（`CWMatch`）换局 / 重装之后走这一条，别走 `rebase()`
func rebase_hard() -> void:
	_rebase_next = true
	rebase()


# =====================================================================
# 装闸（幂等）
# =====================================================================

## 把游标这一条的**闸与禁操作层**装上去。三个调用点（都走这一个函数，所以幂等）：
##   ① 关首（`open()` 之后、`kernel.run()` 之前）；② `step_end`；③ 游标自己翻页那一下。
##
## **非 `player` 条目一律 `allow = []`**（PRD:51「当提示 / 对话开始后，所有操作禁用」）：
## 这一问挂起不作答、**行动栏根本不建**。真机血账：第一版没写 `[]`，关首讲解步缺省 = 全开，
## 行动栏当场把「基因表达」亮着建出来，之后翻到操作步**也不会重建** —— 闸是**问的时候**过的
func install() -> void:
	if not active:
		return
	var row := _row()
	var is_player := str(row.get("do", "")) == "player"
	if gate != null and is_instance_valid(gate):
		gate.set_allow(row.get("allow", null) if is_player else [])
	if view != null and is_instance_valid(view):
		view.block(not is_player)      ## PRD:51 的第 2 层：全屏 STOP，常驻按钮仍在它之上


func _row() -> Dictionary:
	var flow: Array = level.get("flow", [])
	if _at < 0 or _at >= flow.size():
		return {}
	return flow[_at]


func _mirror() -> CWMirror:
	return mirror_of.call() as CWMirror if mirror_of.is_valid() else null


# =====================================================================
# 游标
# =====================================================================

func _tick(delta: float) -> void:
	var flow: Array = level.get("flow", [])
	## 章节提示播着的时候不往下翻页（PRD:35：那一屏播完才继续），**但关首那条 `state` 先办掉** ——
	## 它管的是「界面变化 + 状态变化」，正该在那一屏底下落定：提示一撤，露出来的就是这一关
	## 该有的界面，一帧全套 UI 都不闪（同 `main.gd` 让开场动画的幕布盖住推镜头那条账）。
	## 09-19 真机第一版没这一段：章节提示那 1.8 秒里右栏、回合块、能量全亮着
	if _chapter_busy:
		if _at == 0 and not _entered and not flow.is_empty() \
				and str((flow[0] as Dictionary).get("do", "")) == "state":
			_entered = true
			_enter(flow[0])
			install()
		return
	var budget := 64          ## 一帧最多翻这么多条：不阻塞的条目连着跑（state → point → unlock → say）
	var dt := delta
	while active and _at < flow.size() and budget > 0:
		budget -= 1
		var row: Dictionary = flow[_at]
		if not _entered:
			_entered = true
			_enter(row)
			install()          ## 进一条就把闸对齐（同一个幂等函数，见 install 的头注）
			if not active or _chapter_busy:
				return
		if not _advance_ok(row, dt):
			return
		dt = 0.0               ## 同一帧里后面那几条不再重复消耗时间
		_at += 1
		_entered = false
	if active and _at >= flow.size():
		_finish()


## 这一条的**即时效果**：九个动词各一支
func _enter(row: Dictionary) -> void:
	var v := str(row.get("do", ""))
	match v:
		"state":
			_enter_state(row)
		"say":
			_saying = true
			_play_say(row)
		"point":
			if view != null and is_instance_valid(view):
				view.point(_targets(row), str(row.get("mode", "soft")), str(row.get("tip", "")))
		"unlock":
			var added := CWGuideProgress.unlock(PackedStringArray(row.get("ids", [])))
			if view != null and is_instance_valid(view) and not added.is_empty():
				view.codex_unlocked(added)
		"play":
			## 教程演出库是 S7 的 `cw_tutor_fx.gd`；这一片先按 `secs` 空等，接缝留着
			_wait_left = float(row.get("secs", 0.0))
		"wait":
			_wait_left = float(row.get("secs", 0.0))
		"player":
			_enter_player(row)
		"npc":
			want_npc.emit(int(row.get("seat", -1)), row.get("plan", []) as Array)
		"hook":
			## 钩子层是 S8 的 `cw_tutor_ctx.gd`（九个方法，见文件末的接缝注释）。
			## 这一片一条钩子都没有；真撞上就**说出来再往下走**，不静默、也不挂死
			push_warning("flow[%d] 的 hook「%s」还没接上（S8）" % [_at, str(row.get("call", ""))])
		_:
			push_warning("flow[%d] 的动词「%s」不在九个里" % [_at, v])


func _enter_state(row: Dictionary) -> void:
	if row.has("ui"):
		CWTutorLayers.apply(row["ui"] as Dictionary)
	if row.has("load") and row["load"] != null:
		want_load.emit(str(row["load"]))     ## 已经是这一份的话调用方自己判掉（幂等）
	if row.has("npc"):
		for e in row["npc"]:
			want_npc.emit(int((e as Dictionary).get("seat", -1)), (e as Dictionary).get("plan", []) as Array)
	var reveal: Array = row.get("reveal", [])
	if not reveal.is_empty() and view != null and is_instance_valid(view):
		view.reveal(reveal)


func _enter_player(row: Dictionary) -> void:
	rebase()                                  ## 差分判据的基线就在这一刻拍
	_advising = false
	if view != null and is_instance_valid(view):
		view.hint(str(row.get("hint", "")))
		view.urge_reset(false)
		if row.has("hex") or row.has("ui"):
			view.point(_targets(row), str(row.get("mode", "soft")), str(row.get("tip", "")))


## `point` / `player` 共用的目标表：`ui` 是控件 id、`hex` 是 `"q,r"`
func _targets(row: Dictionary) -> Array:
	var out: Array = []
	for id in row.get("ui", []):
		out.append({ "kind": "ui", "id": str(id) })
	for at in row.get("hex", []):
		out.append({ "kind": "hex", "at": SCRIPT_DATA.parse_at(str(at)) })
	return out


## 这一条能翻页了吗
func _advance_ok(row: Dictionary, delta: float) -> bool:
	if not BEATS.is_blocking(row):
		return true
	match str(row.get("do", "")):
		"say":
			return not _saying and (view == null or not is_instance_valid(view) or not view.busy())
		"wait", "play":
			_wait_left -= delta
			return _wait_left <= 0.0
		"player":
			return _player_done(row)
		"hook":
			return true          ## S8 之前不挂死（_enter 已经 warning 过）
	return true


## `player` 这一条：先看自动重置 / 劝重置，再看 `until`
func _player_done(row: Dictionary) -> bool:
	var m := _mirror()
	var now := BEATS.snap(m, human_seat)
	## PRD:17/47 自动重置：命中 → 播重置动画 → 退回关首（次序由调用方的拆装序列保证）
	if row.has("reset_when") and BEATS.done(row["reset_when"] as Dictionary, _base, now, m):
		_do_auto_reset()
		return false
	## PRD:251 第二条（Kevin 2026-09-19 拍板「提示玩家重置」而不是自动重置）：
	## 命中只换提示行 + 重置按钮慢闪；**每帧都要写**（含不命中那一边），玩家重置之后劝退要自己散掉
	if row.has("advise_when"):
		var hit: bool = BEATS.done(row["advise_when"] as Dictionary, _base, now, m)
		if hit != _advising:
			_advising = hit
			if view != null and is_instance_valid(view):
				view.hint(str(row.get("advise", "")) if hit else str(row.get("hint", "")))
				view.urge_reset(hit)
	if _advising:
		return false            ## 正劝着就按住这一页（见 _advising 的注释）
	if not row.has("until"):
		return true
	return BEATS.done(row["until"] as Dictionary, _base, now, m)


## PRD 通用规则 7：自动重置要有动画提示。**协程**：播完才真的退回关首
func _do_auto_reset() -> void:
	var ep := epoch
	active = false                    ## 动画期间先停住游标，免得判据又命中一次
	if view != null and is_instance_valid(view):
		await view.reset_anim()
	if ep != epoch:
		await dead                    ## 代际闸：这一代已经作废，旧协程永挂
	active = true
	reset_level()


func _play_say(row: Dictionary) -> void:
	var ep := epoch
	if view == null or not is_instance_valid(view):
		_saying = false
		return
	await view.say(str(row.get("who", "player")),
		PackedStringArray(row.get("lines", [])),
		{ "beats": int(row.get("beats", 0)), "auto": bool(row.get("auto", false)),
			"at": row.get("at", null) })
	if ep != epoch:
		await dead
	_saying = false


func _play_chapter(no: int, title: String) -> void:
	var ep := epoch
	if view != null and is_instance_valid(view):
		await view.chapter(no, title)
	if ep != epoch:
		await dead
	_chapter_busy = false


func _finish() -> void:
	active = false
	if gate != null and is_instance_valid(gate):
		gate.set_allow([])            ## 关末把闸关死：换局那几帧不许玩家再动
	CWGuideProgress.set_at(int(level.get("chapter", 1)), 0, _at)
	level_done.emit(str(level.get("on_done", "")))


# =====================================================================
# 钩子接口 `ctx` 的接缝（方案 §3.7；**实现是 S8 的 cw_tutor_ctx.gd**）
# =====================================================================
#
# 钩子 → 导演 的唯一接口。纪律：`ctx` **不暴露 kernel / mirror / game / view / stage 任何原始句柄**；
# 钩子文件**零成员变量**（状态只能进 `ctx.state()`）；**每个 while 的条件都必须含 `ctx.alive()`**。
# 每个 await 原语返回前都过一次代际闸（`if _ep != director.epoch: await director.dead`）。
#
#   ① func beat(row: Dictionary) -> void                      ## 协程：跑一条与 flow[] 完全同构的条目
#   ② func until(pred: Dictionary, timeout_secs := 0.0) -> bool ## 协程：等一个谓词（同一张表、同一个基线）
#   ③ func read(q: String, arg = null) -> Variant             ## 只读查询（白名单，返回派生量的副本）
#        "cells" / "tile" / "dist" / "beside" / "alive_count" / "round" / "energy" / "active"
#   ④ func alive() -> bool                                    ## 代际闸：这一代还活着吗
#   ⑤ func frame() -> void                                    ## 协程：让一帧（内含代际闸）
#   ⑥ func rng() -> RandomNumberGenerator                     ## 钩子自己的演出随机数，**绝不碰内核 rng**
#   ⑦ func state() -> Dictionary                              ## 钩子唯一合法的状态落点
#   ⑧ func log(msg: String) -> void                           ## 记一笔（进无头流水账，不上屏）
#   ⑨ func fail(why: String) -> void                          ## 剧本写不下去了：warning + 挂起
