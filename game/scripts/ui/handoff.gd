## handoff.gd —— 热座换手遮罩：从一位真人切到另一位真人时，先把电脑「交出去」再露牌
##
## 为什么要有它：一台电脑轮流玩（本地多人），A 结束回合后屏幕立刻就是 B 的手牌，A 顺手就能看见。
## 遮罩只遮**私密信息**（手牌、待决选项、日志里别人的牌名），棋盘是明盘不遮 —— 桌游本来就是明盘。
##
## 谁来判定「该换手了」：CWUIBridge._ask_human —— 某次询问轮到的席位是真人、且不是上一位露过牌的真人。
## 复活选落点、抽卡中途选择都走同一个 ask()，自动覆盖；AI 席位的回合之间不弹；连续两个 AI 之后再轮到真人才弹一次。
## 本节点只管演：卡片、按钮、键盘确认、入场出场动画。判定与手牌/日志的收放在桥和 CWMatch 里。
##
## 节拍全部取自现有常量，不新造：遮罩 0.2s（CWOnlinePanel.PAGE_FADE）、卡片淡入 + 上浮 8px 0.22s
## （CWSettleScreen.T_ROW / LIFT）、标题辉光 1.8s 一呼一吸、按钮悬停转白 + 50% 白光 + 上浮 3px（CWConfigPanel 的「进入棋盘」）。
## **Esc 无效、中途点击不快进** —— 隐私不是演出，不能跳过（与结算屏「任意点击到位」相反，故意的）。
class_name CWHandoff
extends Control

## 玩家点了「开始回合」或按了 Enter / 空格；hide_now() 也发它，好让等在 pass_to 上的桥醒过来
signal confirmed

const CARD_W := 380.0
const CARD_H := 206.0
const SCRIM_ALPHA := 0.62
const T_SCRIM := 0.2        ## = CWOnlinePanel.PAGE_FADE
const T_CARD := 0.22        ## = CWSettleScreen.T_ROW
const LIFT := 8.0           ## = CWSettleScreen.LIFT（取偶数：20px 字号下 1 字模像素 = 2 屏幕像素）
const T_OUT := 0.15         ## 确认后卡片淡出 + 微放大
const OUT_SCALE := 1.03
const BREATHE := 1.8        ## 标题辉光一呼一吸的周期
const BTN_W := 182.0        ## 与「进入棋盘」同尺寸
const BTN_H := 38.0
const BTN_LIFT := 3.0
const PULSE_PERIOD := 1.8   ## 该玩家细胞脚下阵营色光环的周期；CWMatch 每帧读 pulse() 画进 marks
const INVALID := Vector2i(9999, 9999)   ## cell_pos 的「没有细胞可指」

var active := false                     ## 正在等玩家确认（含入场动画）；出场动画期间已是 false
var cell_pos: Vector2i = INVALID        ## 该玩家细胞所在格；开局布置阶段还没落子 = INVALID
var faction_color: Color = CWStyle.IMMUNE

var _scrim: ColorRect
var _card: Control
var _card_base_y := 0.0
var _bar: ColorRect
var _eyebrow: Label
var _glow: Control
var _title: Label       ## 「轮到 」
var _name: Label        ## 席位名，阵营色
var _hint1: Label
var _hint2: Label
var _marker: Node2D
var _marker_core: ColorRect
var _marker_halo: Sprite2D
var _btn: Panel
var _btn_rest: StyleBoxFlat
var _btn_hot: StyleBoxFlat
var _btn_hover := false
var _tween: Tween
var _breath: Tween
var _t0 := 0.0          ## 开演时刻（秒），pulse() 用


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP   ## 遮罩期间吃掉一切点击：棋盘 / 手牌 / 行动栏都碰不到
	visible = false
	_build()


## 开演并等玩家确认。返回时出场动画已经在跑（不等它跑完 —— 手牌飞入要和它重叠）。
##   pid / faction / seat_name   谁的回合（席位名就是引擎 players[].name，「免疫A」这种）
##   at   该玩家细胞所在格，没有就传 INVALID（开局布置阶段）
func pass_to(_pid: int, faction: int, seat_name: String, at: Vector2i) -> void:
	faction_color = CWStyle.IMMUNE if faction == CWData.Faction.IMMUNE else CWStyle.CANCER
	cell_pos = at
	_name.text = seat_name
	_name.add_theme_color_override("font_color", faction_color)
	_name.position.x = _title.position.x + CWStyle.FONT.get_string_size(
		_title.text, HORIZONTAL_ALIGNMENT_LEFT, -1, CWStyle.SIZE_BIG).x
	for layer in _glow.get_children():
		(layer as Label).text = _title.text + seat_name
	_bar.color = faction_color
	_marker_core.color = faction_color
	_marker_halo.modulate = faction_color
	_btn_hover = false
	_paint_btn()
	active = true
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	_t0 = Time.get_ticks_msec() / 1000.0
	## 入场：遮罩淡入 0.2s；卡片淡入 + 上浮 8px 0.22s（结算屏的手感）
	_kill_tweens()
	_scrim.color.a = 0.0
	_card.modulate.a = 0.0
	_card.scale = Vector2.ONE
	_card.position.y = _card_base_y + LIFT
	_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_scrim, "color:a", SCRIM_ALPHA, T_SCRIM)
	_tween.parallel().tween_property(_card, "modulate:a", 1.0, T_CARD)
	_tween.parallel().tween_property(_card, "position:y", _card_base_y, T_CARD)
	## 标题辉光呼吸：告诉玩家「在等你」
	_breath = create_tween().set_loops().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_breath.tween_property(_glow, "modulate:a", 1.0, BREATHE / 2.0).from(0.55)
	_breath.tween_property(_glow, "modulate:a", 0.55, BREATHE / 2.0)
	await confirmed
	if not active:
		return          ## hide_now() 收掉的：拆局，不演出场
	active = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE   ## 立刻放行点击，别让玩家等 0.2s 才能碰棋盘
	_kill_tweens()
	_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_card, "modulate:a", 0.0, T_OUT)
	_tween.parallel().tween_property(_card, "scale", Vector2.ONE * OUT_SCALE, T_OUT)
	_tween.parallel().tween_property(_scrim, "color:a", 0.0, T_SCRIM)
	_tween.tween_callback(func() -> void:
		visible = false
		_card.scale = Vector2.ONE)


## 玩家确认（点按钮 / Enter / 空格）。不在等的时候按了不算。
func confirm() -> void:
	if not active:
		return
	confirmed.emit()


## 拆局 / 重开：不演出场，直接收干净，并放掉等在 pass_to 上的桥。
func hide_now() -> void:
	var was_active := active
	active = false
	_kill_tweens()
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	_card.scale = Vector2.ONE
	cell_pos = INVALID
	if was_active:
		confirmed.emit()


## 0~1 的呼吸值（正弦），CWMatch 拿它给该玩家细胞脚下的阵营色光环定 alpha
func pulse() -> float:
	var t := Time.get_ticks_msec() / 1000.0 - _t0
	return 0.5 + 0.5 * sin(TAU * t / PULSE_PERIOD)


func _unhandled_input(event: InputEvent) -> void:
	if not active:
		return
	if event.is_action_pressed("ui_accept"):
		get_viewport().set_input_as_handled()
		confirm()


func _kill_tweens() -> void:
	for tw in [_tween, _breath]:
		if tw != null and tw.is_valid():
			tw.kill()
	_tween = null
	_breath = null
	_glow.modulate.a = 1.0


# ============ 搭建 ============

func _build() -> void:
	var screen := get_viewport_rect().size if is_inside_tree() else Vector2(960, 540)
	if screen.x <= 0.0 or screen.y <= 0.0:
		screen = Vector2(960, 540)
	_scrim = ColorRect.new()
	_scrim.color = Color(CWStyle.GROUND, 0.0)
	_scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_scrim)

	_card = Control.new()
	_card.size = Vector2(CARD_W, CARD_H)
	_card.pivot_offset = _card.size / 2.0
	_card_base_y = floorf((screen.y - CARD_H) / 2.0)
	_card.position = Vector2(floorf((screen.x - CARD_W) / 2.0), _card_base_y)
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_card)

	## 卡片底：面板底色 + 描边，圆角 6（暂停菜单 / 结算屏同一套）
	var bg := Panel.new()
	var box := CWStyle.box(0.42, Color(CWStyle.PANEL, 0.96))
	box.set_corner_radius_all(6)
	bg.add_theme_stylebox_override("panel", box)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(bg)
	## 左侧阵营色竖条，呼应右栏玩家列表的色条
	_bar = ColorRect.new()
	_bar.position = Vector2(2, 2)
	_bar.size = Vector2(4, CARD_H - 4)
	_bar.color = CWStyle.IMMUNE
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(_bar)

	## 眉题：同配置面板的 SETUP（px20 变体 + 青色）
	_eyebrow = CWStyle.label("HOT SEAT · 换手", CWStyle.SIZE_BODY, CWStyle.IMMUNE)
	var fv := FontVariation.new()
	fv.base_font = CWStyle.FONT
	fv.spacing_glyph = 2
	_eyebrow.add_theme_font_override("font", fv)
	_eyebrow.position = Vector2(28, 18)
	_card.add_child(_eyebrow)

	## 标题辉光（CWPauseMenu.GLOW 四层白描边，压在文字底下）
	_glow = Control.new()
	_glow.position = Vector2(56, 50)
	_glow.size = Vector2(300, 36)
	_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(_glow)
	for layer in CWPauseMenu.GLOW:
		var g := CWStyle.label("", CWStyle.SIZE_BIG, Color(1, 1, 1, 0))
		g.add_theme_color_override("font_outline_color", Color(1, 1, 1, layer[1]))
		g.add_theme_constant_override("outline_size", layer[0])
		g.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_glow.add_child(g)
	_title = CWStyle.label("轮到 ", CWStyle.SIZE_BIG, CWStyle.TEXT_HI)
	_title.position = Vector2(56, 50)
	_card.add_child(_title)
	_name = CWStyle.label("", CWStyle.SIZE_BIG, CWStyle.IMMUNE)
	_name.position = Vector2(56, 50)
	_card.add_child(_name)

	## 菱形焦点标 + 径向光晕（参数照抄配置面板 / 主菜单那一颗，颜色换阵营色）
	_marker = Node2D.new()
	_marker.position = Vector2(37, 69)
	var halo_grad := Gradient.new()
	halo_grad.offsets = PackedFloat32Array([0.0, 0.34, 1.0])
	halo_grad.colors = PackedColorArray([Color(1, 1, 1, 0.44), Color(1, 1, 1, 0.2), Color(1, 1, 1, 0.0)])
	var halo_tex := GradientTexture2D.new()
	halo_tex.gradient = halo_grad
	halo_tex.fill = GradientTexture2D.FILL_RADIAL
	halo_tex.fill_from = Vector2(0.5, 0.5)
	halo_tex.fill_to = Vector2(1, 0.5)
	halo_tex.width = 48
	halo_tex.height = 48
	_marker_halo = Sprite2D.new()
	_marker_halo.texture = halo_tex
	_marker_halo.modulate = CWStyle.IMMUNE
	_marker.add_child(_marker_halo)
	_marker_core = ColorRect.new()
	_marker_core.position = Vector2(-7, -7)
	_marker_core.size = Vector2(14, 14)
	_marker_core.rotation = PI / 4
	_marker_core.pivot_offset = Vector2(7, 7)
	_marker_core.color = CWStyle.IMMUNE
	_marker_core.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_marker.add_child(_marker_core)
	_card.add_child(_marker)

	_hint1 = CWStyle.label("请把电脑交给这位玩家 · 其他人请回避", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	_hint1.position = Vector2(28, 98)
	_card.add_child(_hint1)
	_hint2 = CWStyle.label("手牌与日志里的牌名在你点开始之前不会显示", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	_hint2.position = Vector2(28, 116)
	_card.add_child(_hint2)

	## 「开始回合」：与「进入棋盘」同一套 —— 青底深字；悬停转白 + 50% 白光 + 上浮 3px
	_btn_rest = _btn_box(CWStyle.IMMUNE, 0.0)
	_btn_hot = _btn_box(Color.WHITE, 0.5)
	_btn = Panel.new()
	_btn.position = Vector2(28, 146)
	_btn.size = Vector2(BTN_W, BTN_H)
	_btn.add_theme_stylebox_override("panel", _btn_rest)
	_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_btn.mouse_entered.connect(func() -> void:
		_btn_hover = true
		_paint_btn())
	_btn.mouse_exited.connect(func() -> void:
		_btn_hover = false
		_paint_btn())
	_btn.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			get_viewport().set_input_as_handled()
			confirm())
	_card.add_child(_btn)
	var text := CWStyle.label("开始回合", CWStyle.SIZE_BODY, Color("0d1620"))
	text.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_btn.add_child(text)

	## 键位提示：Enter / 空格 都能确认
	var caps := HBoxContainer.new()
	caps.position = Vector2(226, 158)
	caps.add_theme_constant_override("separation", 4)
	caps.mouse_filter = Control.MOUSE_FILTER_IGNORE
	caps.add_child(CWStyle.keycap("Enter"))
	caps.add_child(CWStyle.label("/", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM))
	caps.add_child(CWStyle.keycap("空格"))
	_card.add_child(caps)


func _paint_btn() -> void:
	_btn.add_theme_stylebox_override("panel", _btn_hot if _btn_hover else _btn_rest)
	_btn.position.y = 146.0 - (BTN_LIFT if _btn_hover else 0.0)


## 实心按钮的底：圆角 5；hot 版转白并带一圈白光（CWConfigPanel._btn_box 同款）
func _btn_box(bg: Color, glow: float) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = bg
	b.set_corner_radius_all(5)
	if glow > 0.0:
		b.shadow_color = Color(1, 1, 1, glow)
		b.shadow_size = 10
	return b
