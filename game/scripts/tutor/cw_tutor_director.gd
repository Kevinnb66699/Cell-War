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
## 钩子接口（方案 §3.7，S8）。**不标类型**：它没有 class_name（要走热更）
const CTX := preload("res://scripts/tutor/cw_tutor_ctx.gd")

## 代际闸（搬方案 §3.7 / 乙的 epoch，`match.gd` 的换局代际号有先例）：
## GDScript 的协程**杀不掉，只能让它永挂**。`dead` 永不 emit —— 旧协程 `await` 在它上面，
## 随导演一起被回收。重置 / 目录跳关 / 换局各调一次 `invalidate()`
signal dead
## 这一关的 `flow` 走完了（`on_done` 指名的下一关；空串 = 全部通关）
signal level_done(next_id: String)
## 剧本要换一份 world（`flow[].state.load`）。**拆装次序不归导演管** ——
## 调用方走舞台的 `reload_world`（`abort → queue.stop → close → dispose`，次序一个字不能动）
signal want_load(world_id: String)
## 剧本要把世界**重心平移到锚点**（`state.load` 的 `{"recenter": …, "radius": …}` 写法，S9a）。
## `delta` = −P（P = 锚点那只此刻那格），装完它就站在 `(0,0)`。调用方走舞台的 `reload_recentered`
signal want_recenter(delta: Vector2i, radius: int)
## 自动重置（`reset_when` 命中）/ 常驻「重置本关」
signal want_reset
## 给某席换脚本（`flow[].npc`）
signal want_npc(seat: int, plan: Array)
## 剧本要播一段教程演出（`flow[].play`，S9b）。**同 `want_npc` 的形制**：发意图，做事的是调用方
## —— 演出库（`cw_tutor_fx.gd`）挂在棋盘底下，归 `CWMatch` 持，导演一个节点都不认识。
## `done` 是**一次性回执**：`await: true` 的那一条要等演完才翻页，调用方播完回调它
## （`await: false` 只按 `secs` 空等，回执照发、导演自己判要不要理）
signal want_play(fx: String, args: Dictionary, done: Callable)
## 剧本要走一次**跨关规格的完整换局**（`state.load` 写成 `{"world": …, "rematch": true}`，S9b）。
## 间章分镜 6 的阵营翻转：席位 order 在 `g.init(order, 1)` 时定死，而关内 `reload_world` 是
## 四步拆装的**短路版**（跳过「算关 / 换席位 / 重挂面板」三段）—— 翻转必须走长的那一条
signal want_rematch(world_id: String)
## 剧本**显式**写了 `ui.camera` 的那一条 `state`：请调用方按**此刻**玩家站的格重算一次机位（倍率不动）。
## 层表没变的话 `CWMatch._sync_tutor_layers` 不会重算 —— 同一档 {player, right} 再写一遍，镜头就不动；
## 第六关两次【转移】之后玩家已经跳到 T 那一头、第二跳的落点 (-10,1) 还在镜头外，通用规则 13 把那一下点击
## 挡掉（Kevin 2026-09-24「第二段转移按不出去」）。**不是跟随**：只有剧本写了这一条才挪一次
signal want_camera
## 目录跳关（S6）：常驻壳点了某一关 → 皮 → `goto_level()` → 这一条。
## **换局本体归调用方**（拆装次序那串一个字不能动，见 `CWMatch._tutor_next_level`）
signal want_goto(level_id: String)

## 取「**此刻**那一份」镜像的一条线（`CWMatch` 给自己的 `mirror`）。
## **不存镜像、只存取法**：一关之内会换好几次局，存下来的那一份换局就过期了
var mirror_of: Callable = Callable()
## 闸桥（`cw_tutor_gate.gd`）。**不标类型**：它没有 class_name（要走热更）
var gate = null
var view: CWTutorView = null
## 取「此刻那一份」活跃格的一条线（`CWBoard.active_tiles`）。**只给 `ctx.read("active")` 用**，
## 没接就给空表 —— 钩子层之外没有人读它，接不接不影响别的关
var active_of: Callable = Callable()
## 钩子的流水账（`ctx.log()`）。无头验收读它：`invalidate()` 之后旧协程**一条都不该再产生**
var hook_log: Array = []

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
## `play` 且 `await: true` 时：演出还没播完（同 `_saying` 的形制）
var _playing := false
## 发出去的第 n 段演出。回执带着这个号回来 —— 上一段的迟到回执不许把这一段的 `_playing` 解掉
var _play_seq := 0
## `say` 还在念吗（皮的协程没回来）
var _saying := false
## 章节提示正在播（协程，播完才往下，PRD:35）
var _chapter_busy := false
## 上一次弹过的章节。比的是 **`(chapter_kind, chapter)` 二元组**，不是单个整数 ——
## 间章不是主章节的附属（Kevin 2026-09-19），它与主章节的 `chapter` 可能撞号
var _shown_chapter: Array = []
## 这一关的钩子实例（`level.hook` 那支脚本，一关一只）。**不标类型**：关卡钩子没有 class_name
var _hook_obj = null
## 此刻有几只钩子协程在跑（`ctx.beat` 里再点一支钩子就会嵌套）。
## 主游标只认「回到 0」才翻过 `hook` 那一条 —— 用计数不用布尔，否则内层跑完外层就被当成完事了
var _hook_depth := 0
## `ctx.state()`：钩子唯一合法的状态落点。**随代际清空**（见 `invalidate()`）
var _hook_state := {}
## 「切换种类」按到第几份了（`ui.switch_type` 那一组 world 名的下标，S5）。
## 换关 / 重置一律回到第一份（随代际闸清，见 `invalidate()`）
var _switch_at := 0
## 锚点（`"player"` / `"seat:<n>"`）在镜像里找不到时的哨兵。
## 轴坐标本身有负数、(0,0) 又是盘心，所以不能拿 0 或 -1 当「没有」
const NO_ANCHOR := Vector2i(9999, 9999)
## 正劝着重置（`advise_when` 命中）：这时 `until` **不翻页** ——
## 第三关「站到相邻格」在能量算亏时照样成立，翻过去那句劝退当场消失
var _advising := false
## 钩子正在跑的那一条声明式条目（`ctx.beat`）。**装闸时优先它**——
## 主游标此刻停在 `hook` 那一条上（非 `player` ⇒ `install()` 给 `[]` 全禁），
## 不认这一条的话，钩子里每一个 `player` beat 都会被它自己所在的 `hook` 行关死
## —— 阀关着⇒玩家那一问挂起不作答，而 beat 的 `until` 永远等不到，当场死锁
## （S11 第六关钩子 `encircle` 实测；间章的 `interlude.gd` 走同一条路）。
## 非阻塞条目装完就还回去，阻塞条目撑到它自己跑完
var _beat_row: Variant = null


# =====================================================================
# 生命周期
# =====================================================================

## 开一关。调用方的次序钉死：`stage.open_level()` → `_start_queue()` → **`install()`** → `kernel.run()`
func open(lv: Dictionary, seat: int) -> void:
	invalidate()         ## 换局也是一代（方案 §3.7）：上一关挂在 await 上的钩子协程到这儿作废
	level = lv
	human_seat = seat
	_at = 0
	_entered = false
	_wait_left = 0.0
	_saying = false
	_playing = false     ## 上一关的演出回执迟到也解不开新关的这一条（回执带段号，见 `_enter_play`）
	## 上一关那一屏章节提示挂在代际闸上永不返回（`_play_chapter` 里 `await dead`）⇒
	## 它再也没机会把这一位放下。不在这儿清的话，下一关的游标永远被 `_tick` 开头
	## 那条 `if _chapter_busy: return` 按死 —— 真机上的表现是「进了间章却一拍也不演」
	_chapter_busy = false
	_held = false        ## 上一关关间过渡的替身要是还在飞，`_tutor_glide_abort` 已经放手；这儿再保一次
	_advising = false
	_hook_depth = 0      ## 上一关挂死的钩子协程不许按住新关的游标
	_beat_row = null     ## 挂死的那一条 beat 也不许再把闸撑开
	_hook_obj = null     ## 换关就换一支钩子脚本
	active = true
	rebase_hard()
	## 章节提示（PRD:35）：`(chapter_kind, chapter)` 变了才弹，没变就静默切关（PRD:37）。
	## **间章一律不弹**（Kevin 2026-09-19：静默进入，进第六关时照常弹「第三章 Cancer」）——
	## 二元组照记，所以下一条主章节与它不相等、该弹的那一屏一次都不少
	var kind := str(lv.get("chapter_kind", SCRIPT_DATA.KIND_MAIN))
	var key: Array = [kind, int(lv.get("chapter", 1))]
	if key != _shown_chapter:
		_shown_chapter = key
		if kind != SCRIPT_DATA.KIND_INTERLUDE:
			_chapter_busy = true
			_play_chapter(int(lv.get("chapter", 1)), str(lv.get("chapter_title", "")))
	## 断点续读的落点（S6）：`at.level` 是关 id，`beat` 关首归 0。**续读只认「关」**（Q-11）
	CWGuideProgress.set_at(str(lv.get("id", "")), 0)
	if view != null and is_instance_valid(view):
		view.shell({ "chapter": key[1], "level": str(lv.get("id", "")), "can_reset": true,
			"menu": menu_rows() })


## 退回关首（常驻「重置本关」与自动重置共用这一条）。
## 代际 +1：挂在旧闸 / 旧协程上的东西随导演一起被回收
func reset_level() -> void:
	invalidate()
	_at = 0
	_entered = false
	_wait_left = 0.0
	_saying = false
	_playing = false
	_advising = false
	_hook_depth = 0      ## 挂死的钩子协程再也回不来，不清就把重置后的 `hook` 那一条按死
	_beat_row = null
	active = true
	rebase_hard()
	want_reset.emit()


## 取消语义：重置 / 目录跳关 / 换局各调一次。旧协程停在 `await dead` 上，永不返回
func invalidate() -> void:
	epoch += 1
	_hook_state.clear()   ## 钩子的状态随代际一起清空（方案 §3.7 ⑦：钩子文件零成员变量，状态全在这儿）
	_switch_at = 0        ## 「切换种类」的轮转下标也随代际回到第一份（S5）


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
	var row: Dictionary = _beat_row if _beat_row is Dictionary else _row()
	var is_player := str(row.get("do", "")) == "player"
	if gate != null and is_instance_valid(gate):
		if gate.has_method("set_auto"):
			gate.set_auto(is_player and bool(row.get("auto", false)))   ## 先设开关再装闸（装闸会叫醒挂着的那一问）
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
	## 关间过渡的替身在飞（`hold()`，2026-09-20）同样先别翻页：第一句台词气泡指着真身，真身还没到位
	if _chapter_busy or _held:
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
			_enter_play(row)
		"wait":
			_wait_left = float(row.get("secs", 0.0))
			## 真停一拍（secs > 0）就把上一条 `player` 留下的提示行与提亮收掉，同 `play` / `say` 的口径：
			## 第六关 revived 之后那 0.9 s 里「在固化癌组织旁原地复活」还挂在顶上（09-25 真机抓到）。
			## secs 0 的 wait（测试里当占位）不动，免得搅乱意图序列
			if _wait_left > 0.0 and view != null and is_instance_valid(view):
				view.hint("")
				view.clear_point()
		"player":
			_enter_player(row)
		"npc":
			want_npc.emit(int(row.get("seat", -1)), row.get("plan", []) as Array)
		"hook":
			## 交给关卡钩子的一段（方案 §3.7）。**不 await**：`_enter` 是「即时效果」那一拍，
			## 翻不翻页由 `_advance_ok` 看 `_hook_depth`。点不到就 warning 再往下走，不静默、也不挂死
			_run_hook(row)
		_:
			push_warning("flow[%d] 的动词「%s」不在九个里" % [_at, v])


func _enter_state(row: Dictionary) -> void:
	if row.has("ui"):
		CWTutorLayers.apply(row["ui"] as Dictionary)
		if (row["ui"] as Dictionary).has("camera"):
			want_camera.emit()
	if row.has("load") and row["load"] != null:
		if _is_recenter(row["load"]):
			_emit_recenter(row["load"] as Dictionary)
		else:
			var wid := _world_for(row["load"])
			## 「切换种类」从**此刻这一份**往下轮（S5 修订）：装的是哪一份，下标就对到哪一份，
			## 否则按第一下会跳回表头那一份（玩家刚挑完 T 细胞、一按就变回 B）
			var k: int = CWTutorLayers.switch_types().find(wid)
			if k >= 0:
				_switch_at = k
			if _is_rematch(row["load"]):
				want_rematch.emit(wid)       ## 跨关规格的完整换局（间章分镜 6 的阵营翻转，S9b）
			else:
				want_load.emit(wid)          ## 已经是这一份的话调用方自己判掉（幂等）
	if row.has("npc"):
		for e in row["npc"]:
			want_npc.emit(int((e as Dictionary).get("seat", -1)), (e as Dictionary).get("plan", []) as Array)
	var reveal: Array = row.get("reveal", [])
	if not reveal.is_empty() and view != null and is_instance_valid(view):
		view.reveal(reveal)


## 这一条 `load` 是重心平移写法吗（S9a）
static func _is_recenter(v: Variant) -> bool:
	return v is Dictionary and (v as Dictionary).has("recenter")


## 这一条 `load` 要走**完整换局**吗（S9b，`{"world": "flip", "rematch": true}`）
static func _is_rematch(v: Variant) -> bool:
	return v is Dictionary and bool((v as Dictionary).get("rematch", false))


## 把 `{"recenter": "player", "radius": 11}` 翻成一条 `want_recenter(−P, radius)`。
## 为什么解析在导演这儿（同 `_world_for`）：「锚点那只此刻站哪」只有运行期答得上来，
## 而数据是死的；平移本身归数据门面（`CWTutorScript.translate`），舞台负责拆装次序
func _emit_recenter(d: Dictionary) -> void:
	var at := _anchor_at(str(d.get("recenter", "")))
	if at == NO_ANCHOR:
		push_warning("flow[%d].load.recenter 的锚点在镜像里找不到，这一拍不平移" % _at)
		return
	want_recenter.emit(-at, int(d.get("radius", CWData.BOARD_RADIUS)))


## `flow[].state.load` 解析成一份 world 名。两种写法：
## · **字符串** —— 点名那一份（老写法）；
## · **`{"by_player_type": {"BCell": "b", …}}`** —— 按**玩家此刻的免疫种类**挑一份
##   （S5 修订，Kevin 2026-09-19：「Step2 重装要保留玩家 Step1 选的那一种」）。
##   键就是 world spec 里 `cells[].type` 那个词，校验器（判据 ⑮）装载期核键与 world 名。
##
## 为什么解析在导演这儿：这一问的答案只有**运行期**才有（玩家挑了什么），而数据是死的；
## 导演本来就持着取镜像的那条线，调用方（`CWMatch._tutor_load_world`）照旧只收一个 world 名。
## 表里没有这一档（剧本写漏 / 玩家还没分化）→ warning + 退回表里第一份：挑错一份还能玩，
## 什么都不装则是关卡当场停死
func _world_for(v: Variant) -> String:
	if not (v is Dictionary):
		return str(v)
	if (v as Dictionary).has("world"):
		return str((v as Dictionary)["world"])     ## 完整换局写法（S9b）：点名的那一份
	var by: Dictionary = (v as Dictionary).get("by_player_type", {})
	if by.is_empty():
		push_warning("flow[%d].load 的表里没有 by_player_type" % _at)
		return ""
	var kind := _player_kind()
	if by.has(kind):
		return str(by[kind])
	push_warning("flow[%d].load.by_player_type 里没有「%s」这一档，退回第一份" % [_at, kind])
	return str(by.values()[0])


## 席位 → 这一刻那只细胞站的格。**演出层认不得席位**（它碰不到内核），所以由调用方把这条线
## 注入进 `cw_tutor_fx.seat_at`。找不到那只时给盘心：演出画歪一格总好过让 `board.tile_center`
## 拿哨兵坐标去查一张没有这个键的表
func seat_at(seat: int) -> Vector2i:
	var at := _anchor_at("seat:%d" % seat)
	if at == NO_ANCHOR:
		push_warning("seat_at：席位 %d 此刻在镜像里找不到活细胞" % seat)
		return Vector2i.ZERO
	return at


## `flow[].play` 这一条（S9b）：把意图发给调用方，自己只管「等多久」。
##
## `args` 原样透传给演出库，只补几处**数据写不出来的东西**：
## · `at`（这一段画在哪一格）与 `args.actor`（代画哪一只）、`args.from` / `args.to`（光束 / 击退的两头，
##   `from` 也许是数组 = 齐发）里的 `"player"` / `"seat:<n>"` 翻成**席位号** —— 演出层再用注入的 `seat_at`
##   换成格；写成 `"q,r"` 的直接翻成 `Vector2i`。**2026-09-24 前 `from` / `to` 不翻**：数据里的 `"-11,1"`
##   原样到了演出库、`_coord` 遇到字符串给盘心 ⇒ 第六关 T 的效应应答与两次击退全画在 (0,0)、光束长度为零
##   （Kevin「T 细胞放大招」看不见的那一半）；
## · `args.target`（写席位）没写 `to` 时就是 `to` —— 光束只认 from / to；
## · `seed`（演出随机的种子，数据里写了就用数据的）。
## 钩子喂进来的行里 `at` / `actor` 本来就可能已经是 `Vector2i` / 席位号，那种原样过
func _enter_play(row: Dictionary) -> void:
	_wait_left = float(row.get("secs", 0.0))
	var kind := str(row.get("fx", ""))
	if kind == "":
		push_warning("flow[%d] 是 play 却没写 fx" % _at)
		return
	## 演出一开演，上一条 `player` 留下的提示行与提亮 / 控件旁小气泡收掉（`say` 本来就收、`player` 会重挂）：
	## 第六关第 9 步 T 放光束时底下还挂着「点右边的结束回合」，右栏那颗按钮收了、小气泡掉到左上角
	## （2026-09-24 真机截图）。每一条 `player` 都自己重挂 hex / ui，收在这儿不影响后面的提示
	if view != null and is_instance_valid(view):
		view.hint("")
		view.clear_point()
	var args: Dictionary = (row.get("args", {}) as Dictionary).duplicate(true)
	if row.has("at"):
		args["at"] = _fx_where(row["at"])
	if args.has("actor"):
		args["actor"] = _fx_where(args["actor"])
	for k in ["from", "to", "target"]:
		if args.has(k):
			args[k] = _fx_where_each(args[k])
	if args.has("target") and not args.has("to"):
		args["to"] = args["target"]
	if row.has("seed"):
		args["seed"] = int(row["seed"])
	_play_seq += 1
	var tok := _play_seq
	var ep := epoch
	if bool(row.get("await", false)):
		_playing = true
	want_play.emit(kind, args, func() -> void:
		if ep == epoch and tok == _play_seq:
			_playing = false)


## `play` 里位置字段的三种写法 → 演出库认得的东西：
## `"player"` / `"seat:<n>"` → 席位号（int），`"q,r"` → `Vector2i`，JSON 里的 `0` 读出来是 `0.0` ⇒ 收成 int，其余原样
func _fx_where(v: Variant) -> Variant:
	if v is float:
		return int(v)
	if not (v is String):
		return v
	var s := str(v)
	if s == "player":
		return human_seat
	if s.begins_with("seat:"):
		return int(s.substr(5))
	return SCRIPT_DATA.parse_at(s)


## 同 `_fx_where`，数组逐项翻（`args.from` 写成数组 = 几个发点齐发，第六关第 24 步）
func _fx_where_each(v: Variant) -> Variant:
	if v is Array:
		var out: Array = []
		for e in v:
			out.append(_fx_where(e))
		return out
	return _fx_where(v)


## `"player"` / `"seat:<n>"` 那只此刻站的格；找不到给 `NO_ANCHOR`
func _anchor_at(who: String) -> Vector2i:
	var seat := -1
	if who == "player":
		seat = human_seat
	elif who.begins_with("seat:"):
		seat = int(who.substr(5))
	var m := _mirror()
	if seat < 0 or m == null:
		return NO_ANCHOR
	for c in m.cells:
		if int(c["pid"]) == seat:
			return Vector2i(c["pos"])
	return NO_ANCHOR


## 玩家那一只此刻是什么免疫种类（world spec 里 `cells[].type` 那个词）。
## **对照表不在这儿**：走数据门面的 `kind_name`（它再转给装载器那一份，全案只有一处）
func _player_kind() -> String:
	var m := _mirror()
	if m == null:
		return ""
	for c in m.cells:
		if int(c["pid"]) == human_seat:
			return SCRIPT_DATA.kind_name(c)
	return ""


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
		"wait":
			_wait_left -= delta
			return _wait_left <= 0.0
		"play":
			## `await: true` ⇒ 等演完**并且**等够 `secs`；`await: false` ⇒ 只等 `secs`
			_wait_left -= delta
			return not _playing and _wait_left <= 0.0
		"player":
			return _player_done(row)
		"hook":
			return _hook_depth == 0   ## 钩子的协程跑完才翻页（点不到那支函数时 `_run_hook` 压根没加过计数）
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


## 关间过渡（CWMatch 的替身在飞，2026-09-20）：游标按住不翻页，关首那条 `state` 照旧先办掉（同章节提示）
var _held := false

func hold(on: bool) -> void:
	_held = on


func _finish() -> void:
	active = false
	if gate != null and is_instance_valid(gate):
		gate.set_allow([])            ## 关末把闸关死：换局那几帧不许玩家再动
	CWGuideProgress.set_at(str(level.get("id", "")), _at)
	level_done.emit(str(level.get("on_done", "")))


# =====================================================================
# 目录（S6）：跳关入口 + 喂给常驻壳的那份关表
# =====================================================================

## 目录跳关。常驻壳发 `menu_goto` → 皮 → 这里。**只做两件**：
##   ① 代际 +1（`invalidate()`）—— 挂在旧闸 / 旧协程上的东西随之作废，
##      正在播的 `say` / `reset_anim` 醒来时撞上代际闸，永挂而不是抢新一关的镜头；
##   ② 发 `want_goto` —— **换局的拆装次序归调用方**（`abort → stop → close → dispose → 重挂皮与导演`，
##      `CWMatch._tutor_next_level` 那一串一个字不能动）。
##
## **跳关不记「通关」**：`done` 只由 `level_done` 那条路推进 ——
## 否则点一下目录就把没打的那关记成过了，下次目录里它是亮的，进度越点越前
func goto_level(id: String) -> void:
	if id == "":
		return
	invalidate()
	active = false
	want_goto.emit(id)


## 喂给常驻壳的关表（`shell()` 的 `menu` 键）。每行 `{id, title, kind, unlocked}`，
## `kind` 三档见 `cw_tutor_chrome.gd` 的 `_rows`。
##
## **章标题行是现插的**：`index.json` 里没有「章」这个东西，章是关的属性 ——
## `(chapter_kind, chapter)` 二元组一变就插一条（同关首那条章节提示的比法）。
## **间章不插章标题**：它自己那一行就是顶层的一条（Kevin 2026-09-19：与三个主章节平级单列），
## 而且它**打断分组** —— 间章之后那一章要重新出一条章标题。
##
## **未通关的灰显不可点**（PRD:43）：`unlocked = 关下标 < done`。
## 正在打的那一关也是灰的 —— 重来一遍是左边那颗「重置」的活，不是目录的
static func menu_rows() -> Array:
	var data = SCRIPT_DATA.new()
	var rows: Array = data.load_index().get("levels", [])
	var done := CWGuideProgress.done_count()
	var out: Array = []
	var seen: Array = []
	for i in rows.size():
		var lv: Dictionary = rows[i]
		var kind := str(lv.get("chapter_kind", "main"))
		var no := int(lv.get("chapter", 1))
		if kind != "main":
			seen = []     ## 间章打断分组
		else:
			var key: Array = [kind, no]
			if key != seen:
				seen = key
				out.append({ "id": "", "kind": "chapter", "unlocked": false,
					"title": CWTutorChrome.chapter_text(no, str(lv.get("chapter_title", "")))[0] })
		out.append({ "id": str(lv.get("id", "")), "title": str(lv.get("title", "")),
			"kind": "level" if kind == "main" else "interlude", "unlocked": i < done })
	return out


# =====================================================================
# 钩子接口 `ctx` 的接缝（方案 §3.7；**实现是 S8 的 cw_tutor_ctx.gd**）

# 钩子调度（方案 §3.7，S8）
# =====================================================================
#
# 钩子 → 导演 的唯一接口是 `cw_tutor_ctx.gd` 的**九个方法**：
#   ① beat(row)  ② until(pred, timeout_secs)  ③ read(q, arg)  ④ alive()  ⑤ frame()
#   ⑥ rng()      ⑦ state()                    ⑧ log(msg)      ⑨ fail(why)
# 纪律：`ctx` **不暴露 kernel / mirror / game / view / stage 任何原始句柄**；钩子文件**零成员变量**
# （状态只能进 `ctx.state()`）；**每个 while 的条件都必须含 `ctx.alive()`**。护栏 `t_tutor_hooks` 逐条扫。
#
# 取消语义：每个 await 原语返回前过一次代际闸，代际变了就 `await dead`（那条信号永不 emit）。
# GDScript 的协程杀不掉、只能永挂 —— **挂死的协程持 ctx 与导演的引用，随导演一起被回收**，
# 所以导演一关一只、关末显式 `teardown()` + `queue_free()`（`t_tutor_hooks` 有一条正面断言）。


## `flow[].hook` 这一条：把钩子那支函数当协程跑起来。**调用方不 await** ——
## `_enter` 是「即时效果」那一拍，翻不翻页由 `_advance_ok` 看 `_hook_depth`
func _run_hook(row: Dictionary) -> void:
	var ep := epoch
	var call_name := str(row.get("call", ""))
	var obj := _hook_of()
	if obj == null or not obj.has_method(call_name):
		## 点不到就说出来再往下走（不静默、也不挂死）。校验器 ⑩ 在装载期就该拦住这种数据
		push_warning("flow[%d] 的 hook「%s」点不到（这一关的 hook 文件是「%s」）"
			% [_at, call_name, str(level.get("hook", ""))])
		return
	_hook_depth += 1
	await obj.call(call_name, CTX.new(self, ep, row.get("args", {}) as Dictionary))
	if ep != epoch:
		await dead                ## 代际闸：这一代已经作废，旧协程永挂（`_hook_depth` 由重置那边清零）
	_hook_depth = maxi(_hook_depth - 1, 0)


## 这一关的钩子实例（`level.hook`，一关一只，换关时 `open()` 清掉）
func _hook_of() -> Object:
	if _hook_obj != null:
		return _hook_obj
	var path := str(level.get("hook", ""))
	if path == "" or not ResourceLoader.exists(path):
		return null
	var scr = load(path)
	if scr == null:
		return null
	_hook_obj = scr.new()
	return _hook_obj


## `ctx.beat()`：跑一条与 `flow[]` 同构的条目。**走同一个 `_enter` + 同一套阻塞判据** ——
## 钩子不自己说话、不自己画，也不另开第二条执行路（漏了这一条，钩子就会绕过闸与禁操作层）
func run_beat(row: Dictionary, ep: int) -> void:
	if not alive(ep):
		return
	if str(row.get("do", "")) == "hook":
		## 钩子里再点一支钩子：直接 await 内层那只（`_hook_depth` 那道闸是给**主游标**的）
		await _run_hook(row)
		return
	var prev: Variant = _beat_row
	_beat_row = row
	_enter(row)
	install()
	if not BEATS.is_blocking(row):
		_beat_row = prev
		install()
		return
	while alive(ep) and not _advance_ok(row, get_process_delta_time()):
		await next_frame()
	_beat_row = prev
	install()


## `ctx.until()`：等一个谓词。**同一张表、同一个基线**（`BEATS.done` + 入口处 `rebase()`）。
## `timeout_secs > 0` 时超时返回 false —— 钩子拿它兜底，不然剧本写歪就是无声卡死
func run_until(pred: Dictionary, ep: int, timeout_secs := 0.0) -> bool:
	if not alive(ep):
		return false
	rebase()
	var left := timeout_secs
	while alive(ep):
		var m := _mirror()
		if BEATS.done(pred, _base, BEATS.snap(m, human_seat), m):
			return true
		if timeout_secs > 0.0:
			left -= get_process_delta_time()
			if left <= 0.0:
				return false
		await next_frame()
	return false


## `ctx.frame()` 与两条 `run_*` 共用的「让一帧」。不在树里就直接回来，
## 免得钩子挂在一个永远不会到来的帧上（无头里导演是 `root` 的子节点，真机里是 `CWMatch` 的）
func next_frame() -> void:
	var t := get_tree()
	if t != null:
		await t.process_frame


## `ctx.state()`：钩子唯一合法的状态落点（同一只字典反复给出去，`invalidate()` 时清空）
func hook_state() -> Dictionary:
	return _hook_state


## `ctx.fail()`：剧本写不下去了。warning + **挂起** —— 游标停住、闸关死，不静默继续、不替玩家乱答。
## 出路是常驻「重置 / 目录」：它们走 `reset_level()` / 换局，各自把 `active` 重新打开
func hook_fail(why: String) -> void:
	push_warning("教程钩子在 flow[%d] 挂起：%s" % [_at, why])
	active = false
	if gate != null and is_instance_valid(gate):
		gate.set_allow([])


## 常驻壳的「切换种类」按下了（PRD:375，第五关 Step2，S5）。
## 换法就是**关内 `load`**：那四份 world 只差玩家那一只的 `type` ——
## 分化在规则里是一次性的，就地改 `itype` 等于绕开规则往引擎状态里写字。
## **拆装次序不归导演管**：同 `flow[].state.load`，发 `want_load`，
## 由调用方走舞台的 `reload_world`（`abort → stop → close → dispose`，次序一个字不能改）
## **下标已经对在「此刻这一份」上**（`_enter_state` 装完就对，见 `_world_for`），
## 所以按一下永远是「从现在这种往下一种」
func switch_type() -> void:
	var names: Array = CWTutorLayers.switch_types()
	if names.is_empty():
		return
	_switch_at = (_switch_at + 1) % names.size()
	want_load.emit(str(names[_switch_at]))
