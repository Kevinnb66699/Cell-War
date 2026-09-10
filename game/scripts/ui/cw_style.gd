## cw_style.gd —— 界面的配色、字体与控件样式
##
## 这些值全部取自团队定稿的界面设计稿。**改配色改字号只改这里**，
## 别在各个界面里各写一份 —— 上一版就是因为散着写，改一个色要翻五个文件。
##
## 字号只能取 10 的整数倍：正文字体是 10×10 的点阵，非整数倍会被重采样磨出灰边
## （架构约定 #13，来龙去脉见 assets/fonts/README.md）。
class_name CWStyle
extends RefCounted

# ---- 配色 ----
const GROUND := Color("141f2e")      ## 画布底
const PANEL := Color("0f1822")       ## 面板底
const BTN_BG := Color("0a1018e6")    ## 按钮底（半透明，压在棋盘上要能看见后面）
const IMMUNE := Color("30d1fa")      ## 免疫方 / 强调色
const CANCER := Color("ffb03a")      ## 癌方
const LINE := Color("3fa5b6")        ## 描边基色，实际用时带 alpha
const TEXT_HI := Color("eaf8fc")     ## 主要文字
const TEXT := Color("cfe2e6")        ## 常规文字
const TEXT_DIM := Color("7b929b")    ## 次要文字（字段名、费用、单位）
const TEXT_OFF := Color("5c737c")    ## 灰掉的文字
const TEXT_OFF_DIM := Color("44565e")## 灰掉的次要文字

# ---- 字号（只有四档，见设计稿「右侧竖条 · 尺寸与字号」）----
## 结算屏的胜负宣告。**一局只出现一次**，比回合数还大一档 ——
## 40 仍是 10 的整数倍，点阵不会被重采样磨出灰边（架构约定 #13）。
const SIZE_HERO := 40
const SIZE_BIG := 30                 ## 一屏只出现一次的主数值（回合数）
const SIZE_BODY := 20                ## 正文：玩家名 / 能量 / 按钮 / 提示
const SIZE_LABEL := 10               ## 标签：字段名 / 费用 / 种类 / 单位

const FONT := preload("res://assets/fonts/fusion_pixel_10px.ttf")


static func label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", FONT)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE   ## 文字不该挡住底下按钮的点击
	return l


## 可点击的文字：命中框贴着字、手型光标、左键回调。
## 必须在这里标记事件已处理，否则点击会漏到上层菜单，误触其「跳过过场」逻辑。
## 调用者仍自行决定位置、悬停反馈和焦点；这里只收口两个页面完全相同的输入底座。
static func clickable_label(parent: Control, text: String, at: Vector2,
		on_click: Callable) -> Label:
	var clickable := label(text, SIZE_BODY, TEXT_HI)
	clickable.position = at
	clickable.mouse_filter = Control.MOUSE_FILTER_STOP
	clickable.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	clickable.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			var viewport := clickable.get_viewport()
			if viewport != null:
				viewport.set_input_as_handled()
			on_click.call())
	parent.add_child(clickable)
	return clickable


## 焦点菱形：一颗免疫青的方块转 45 度 + 一圈径向光晕，摆在焦点行左边。
## 主菜单（MainMenu.tscn 里那颗）、配置面板、联机建房页、回放列表用的是同一颗。
##
## 参数照抄 MainMenu.tscn 的 Marker（同一颗才像一家人）。
## 光晕用 GradientTexture2D 而不是画描边：菱形只有 14px，描边会糊成一团小方块，
## 而三档渐变（0.44 → 0.2 → 0）在深底上读起来才像「亮起来了」。
## 而且必须挂 **Sprite2D**（centered 默认开，天生以节点原点为中心画，
## 菱形与光晕的圆心必然重合）—— 第一版用 TextureRect 摆负偏移，圆心跑到了右下角。
##
## 放这儿的理由同 clickable_label / link_hot：2026-09-10 之前配置面板与联机面板
## 各存了一份**逐字节相同**的拷贝，回放面板要用时差点又添第三份。
static func focus_marker() -> Node2D:
	var marker := Node2D.new()
	var halo_grad := Gradient.new()
	halo_grad.offsets = PackedFloat32Array([0.0, 0.34, 1.0])
	halo_grad.colors = PackedColorArray([Color(IMMUNE, 0.44),
		Color(IMMUNE, 0.2), Color(IMMUNE, 0.0)])
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
	core.color = IMMUNE
	core.mouse_filter = Control.MOUSE_FILTER_IGNORE
	marker.add_child(core)
	return marker


## 文字链接的悬停态：**转白 + 白光描边**（正文 8 / 小字 6），移开还原。
## 2026-09-03 Kevin 定的：联机各页也要有和主菜单一样的辉光。
##
## 静止色记在 `rest` meta 里 —— 列表是随时重画的，重画时直接写 font_color
## 会把正悬停着的那一行的白光盖掉（所以定静止色一律走 `paint_link`）。
##
## 放这儿而不是各面板自己写一份：2026-09-10 回放面板漏了辉光，一眼就跟
## 大厅那两栏不是一家人 —— 和 `clickable_label` 同一个理由（散着写就会漏）。
static func link_hot(label: Label, hot: bool) -> void:
	label.set_meta("hot", hot)
	if hot:
		if not label.has_meta("rest"):
			label.set_meta("rest", label.get_theme_color("font_color"))
		label.add_theme_color_override("font_color", Color.WHITE)
		label.add_theme_color_override("font_outline_color", Color(1, 1, 1, 0.5))
		label.add_theme_constant_override("outline_size",
			8 if label.get_theme_font_size("font_size") >= SIZE_BODY else 6)
	else:
		label.add_theme_color_override("font_color", label.get_meta("rest", TEXT_HI))
		label.add_theme_constant_override("outline_size", 0)


## 给链接定静止色：正在悬停就只记下来，等移开再生效
static func paint_link(label: Label, color: Color) -> void:
	label.set_meta("rest", color)
	if not label.get_meta("hot", false):
		label.add_theme_color_override("font_color", color)


## 无描边的垫块：只有底色和内边距。快捷键数字那种小标记用。
## 键盘上下选的下一格：**绕回**，并跳过 `ok(i)` 说不能停的那些。
##
## 三处在用（主菜单、暂停菜单、大厅房间列表），它们的「不能停」各不相同 ——
## 灰掉的菜单项 / 灰掉的暂停项 / 大厅里的分隔行 —— 但「绕一圈就收手」这条
## 一样，而写错它的后果是**死循环**（全灰时永远找不到落脚点）。所以收口在这儿。
##
## 绕满一圈还没有能停的（或只剩自己）就返回 from。
static func step_wrap(from: int, dir: int, n: int, ok := Callable()) -> int:
	if n <= 0 or dir == 0:
		return from
	var i := from
	for _k in n:
		i = posmod(i + dir, n)
		if not ok.is_valid() or ok.call(i):
			return i
	return from


static func plate(bg: Color, pad_v: int, pad_h: int) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = bg
	b.set_border_width_all(0)
	b.content_margin_top = pad_v
	b.content_margin_bottom = pad_v
	b.content_margin_left = pad_h
	b.content_margin_right = pad_h
	return b


## 快捷键标记：灰底垫块 + 比费用文字亮一档的字。行动栏的数字键与
## 「对局日志 L」共用这一份（试玩二轮定：全游戏快捷键提示统一这种底框）。
## **定尺寸 + 字形带手工对中**：这套点阵字的行框虚高（ascent 11 / descent 3，
## 行框 14 而字形只有 10px），交给行框去居中字必偏（试玩二轮报「L 不在正中」；
## 自动包字的 PanelContainer 还会把行框的空高一起包进去）。
static func keycap(text: String) -> Control:
	var cap := Panel.new()
	cap.add_theme_stylebox_override("panel", plate(Color(TEXT_DIM, 0.25), 0, 0))
	cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var glyph_w: float = FONT.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, SIZE_LABEL).x
	cap.size = Vector2(glyph_w + 6.0, 14.0)
	cap.custom_minimum_size = cap.size            ## 进 HBox（行动栏费用行）时不被拉扁
	cap.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	cap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var l := label(text, SIZE_LABEL, TEXT)
	## 字形带（数字/大写/汉字都是满高 10px）在行框里从 ascent-10 行开始：
	## 把这条带对中到 14 高的垫块里，上下各留 2
	l.position = Vector2(3.0, 2.0 - (FONT.get_ascent(SIZE_LABEL) - 10.0))
	cap.add_child(l)
	return cap


## 描边框：设计稿里所有面板/按钮都是 2px 单色描边，只有 alpha、底色和内边距不同。
## pad 对应设计稿的 padding，**不给默认值就是 0，边框会直接贴着字**（踩过）。
static func box(border_alpha: float, bg: Color = BTN_BG,
		pad_v: int = 0, pad_h: int = 0) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = bg
	b.border_color = Color(LINE, border_alpha)
	b.set_border_width_all(2)
	b.content_margin_top = pad_v
	b.content_margin_bottom = pad_v
	b.content_margin_left = pad_h
	b.content_margin_right = pad_h
	return b
