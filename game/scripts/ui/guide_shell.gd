## guide_shell.gd —— 新手引导的**常驻壳**（docs/新手引导_实现方案.md §1.12 / PRD 通用规则 1/2/4/5/8/9，S4，2026-09-19）
##
## 引导浮层（`CWGuide`）说的是「这一步做什么」；这一层说的是「整个引导的外壳」，四件事：
##
## ① **章节提示**（PRD:35）：`chapter` 字段变了才弹一块覆盖全屏的半透明提示「第 X 章 标题」，点任意处关。
##    关与关之间**不弹**（PRD:37 静默切换）—— 判据就是 `chapter` 有没有变，`show_chapter()` 自己记着上一次。
## ② **提示期间全部操作禁用**（PRD:51 / 方案 §1.5 的第 2 层）：提示或目录开着时，一块**真·全屏**
##    `MOUSE_FILTER_STOP` 的 `Control` 盖住棋盘、行动栏、右栏与引导浮层。
##    **不能指望 `CWGuide` 自己那层**：`CWGuide.ZONE` 只有 600×200，棋盘和行动栏全在它外面。
##    第 1 层（这一问挂起、行动栏根本不建）在 `CWGuideBridge` 那边，两层缺一不可。
## ③ **常驻「重置」「目录」**（PRD:41/43）：这两个按钮排在遮挡层**之上** —— 提示期照样点得到，
##    它们正是「剧本写错把玩家卡住」时唯一的出路（方案 §1.5 那条 warning + 挂起）。
## ④ **轻微慢闪**（PRD:49）：两个按钮底下垫一小片白色柔光，周期与幅度**直接取 `CWGuide` 的三个常数**
##    （09-10 沉浸式浮层那套），闪烁参数收敛到一处。
##
## 只发信号、不动对局：重置与跳章由 `CWMatch` 执行（拆装局面是它的事，方案 §2.1 的一条依赖线）。
class_name CWGuideShell
extends Control

## 「重置」把当前关退回关首、「目录」跳到某一关。执行都在 CWMatch
signal reset_pressed
signal goto_pressed(chapter: int)
## 点了常驻「目录」按钮（要开/关目录面板）。`CWMatch` 知道此刻是第几关，转调 `toggle_menu(current)`
signal menu_pressed
## 点了「切换种类」（PRD:355 第五关 Step2）。换的是哪一份 world 归 `CWMatch` 算（`ui_layers.switch_type`）
signal switch_type_pressed

## 全屏遮罩的黑度。够读清中间那行字，又能看出底下还是同一局（不是换了场景）
const DIM := Color(0.02, 0.06, 0.09, 0.72)
## 目录面板
const MENU_RECT := Rect2(240, 90, 480, 360)
const MENU_ROW_H := 34.0
## 常驻两个按钮：左上角「日志」入口（`CWLogHint` 教程局收成 22px 高的一条，钉在 16,16）之下
const BTN_AT := Vector2(16, 48)
const BTN_GAP := 28.0
## 闪烁参数只有 CWGuide 一份（PRD:49 / 方案 §1.12 规则 8）
const HALO_PERIOD := CWGuide.HALO_PERIOD
const HALO_ALPHA_LO := CWGuide.HALO_ALPHA_LO
const HALO_ALPHA_HI := CWGuide.HALO_ALPHA_HI

var _blocker: Control        ## 全屏 STOP 层（PRD:51 的第 2 层）
var _banner: Control         ## 章节提示
var _banner_text: Label
var _menu: Control           ## 目录
var _menu_rows: Array[Label] = []
var _reset_btn: Label
var _menu_btn: Label
## 「切换种类」：只有声明了 `ui_layers.switch_type` 的步才出（第五关 Step2）
var _switch_btn: Label
var _halo: TextureRect
var _t := 0.0
## 已经弹过提示的章号（PRD:37：`chapter` 没变就静默切换，不弹）
var _chapter_shown := -1
## 正在劝玩家重置（`steps[].advise_when` 命中，PRD:251 第二条）：「重置本关」四个字跟着慢闪
var _urge := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE   ## 壳本身不挡，挡的是 _blocker
	_build()


## 此刻是不是「提示/目录开着」= 全部操作禁用（PRD:51）。
## `CWMatch` 每帧把它喂给 `CWGuideBridge.blocked`，决策闸那一层跟着关上
func blocking() -> bool:
	return (_banner != null and _banner.visible) or (_menu != null and _menu.visible)


## 章节变了就弹（PRD:35）。同一章反复调是空操作 —— 关与关静默切换（PRD:37）就靠这一条
func show_chapter(chapter: int, title: String) -> bool:
	if chapter == _chapter_shown:
		return false
	_chapter_shown = chapter
	_banner_text.text = "第 %d 章　%s" % [chapter, title]
	_banner.visible = true
	_blocker.visible = true
	return true


func close_banner() -> void:
	_banner.visible = false
	_blocker.visible = blocking()


## 无参入口：合成的鼠标点击到不了 `Control`，真机截图只能靠 `screenshot.gd` 的
## `call:CWGuideShell:press_reset`（同 `call:CWGuide:_advance` 的理由，见那个文件头）
func press_reset() -> void:
	reset_pressed.emit()


func press_menu() -> void:
	menu_pressed.emit()


func press_switch_type() -> void:
	switch_type_pressed.emit()


## 「切换种类」这一帧显不显示（`CWMatch._sync_guide_shell` 每帧按 `ui_layers.switch_type` 喂）
func show_switch_type(on: bool) -> void:
	if _switch_btn != null:
		_switch_btn.visible = on


## 此刻显着吗（测试直接读）
func switch_type_shown() -> bool:
	return _switch_btn != null and _switch_btn.visible


## 劝玩家自己按「重置本关」（PRD:251 第二条；Kevin 2026-09-19：提示、**不自动重置**）。
## 开着时那四个字跟着底下柔光同一个呼吸周期在常色 ↔ 白之间慢闪（PRD:49 的闪法，参数仍是那三个常数）；
## 关掉就还原 —— 还原写在这儿而不是 `_process`，免得每帧都覆写一次悬停提白
func urge_reset(on: bool) -> void:
	if on == _urge:
		return
	_urge = on
	if not on and _reset_btn != null:
		_reset_btn.add_theme_color_override("font_color", CWStyle.TEXT)


## 此刻在不在劝重置（测试直接读）
func urging() -> bool:
	return _urge


## 某一关此刻能不能从目录跳过去（Q-14 默认：未通关灰显不可点）。
## **纯函数**：已经通关的，加上正在玩的这一关（否则第一关自己都点不了）
static func unlocked(chapter: int, current: int, done: Callable) -> bool:
	return chapter == current or bool(done.call(chapter))


func toggle_menu(current: int) -> void:
	if _menu.visible:
		_menu.visible = false
		_blocker.visible = blocking()
		return
	_fill_menu(current)
	_menu.visible = true
	_blocker.visible = true


## 目录里每行的可点状态（测试直接读）：下标 = 关号
func menu_enabled() -> Array[bool]:
	var out: Array[bool] = []
	for row in _menu_rows:
		out.append(bool(row.get_meta("enabled", false)))
	return out


func _fill_menu(current: int) -> void:
	for row in _menu_rows:
		row.queue_free()
	_menu_rows.clear()
	var titles := CWGuideData.chapter_titles()
	var subs := CWGuideData.chapter_subtitles()
	for i in titles.size():
		var open := unlocked(i, current, Callable(CWGuideProgress, "has_done"))
		var sub: String = subs[i] if i < subs.size() else ""
		var text := "%d. %s" % [i + 1, titles[i]]
		if sub != "":
			text += "　·　" + sub
		var row := CWStyle.label(text, CWStyle.SIZE_BODY,
			CWStyle.TEXT_HI if open else CWStyle.TEXT_OFF)
		row.position = Vector2(24, 56 + i * MENU_ROW_H)
		row.size = Vector2(MENU_RECT.size.x - 48, MENU_ROW_H - 6)
		row.set_meta("enabled", open)
		if open:
			row.mouse_filter = Control.MOUSE_FILTER_STOP
			row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			var idx := i
			row.gui_input.connect(func(e: InputEvent) -> void:
				if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
					get_viewport().set_input_as_handled()
					_menu.visible = false
					_blocker.visible = blocking()
					goto_pressed.emit(idx))
		else:
			row.mouse_filter = Control.MOUSE_FILTER_IGNORE   ## 灰显不可点（Q-14 默认）
		_menu.add_child(row)
		_menu_rows.append(row)


func _build() -> void:
	## ---- ① 全屏遮挡层：排在最底下，提示 / 目录才显 ----
	_blocker = Control.new()
	_blocker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	_blocker.visible = false
	add_child(_blocker)

	## ---- ② 章节提示：整屏半透明 + 一行大字，点任意处关 ----
	_banner = Control.new()
	_banner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_banner.mouse_filter = Control.MOUSE_FILTER_STOP
	_banner.visible = false
	_banner.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed:
			get_viewport().set_input_as_handled()
			close_banner())
	var veil := ColorRect.new()
	veil.color = DIM
	veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner.add_child(veil)
	_banner_text = CWStyle.label("", CWStyle.SIZE_HERO, CWStyle.TEXT_HI)
	_banner_text.position = Vector2(0, 236)
	_banner_text.size = Vector2(CWView.screen_size().x, 52)
	_banner_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner.add_child(_banner_text)
	add_child(_banner)

	## ---- ③ 目录（PRD:43）：`CWGuide.goto_chapter` 终于有调用方 ----
	_menu = Control.new()
	_menu.position = MENU_RECT.position
	_menu.size = MENU_RECT.size
	_menu.mouse_filter = Control.MOUSE_FILTER_STOP
	_menu.visible = false
	var menu_bg := Panel.new()
	menu_bg.add_theme_stylebox_override("panel", CWStyle.box(0.45, CWStyle.PANEL))
	menu_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	menu_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu.add_child(menu_bg)
	var menu_title := CWStyle.label("章节目录", CWStyle.SIZE_BODY, CWStyle.TEXT_DIM)
	menu_title.position = Vector2(24, 18)
	menu_title.size = Vector2(MENU_RECT.size.x - 48, 28)
	menu_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu.add_child(menu_title)
	add_child(_menu)

	## ---- ④ 常驻两个按钮（排在遮挡层之上：提示期也点得到，PRD:41/43）----
	_halo = TextureRect.new()
	_halo.texture = CWGuide._soft_tex(GradientTexture2D.FILL_RADIAL, Color(Color.WHITE, 0.16))
	_halo.position = BTN_AT + Vector2(-28, -18)
	_halo.size = Vector2(160, BTN_GAP + 56)
	_halo.stretch_mode = TextureRect.STRETCH_SCALE
	_halo.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_halo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_halo)

	_reset_btn = _clicky("重置本关", press_reset)
	_reset_btn.position = BTN_AT
	add_child(_reset_btn)
	_menu_btn = _clicky("目录", press_menu)
	_menu_btn.position = BTN_AT + Vector2(0, BTN_GAP)
	add_child(_menu_btn)
	## 「切换种类」排在两个常驻按钮之下（同一列、同样盖在遮挡层之上）。
	## **默认不显示**：只有第五关 Step2 那一步的 `ui_layers.switch_type` 才把它打开
	_switch_btn = _clicky("切换种类", press_switch_type)
	_switch_btn.position = BTN_AT + Vector2(0, BTN_GAP * 2)
	_switch_btn.visible = false
	add_child(_switch_btn)


## 可点击的文字按钮（同 `CWGuide._clicky` 的打法：命中框贴着字、手型光标、悬停提白）
func _clicky(text: String, on_click: Callable) -> Label:
	var label := CWStyle.label(text, CWStyle.SIZE_BODY, CWStyle.TEXT)
	label.size = label.get_minimum_size()
	label.mouse_filter = Control.MOUSE_FILTER_STOP
	label.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	label.mouse_entered.connect(func() -> void:
		label.add_theme_color_override("font_color", Color.WHITE))
	label.mouse_exited.connect(func() -> void:
		label.add_theme_color_override("font_color", CWStyle.TEXT))
	label.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			get_viewport().set_input_as_handled()
			on_click.call())
	return label


func _process(delta: float) -> void:
	if _halo == null or not visible:
		return
	## 轻微慢闪（PRD:49）：与引导浮层那圈柔光同一个呼吸周期
	_t += delta
	var k := 0.5 + 0.5 * sin(_t * TAU / HALO_PERIOD)
	_halo.modulate.a = lerpf(HALO_ALPHA_LO, HALO_ALPHA_HI, k)
	## 劝重置时那四个字也跟着同一拍提亮（PRD:251 第二条）
	if _urge and _reset_btn != null:
		_reset_btn.add_theme_color_override("font_color", CWStyle.TEXT.lerp(Color.WHITE, k))
