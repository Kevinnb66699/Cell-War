## log_panel.gd —— 对局日志面板：L 键开关的左侧浮层，给 game.logs 开一扇窗
##
## 设计稿见「界面小块」画布（2026-08-29）。引擎日志本就全量记在 game.logs，
## 这里只做展示：定长的 Label 池 + 一个「离底部多远」的偏移，每帧把窗口里的
## 行铺上去（同棋盘的每帧全量刷：text 没变时 Label 直接返回，代价接近零）。
##
## 盖在棋盘左半（那一侧信息密度低），不遮右栏与行动栏。滚轮翻页；
## 偏移 0 = 跟着最新行走，往上翻过就停在原地，再滚回底部才继续跟。
##
## **一条日志可能占好几行**：原来是定高单行 Label + `TRIM_ELLIPSIS`，
## 「免疫A（免疫细胞）经由【基因表达】抽到【永久】LFA-1黏附」这种长行会被截成省略号，
## 而被截掉的恰恰是**抽到了什么牌**。所以先按面板宽度把每条日志折成若干「显示行」，
## 再拿显示行去铺 Label 池 —— 面板本来就是按「行」翻页的，折完照旧翻。
class_name CWLogPanel
extends Control

const RECT := Rect2(16, 16, 340, 460)
const PAD := 12
const TITLE_H := 28
const LINE_H := 19       ## 10px 字 + 行距（设计稿）
const FOOTER_H := 20
const SCROLL_STEP := 3   ## 滚轮一格翻几行

var active := false      ## 对局进行中才响应 L（同 CWPauseMenu.active 的语法）

var _lines: Array[Label] = []
var _offset := 0         ## 离底部多少显示行；0 = 跟随最新
## 折行后的显示行，以及每行来自第几条日志（着色跟源日志走，不看折行后的行首）。
## 日志是只增的，所以按「已折到第几条」增量补，不用每帧重折。
var _rows: Array[String] = []
var _row_src: Array[int] = []
var _built := 0
var _thumb: ColorRect
var _track: ColorRect
var _visible_n := 0
## 热座（2026-09-05）：filter 开着时按 viewer 的视角显示 —— 别人的秘密行（抽到什么牌）换成引擎记的公开替身
## `log_public`，与联机 CWNet.logs_for 同一口径；viewer = -1 是换手期间的「无人视角」，全部秘密行都换。
## 单人局 filter 关，行为与从前完全一样（仍看得到 AI 抽的牌名，要不要收另议）。
var filter := false
var viewer := -1
var _built_key := -3      ## 上次折行时的 (filter, viewer) 组合；变了就整卷重折


func _ready() -> void:
	position = RECT.position
	size = RECT.size
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP   ## 面板要挡住底下棋盘的点击/悬停

	var bg := Panel.new()
	bg.add_theme_stylebox_override("panel", CWStyle.box(0.45, CWStyle.BTN_BG))
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var title := CWStyle.label("对局日志", CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
	title.position = Vector2(PAD, PAD - 2)
	add_child(title)
	## 标题行右侧的 L 键帽（行动栏数字键同款垫块，定尺寸建成即知大小）：
	## 钉右缘，对 20px 标题的字形带中心垂直居中——标题 y=PAD-2、ascent 22、
	## 字形带 20px，带中心 = PAD-2+22-10 = PAD+10
	var key := CWStyle.keycap("L")
	key.name = "KeyCap"
	key.position = Vector2(RECT.size.x - PAD - key.size.x, PAD + 10 - key.size.y / 2.0)
	add_child(key)

	## 行池：能摆多少行就建多少个 Label，之后只改 text/颜色
	_visible_n = int((RECT.size.y - PAD * 2 - TITLE_H - FOOTER_H) / LINE_H)
	for i in _visible_n:
		var l := CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT)
		l.position = Vector2(PAD, PAD + TITLE_H + i * LINE_H)
		l.size = Vector2(RECT.size.x - PAD * 2 - 10, LINE_H)
		## clip_text 留着只当兜底（单个字就比行宽还宽这种病态情况），
		## 正常长行已经在 wrap_line() 里折过了，不会走到截断
		l.clip_text = true
		add_child(l)
		_lines.append(l)

	_track = ColorRect.new()
	_track.color = Color(CWStyle.LINE, 0.15)
	_track.position = Vector2(RECT.size.x - PAD + 4, PAD + TITLE_H)
	_track.size = Vector2(4, _visible_n * LINE_H)
	_track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_track)
	_thumb = ColorRect.new()
	_thumb.color = Color(CWStyle.LINE, 0.6)
	_thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_thumb)

	var hint := CWStyle.label("滚轮翻页 · 新行自动跟到底 · 再按 L 收起",
		CWStyle.SIZE_LABEL, CWStyle.TEXT_OFF)
	hint.position = Vector2(PAD, RECT.size.y - PAD - 12)
	add_child(hint)


## 对局中随时可按 L 开关；面板开着时滚轮翻页（滚轮事件从 gui_input 进不来，
## 因为行 Label 都不吃鼠标，所以统一在这里收）
func _unhandled_input(event: InputEvent) -> void:
	if not active:
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_L:
		get_viewport().set_input_as_handled()
		toggle()
		return
	if not visible or not (event is InputEventMouseButton) or not event.pressed:
		return
	if not get_rect().has_point(event.position):
		return   ## 只有指着面板滚才翻页，别把别处的滚轮吃掉
	if event.button_index == MOUSE_BUTTON_WHEEL_UP:
		get_viewport().set_input_as_handled()
		_scroll(SCROLL_STEP)
	elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		get_viewport().set_input_as_handled()
		_scroll(-SCROLL_STEP)


## 开/关面板。L 键与左上角入口提示（CWLogHint）共用这一条路，
## 开合时回到跟随最新行——上次翻到哪儿早就过时了。
func toggle() -> void:
	visible = not visible
	_offset = 0


func _scroll(delta_lines: int) -> void:
	_offset += delta_lines   ## refresh 里按当前总行数钳位（这里拿不到 game）


## 每帧由 CWMatch 调。窗口起点是纯函数（first_line），测试直接核对。
func refresh(game: CWGame) -> void:
	if not visible or game == null:
		return
	_rebuild_rows(game)
	var total := _rows.size()
	_offset = clampi(_offset, 0, maxi(total - _visible_n, 0))
	var first := first_line(total, _visible_n, _offset)
	for i in _visible_n:
		var idx := first + i
		if idx >= total or idx < 0:
			_lines[i].text = ""
			continue
		_lines[i].text = _rows[idx]
		## 着色看**源日志**的行首，不看折行后的续行（续行以缩进开头，
		## 直接喂给 line_color 会被当成「细节行」而变灰）
		_lines[i].add_theme_color_override("font_color",
			line_color(game.logs[_row_src[idx]]))
	## 滑块：高度按可见比例、位置按窗口在整卷里的位置
	var frac := 1.0 if total <= _visible_n else float(_visible_n) / total
	var h := maxf(_track.size.y * frac, 12.0)
	var span := _track.size.y - h
	var t := 0.0 if total <= _visible_n \
		else float(first) / float(total - _visible_n)
	_thumb.position = Vector2(_track.position.x, _track.position.y + span * t)
	_thumb.size = Vector2(4, h)


## 把新增的日志折成显示行。日志只增不改，所以只折没折过的那几条；
## 万一变短了（重开一局、快照回滚）就整卷重折。
func _rebuild_rows(game: CWGame) -> void:
	var key := viewer if filter else -2
	if game.logs.size() < _built or key != _built_key:
		_rows.clear()
		_row_src.clear()
		_built = 0
		_built_key = key
	if game.logs.size() == _built:
		return
	var w: float = _lines[0].size.x if not _lines.is_empty() \
		else RECT.size.x - PAD * 2 - 10
	while _built < game.logs.size():
		for seg in wrap_line(line_text(game, _built), w):
			_rows.append(seg)
			_row_src.append(_built)
		_built += 1


## 第 i 条日志在当前视角下显示成什么。**纯函数**（只读 game 与本节点两个开关），测试直接核对。
func line_text(game: CWGame, i: int) -> String:
	if not filter or i >= game.log_secret.size():
		return game.logs[i]
	var who: int = game.log_secret[i]
	if who < 0 or who == viewer:
		return game.logs[i]
	return game.log_public[i]


## 把一条日志按像素宽折成若干段。**纯函数，测试直接核对。**
##
## 逐字累加宽度而不是按空格断词：日志正文是中文，没有空格可断；
## 续行加两个半角空格的缩进，让人一眼看出「这是上一行的接续」而不是新的一条。
static func wrap_line(s: String, max_w: float) -> PackedStringArray:
	var out := PackedStringArray()
	if s.is_empty():
		out.append("")
		return out
	const INDENT := "  "
	var indent_w: float = CWStyle.FONT.get_string_size(
		INDENT, HORIZONTAL_ALIGNMENT_LEFT, -1, CWStyle.SIZE_LABEL).x
	var cur := ""
	var cur_w := 0.0
	var limit := max_w
	for i in s.length():
		var ch := s[i]
		var cw: float = CWStyle.FONT.get_string_size(
			ch, HORIZONTAL_ALIGNMENT_LEFT, -1, CWStyle.SIZE_LABEL).x
		## 一个字都放不下就单独占一行，否则这里会死循环
		if cur_w + cw > limit and not cur.is_empty():
			out.append(cur)
			cur = INDENT + ch
			cur_w = indent_w + cw
			limit = max_w
		else:
			cur += ch
			cur_w += cw
	out.append(cur)
	return out


func hide_now() -> void:
	visible = false
	_offset = 0


## 窗口里第一行的下标：offset = 离底部多少行。**行 = 折行后的显示行**。纯函数，测试用。
static func first_line(total: int, lines: int, offset: int) -> int:
	return maxi(total - lines - offset, 0)


## 行着色跟着引擎日志的前缀语法走：▶ 回合头 / ★ 升级 / ☠ 死亡 / 缩进 = 细节。
## 纯函数，测试用。
static func line_color(s: String) -> Color:
	if s.begins_with("▶") or s.begins_with("==="):
		return CWStyle.TEXT_HI
	if s.begins_with("★"):
		return CWStyle.IMMUNE
	if s.begins_with("☠"):
		return CWStyle.CANCER
	if s.begins_with("　") or s.begins_with("（"):
		return CWStyle.TEXT_DIM
	return CWStyle.TEXT
