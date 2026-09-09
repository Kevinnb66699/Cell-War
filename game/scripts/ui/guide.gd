## guide.gd —— 新手引导面板 + 引导流程（教程局专用）
##
## 这是**旁观式教练** + **轻量导演**：引擎照常跑、CWGuideBridge 照常把人类询问
## 交给正常界面；引导只做三件事：
##   ① 挂一块一步步的说明面板（可继续 / 跳过引导 / 打开知识之书）；
##   ② 轮到你做决定时，给出「现在做什么」的实时提示（由 CWGuideBridge 喂进来）；
##   ③ 按步骤把棋盘 / 特殊组织 / 行动栏等区域提亮，帮新手把视线放到正确地方
##      （本类只报当前步骤的 flag，描边由 CWGuideSpotlight 画）；
##   ④ 「继续」在落子 / 结束回合 / 抽卡这几步能替玩家做（Kevin 2026-09-05 拍板：
##      不自动演示，玩家要么亲手做、要么点「继续」让我做，然后剧本翻到下一步）。
##
## 设计上刻意不做硬锁步：教程里玩家做错了也不惩罚，提示永远只是建议。
## 这样引擎 / 询问桥一行规则都不用改，教程坏不了对局。
##
## 本类也管引导进度（已完成哪几关 / 当前进行到第几关第几步），
## 通过 CWGuideProgress 落盘 —— 主菜单入口据此显示完成状态。
class_name CWGuide
extends Control

## 高度 192：标题行 / 提示行 / 正文 / 按钮四段各留约 10px 空档，按钮字底到底边 18px（Kevin 2026-09-05 看真机截图提的两处）
const PANEL := Rect2(16, 48, 470, 192)
const PAD := 14

## 关卡分隔：当前步骤每跨进新一章，就把「引导完成到这一关」写进进度。
## 玩家跳过时，只有已经**按过完成**的章节会被标记（避免没看就全绿）。
var active := false
var auto_next := false
## 「继续」的代做钩子（CWMatch 接线到 CWGuideBridge）：demo_ready 回答「此刻按继续会不会替玩家做这一步」，
## demo 真去做（返回做没做）。无效的 Callable = 没接（无头测试 / 面板单独建）—— 继续就只翻页
var demo := Callable()
var demo_ready := Callable()
## 章节切换钩子（CWMatch 接导演后设）：跨入新章节时回调一次，参数 = 新章节号。
## 教程每一关是导演装配的独立局面，章节切换意味着**换一局**——面板只管翻页，
## 换局由对局侧执行；未设置（无头 / 老测试）时行为与原先完全一致。
var on_chapter_done := Callable()
## 「此刻该提示什么」：翻页时重新问桥一遍，提示跟着正在教的那一步走（教结束回合就说结束回合，不再停在迁移那句）
var hint_now := Callable()
## 提示行尾巴：代做可用时接在桥喂来的提示后面。%s = 右下角按钮此刻的字（继续 / 下一章 / 完成引导），
## 关卡最后一步按钮写的是「下一章」，尾巴不能还说「继续」（Kevin 2026-09-05 截图报的）
const OFFER_TAIL := "（点「%s」我替你做这一步）"

var _match = null
var _chapter := 0
var _step := 0
var _hint_text := ""
var _highlight := ""
var _tutorial_done := false   ## 引导全部看完了（由第 5 关最后一步置位）

var _title: Label
var _hint: Label
var _body: Array[Label] = []
var _btn: Label
var _skip: Label
var _codex_btn: Label
var _content: Control
var _chapter_label: Label


func setup(match) -> void:
	_match = match
	_build()
	active = true
	_chapter = 0
	_step = 0
	auto_next = false
	_hint_text = ""
	_tutorial_done = false
	_read_progress()
	_render()


## 中途玩家切换章节/继续时从保存读进度（只影响默认起始章节，不强制跳关）。
func _read_progress() -> void:
	var prog := CWGuideProgress.read()
	## 只恢复「已完成章节」的下一个；没完成过就从第 0 关开始
	if prog["done"] > 0:
		_chapter = clamp(prog["done"], 0, CWGuideData.CHAPTER_COUNT - 1)


func _build() -> void:
	position = PANEL.position
	size = PANEL.size
	mouse_filter = Control.MOUSE_FILTER_IGNORE   ## 空白处点击要漏给棋盘

	var bg := Panel.new()
	bg.add_theme_stylebox_override("panel", CWStyle.box(0.42, CWStyle.BTN_BG))
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	_chapter_label = CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	_chapter_label.position = Vector2(PAD, PAD - 2)
	add_child(_chapter_label)

	_title = CWStyle.label("", CWStyle.SIZE_BODY, CWStyle.IMMUNE)
	_title.position = Vector2(PAD + 90, PAD - 2)
	add_child(_title)

	_hint = CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.CANCER)
	_hint.position = Vector2(PAD, PAD + 28)   ## 标题 20px 字的行框到 PAD+26，再留 2px，别贴着
	_hint.size = Vector2(PANEL.size.x - PAD * 2, 14)
	_hint.clip_text = true
	_hint.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	add_child(_hint)

	_content = Control.new()
	_content.position = Vector2(PAD, PAD + 48)
	_content.size = Vector2(PANEL.size.x - PAD * 2, PANEL.size.y - PAD - 48 - 38)
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_content)

	_btn = _clicky("继续", Vector2(PANEL.size.x - PAD - 46, PANEL.size.y - 38), func() -> void: _advance())
	add_child(_btn)

	_skip = _clicky("跳过引导", Vector2(PAD, PANEL.size.y - 38), func() -> void: dismiss())
	add_child(_skip)

	## 「跳过引导」20px 字 4 个 = 80px 宽，起点 PAD；这里要留出 ≥ 16px 的空档，不然两串字连成一句
	_codex_btn = _clicky("知识之书", Vector2(PAD + 110, PANEL.size.y - 38),
		func() -> void: _open_codex())
	add_child(_codex_btn)   ## 三个按钮都只在这里挂一次（接入时发现这一个漏挂了）


func _clicky(text: String, at: Vector2, on_click: Callable) -> Label:
	var label := CWStyle.label(text, CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
	label.position = at
	label.size = label.get_minimum_size()
	label.mouse_filter = Control.MOUSE_FILTER_STOP
	label.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	label.mouse_entered.connect(func() -> void:
		label.add_theme_color_override("font_color", Color.WHITE))
	label.mouse_exited.connect(func() -> void:
		label.add_theme_color_override("font_color", CWStyle.TEXT_HI))
	label.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			get_viewport().set_input_as_handled()
			on_click.call())
	return label


func _advance() -> void:
	## 正在教的这一步能代做（落子 / 结束回合 / 抽卡）且引擎正等着玩家 → 先替玩家做了，再按剧本翻页
	if demo.is_valid():
		demo.call()
	_turn_page()


## 只翻页、不做动作。状态推进（check_progress）专用：动作玩家已亲手完成，
## 再走 demo 等于替玩家多做一次他已经做过的事。
func _turn_page() -> void:
	var chapter_before := _chapter
	_step += 1
	while _chapter < CWGuideData.CHAPTER_COUNT and _step >= CWGuideData.steps(_chapter).size():
		## 这一章看完了：记到进度。
		if not CWGuideProgress.has_done(_chapter):
			CWGuideProgress.set_done(_chapter)
		_chapter += 1
		_step = 0
	if _chapter >= CWGuideData.CHAPTER_COUNT:
		if not _tutorial_done:
			_tutorial_done = true
			CWGuideProgress.set_all_done()
			## 全部看完：只收面板，不打断对局，玩家继续自由游玩这局
			active = false
			visible = false
		return
	auto_next = false
	if _chapter != chapter_before and on_chapter_done.is_valid():
		on_chapter_done.call(_chapter)   ## 跨章 = 换一局（导演装配新局面）
	_render()


## 跳到指定章节（引导目录用）。跳到哪一章顺便把它前面的章节都视为读过了 ——
## 玩家主动跳过前面的内容时，进度就跟着跳。
func goto_chapter(idx: int) -> void:
	idx = clampi(idx, 0, CWGuideData.CHAPTER_COUNT - 1)
	var chapter_before := _chapter
	for i in range(idx):
		if not CWGuideProgress.has_done(i):
			CWGuideProgress.set_done(i)
	_chapter = idx
	_step = 0
	auto_next = false
	if _chapter != chapter_before and on_chapter_done.is_valid():
		on_chapter_done.call(_chapter)   ## 目录跳章同样换局面
	_render()


## 关闭引导（不改变进度，只隐藏面板）
func dismiss() -> void:
	active = false
	visible = false


func open_codex_at_current() -> void:
	_open_codex()


func _open_codex() -> void:
	if _match == null or not is_instance_valid(_match):
		return
	## 通过一个信号/约定，让外部（CWMatch）打开知识之书到达对应章节。
	## 这里用最轻的约定：match 暴露一个 codex_focus()；没有就只提示。
	if _match.has_method("focus_codex_on_topic"):
		_match.focus_codex_on_topic(CWGuideData.CODEX_PAGE[_chapter])


## 由 CWGuideBridge 在轮到玩家时喂进来的一句「现在做什么」。
func set_hint(text: String) -> void:
	_hint_text = text
	_refresh_hint()


## 提示行 = 桥喂来的一句 + 代做尾巴。步骤变了（_render）或提示变了（set_hint）都要重算尾巴：
## 同一句提示，翻到「第一步：落子」之前没有尾巴、翻到之后就有
func _refresh_hint() -> void:
	if _hint == null:
		return
	if hint_now.is_valid():
		var now: String = hint_now.call()
		if now != "":
			_hint_text = now
	var tail := ""
	if _hint_text != "" and _btn != null and demo_ready.is_valid() and demo_ready.call():
		tail = OFFER_TAIL % _btn.text
	_hint.text = _hint_text + tail


## 当前步骤想提亮哪个区域（棋盘/特殊组织/能量/…）。CWMatch 每帧读走喂给 CWGuideSpotlight。
func highlight_flag() -> String:
	var all := CWGuideData.steps(_chapter)
	if _step < 0 or _step >= all.size():
		return ""
	return str(all[_step].get("flag", ""))


## 当前章节与步骤号
func chapter() -> int:
	return _chapter


func step_no() -> int:
	return _step


## ---- 状态推进：带 watch 的步骤由真实局面判定完成 ----
## 哨兵 = 没有人类席 / 细胞还没落（与 board.NO_TILE 同一约定）
const WATCH_NONE := Vector2i(9999, 9999)
## watch=moved 的基线：步骤成为当前的这一刻人类细胞在哪（_render 里取）
var _watch_pos := WATCH_NONE


## 每帧由 CWMatch._process 喂：当前步骤带 watch 且真实局面已满足 → 自动翻页（不代做）。
## 讲解型步骤（无 watch）不经过这里，仍只认「继续」。
func check_progress() -> void:
	if not active:
		return
	match CWGuideData.watch_of(_chapter, _step):
		"placed":
			if _human_pos() != WATCH_NONE:
				_turn_page()
		"moved":
			var now := _human_pos()
			if now != WATCH_NONE and now != _watch_pos:
				_turn_page()


## 人类席位细胞的当前位置。不走 cell_of（按 id 直取，未落子时会越界），按 pid 现找。
func _human_pos() -> Vector2i:
	if _match == null or not is_instance_valid(_match) or _match.game == null:
		return WATCH_NONE
	if _match.human_players.is_empty():
		return WATCH_NONE
	var pid: int = _match.human_players[0]
	for c in _match.game.cells:
		if int(c["pid"]) == pid and c["alive"]:
			return c["pos"]
	return WATCH_NONE


func _render() -> void:
	var all := CWGuideData.steps(_chapter)
	if all.is_empty():
		dismiss()
		return
	var s: Dictionary = all[mini(_step, all.size() - 1)]
	_chapter_label.text = "%d/%d %s" % [
		_chapter + 1, CWGuideData.CHAPTER_COUNT,
		CWGuideData.chapter_titles()[_chapter]]
	if _title != null:
		_title.text = "%s  %d/%d" % [s["t"], _step + 1, all.size()]
	for l in _body:
		l.queue_free()
	_body.clear()
	var y := 0.0
	for line in s["b"]:
		var label := CWStyle.label(line, CWStyle.SIZE_LABEL, CWStyle.TEXT)
		label.position = Vector2(0, y)
		label.size = Vector2(_content.size.x, 15)
		label.clip_text = true
		label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_content.add_child(label)
		_body.append(label)
		y += 15
	var last_of_chapter: bool = _step >= all.size() - 1
	var last_of_all: bool = _chapter >= CWGuideData.CHAPTER_COUNT - 1 and last_of_chapter
	_btn.text = "下一章" if last_of_chapter and not last_of_all else ("完成引导" if last_of_all else "继续")
	## 按钮字数会变（继续 2 字 / 下一章 3 字 / 完成引导 4 字）：按实际宽度靠右对齐、右边留 PAD ——
	## 原来按「继续」的宽度定死 x，「下一章」就顶到边框上（Kevin 2026-09-05 截图报的）
	_btn.size = _btn.get_minimum_size()
	_btn.position.x = PANEL.size.x - PAD - _btn.size.x
	## 引导目录/章节选择放在「完成引导」之后不再重复出现，避免面板太挤
	_refresh_hint()
	## watch=moved 的基线在「步骤成为当前」的瞬间取好（渲染即当前）
	_watch_pos = _human_pos()


## 引导结束时由 CWMatch 调用：隐藏面板并清掉引用
func teardown() -> void:
	active = false
	visible = false
	_match = null
