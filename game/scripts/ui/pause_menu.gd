## pause_menu.gd —— 对局中的暂停菜单（Esc 唤出）
##
## **它不是「面板槽」的一员。** 主菜单、对局配置、规则速查、设置共用左侧那个槽位，
## 那是**开局前**的一套语法；暂停是压在对局画面上的覆盖层，两回事。
## 视觉上不另起炉灶：压暗层 + 一块和右侧竖条同宽（264）的面板，
## 描边、配色、字号全走 [CWStyle]，菜单项的选中/**辉光**沿用主菜单那套。
##
## **Esc 的归属**：目标选择态里 Esc 是「取消选目标」，那时不开菜单 ——
## 判断走 `CWActionBar.can_cancel()`，两边各自判断、互不依赖谁先收到事件
## （`_unhandled_input` 的传播顺序不该被写进逻辑里）。
##
## 暂停期间 `get_tree().paused = true`：AI 的行动间隔是 SceneTreeTimer，
## 会跟着一起停，所以这是真暂停而不只是盖一层。本节点自己设成 ALWAYS 才收得到输入。
class_name CWPauseMenu
extends Control

## action 取值见 ITEMS 的 id
signal chose(action: String)

const W := 264
const PAD := 16
const ITEM_H := 36
const TITLE_H := 42     ## 标题（30px）占的高度
## 有副标题时整块要再往下让一行 —— 30px 的标题下缘和 10px 的副标题只差几个像素，
## 不让开的话副标题会贴到标题脚下、再顶到第一项上（第一版就是这样）。
const HINT_H := 20

## enabled=false 的项按主菜单那套画成灰色、不响应鼠标。
## 「规则速查」「设置」直接复用主菜单那两个页面类（2026-08-30 接入）：
## 视图本身无状态（设置的真身在 CWSettings 静态里），暂停里再建一份实例即可；
## 挂在本节点下面顺便继承 PROCESS_MODE_ALWAYS，暂停期间照常收输入——
## 「页压页且保持暂停」就这么解决，见 _unhandled_input 里的子页路由。
## 带 confirm 的项要先过一道确认（团队 2026-08-27 要求：这两项都不可撤销）。
## 「保存并退出」的亮灭另由 can_save 决定（只有 pending 边界能存，见 CWSave）——
## 暂停期间整棵树冻着，开菜单那一刻算一次就是准的。
const ITEMS := [
	{ "id": "resume", "text": "继续对局", "enabled": true, "confirm": "" },
	{ "id": "save_quit", "text": "保存并退出", "enabled": true, "confirm": "" },
	{ "id": "rules", "text": "规则速查", "enabled": true, "confirm": "" },
	{ "id": "settings", "text": "设置", "enabled": true, "confirm": "" },
	{ "id": "menu", "text": "返回主菜单", "enabled": true, "confirm": "返回主菜单？" },
	{ "id": "quit", "text": "退出游戏", "enabled": true, "confirm": "退出游戏？" },
]

## 确认页。副标题写清楚代价 —— 直接退不保存，想留进度走「保存并退出」。
const CONFIRM_HINT := "当前对局不会保存"
const CONFIRM_ITEMS := [
	{ "id": "yes", "text": "确定", "enabled": true, "confirm": "" },
	{ "id": "no", "text": "取消", "enabled": true, "confirm": "" },
]

## 主菜单那套辉光：四层白描边由外到内叠出来，越外越淡（尺寸与 alpha 照搬 MainMenu.tscn）。
## 为什么不用引擎的辉光后期：开 hdr_2d 会把整张画布的颜色都改掉。
## 为什么层数要密：只叠两三层时最外那圈会露出一条硬边，读起来就是团队否掉的「垫块」。
const GLOW := [[24, 0.012], [16, 0.035], [10, 0.08], [6, 0.28]]

## 行动栏；用来判断 Esc 此刻该不该归暂停菜单
var action_bar: CWActionBar

## 「此刻能不能存档」的判据，由 CWMatch 注入（引擎在 pending 边界才有完整快照）。
## 无效的 Callable 按「不能存」处理 —— 没接线就宁可灰着。
var can_save := Callable()

## 对局进行中才响应 Esc。主菜单上按 Esc 不该弹出「暂停」——
## 由 CWMatch 在 start() / teardown() 里翻。
var active := false
## 联机局：没有「保存并退出」（状态在服务器），「返回主菜单」改成「离开房间」（本局交给 AI 代打）
var online := false

var _rules: CWRulesPage        ## 对局内的规则速查/设置：主菜单同款页面类的另一份实例
var _settings: CWSettingsPage
var _panel: Control
var _title: Label
var _hint: Label
var _list: Array = []          ## 当前这一页的项（ITEMS 或 CONFIRM_ITEMS）
var _labels: Array[Label] = []
var _bars: Array[ColorRect] = []
var _glow: Control             ## 全菜单共用一套，跟着选中项走
var _selected := 0
var _hovered := -1
var _confirming := ""          ## 正在确认哪一项的 id；空 = 在主列表上


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   ## 暂停时仍要收输入
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP  ## 盖住底下的一切点击
	_build_chrome()
	## 子页压在列表上面（后建的在上）。它们自己会在 Esc/右键时收起，
	## 这里只需盯着 visibility_changed 决定列表要不要让位。
	_rules = CWRulesPage.new()
	add_child(_rules)
	_settings = CWSettingsPage.new()
	add_child(_settings)
	_rules.visibility_changed.connect(_sub_changed)
	_settings.visibility_changed.connect(_sub_changed)
	visible = false


func toggle() -> void:
	if visible:
		close()
	else:
		open()


func open() -> void:
	visible = true
	if is_inside_tree():
		get_tree().paused = true
	_show_page("")


func close() -> void:
	visible = false
	_confirming = ""
	## 子页一并收掉：save_quit/teardown 这类外部关闭可能发生在子页开着的时候，
	## 不收的话下次 open() 会顶着一张残留的规则页
	if _rules != null:
		_rules.visible = false
	if _settings != null:
		_settings.visible = false
	## teardown() 在 _exit_tree 里也会调到这儿，那时已经离开场景树、get_tree() 是 null
	if is_inside_tree():
		get_tree().paused = false


## 子页开着时列表让位（两块面板同宽同位，叠着会透出一圈重影）；树保持冻结
func _sub_changed() -> void:
	var sub_open: bool = (_rules != null and _rules.visible) \
		or (_settings != null and _settings.visible)
	_panel.visible = not sub_open


func _unhandled_input(event: InputEvent) -> void:
	if not active:
		return
	## 页压页路由：子页开着时键盘输入全数转给它（Esc 由子页自己收——
	## 关的是子页不是暂停菜单，树保持冻结，退回列表继续选）
	if _rules != null and _rules.visible:
		_rules.handle_input(event)
		return
	if _settings != null and _settings.visible:
		_settings.handle_input(event)
		return
	if event.is_action_pressed("ui_cancel"):
		## 正在选目标格时，Esc 归行动栏的「取消」，不开菜单
		if not visible and action_bar != null and action_bar.can_cancel():
			return
		get_viewport().set_input_as_handled()
		if _confirming != "":
			_show_page("")      ## 确认页上按 Esc 是「退回上一层」，不是关掉整个菜单
		else:
			toggle()
		return
	if not visible:
		return
	if event.is_action_pressed("ui_down"):
		_step(1)
	elif event.is_action_pressed("ui_up"):
		_step(-1)
	elif event.is_action_pressed("ui_accept"):
		get_viewport().set_input_as_handled()   ## 别让空格穿透到「结束回合」
		_activate(_selected)


# ============ 两页：主列表 / 确认 ============

## confirm_id 为空 = 主列表；否则是那一项的确认页。
func _show_page(confirm_id: String) -> void:
	_confirming = confirm_id
	if confirm_id == "":
		_title.text = "暂停"
		_hint.text = ""
		_rebuild(items())
		return
	for item in items():
		if item["id"] == confirm_id:
			_title.text = item["confirm"]
			break
	_hint.text = "离开后本局由 AI 代打" if online and confirm_id == "menu" else CONFIRM_HINT
	_rebuild(CONFIRM_ITEMS)
	_selected = 1                 ## 确认页默认停在「取消」上，别让回车顺手就确认了
	_repaint()


## 此刻的主列表：本地对局 = ITEMS；联机局去掉「保存并退出」、「返回主菜单」换成「离开房间」
func items() -> Array:
	if not online:
		return ITEMS
	var out: Array = []
	for item in ITEMS:
		if item["id"] == "save_quit":
			continue
		if item["id"] == "menu":
			var leave: Dictionary = item.duplicate()
			leave["text"] = "离开房间"
			leave["confirm"] = "离开房间？"
			out.append(leave)
		else:
			out.append(item)
	return out


## 这一项此刻可不可用：静态 enabled 之外，「保存并退出」还要问 can_save
func _enabled(item: Dictionary) -> bool:
	if not item["enabled"]:
		return false
	if item["id"] == "save_quit":
		return can_save.is_valid() and can_save.call()
	return true


func _activate(i: int) -> void:
	if not _enabled(_list[i]):
		return
	var id: String = _list[i]["id"]
	if _confirming != "":
		if id != "yes":
			_show_page("")
			return
		var target := _confirming
		close()                   ## 先解除暂停，否则返场动画不会走
		chose.emit(target)
		return
	if id == "resume":
		close()
		return
	## 规则/设置在菜单内部消化（页压页，不关菜单不解除暂停）；其余项发给 main.gd
	if id == "rules":
		_rules.open()
		return
	if id == "settings":
		_settings.open()
		return
	if _list[i]["confirm"] != "":
		_show_page(id)
		return
	close()
	chose.emit(id)


# ============ 外观 ============

func _build_chrome() -> void:
	var scrim := ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.55)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(scrim)

	_panel = Control.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)

	var bg := Panel.new()
	bg.add_theme_stylebox_override("panel", CWStyle.box(0.45, CWStyle.PANEL))
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(bg)

	_title = CWStyle.label("", CWStyle.SIZE_BIG, CWStyle.TEXT_HI)
	_title.position = Vector2(PAD, PAD)
	_title.size = Vector2(W - PAD * 2, 0)
	_panel.add_child(_title)

	_hint = CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	_hint.position = Vector2(PAD, PAD + TITLE_H)
	_hint.size = Vector2(W - PAD * 2, 0)
	_panel.add_child(_hint)

	## 辉光整套只备一份、跟着选中项走 —— 同时只可能有一项被选中，不必每项各备一份
	_glow = Control.new()
	_glow.size = Vector2(W, 28)
	_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_glow.visible = false
	_panel.add_child(_glow)
	for layer in GLOW:
		var l := CWStyle.label("", CWStyle.SIZE_BODY, Color(1, 1, 1, 0))
		l.add_theme_color_override("font_outline_color", Color(1, 1, 1, layer[1]))
		l.add_theme_constant_override("outline_size", layer[0])
		l.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_glow.add_child(l)


func _rebuild(list: Array) -> void:
	for label in _labels:
		label.queue_free()
	for bar in _bars:
		bar.queue_free()
	_labels.clear()
	_bars.clear()
	_list = list
	_selected = 0
	_hovered = -1

	var head: float = TITLE_H + (HINT_H if _hint.text != "" else 0.0)
	var h: float = PAD + head + list.size() * ITEM_H + PAD
	var screen := CWView.screen_size()
	_panel.position = Vector2((screen.x - W) / 2.0, (screen.y - h) / 2.0)
	_panel.size = Vector2(W, h)

	for i in list.size():
		var y: float = PAD + head + i * ITEM_H
		## 选中标记用一条 4px 的阵营青色条，和玩家列表那一列是同一个语汇
		var mark := ColorRect.new()
		mark.position = Vector2(PAD, y + 6)
		mark.size = Vector2(4, 22)
		mark.color = Color(CWStyle.IMMUNE, 0.0)
		mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_panel.add_child(mark)
		_bars.append(mark)

		var label := CWStyle.label(list[i]["text"], CWStyle.SIZE_BODY, CWStyle.TEXT)
		label.position = Vector2(PAD + 16, y + 5)
		label.size = label.get_minimum_size()   ## 命中框贴着字，别把右边空白也算进去
		_panel.add_child(label)
		_labels.append(label)
		if not _enabled(list[i]):
			continue
		label.mouse_filter = Control.MOUSE_FILTER_STOP
		label.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		label.mouse_entered.connect(func() -> void: _hover(i))
		label.mouse_exited.connect(func() -> void: _hover(-1 if _hovered == i else _hovered))
		label.gui_input.connect(func(e: InputEvent) -> void:
			if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				get_viewport().set_input_as_handled()   ## 理由同主菜单：别让这一下漏下去
				_activate(i))
	_repaint()


func _hover(i: int) -> void:
	if _hovered == i:
		return
	_hovered = i
	if i >= 0:
		_selected = i
	_repaint()


func _repaint() -> void:
	for i in _labels.size():
		var usable := _enabled(_list[i])
		var on: bool = i == _selected and usable
		var color := CWStyle.TEXT_OFF
		if usable:
			color = Color.WHITE if on else CWStyle.TEXT
		_labels[i].add_theme_color_override("font_color", color)
		_bars[i].color = Color(CWStyle.IMMUNE, 1.0 if on else 0.0)
	_move_glow()


## 辉光跟着选中项走，和主菜单同一套做法。
## 主菜单那边跟的是**悬停**，这里悬停会顺手把选中也带过去，所以键鼠两种输入下表现一致。
func _move_glow() -> void:
	var on: bool = _selected < _labels.size() and _enabled(_list[_selected])
	_glow.visible = on
	if not on:
		return
	_glow.position = _labels[_selected].position
	for layer in _glow.get_children():
		(layer as Label).text = _labels[_selected].text


## 往 dir 方向找下一个可用项，跳过灰掉的；到头就停在原地，不绕回（和主菜单同一条规则）
func _step(dir: int) -> void:
	var i := _selected + dir
	while i >= 0 and i < _list.size():
		if _enabled(_list[i]):
			_selected = i
			_repaint()
			return
		i += dir
