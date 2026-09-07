## log_hint.gd —— 左上角「对局日志 L」常驻入口 + **迷你日志**（Kevin 2026-09-06 定方案 A）
##
## 入口提示原地长成 300×52 的条：标题行「对局日志 L」+ 日志尾巴两行（折行后的显示行），
## 别人回合里发生的每一步都会从这里滚过去，不用按 L。**不压棋盘顶行**（棋盘顶边在 y=75，条底 68）——
## Kevin 看方案预览图时提的：日志框不要太靠下、别挡棋盘。视角过滤与折行、着色都复用 CWLogPanel 的纯函数，
## 数据同一份（game.logs），新行淡入。
##
## 钉在日志面板将来展开的那个角上（CWLogPanel.RECT.position）：按 L 或点这条提示，
## 面板就从提示所在的位置长出来、盖掉提示——「提示在哪，面板就在哪」，空间上自洽；
## 观战和亲手打都常驻可见（另一候选「右栏底部」会和「结束回合」按钮挤在一起）。
## 显隐归 CWMatch 管（开局亮、面板开着让位、拆局收起），这里只画外观、收点击。
class_name CWLogHint
extends Control

signal pressed   ## 点提示 = 按 L（CWMatch 把它接到 CWLogPanel.toggle）

const SIZE := Vector2(300, 52)
const ROWS := 2               ## 日志尾巴几行（折行后的显示行）
const ROW_Y := 21.0           ## 第一行日志的 y；标题行在 5
const ROW_H := 15.0
const PAD_X := 7.0
const FADE := 0.25            ## 新行淡入

var _bg: Panel
var _text: Label
var _rows: Array[Label] = []
var _cache: PackedStringArray = PackedStringArray()   ## 折行后的显示行（增量）
var _cache_src: PackedInt32Array = PackedInt32Array() ## 每行来自第几条日志
var _built := 0
var _built_key := -3
var _last_total := -1


func _ready() -> void:
	position = CWLogPanel.RECT.position
	size = SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	## 必须标记已处理，否则点击会漏到 main.gd 被「过场中点一下跳过」接走（主菜单踩过的坑）
	gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			get_viewport().set_input_as_handled()
			pressed.emit())
	mouse_entered.connect(func() -> void: _paint(true))
	mouse_exited.connect(func() -> void: _paint(false))

	## 底板用 1px 描边：整条提示只有 22px 高，全局那套 2px 描边（CWStyle.box）
	## 在这个尺寸上太重，试过一眼假。「L」底框走 CWStyle.keycap（与面板标题行共用）
	_bg = Panel.new()
	_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)

	_text = CWStyle.label("对局日志", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	_text.position = Vector2(PAD_X, 5)
	add_child(_text)

	## 键帽定尺寸（CWStyle.keycap），建成即知大小，钉在标题行右缘
	var key := CWStyle.keycap("L")
	key.position = Vector2(SIZE.x - 6.0 - key.size.x, 5.0 + 6.0 - key.size.y / 2.0)
	add_child(key)
	## 日志尾巴：定长的行池，每帧只改 text / 颜色（同 CWLogPanel）
	for i in ROWS:
		var l := CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT)
		l.position = Vector2(PAD_X, ROW_Y + i * ROW_H)
		l.size = Vector2(row_width(), ROW_H)
		l.clip_text = true
		add_child(l)
		_rows.append(l)
	_paint(false)


## 条的右缘（左侧那一列都按它对齐：事件列表 CWFeed 同 x 同宽）
static func right_edge() -> float:
	return CWLogPanel.RECT.position.x + SIZE.x


static func row_width() -> float:
	return SIZE.x - PAD_X * 2.0


## 每帧由 CWMatch 调（面板之后）：把日志尾巴的最后 ROWS 个显示行铺上去。
## 视角（filter / viewer）直接用面板那份 —— 别人抽到什么牌在这里也是公开替身。
func refresh(game: CWGame, panel: CWLogPanel) -> void:
	if game == null or panel == null:
		return
	var key: int = panel.viewer if panel.filter else -2
	if game.logs.size() < _built or key != _built_key:
		_cache.clear()
		_cache_src.clear()
		_built = 0
		_built_key = key
	## 末条可能被就地改写（连续的【定殖】/【净化】合并，Kevin 2026-09-07），每帧重折它
	var stable: int = maxi(game.logs.size() - 1, 0)
	while _built < stable:
		for seg in CWLogPanel.wrap_line(panel.line_text(game, _built), row_width()):
			_cache.append(seg)
			_cache_src.append(_built)
		_built += 1
	while _cache_src.size() > 0 and _cache_src[_cache_src.size() - 1] >= stable:
		_cache.remove_at(_cache.size() - 1)
		_cache_src.remove_at(_cache_src.size() - 1)
	if game.logs.size() > stable:
		for seg in CWLogPanel.wrap_line(panel.line_text(game, stable), row_width()):
			_cache.append(seg)
			_cache_src.append(stable)
	var total := _cache.size()
	var first := maxi(total - ROWS, 0)
	for i in ROWS:
		var idx := first + i
		if idx >= total:
			_rows[i].text = ""
			continue
		_rows[i].text = _cache[idx]
		var c: Color = CWLogPanel.line_color(game.logs[_cache_src[idx]])
		## 越旧越淡：最后一行全亮
		var age: int = ROWS - 1 - i
		_rows[i].add_theme_color_override("font_color", Color(c, 1.0 - 0.35 * age))
	if total != _last_total:
		if _last_total >= 0 and total > 0:
			var newest: Label = _rows[mini(total, ROWS) - 1]
			newest.modulate.a = 0.15
			create_tween().tween_property(newest, "modulate:a", 1.0, FADE)
		_last_total = total


## 可点的东西要会答话（本作的悬停语言）：描边提亮一档、灰字转常规
func _paint(hot: bool) -> void:
	_bg.add_theme_stylebox_override("panel",
		_box(CWStyle.BTN_BG, Color(CWStyle.LINE, 0.9 if hot else 0.5)))
	_text.add_theme_color_override("font_color", CWStyle.TEXT if hot else CWStyle.TEXT_DIM)


static func _box(bg: Color, border: Color) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = bg
	b.border_color = border
	b.set_border_width_all(1)
	return b
