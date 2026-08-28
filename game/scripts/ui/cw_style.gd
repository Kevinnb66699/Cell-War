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

# ---- 字号（只有三档，见设计稿「右侧竖条 · 尺寸与字号」）----
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


## 无描边的垫块：只有底色和内边距。快捷键数字那种小标记用。
static func plate(bg: Color, pad_v: int, pad_h: int) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = bg
	b.set_border_width_all(0)
	b.content_margin_top = pad_v
	b.content_margin_bottom = pad_v
	b.content_margin_left = pad_h
	b.content_margin_right = pad_h
	return b


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
