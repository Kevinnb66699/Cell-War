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
##
## **自定义对局**（2026-09-03 Kevin）：主菜单「自定义对局」打开的是同一张面板（`custom = true`），
## 四行之后多出「癌症A/B/C 种类」几行（随人数 1 / 2 / 3 行），每行在「随机」与四种癌之间拨、
## 不同席位不许选同一种；cfg 多一项 `cancer_types`（按癌席顺序，-1 = 随机）→ CWTuning.cancer_types。
## 七行 + 按钮放不进 42 的行距，自定义模式行距压到 32、按钮贴在最后一行下方；普通模式一个像素不动。
class_name CWConfigPanel
extends Control

## cfg = { players: 2/4/6, faction: CWData.Faction 或 -1（观战）, smart: bool, seed: int,
##         cancer_types: Array（自定义对局：按癌席顺序的 CWData.CancerType，-1 = 随机；普通对局为空表）}
signal confirmed(cfg: Dictionary)
## Esc 退回：主菜单收到后把自己淡回来
signal cancelled

const SLOT_X := 120.0        ## 槽位左缘（眉题/标题/标签/按钮共用，原型 12.5cqw）
const VALUE_X := 250.0       ## 值那一列（原型 26cqw）
## 右拨值箭头**固定横坐标**，在最长值文案（4 人（2 免疫 · 2 癌症））右侧——
## 跟着字宽跑的话，换一档箭头挪一次，玩家没法停在原地连点（Kevin 8-30）
const ARROW_R_X := 500.0
const ROW_Y0 := 251.0        ## 第一行的纵坐标
const ROW_H := 42.0          ## 行距（和主菜单项一致）
const BTN_Y := 438.0
const BTN_W := 182.0
const BTN_H := 38.0
const FADE_IN := 0.32        ## 原型节拍：菜单 0.30s 淡出后，配置 0.32s 淡入

## 原型的行文字色（比 TEXT_DIM 亮半档，值列用 TEXT_HI）
const ROW_LABEL := Color("9fb6bd")
## 「进入棋盘」的变白（白底+白光+上浮 3px）跟着**最后动的输入设备**走
## （Kevin 2026-08-30 终稿）：键盘选到按钮 = 变白；鼠标一旦划过，
## 颜色就按悬停状态算（悬停白、移开蓝），直到下一次键盘按键夺回焦点权。
const BTN_LIFT := 3.0

const ROW_NAMES := ["人数", "我的阵营", "AI 强度", "随机种子"]
const ROW_PLAYERS := 0
const ROW_FACTION := 1
const ROW_SMART := 2
const ROW_SEED := 3
const N_ROWS := 4
const PLAYER_STEPS := [2, 4, 6]
const FACTION_STEPS := [CWData.Faction.IMMUNE, CWData.Faction.CANCER, -1]
## 自定义对局：癌种行（最多 3 行 = 6 人局的三个癌席）。行距 32 才放得下 7 行 + 按钮（251 + 7×32 + 18 = 493，按钮底 531 < 540）
const ROW_H_CUSTOM := 32.0
const BTN_GAP := 18.0
const CANCER_ROW_MAX := 3
const CANCER_STEPS := [-1, CWData.CancerType.MELANOMA, CWData.CancerType.SIGNET,
	CWData.CancerType.OSTEO, CWData.CancerType.SCLC]

var _players := 4
var _faction: int = CWData.Faction.IMMUNE   ## -1 = 观战
var _smart := false
var _seed := 0
## 自定义对局开关：主菜单在 open() 之前拨；普通对局 false（癌种行全部收起、按钮在 438）
var custom := false
var _ctypes: Array = [-1, -1, -1]   ## 癌症A/B/C 的钉死癌种（-1 = 随机），局间保留
var _eyebrow: Label
var _title: Label
var _hits: Array[Control] = []

var _sel := N_ROWS           ## 焦点：0..3 = 行，N_ROWS = 「进入棋盘」
var _name_labels: Array[Label] = []
var _value_labels: Array[Label] = []
var _arrows: Array = []      ## [[‹, ›], ...]；› 的横坐标随值宽变，_repaint 里摆
var _marker: Node2D          ## 菱形焦点标（带光晕，和主菜单同一颗的做法）
var _glow: Control           ## 选中行标题的辉光（主菜单悬停那套四层白描边）
var _btn: Panel
var _btn_rest: StyleBoxFlat
var _btn_hot: StyleBoxFlat   ## 仅鼠标悬停：转白 + 白光（上浮在 _repaint 里挪位置）
var _btn_hover := false
var _back: Label             ## 「返回主菜单」链接：与 Esc 同一条路（2026-09-04 Kevin：两种配置页都要有鼠标出口）
var _hot_arrow: Label = null ## 正被鼠标悬停的拨值箭头；null = 没有
## 最后动的是不是鼠标——按钮变白的裁判（见文件头的焦点权规则）
var _mouse_led := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP   ## 整层接管：底下淡掉的菜单项收不到点击
	visible = false
	_seed = _roll_seed()
	_build()


func open() -> void:
	_sel = 0   ## 焦点落第一行，见文件头（停在按钮上会让玩家以为不能改）
	_eyebrow.text = "CUSTOM" if custom else "SETUP"
	_title.text = "自定义对局" if custom else "对局配置"
	_mouse_led = false
	_btn_hover = false   ## 上次关面板时悬停着的话，exited 可能没来得及送到
	visible = true
	modulate.a = 0.0
	create_tween().tween_property(self, "modulate:a", 1.0, FADE_IN)
	_repaint()


## 由 CWMainMenu 的 _unhandled_input 转发（覆盖层统一走菜单路由）
func handle_input(event: InputEvent) -> void:
	## 键盘一动就夺回焦点权（按钮变白从此按键盘焦点算，直到鼠标再介入）
	for act in ["ui_cancel", "ui_down", "ui_up", "ui_left", "ui_right", "ui_accept"]:
		if event.is_action_pressed(act):
			_mouse_led = false
			break
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_cancel()
	elif event.is_action_pressed("ui_down"):
		_sel = mini(_sel + 1, _n_rows())
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
		if _sel == _n_rows():
			_confirm()
		else:
			_cycle(_sel, 1)   ## 行上回车 = 往后拨一格（和点值一致）


func config() -> Dictionary:
	return { "players": _players, "faction": _faction, "smart": _smart, "seed": _seed,
		"cancer_types": _ctypes.slice(0, _n_cancer()) if custom else [] }


## 自定义模式下的几何：癌席数 = 人数一半；行数 = 4 + 癌席数；行距 32；按钮贴最后一行下方
func _n_cancer() -> int:
	@warning_ignore("integer_division")
	return _players / 2


func _n_rows() -> int:
	return N_ROWS + (_n_cancer() if custom else 0)


func _row_h() -> float:
	return ROW_H_CUSTOM if custom else ROW_H


func _row_y(i: int) -> float:
	return ROW_Y0 + i * _row_h()


func _btn_y() -> float:
	return ROW_Y0 + _n_rows() * ROW_H_CUSTOM + BTN_GAP if custom else BTN_Y


## 某个癌种是否已被**另一席**（只算当前人数下露出来的席位）选走
func _taken_elsewhere(t: int, k: int) -> bool:
	for j in _n_cancer():
		if j != k and _ctypes[j] == t:
			return true
	return false


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
	if row >= N_ROWS and row < _n_rows():
		## 癌种行：在「随机」与四种癌之间拨；别的席位已选走的种类跳过（同局不重复，说明 #12）
		var k := row - N_ROWS
		var i := CANCER_STEPS.find(_ctypes[k])
		for _step in CANCER_STEPS.size():
			i = (i + dir + CANCER_STEPS.size()) % CANCER_STEPS.size()
			var t: int = CANCER_STEPS[i]
			if t < 0 or not _taken_elsewhere(t, k):
				_ctypes[k] = t
				break
		_repaint()
		return
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
	_eyebrow = CWStyle.label("SETUP", CWStyle.SIZE_BODY, CWStyle.IMMUNE)
	_eyebrow.add_theme_font_override("font", _px20())
	_eyebrow.position = Vector2(SLOT_X, 127)
	add_child(_eyebrow)

	_title = CWStyle.label("对局配置", CWStyle.SIZE_BIG, CWStyle.TEXT_HI)
	_title.position = Vector2(SLOT_X, 160)
	add_child(_title)

	var rule := ColorRect.new()
	rule.position = Vector2(SLOT_X, 230)
	rule.size = Vector2(288, 1)
	rule.color = Color(CWStyle.LINE, 0.42)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(rule)

	_marker = _build_marker()
	add_child(_marker)

	## 选中行标题的辉光：全面板只备一份、跟着焦点行走（先建，压在文字底下——
	## 层数与 alpha 即 CWPauseMenu.GLOW，和主菜单悬停是同一套光）
	_glow = Control.new()
	_glow.size = Vector2(200, 28)
	_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_glow)
	for layer in CWPauseMenu.GLOW:
		var g := CWStyle.label("", CWStyle.SIZE_BODY, Color(1, 1, 1, 0))
		g.add_theme_color_override("font_outline_color", Color(1, 1, 1, layer[1]))
		g.add_theme_constant_override("outline_size", layer[0])
		g.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_glow.add_child(g)

	## 四行基础 + 三行癌种一次建齐；露几行、摆在哪由 _repaint 按模式定
	for i in N_ROWS + CANCER_ROW_MAX:
		_build_row(i)
	_build_button()


## 菱形焦点标 + 径向光晕：参数照抄 MainMenu.tscn 的 Marker（同一颗才像一家人）。
## 光晕用 Sprite2D（centered 默认开）——它天生以节点原点为中心画，
## 菱形和光晕的圆心必然重合；第一版用 TextureRect 摆负偏移，圆心跑到了右下角。
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
	halo_tex.width = 48
	halo_tex.height = 48
	var halo := Sprite2D.new()
	halo.texture = halo_tex
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
		_mouse_led = true
		_repaint())
	add_child(hit)
	_hits.append(hit)

	var row_name: String = ROW_NAMES[i] if i < N_ROWS else "癌症%s 种类" % char(65 + i - N_ROWS)
	var name_label := CWStyle.label(row_name, CWStyle.SIZE_BODY, ROW_LABEL)
	name_label.position = Vector2(SLOT_X, y)
	add_child(name_label)
	_name_labels.append(name_label)

	## 拨值箭头用 ASCII 的 < >（点阵字库没有 ‹ ›）；两枚都在**固定位置**，
	## 悬停时和菜单项一样亮起白光（_hot_arrow 记着谁在被悬停，_repaint 统一画）
	var left := CWStyle.clickable_label(self, "<", Vector2(VALUE_X - 22, y), func() -> void: _tap(i, -1))
	var value := CWStyle.clickable_label(self, "", Vector2(VALUE_X, y), func() -> void: _tap(i, 1))
	var right := CWStyle.clickable_label(self, ">", Vector2(ARROW_R_X, y), func() -> void: _tap(i, 1))
	for arrow: Label in [left, right]:
		arrow.mouse_entered.connect(func() -> void:
			_hot_arrow = arrow
			_mouse_led = true
			_repaint())
		arrow.mouse_exited.connect(func() -> void:
			if _hot_arrow == arrow:
				_hot_arrow = null
			_repaint())
	_value_labels.append(value)
	_arrows.append([left, right])


func _build_button() -> void:
	_btn_rest = _btn_box(CWStyle.IMMUNE, 0.0)
	_btn_hot = _btn_box(Color.WHITE, 0.5)   ## 原型 .cbtn:hover：转白 + 50% 白光
	_btn = Panel.new()
	_btn.position = Vector2(SLOT_X, BTN_Y)
	_btn.size = Vector2(BTN_W, BTN_H)
	_btn.add_theme_stylebox_override("panel", _btn_rest)
	_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_btn.mouse_entered.connect(func() -> void:
		_btn_hover = true
		_mouse_led = true
		_sel = _n_rows()
		_repaint())
	_btn.mouse_exited.connect(func() -> void:
		_btn_hover = false
		_mouse_led = true
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
	## 「返回主菜单」（2026-09-04 Kevin 要的，联机连接页已有同款）：按钮右侧 200、同一行；
	## 悬停转白发光（和拨值箭头 / 联机链接同一套语言），点击走 Esc 那条路。自定义模式随按钮下移（_repaint）
	_back = CWStyle.clickable_label(self, "返回主菜单", Vector2(SLOT_X + 200, BTN_Y + 5), _cancel)
	_back.mouse_entered.connect(func() -> void: _link_hot(true))
	_back.mouse_exited.connect(func() -> void: _link_hot(false))


func _link_hot(hot: bool) -> void:
	_back.add_theme_color_override("font_color", Color.WHITE if hot else CWStyle.TEXT_HI)
	_back.add_theme_color_override("font_outline_color", Color(1, 1, 1, 0.5))
	_back.add_theme_constant_override("outline_size", 8 if hot else 0)


## 收面板退回主菜单：Esc 与「返回主菜单」链接共用；主菜单收到 cancelled 后把自己淡回来
func _cancel() -> void:
	visible = false
	cancelled.emit()


## 实心按钮的底：圆角 5（原型 .5cqw）；hot 版转白并带一圈白光
func _btn_box(bg: Color, glow: float) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = bg
	b.set_corner_radius_all(5)
	if glow > 0.0:
		b.shadow_color = Color(1, 1, 1, glow)
		b.shadow_size = 10
	return b


func _tap(row: int, dir: int) -> void:
	_sel = row
	_mouse_led = true
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
	if i >= N_ROWS and i - N_ROWS < CANCER_ROW_MAX:
		var t: int = _ctypes[i - N_ROWS]
		return "随机" if t < 0 else CWData.CANCER_TYPE_NAMES[t]
	return ""


func _repaint() -> void:
	var n := _n_rows()
	_sel = mini(_sel, n)   ## 人数拨少了，焦点可能停在已收起的癌种行上
	for i in _name_labels.size():
		var shown := i < n
		var on := shown and i == _sel
		var y := _row_y(i)
		_name_labels[i].visible = shown
		_name_labels[i].position = Vector2(SLOT_X, y)
		_name_labels[i].add_theme_color_override("font_color",
			Color.WHITE if on else ROW_LABEL)
		_hits[i].visible = shown
		_hits[i].position = Vector2(SLOT_X - 30, y - 8)
		_hits[i].size = Vector2(420, _row_h() - 4)
		var value: Label = _value_labels[i]
		value.visible = shown
		value.position = Vector2(VALUE_X, y)
		value.text = _value_text(i)
		value.add_theme_color_override("font_color",
			Color.WHITE if on else CWStyle.TEXT_HI)
		## 拨值箭头只在焦点行亮出来；位置固定不随字宽跑（见 ARROW_R_X）。
		## 被悬停的那枚转白发光——和菜单项同一套「字亮起来」的语言
		for arrow: Label in _arrows[i]:
			arrow.position.y = y
			arrow.visible = on
			var hovering := arrow == _hot_arrow
			arrow.add_theme_color_override("font_color",
				Color.WHITE if hovering else CWStyle.IMMUNE)
			arrow.add_theme_color_override("font_outline_color", Color(1, 1, 1, 0.5))
			arrow.add_theme_constant_override("outline_size", 8 if hovering else 0)
	## 选中行标题的辉光跟焦点走（在按钮上时收起——按钮有自己的高亮语言）
	_glow.visible = _sel < n
	if _sel < n:
		_glow.position = Vector2(SLOT_X, _row_y(_sel))
		for layer in _glow.get_children():
			(layer as Label).text = _name_labels[_sel].text
	## 菱形标跟着焦点走：行上贴行首，按钮上贴按钮左侧
	if _sel < n:
		_marker.position = Vector2(SLOT_X - 18, _row_y(_sel) + 13)
	else:
		_marker.position = Vector2(SLOT_X - 18, _btn_y() + BTN_H / 2.0)
	## 「进入棋盘」的变白按**最后动的设备**裁决（文件头的焦点权规则）：
	## 键盘当权 → 焦点在按钮上就白；鼠标当权 → 按悬停状态算
	var hot := _btn_hover if _mouse_led else _sel == n
	_btn.add_theme_stylebox_override("panel", _btn_hot if hot else _btn_rest)
	_btn.position = Vector2(SLOT_X, _btn_y() - (BTN_LIFT if hot else 0.0))
	_back.position = Vector2(SLOT_X + 200, _btn_y() + 5)
