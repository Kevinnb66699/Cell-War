## pause_menu.gd —— 对局中的暂停菜单（Esc 唤出）
##
## **它不是「面板槽」的一员。** 主菜单、对局配置、规则速查、设置共用左侧那个槽位，
## 那是**开局前**的一套语法；暂停是压在对局画面上的覆盖层，两回事。
## 视觉上不另起炉灶：压暗层 + 一块和右侧竖条同宽（264）的面板，
## 描边、配色、字号全走 [CWStyle]，菜单项的选中/悬停沿用主菜单那套。
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
const TITLE_H := 42

## enabled=false 的项按主菜单那套画成灰色、不响应鼠标。
## 「规则速查」「设置」在主菜单里也是灰的，这里保持一致：**做出来两边一起亮**。
const ITEMS := [
	{ "id": "resume", "text": "继续对局", "enabled": true },
	{ "id": "rules", "text": "规则速查", "enabled": false },
	{ "id": "settings", "text": "设置", "enabled": false },
	{ "id": "menu", "text": "返回主菜单", "enabled": true },
	{ "id": "quit", "text": "退出游戏", "enabled": true },
]

## 行动栏；用来判断 Esc 此刻该不该归暂停菜单
var action_bar: CWActionBar

## 对局进行中才响应 Esc。主菜单上按 Esc 不该弹出「暂停」——
## 由 CWMatch 在 start() / teardown() 里翻。
var active := false

var _panel: Control
var _labels: Array[Label] = []
var _bars: Array[ColorRect] = []
var _selected := 0
var _hovered := -1


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   ## 暂停时仍要收输入
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP  ## 盖住底下的一切点击
	_build()
	visible = false


func toggle() -> void:
	if visible:
		close()
	else:
		open()


func open() -> void:
	_selected = 0
	_hovered = -1
	visible = true
	get_tree().paused = true
	_repaint()


func close() -> void:
	visible = false
	## teardown() 在 _exit_tree 里也会调到这儿，那时已经离开场景树、get_tree() 是 null
	if is_inside_tree():
		get_tree().paused = false


func _unhandled_input(event: InputEvent) -> void:
	if not active:
		return
	if event.is_action_pressed("ui_cancel"):
		## 正在选目标格时，Esc 归行动栏的「取消」，不开菜单
		if not visible and action_bar != null and action_bar.can_cancel():
			return
		get_viewport().set_input_as_handled()
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


# ============ 外观 ============

func _build() -> void:
	var scrim := ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.55)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(scrim)

	var h := PAD + TITLE_H + ITEMS.size() * ITEM_H + PAD
	var screen := CWView.screen_size()
	_panel = Control.new()
	_panel.position = Vector2((screen.x - W) / 2.0, (screen.y - h) / 2.0)
	_panel.size = Vector2(W, h)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)

	var bg := Panel.new()
	bg.add_theme_stylebox_override("panel", CWStyle.box(0.45, CWStyle.PANEL))
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(bg)

	var title := CWStyle.label("暂停", CWStyle.SIZE_BIG, CWStyle.TEXT_HI)
	title.position = Vector2(PAD, PAD)
	title.size = Vector2(W - PAD * 2, 0)
	_panel.add_child(title)

	for i in ITEMS.size():
		var y: float = PAD + TITLE_H + i * ITEM_H
		## 选中标记用一条 4px 的阵营青色条，和玩家列表那一列是同一个语汇
		var mark := ColorRect.new()
		mark.position = Vector2(PAD, y + 6)
		mark.size = Vector2(4, 22)
		mark.color = Color(CWStyle.IMMUNE, 0.0)
		mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_panel.add_child(mark)
		_bars.append(mark)

		var label := CWStyle.label(ITEMS[i]["text"], CWStyle.SIZE_BODY, CWStyle.TEXT)
		label.position = Vector2(PAD + 16, y + 5)
		label.size = label.get_minimum_size()   ## 命中框贴着字，别把右边空白也算进去
		_panel.add_child(label)
		_labels.append(label)
		if not ITEMS[i]["enabled"]:
			continue
		label.mouse_filter = Control.MOUSE_FILTER_STOP
		label.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		label.mouse_entered.connect(func() -> void: _hover(i))
		label.mouse_exited.connect(func() -> void: _hover(-1 if _hovered == i else _hovered))
		label.gui_input.connect(func(e: InputEvent) -> void:
			if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				_activate(i))


func _hover(i: int) -> void:
	if _hovered == i:
		return
	_hovered = i
	if i >= 0:
		_selected = i
	_repaint()


func _repaint() -> void:
	for i in _labels.size():
		var hot := i == _hovered
		var color := CWStyle.TEXT_OFF
		if ITEMS[i]["enabled"]:
			color = CWStyle.TEXT_HI if (hot or i == _selected) else CWStyle.TEXT
		_labels[i].add_theme_color_override("font_color", color)
		_bars[i].color = Color(CWStyle.IMMUNE, 1.0 if i == _selected and ITEMS[i]["enabled"] else 0.0)


## 往 dir 方向找下一个可用项，跳过灰掉的；到头就停在原地，不绕回（和主菜单同一条规则）
func _step(dir: int) -> void:
	var i := _selected + dir
	while i >= 0 and i < ITEMS.size():
		if ITEMS[i]["enabled"]:
			_selected = i
			_repaint()
			return
		i += dir


func _activate(i: int) -> void:
	if not ITEMS[i]["enabled"]:
		return
	if ITEMS[i]["id"] == "resume":
		close()
		return
	close()                      ## 先解除暂停，否则返回主菜单的过场动画不会走
	chose.emit(ITEMS[i]["id"])
