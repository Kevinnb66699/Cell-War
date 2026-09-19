## cw_tutor_gate.gd —— 教程局的**闸桥**：包一层 `CWUIBridge`，只加一道决策闸
## （docs/新手引导v2_实现方案.md §3.2(a)，S1，2026-09-19）
##
## 老 `guide_bridge.gd` 的「继续」代做整条**不要了**（方案 Q-10）：每一步 `allow` 已经把选项
## 收到一两个，代做没价值；而它是老方案里最容易**静默错到底**的一处（下标映射了两次，不崩）。
## 留下来的只有三态闸、「下标只映射一次」、`mutes_result` 三件 —— 机制照抄、代码不留。
##
## **不带 class_name，调用方 preload**（方案 §1.5）：闸是会反复改的四件之一，要能走热更。
extends CWUIBridge

const BEATS := preload("res://scripts/kernel/cw_tutor_beats.gd")

## 闸非空却一条都没命中时，先让这么多帧再喊（见 `ask()` 里那一段）。
## 6 帧 ≈ 0.1 秒：够导演的 `_process` 把这一步判完并翻页，又短到真写错时立刻看得见
const MISS_GRACE_FRAMES := 6

## **决策闸换了**（`set_allow` / `set_blocked` 变了都发）。`ask()` 挂在它上面等闸放开
signal allow_changed

## 三态（方案 §3.2(a)）：
##   `null`  —— 不过滤（自由游玩段，本 PRD 只有第五关 Step2 半开）
##   `[]`    —— 全禁：这一问挂起不作答、**行动栏根本不建**（提示 / 对话播放期，PRD:51）
##   非空    —— 只留命中的选项（**前缀**匹配语义键，`CWSemKey.key` 的键形）
## 由导演在 `step_end` 与关首两处装（方案 §3.1：`step_begin` 标的是「已经答完、动作开演」）
var _allow: Variant = null
## 常驻壳的章节提示 / 目录开着（PRD:51 的第 1 层）：等同于 `allow = []`，但不覆盖剧本的闸
var blocked := false


## 教程局静掉「谁复活不了」那类通报（Kevin 2026-09-12 截图）。
## 教程的癌方常是个**占位对手**：它一直是死的、场上又没有固化癌组织，于是每个 S 阶段都复活失败，
## 一句「癌症A 无法复活：没有固化癌组织」弹在屏幕上方，正好压在教程的说明行上。
## **只在这只桥里静**：正式局照旧要这句（口径 #93「被堵住这件事必须说出来」）；
## 日志也照写，静掉的只是气泡。**纯函数**，护栏直接核
static func mutes_result(text: String) -> bool:
	return text.contains(CWData.NO_REVIVE_MARK)


func show_result(text: String, at: Vector2i, linger := false) -> void:
	if mutes_result(text):
		return
	super.show_result(text, at, linger)


## 装一道新的决策闸。挂在闸上的那一问会被叫醒、重新判一次
func set_allow(a: Variant) -> void:
	_allow = a
	allow_changed.emit()


func allow() -> Variant:
	return _allow


## 常驻壳的遮挡开合：同样要把挂着的那一问叫醒
func set_blocked(v: bool) -> void:
	if blocked == v:
		return
	blocked = v
	allow_changed.emit()


## 闸关着吗（`[]` 全禁 / 遮挡层开着）
func gate_closed() -> bool:
	return blocked or (_allow is Array and (_allow as Array).is_empty())


## 闸不是 `_pending`，基类够不着它，不发这一下就留一条永远醒不来的协程
func abort() -> void:
	super.abort()
	allow_changed.emit()


## 轮到人类玩家的某一次询问。三件事按序：**等这一步的演出播完 → 过闸 → 照常交给界面**。
##
## ★ **必须自己先 `_await_playback()`**：`_allow` 是队列播到 `step_end` 那一刻才装的，
##   而 `CWUIBridge` 的那次等在 `super.ask` **内部**（`ui_bridge.gd` 的 `_ask_human` → `_await_playback`）
##   —— 不先等就读到上一条的闸。这是老方案附 C 第 7 条那个坑，原样照抄。
func ask(req: Dictionary) -> int:
	if not (req["pid"] in human_pids):
		return await super.ask(req)
	_aborted = false              ## 新的一问：上一次 abort() 的余波不该把这一问当场打掉（同 super.ask 开头）
	await _await_playback()
	while not _aborted and gate_closed():
		await allow_changed       ## `[]` = 全禁：挂起，行动栏根本不建
	if _aborted:
		return 0
	if _allow == null:
		return await super.ask(req)
	var keep := _keep(req)
	## **一条都没命中先别喊**：玩家刚做完这一步的时候，引擎会在导演翻页**之前**就把下一问抛上来
	## （`_close_step()` 推完 step_end 立刻 `ask`，而队列是隔几帧才播到那条的），那一刻闸还停在
	## 上一步 —— 点名的那一格已经走过了，当然一条都不命中。这是过渡态，不是剧本写错。
	## 09-19 真机实测：不让这几帧的话，**每走一步都要报一条假警告**，真出事那条就淹在里头了
	var waited := 0
	while keep.is_empty() and not _aborted and waited < MISS_GRACE_FRAMES and _can_yield():
		await board.get_tree().process_frame
		waited += 1
		if _allow == null or gate_closed():
			return await ask(req)    ## 闸换了：不过滤 / 挂起都在那条路上，从头走一遍
		keep = _keep(req)
	if _aborted:
		return 0
	if keep.is_empty():
		## 等过了还是一条不命中 = 剧本写错：**warning + 挂起**，绝不回落成全开、也绝不替玩家乱答。
		## 出路是常驻「重置 / 目录」按钮（PRD:41/43，提示期也可点）
		push_warning("剧本 allow 在这一问里一条都没命中：%s" % str(_allow))
		while not _aborted:
			await allow_changed
			if _allow == null or not (_allow as Array).is_empty():
				return await ask(req)    ## 闸换了就重来一遍
		return 0
	var view := req.duplicate()
	var opts: Array = []
	for i in keep:
		opts.append(req["options"][i])
	view["options"] = opts
	return keep[await super.ask(view)]   ## ← 下标映射回原表，**全文件只此一处**


## 这一问里闸放行的那几条（view 下标 → 原表下标）
func _keep(req: Dictionary) -> Array:
	var out: Array = []
	for i in (req["options"] as Array).size():
		if BEATS.hits(CWSemKey.key(req, req["options"][i]["data"]), _allow as Array):
			out.append(i)
	return out


## 此刻让得出一帧吗（无头测试 / 拆局途中没有棋盘节点，那就别等，直接判）
func _can_yield() -> bool:
	return board != null and board.is_inside_tree()
