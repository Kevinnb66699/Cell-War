## cw_tutor_chrome.gd —— 教程的**常驻壳**：全屏 STOP 层 + 左上角「重置 / 目录」两颗图标 + 章节提示那一屏
## （docs/新手引导v2_实现方案.md §3.4 / §3.6，S1 起骨架、S2 补全，2026-09-19）
##
## 三件（PRD 通用规则 1 / 4 / 5 / 9）：
## ① **禁操作的第二层**（PRD:51）—— 提示 / 对话播放期，闸那一层把「这一问」挂起了，
##    但玩家还能点棋盘、点行动栏上一问留下的按钮。所以要一层**真·全屏 `Control`**
##    （`MOUSE_FILTER_STOP`），z 序盖在棋盘与行动栏之上、**排在常驻按钮之下**
##    —— 「重置 / 目录」提示期照常可点（PRD:41/43）。
##    **不能指望皮自己那层**：老 `CWGuide.ZONE` 只有 600×200，盖不住棋盘与右栏。
##    挡着的时候光标跟着变「…」（Kevin 2026-09-19 照方向 A）：降灰只说「这颗按钮不可用」，
##    光标说的是「整个画面此刻不接受操作」，两句话都得有。
## ② **常驻「重置 / 目录」**（PRD:41/43）：左上角两颗小图标按钮，悬停出字（Kevin 拍板取方向 A 的画法）。
##    劝重置时「重置」跟着慢闪（PRD 通用规则 8）。**目录面板本体 S6 落地**（2026-09-19）：
##    章-关两级、**间章与三个主章节平级单列**（Kevin 拍板：间章不是主章节的附属）、
##    未通关的关灰显不可点、已通关的点了发 `menu_goto`，底部一行「**Cell War**」= 重看开场
##    （Q-21：按钮名就叫片名，不写「重看开场」四个字）。关表与解锁与否由导演的 `shell()` 喂进来 ——
##    壳不读 `index.json`、不读存档，它只会画。
## ③ **章节提示**（PRD:35）：全屏黑底 + 居中大字「第X章 XXXX」+ 一行英文副标
##    —— Kevin 2026-09-19 拍板「章节提示用 B 的样子」（`docs/新手引导v2_方向B.md` 的 ① 帧）。
##
## 带 class_name 的理由同两版皮（方案 §1.5 的三个例外）：真机截图要 `call:CWTutorChrome:方法` 驱动。
class_name CWTutorChrome
extends Control

## 提亮层那条慢闪曲线（`urge_reset` 的慢闪与提亮走同一条，不各写一份）
const SPOT := preload("res://scripts/tutor/cw_tutor_spot.gd")

## 章节提示整屏停多久（**S1 定的口径一个数没动**，S2 只是把它切成「淡入 / 停 / 淡出」三段）
const CHAPTER_SECS := 1.8
const CHAPTER_IN := 0.30
const CHAPTER_OUT := 0.35
## 幕布同 `tutorial_opening.SKY`：这一屏是开场最后一页的延续，换一套底色就断气了。
## **半透明**（通用规则 1 点名要的）：玩家得看得见自己刚才站在哪一格
const SKY := Color("0a0d14")
## **0.88 → 0.94**（S3 2026-09-19 答 S2 留的第 ① 问）：0.88 挡不住棋盘正中的主角细胞 ——
## 它比幕布亮一档，直接从「第一章」三个字底下透出来（09-19 真机 S2 的 ① 帧，「一」整个糊掉）。
## 抬 alpha 是一半，另一半是下面那条 BAND（方向 A 的解法）；两条都要，只抬 alpha 仍压不住
const SKY_ALPHA := 0.94
## 方向 B 的 ① 帧：两道 360×1 横线夹住大字，副标在下一行
const RULE_W := 360.0
const RULE_Y := [222.0, 298.0]
## **整幅不透明横带**（方向 A §3 的解法，S3 补给 B 的样式）：字压在它上面而不是压在
## 压暗的棋盘上。上下缘正好是 B 那两道横线，所以看起来仍是 B ——「透出来」那件事没了而已
const BAND_TOP := RULE_Y[0]
const BAND_H := 124.0        ## 下缘 346 = 副标（SUB_Y 310 + 一行 32）也整行压在带子上
const BAND_ALPHA := 0.99
const TITLE_Y := 236.0
const SUB_Y := 310.0
## 副标那支字：方向 B 的表里写死「silkscreen_bold 20 + `spacing_glyph` 2」，照它走。
## ⚠ 它旁边那句理由「照抄开场页」对不上 —— 开场页的副标（`tutorial_opening.gd:57-60`）
## 用的是**点阵字** PIXEL_FONT，同样 20 号、同样字距 2，silkscreen 是那一页的大 Logo 那支。
## 两支都是 ASCII 字形、都过字形闸，**按 B 的表落 silkscreen**；要改成点阵只换这一行
const SUB_FONT := preload("res://assets/fonts/silkscreen_bold.ttf")
const SUB_SIZE := 20
const SUB_SPACING := 2
## 「第X章」的汉字数与罗马数字。本 PRD 只到第三章，表长到七够用；超出就退成阿拉伯数字
const CN_NUM := ["", "一", "二", "三", "四", "五", "六", "七"]
const ROMAN := ["", "I", "II", "III", "IV", "V", "VI", "VII"]

## 左上角两颗图标按钮（方向 A 的 `_corner`）。
## **位置不照抄 A 的 (12,12)**：那一格被迷你日志占着（`CWLogPanel.RECT` 从 (16,16) 起、
## 收成 compact 之后仍是 300×22，见 `log_hint.gd:33`），09-19 真机第一版就是这么把两行字叠成
## 一团的。往下让过 22+8 的行距 ⇒ y=46；再往下 y=76 是出牌列 `CWFeed.RECT` 的顶
## ⇒ 图标收成 28×28（A 写的是 32×32），正好卡在这条缝里
const ICON := 28.0
const RESET_RECT := Rect2(16, 46, ICON, ICON)
const MENU_RECT := Rect2(52, 46, ICON, ICON)
const ICON_BG := Color("0a1018cc")
const ICON_BG_HOT := Color("12212ee6")
const TIP_DX := 6.0          ## 悬停出的字摆在图标右侧几像素
## 目录面板（方向 A 的 ⑤ 帧）。**480×360 是方案 §3.6 的排版上限，别再往上加**；
## 960×540 的屏上居中摆 ⇒ 左上角 (240, 90)，既不压左上两颗图标（y 到 74）也不压出牌列（x 从 16 起）。
##
## ⚠ **行高取 26 不取 §3.6 顺手写的 34**：本 PRD 满编是「3 个章标题 + 6 关 + 1 个间章」= 10 行，
## 10 × 34 = 340，再加表头 48 与底部那行「Cell War」就 440 了，480×360 装不下。
## 26 正好：48 + 10 × 26 = 308 ≤ 314（页脚横线），一行不溢出。**再加关就得先加高面板**，
## 所以 `capacity()` 是纯函数、`t_tutor_progress` 逐关算一遍
const MENU_PANEL := Rect2(240, 90, 480, 360)
const MENU_ROW_H := 26.0
const MENU_PAD_X := 22.0        ## 章标题行 / 间章行 / 「Cell War」行的左边距
const MENU_INDENT := 24.0       ## 关行相对章标题的缩进（**间章行不缩进**，它与章标题同级）
const MENU_HEAD_Y := 12.0       ## 「目录」两个字
const MENU_ROW_Y := 48.0        ## 第一行数据行的 y
const MENU_FOOT_Y := 316.0      ## 页脚横线；「Cell War」在它下面
const MENU_REPLAY := "Cell War" ## 重看开场那一行的字（Kevin 2026-09-19 Q-21：就叫片名）
## 禁操作期光标那三颗点（方向 A：「…」跟着指针走）
const DOTS_AT := Vector2(14.0, 10.0)
const DOTS_SIZE := 4.0
const DOTS_GAP := 6.0
const DOTS_ALPHA := [1.0, 0.55, 0.22]

signal reset_pressed
signal menu_pressed
signal menu_goto(level_id: String)
## 目录底部「Cell War」：重看开场（接线方走 `tutorial_opening.clear_seen()` + 重进引导）
signal replay_opening

var _block: Block             ## 全屏 STOP 层
var _reset: Icon
var _menu: Icon
var _menu_panel: Control      ## 目录面板（S6 落地）
var _chapter: Control         ## 章节提示那一屏
var _chapter_title: Label
var _chapter_sub: Label
## 目录里的关表（`shell()` 的 `menu` 键喂进来，导演从 `index.json` + 进度现拼）。每行：
##   `{ id, title, kind: "chapter" | "level" | "interlude", unlocked: bool }`
##   · `chapter`   章标题行，不可点（`id` 空）；
##   · `level`     关，缩进一格，`unlocked` 决定亮 / 灰与点不点得动；
##   · `interlude` 间章，**不缩进**（与章标题同级，Kevin 2026-09-19），点法同 `level`。
## 缺 `kind` 按 `level` 算 —— S2 那会儿喂的两行没有这个键
var _rows: Array = []
var _urging := false
var _pulse_t := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	## ---- z 序：**加进来的先后就是上下**（PRD:51 / 41 / 43 / 35）----
	## 遮挡层在最底 ⇒ 盖住棋盘与行动栏；两颗按钮加在它之后 ⇒ 提示期照常可点；
	## 章节提示在最顶 ⇒ 它自己也挡操作（通用规则 9），连那两颗一起罩住
	_block = Block.new()
	_block.set_anchors_preset(Control.PRESET_FULL_RECT)
	_block.mouse_filter = Control.MOUSE_FILTER_STOP
	_block.visible = false
	add_child(_block)
	_reset = _icon(RESET_RECT, "reset", "重置本关", reset_pressed)
	_menu = _icon(MENU_RECT, "menu", "目录", menu_pressed)
	_menu.pressed.connect(toggle_menu)
	_build_menu_panel()
	_build_chapter()


## 一颗图标按钮：底 + 描边 + 12×12 的点阵图标 + 悬停出的那两个字
func _icon(rect: Rect2, kind: String, tip: String, sig: Signal) -> Icon:
	var ic := Icon.new()
	ic.kind = kind
	ic.position = rect.position
	ic.size = rect.size
	ic.mouse_filter = Control.MOUSE_FILTER_STOP
	ic.pressed.connect(func() -> void: sig.emit())
	add_child(ic)
	var l := CWStyle.label(tip, CWStyle.SIZE_LABEL, CWStyle.TEXT_HI)
	l.position = rect.position + Vector2(rect.size.x + TIP_DX, rect.size.y / 2.0 - 6.0)
	l.visible = false
	add_child(l)
	ic.hover.connect(func(on: bool) -> void: l.visible = on)
	return ic


## 目录面板的壳（底 + 表头「目录」 + 两道横线）。**每次开面板只换数据行**，这几件不重建
func _build_menu_panel() -> void:
	_menu_panel = Control.new()
	_menu_panel.position = MENU_PANEL.position
	_menu_panel.size = MENU_PANEL.size
	_menu_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_menu_panel.visible = false
	var bg := Panel.new()
	bg.add_theme_stylebox_override("panel", CWStyle.box(0.45, CWStyle.PANEL))
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu_panel.add_child(bg)
	for y in [MENU_ROW_Y - 8.0, MENU_FOOT_Y]:
		var rule := ColorRect.new()
		rule.color = Color(CWStyle.LINE, 0.22)
		rule.position = Vector2(MENU_PAD_X, float(y))
		rule.size = Vector2(MENU_PANEL.size.x - MENU_PAD_X * 2.0, 1.0)
		rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_menu_panel.add_child(rule)
	add_child(_menu_panel)


## 章节提示那一屏（方向 B 的 ① 帧）。**每次 `show_chapter` 只改文字**，不重建节点
func _build_chapter() -> void:
	_chapter = Control.new()
	_chapter.set_anchors_preset(Control.PRESET_FULL_RECT)
	_chapter.mouse_filter = Control.MOUSE_FILTER_STOP   ## 通用规则 9：这一屏自己也禁操作
	_chapter.visible = false
	var sky := ColorRect.new()
	sky.color = Color(SKY, SKY_ALPHA)
	sky.set_anchors_preset(Control.PRESET_FULL_RECT)
	sky.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_chapter.add_child(sky)
	var w := CWView.screen_size().x
	## 横带排在幕布之后、两道横线之前 ⇒ 它盖住棋盘，横线仍描在它的上下缘上
	var band := ColorRect.new()
	band.color = Color(SKY, BAND_ALPHA)
	band.position = Vector2(0.0, BAND_TOP)
	band.size = Vector2(w, BAND_H)
	band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_chapter.add_child(band)
	for y in RULE_Y:
		var rule := ColorRect.new()
		rule.color = Color(CWStyle.LINE, 0.30)
		rule.position = Vector2((w - RULE_W) / 2.0, float(y))
		rule.size = Vector2(RULE_W, 1.0)
		rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_chapter.add_child(rule)
	_chapter_title = CWStyle.label("", CWStyle.SIZE_HERO, CWStyle.TEXT_HI)
	_chapter_title.position = Vector2(0.0, TITLE_Y)
	_chapter_title.size = Vector2(w, float(RULE_Y[1]) - TITLE_Y)
	_chapter_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_chapter.add_child(_chapter_title)
	_chapter_sub = CWStyle.label("", SUB_SIZE, CWStyle.IMMUNE)
	var sub_font := FontVariation.new()
	sub_font.base_font = SUB_FONT
	sub_font.spacing_glyph = SUB_SPACING
	_chapter_sub.add_theme_font_override("font", sub_font)
	_chapter_sub.position = Vector2(0.0, SUB_Y)
	_chapter_sub.size = Vector2(w, float(SUB_SIZE) * 1.6)
	_chapter_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_chapter.add_child(_chapter_sub)
	add_child(_chapter)


func _process(delta: float) -> void:
	if not _urging:
		return
	## PRD 通用规则 8：较慢频次、反差较低的轻微闪烁。三个参数收敛在 CWStyle 一处 ——
	## 提亮层 `cw_tutor_spot.pulse()` 走的是同一条曲线
	_pulse_t += delta
	_reset.modulate.a = SPOT.pulse(_pulse_t)


## ---- ① 禁操作层（PRD:51 的第 2 层）----

func set_block(on: bool) -> void:
	if _block != null and is_instance_valid(_block):
		_block.visible = on


func blocking() -> bool:
	return _block != null and is_instance_valid(_block) and _block.visible


## ---- ② 常驻「重置 / 目录」（PRD:41/43）----

## 劝重置（方案 §3.5）：**不重置**，只让「重置」那颗慢闪
func urge_reset(on: bool) -> void:
	_urging = on
	if not on and _reset != null and is_instance_valid(_reset):
		_pulse_t = 0.0
		_reset.modulate.a = 1.0


## 开 / 关目录占位面板。**真机截图走 `call:CWTutorChrome:toggle_menu`** —— 合成鼠标点不到 Control
func toggle_menu() -> void:
	if _menu_panel == null or not is_instance_valid(_menu_panel):
		return
	_menu_panel.visible = not _menu_panel.visible
	if _menu_panel.visible:
		_fill_menu()


func menu_open() -> bool:
	return _menu_panel != null and is_instance_valid(_menu_panel) and _menu_panel.visible


## 第 i 行数据行的 y。**纯函数**：排版会不会溢出由判据算，不靠真机上一眼看
static func row_y(i: int) -> float:
	return MENU_ROW_Y + MENU_ROW_H * float(i)


## 面板装得下几行数据行（页脚横线之上）。**加关之前先看这个数**（方案 §3.6：别再往上加）
static func capacity() -> int:
	return int(floorf((MENU_FOOT_Y - MENU_ROW_Y) / MENU_ROW_H))


## 面板里的关表：`shell()` 的 `menu` 那一份（见 `_rows` 的注释）。
## 装不下的那些**不画**（宁可少一行也不许画到面板外面去，那是 09-19 之前老面板到 9 关时的样子）
func _fill_menu() -> void:
	for c in _menu_panel.get_children():
		if c is Panel or c is ColorRect:
			continue
		_menu_panel.remove_child(c)
		c.queue_free()
	var head := CWStyle.label("目录", CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
	head.position = Vector2(MENU_PAD_X, MENU_HEAD_Y)
	_menu_panel.add_child(head)
	for i in mini(_rows.size(), capacity()):
		_menu_panel.add_child(_menu_row(_rows[i], i))
	## 底部「Cell War」= 重看开场（PRD 的片名，Q-21）。**常驻可点**：它不是一关，
	## 不受「未通关灰显」那条管 —— 开场动画谁都看过得了
	var replay := CWStyle.label(MENU_REPLAY, CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
	replay.position = Vector2(MENU_PAD_X, MENU_FOOT_Y + 8.0)
	replay.size = Vector2(MENU_PANEL.size.x - MENU_PAD_X * 2.0, MENU_ROW_H)
	replay.mouse_filter = Control.MOUSE_FILTER_STOP
	replay.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			_menu_panel.visible = false
			replay_opening.emit())
	_menu_panel.add_child(replay)


## 一行：章标题（不可点）/ 关（缩进一格）/ 间章（**不缩进**，与章标题同级）
func _menu_row(raw: Variant, i: int) -> Label:
	var row: Dictionary = raw
	var kind := str(row.get("kind", "level"))
	var open := bool(row.get("unlocked", false))
	var is_head := kind == "chapter"
	var ink: Color = CWStyle.IMMUNE if is_head else (CWStyle.TEXT_HI if open else CWStyle.TEXT_OFF)
	var l := CWStyle.label(str(row.get("title", "")), CWStyle.SIZE_BODY, ink)
	## 间章与章标题同级（Kevin 2026-09-19）：只有 `level` 缩进
	l.position = Vector2(MENU_PAD_X + (MENU_INDENT if kind == "level" else 0.0), row_y(i))
	l.size = Vector2(MENU_PANEL.size.x - MENU_PAD_X * 2.0 - MENU_INDENT, MENU_ROW_H)
	if is_head or not open:
		return l                      ## 章标题行与没通关的那些：灰着、点不动（PRD:43）
	l.mouse_filter = Control.MOUSE_FILTER_STOP
	var id := str(row.get("id", ""))
	l.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			_menu_panel.visible = false
			menu_goto.emit(id))
	return l


## ---- ③ 章节全屏提示（PRD:35，方向 B 的样子）----

## 「第X章 XXXX」与英文副标。**纯函数**：测试逐字核这两行，免得真机上才发现少个空格
static func chapter_text(no: int, title: String) -> PackedStringArray:
	var cn: String = CN_NUM[no] if no > 0 and no < CN_NUM.size() else str(no)
	var ro: String = ROMAN[no] if no > 0 and no < ROMAN.size() else str(no)
	return PackedStringArray(["第%s章  %s" % [cn, title],
		"CHAPTER %s - %s" % [ro, title.to_upper()]])


## 整屏的亮度曲线：淡入 → 停 → 淡出。**纯函数**，时长口径与 S1 的 `CHAPTER_SECS` 一致
static func chapter_alpha(t: float) -> float:
	if t <= 0.0:
		return 0.0
	if t < CHAPTER_IN:
		return t / CHAPTER_IN
	if t <= CHAPTER_SECS - CHAPTER_OUT:
		return 1.0
	return clampf((CHAPTER_SECS - t) / CHAPTER_OUT, 0.0, 1.0)


## **协程**：播完才往下（导演等着它）
func show_chapter(no: int, title: String) -> void:
	if not is_inside_tree():
		return
	var texts := chapter_text(no, title)
	_chapter_title.text = texts[0]
	_chapter_sub.text = texts[1]
	_chapter.modulate.a = 0.0
	_chapter.visible = true
	var t := 0.0
	while t < CHAPTER_SECS and is_inside_tree():
		await get_tree().process_frame
		t += get_process_delta_time()
		_chapter.modulate.a = chapter_alpha(t)
	_chapter.visible = false


## ---- 常驻壳的一份状态：{chapter, level, menu:[{id,title,unlocked}], can_reset} ----

func sync(state: Dictionary) -> void:
	if _reset != null and is_instance_valid(_reset):
		_reset.visible = bool(state.get("can_reset", true))
	if state.has("menu"):
		_rows = (state["menu"] as Array).duplicate(true)
		if menu_open():
			_fill_menu()


## 全屏 STOP 层。**只挡点击，不改画面**（PRD 没要求压暗），
## 另外把光标画成「…」—— 方向 A 第 7 条，Kevin 2026-09-19 照办
class Block extends Control:
	func _process(_delta: float) -> void:
		if visible:
			queue_redraw()

	func _draw() -> void:
		var at := get_local_mouse_position() + CWTutorChrome.DOTS_AT
		for i in CWTutorChrome.DOTS_ALPHA.size():
			draw_rect(Rect2(at + Vector2(CWTutorChrome.DOTS_GAP * float(i), 0.0),
				Vector2(CWTutorChrome.DOTS_SIZE, CWTutorChrome.DOTS_SIZE)),
				Color(CWStyle.TEXT_HI, float(CWTutorChrome.DOTS_ALPHA[i])), true)


## 左上角那两颗。图标是画出来的 12×12 点阵（和全游戏的点阵字同一副嗓子），
## 不烤图是因为两个形状都只有几笔，烤出来反而多两份资产要管
class Icon extends Control:
	signal pressed
	signal hover(on: bool)

	var kind := "reset"
	var hot := false

	func _ready() -> void:
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		mouse_entered.connect(func() -> void: _set_hot(true))
		mouse_exited.connect(func() -> void: _set_hot(false))

	func _set_hot(on: bool) -> void:
		hot = on
		hover.emit(on)
		queue_redraw()

	func _gui_input(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			accept_event()
			pressed.emit()

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), CWTutorChrome.ICON_BG_HOT if hot else CWTutorChrome.ICON_BG, true)
		draw_rect(Rect2(Vector2.ZERO, size), Color(CWStyle.LINE, 0.5 if hot else 0.3),
			false, 1.0)
		var ink := CWStyle.TEXT_HI if hot else CWStyle.TEXT
		var o := (size - Vector2(12.0, 12.0)) / 2.0   ## 12×12 的图标居中
		if kind == "menu":
			## 目录：三条横杠
			for i in 3:
				draw_rect(Rect2(o + Vector2(0.0, float(i) * 5.0), Vector2(12.0, 2.0)), ink, true)
			return
		## 重置：一圈缺口的回转环 + 一枚箭头（同「倒带」那支演出的语言）
		draw_arc(o + Vector2(6.0, 6.0), 5.0, deg_to_rad(40.0), deg_to_rad(340.0), 16, ink, 2.0)
		draw_colored_polygon(PackedVector2Array([
			o + Vector2(10.0, 0.0), o + Vector2(10.0, 6.0), o + Vector2(4.0, 3.0)]), ink)
