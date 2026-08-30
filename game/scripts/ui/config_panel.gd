## config_panel.gd —— 对局配置：主菜单同一槽位的左侧面板（人数 / 阵营 / AI 强度 / 随机种子）
##
## **面板槽语法**（开局过场原型的定稿，2026-08-29 第二稿设计定案）：
## 主菜单 0.30s 淡出 → 本面板在同一位置 0.32s 淡入——内容换、位置不换；
## 「进入棋盘」按下去就是现有的 1.55s 拉远过场。坐标全按原型标注搬：
## 标签 x120 / 值 x250 / 行距 42 / 按钮 182×38。第一版曾做成居中弹窗，
## 那是暂停菜单（覆盖层）的语汇，借错了地方——槽位才是开局前界面的语法。
##
## 键盘：上下选行（菱形标随焦点走，和主菜单同一颗）、左右拨值、
## 回车在「进入棋盘」上才开局；Esc 退回主菜单。鼠标：点值/箭头拨值、点按钮开局。
## **打开时焦点停在第一行「人数」**（Kevin 2026-08-29 定：默认停在按钮上，
## 玩家会以为配置改不了）。行上回车 = 拨值，走到按钮再回车才开局。取值局间保留。
class_name CWConfigPanel
extends Control

## cfg = { players: 2/4/6, faction: CWData.Faction 或 -1（观战）, smart: bool, seed: int }
signal confirmed(cfg: Dictionary)
## Esc 退回：主菜单收到后把自己淡回来
signal cancelled

const SLOT_X := 120.0        ## 槽位左缘（眉题/标题/标签/按钮共用，原型 12.5cqw）
const VALUE_X := 250.0       ## 值那一列（原型 26cqw）
const ROW_Y0 := 251.0        ## 第一行的纵坐标
const ROW_H := 42.0          ## 行距（和主菜单项一致）
const BTN_Y := 438.0
const BTN_W := 182.0
const BTN_H := 38.0
const FADE_IN := 0.32        ## 原型节拍：菜单 0.30s 淡出后，配置 0.32s 淡入

## 原型的行文字色（比 TEXT_DIM 亮半档，值列用 TEXT_HI）
const ROW_LABEL := Color("9fb6bd")
## 「进入棋盘」按钮底色**不做悬停变化**（Kevin 2026-08-29 定：现在的效果保留）——
## 焦点/悬停用菱形标示意，和选项行同一颗，按钮本身一个像素不动。

const ROW_NAMES := ["人数", "我的阵营", "AI 强度", "随机种子"]
const ROW_PLAYERS := 0
const ROW_FACTION := 1
const ROW_SMART := 2
const ROW_SEED := 3
const N_ROWS := 4
const PLAYER_STEPS := [2, 4, 6]
const FACTION_STEPS := [CWData.Faction.IMMUNE, CWData.Faction.CANCER, -1]

var _players := 4
var _faction: int = CWData.Faction.IMMUNE   ## -1 = 观战
var _smart := false
var _seed := 0

var _sel := N_ROWS           ## 焦点：0..3 = 行，N_ROWS = 「进入棋盘」
var _name_labels: Array[Label] = []
var _value_labels: Array[Label] = []
var _arrows: Array = []      ## [[‹, ›], ...]；› 的横坐标随值宽变，_repaint 里摆
var _marker: Node2D          ## 菱形焦点标（带光晕，和主菜单同一颗的做法）
var _btn: Panel


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP   ## 整层接管：底下淡掉的菜单项收不到点击
	visible = false
	_seed = _roll_seed()
	_build()


func open() -> void:
	_sel = 0   ## 焦点落第一行，见文件头（停在按钮上会让玩家以为不能改）
	visible = true
	modulate.a = 0.0
	create_tween().tween_property(self, "modulate:a", 1.0, FADE_IN)
	_repaint()


## 由 CWMainMenu 的 _unhandled_input 转发（覆盖层统一走菜单路由）
func handle_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		visible = false
		cancelled.emit()
	elif event.is_action_pressed("ui_down"):
		_sel = mini(_sel + 1, N_ROWS)
		_repaint()
	elif event.is_action_pressed("ui_up"):
		_sel = maxi(_sel - 1, 0)
		_repaint()
	elif event.is_action_pressed("ui_left"):
		_cycle(_sel, -1)
	elif event.is_action_pressed("ui_right"):
		_cycle(_sel, 1)
	elif event.is_action_pressed("ui_accept"):
		get_viewport().set_input_as_handled()
		if _sel == N_ROWS:
			_confirm()
		else:
			_cycle(_sel, 1)   ## 行上回车 = 往后拨一格（和点值一致）


func config() -> Dictionary:
	return { "players": _players, "faction": _faction, "smart": _smart, "seed": _seed }


## 人类坐第几号位：该阵营在行动顺序里的第一个座位（观战返回 -1）。
## 单独成 static 是给无头测试直接查座位规则用。
static func human_seat(n_players: int, faction: int) -> int:
	if faction < 0:
		return -1
	var order: Array = CWData.FACTION_ORDER[n_players]
	for i in order.size():
		if order[i] == faction:
			return i
	return -1


func _cycle(row: int, dir: int) -> void:
	match row:
		ROW_PLAYERS:
			var i := PLAYER_STEPS.find(_players)
			_players = PLAYER_STEPS[(i + dir + PLAYER_STEPS.size()) % PLAYER_STEPS.size()]
		ROW_FACTION:
			var i := FACTION_STEPS.find(_faction)
			_faction = FACTION_STEPS[(i + dir + FACTION_STEPS.size()) % FACTION_STEPS.size()]
		ROW_SMART:
			_smart = not _smart
		ROW_SEED:
			_seed = _roll_seed()   ## 种子没有「上一个」，拨就是换一个
		_:
			return
	_repaint()


## 8 位十进制：够躲重复、念给队友也不费劲。UI 的随机不碰 game.rng（那是对局状态）。
func _roll_seed() -> int:
	return randi() % 90000000 + 10000000


func _confirm() -> void:
	visible = false
	confirmed.emit(config())


# ============ 搭建（坐标 = 原型标注 ×9.6，见设计稿标注版）============

func _build() -> void:
	## 槽位自带一份左侧暗罩：主菜单的 Scrim 跟着菜单整层淡走了，
	## 面板要自己把身后的棋盘压暗（渐变参数照抄 MainMenu.tscn 的 Gradient_scrim）
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.44, 1.0])
	grad.colors = PackedColorArray([Color(0.078431, 0.121569, 0.180392, 0.96),
		Color(0.078431, 0.121569, 0.180392, 0.0)])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill_to = Vector2(1, 0)
	var scrim := TextureRect.new()
	scrim.texture = tex
	scrim.size = Vector2(538, 540)
	scrim.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(scrim)

	## 眉题 SETUP：和主菜单 IMMUNE VS CANCER 同一套（px20 变体 + 青色）
	var eyebrow := CWStyle.label("SETUP", CWStyle.SIZE_BODY, CWStyle.IMMUNE)
	eyebrow.add_theme_font_override("font", _px20())
	eyebrow.position = Vector2(SLOT_X, 127)
	add_child(eyebrow)

	var title := CWStyle.label("对局配置", CWStyle.SIZE_BIG, CWStyle.TEXT_HI)
	title.position = Vector2(SLOT_X, 160)
	add_child(title)

	var rule := ColorRect.new()
	rule.position = Vector2(SLOT_X, 230)
	rule.size = Vector2(288, 1)
	rule.color = Color(CWStyle.LINE, 0.42)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(rule)

	_marker = _build_marker()
	add_child(_marker)

	for i in N_ROWS:
		_build_row(i)
	_build_button()


## 菱形焦点标 + 径向光晕：参数照抄 MainMenu.tscn 的 Marker（同一颗才像一家人）
func _build_marker() -> Node2D:
	var marker := Node2D.new()
	var halo_grad := Gradient.new()
	halo_grad.offsets = PackedFloat32Array([0.0, 0.34, 1.0])
	halo_grad.colors = PackedColorArray([Color(CWStyle.IMMUNE, 0.44),
		Color(CWStyle.IMMUNE, 0.2), Color(CWStyle.IMMUNE, 0.0)])
	var halo_tex := GradientTexture2D.new()
	halo_tex.gradient = halo_grad
	halo_tex.fill = GradientTexture2D.FILL_RADIAL
	halo_tex.fill_from = Vector2(0.5, 0.5)
	halo_tex.fill_to = Vector2(1, 0.5)
	var halo := TextureRect.new()
	halo.texture = halo_tex
	halo.position = Vector2(-24, -24)
	halo.size = Vector2(48, 48)
	halo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	halo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	marker.add_child(halo)
	var core := ColorRect.new()
	core.position = Vector2(-7, -7)
	core.size = Vector2(14, 14)
	core.rotation = PI / 4
	core.pivot_offset = Vector2(7, 7)
	core.color = CWStyle.IMMUNE
	core.mouse_filter = Control.MOUSE_FILTER_IGNORE
	marker.add_child(core)
	return marker


func _build_row(i: int) -> void:
	var y := ROW_Y0 + i * ROW_H
	var hit := Control.new()
	hit.position = Vector2(SLOT_X - 30, y - 8)
	hit.size = Vector2(420, ROW_H - 4)
	hit.mouse_filter = Control.MOUSE_FILTER_PASS   ## 只感应悬停，点击留给值/箭头
	hit.mouse_entered.connect(func() -> void:
		_sel = i
		_repaint())
	add_child(hit)

	var name_label := CWStyle.label(ROW_NAMES[i], CWStyle.SIZE_BODY, ROW_LABEL)
	name_label.position = Vector2(SLOT_X, y)
	add_child(name_label)
	_name_labels.append(name_label)

	## 拨值箭头用 ASCII 的 < >：点阵字库没有 ‹ ›（字形覆盖测试盯着这类字符）
	var left := _clicky("<", Vector2(VALUE_X - 22, y), func() -> void: _tap(i, -1))
	var value := _clicky("", Vector2(VALUE_X, y), func() -> void: _tap(i, 1))
	var right := _clicky(">", Vector2(VALUE_X, y), func() -> void: _tap(i, 1))
	_value_labels.append(value)
	_arrows.append([left, right])


func _build_button() -> void:
	## 底色 = IMMUNE、圆角 5（原型 .5cqw），没有任何悬停变体——见文件头 Kevin 的定案
	var box := StyleBoxFlat.new()
	box.bg_color = CWStyle.IMMUNE
	box.set_corner_radius_all(5)
	_btn = Panel.new()
	_btn.position = Vector2(SLOT_X, BTN_Y)
	_btn.size = Vector2(BTN_W, BTN_H)
	_btn.add_theme_stylebox_override("panel", box)
	_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_btn.mouse_entered.connect(func() -> void:
		_sel = N_ROWS
		_repaint())
	_btn.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			get_viewport().set_input_as_handled()
			_confirm())
	add_child(_btn)
	var text := CWStyle.label("进入棋盘", CWStyle.SIZE_BODY, Color("0d1620"))
	text.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_btn.add_child(text)


## 可点击的文字：命中框贴着字、手型光标、左键回调（必须标记已处理，
## 否则会漏到 main.gd 被「过场中点一下跳过」接走——主菜单踩过的坑）
func _clicky(text: String, at: Vector2, on_click: Callable) -> Label:
	var label := CWStyle.label(text, CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
	label.position = at
	label.mouse_filter = Control.MOUSE_FILTER_STOP
	label.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	label.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			get_viewport().set_input_as_handled()
			on_click.call())
	add_child(label)
	return label


func _tap(row: int, dir: int) -> void:
	_sel = row
	_cycle(row, dir)


func _px20() -> FontVariation:
	var fv := FontVariation.new()
	fv.base_font = CWStyle.FONT
	fv.spacing_glyph = 2
	return fv


# ============ 呈现 ============

func _value_text(i: int) -> String:
	match i:
		ROW_PLAYERS:
			if _faction < 0:
				return "%d 人（AI × %d）" % [_players, _players]
			@warning_ignore("integer_division")
			var half := _players / 2
			return "%d 人（%d 免疫 · %d 癌症）" % [_players, half, half]
		ROW_FACTION:
			if _faction < 0:
				return "观战"
			return "免疫细胞" if _faction == CWData.Faction.IMMUNE else "癌细胞"
		ROW_SMART:
			return "较强" if _smart else "普通"
		ROW_SEED:
			return str(_seed)
	return ""


func _repaint() -> void:
	for i in N_ROWS:
		var on := i == _sel
		_name_labels[i].add_theme_color_override("font_color",
			Color.WHITE if on else ROW_LABEL)
		var value: Label = _value_labels[i]
		value.text = _value_text(i)
		value.add_theme_color_override("font_color",
			Color.WHITE if on else CWStyle.TEXT_HI)
		## 拨值箭头只在焦点行亮出来；› 跟在值的右边（值宽随文案变）
		var left: Label = _arrows[i][0]
		var right: Label = _arrows[i][1]
		left.visible = on
		right.visible = on
		left.add_theme_color_override("font_color", CWStyle.IMMUNE)
		right.add_theme_color_override("font_color", CWStyle.IMMUNE)
		right.position.x = VALUE_X + value.get_minimum_size().x + 10
	## 菱形标跟着焦点走：行上贴行首，按钮上贴按钮左侧（按钮底色不变，见头注）
	if _sel < N_ROWS:
		_marker.position = Vector2(SLOT_X - 18, ROW_Y0 + _sel * ROW_H + 13)
	else:
		_marker.position = Vector2(SLOT_X - 18, BTN_Y + BTN_H / 2.0)
