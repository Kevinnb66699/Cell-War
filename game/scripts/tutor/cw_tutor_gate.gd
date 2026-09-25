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
## 行动栏正挂在屏幕上等玩家（闸已经过了、`super.ask` 还没回来）。**这期间闸一换就得收掉这一问重问**：
## 09-20 真机（Kevin「无法选择迁移到最右边的癌组织」）：玩家刚净化完，引擎立刻抛下一问，闸那一刻还是上一步的
## （导演要到下一帧的 `_process` 才翻页），上一步的 allow 里正好有一格与玩家相邻 ⇒ 命中一条、行动栏就建起来了；
## 导演随后把闸换成「到 0,-1」，可 `super.ask` 已经在等点击，谁也不会再过一遍闸 —— 屏幕上只亮着上一步那格。
## `MISS_GRACE_FRAMES` 只兜「一条都没命中」，兜不住「命中了上一步那格」。
## 重问不掉迁移模式：`CWUIBridge._sticky_move` 是跨问留存的，重问直接回到选格
var _prompting := false
var _refilter := false


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


## `notice` 层关着（间章 `"*": false`，PRD:409「所有 UI 消失」）就一只气泡都不弹。
## 只拦气泡：基类 show_result 里的盘面特效已经在这之前演过了。**纯函数**，护栏直接核
static func mutes_bubbles() -> bool:
	return not CWTutorLayers.on("notice")


func _bubble_result(text: String, at: Vector2i, linger: bool) -> void:
	if mutes_bubbles():
		## 掷骰时 `show_roll` 挂的那行「攻击」是 hold=0、专等结算说明来顶掉的（基类 `_bubble_result` 第一句
		## 就是 `toast.hide_box()`）；气泡静了也得把它收掉，否则第六关巨噬打一下之后「攻击」框挂到通关
		## （2026-09-24 真机截图）。静的是结算那句话，不是掷骰的收尾
		if toast != null:
			toast.hide_box()
		return
	super._bubble_result(text, at, linger)


## 装一道新的决策闸。挂在闸上的那一问会被叫醒、重新判一次；行动栏挂着的那一问会被收掉重问。
## **同一道不重装**：导演的 `install()` 每个 step_end 都会再装一遍当前行的闸，没变就别惊动屏幕上那一问
func set_allow(a: Variant) -> void:
	if same_allow(_allow, a):
		return
	_allow = a
	_poke()


## 两道闸一样吗（null / [] / 逐条比字面）。**纯函数**，护栏直接核
static func same_allow(a: Variant, b: Variant) -> bool:
	if a == null or b == null:
		return a == null and b == null
	var x: Array = a
	var y: Array = b
	if x.size() != y.size():
		return false
	for i in x.size():
		if str(x[i]) != str(y[i]):
			return false
	return true


## 闸换了：挂着的那一问叫醒重判；行动栏挂着的那一问当场收掉（`super.abort`），`ask()` 里 `super.ask` 一回来就按新闸重问
func _poke() -> void:
	if _prompting:
		_refilter = true
		super.abort()
	allow_changed.emit()


func allow() -> Variant:
	return _allow


## 常驻壳的遮挡开合：同样要把挂着的那一问叫醒
func set_blocked(v: bool) -> void:
	if blocked == v:
		return
	blocked = v
	_poke()


## 闸关着吗（`[]` 全禁 / 遮挡层开着）
func gate_closed() -> bool:
	return blocked or (_allow is Array and (_allow as Array).is_empty())


## 强制演出（PRD:453「玩家仅可点击 UI 提示的部分」）：闸非空的那几步里，
## `allow` 之外的行动种类**根本不建**（`CWUIBridge._ask_action` 的那一行问的就是这个），
## **不是置灰** —— 灰按钮只会把玩家引过去点一下再被挡回来（09-19 真机截图抓到的）。
## `null`（自由游玩段）与 `[]`（全禁，行动栏本来就不建）两档都返回 false
func hides_dead_acts() -> bool:
	return _allow is Array and not (_allow as Array).is_empty()


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
	_prompting = true
	var picked: int = await super.ask(view)
	_prompting = false
	if _refilter:
		_refilter = false
		return await ask(req)          ## 闸在玩家挑的时候换了：从头再过一遍闸（`ask()` 开头会把 _aborted 复位）
	return keep[picked]   ## ← 下标映射回原表，**全文件只此一处**


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
