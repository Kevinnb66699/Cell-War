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

signal pressed        ## 点「对局日志」= 按 L（CWMatch 接到 CWLogPanel.toggle）
signal chat_pressed   ## 点「聊天」= 按回车（CWMatch 接到 CWChatBox.toggle）

## **聊天页**（Kevin 2026-09-09 定的标签页）。这条 300×52 的迷你条同时是两页的入口：
## 默认显示日志尾巴，有人说话且聊天框关着时**临时切到聊天页**显示最近两条，
## `CHAT_HOLD` 秒后自己切回去。
##
## 这就是「浮出两条」那个想法 —— 只是实现成标签切换，**零新增屏幕面积**。
## 左下角摆不下：出牌列占 x 8..80 / y 76..348，手牌悬停抬起到 y 428，
## 行动提示条 y 466..518，常驻件之间一点缝都没有（Kevin 一眼看出来的）。
const CHAT_HOLD := 6.0

const SIZE := Vector2(300, 52)
## 教程局收成只剩「日志 L」那个入口（Kevin 2026-09-13）：300 宽的条横在 x 16..316，
## 正好压住引导浮层（`CWGuide.ZONE` 从 x=88 起）的章节行和标题 —— 标题一长就被吃掉两个字。
## 滚动的日志尾巴对新手也是噪音：这两行说的是引擎流水账，引导自己会讲。
## **入口必须留着**：第 13 关教的就是「多看对局日志（L 键）」，提亮层也认它。
## 宽度算出来之后钉死在浮层左沿之内（`t_guide_quiet` 盯着这条关系）。
const COMPACT_H := 22.0
const COMPACT_GAP := 8.0
const COMPACT_TEXT := "日志"
const ROWS := 2               ## 日志尾巴几行（折行后的显示行）
const ROW_Y := 21.0           ## 第一行日志的 y；标题行在 5
const ROW_H := 15.0
const PAD_X := 7.0
const FADE := 0.25            ## 新行淡入

var _bg: Panel
var _text: Label
var _key: Control         ## 「L」键帽：收起 / 展开时要跟着右缘走
var _compact := false     ## 教程局只留入口，见 set_compact
var _rows: Array[Label] = []
var _cache: PackedStringArray = PackedStringArray()   ## 折行后的显示行（增量）
var _cache_src: PackedInt32Array = PackedInt32Array() ## 每行来自第几条日志
var _built := 0
var _built_key := -3
var _last_total := -1
var _chat: CWChatBox      ## 聊天框（联机局才有）；null = 这一局没有聊天
var _chat_tab: Label
var _chat_hold := 0.0     ## 还剩多久切回日志页
var _chat_seen := 0       ## 已经因为「有新消息」闪过的条数


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
	_key = CWStyle.keycap("L")
	_key.position = Vector2(SIZE.x - 6.0 - _key.size.x, 5.0 + 6.0 - _key.size.y / 2.0)
	add_child(_key)
	## 聊天页的标签，摆在「对局日志」右边。没有聊天框（单机局）时整个隐掉
	_chat_tab = CWStyle.label("聊天", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	_chat_tab.position = Vector2(PAD_X + 74.0, 5)
	_chat_tab.mouse_filter = Control.MOUSE_FILTER_STOP
	_chat_tab.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_chat_tab.visible = false
	_chat_tab.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			get_viewport().set_input_as_handled()
			chat_pressed.emit())
	add_child(_chat_tab)
	## 日志尾巴：定长的行池，每帧只改 text / 颜色（同 CWLogPanel）
	for i in ROWS:
		var l := CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT)
		l.position = Vector2(PAD_X, ROW_Y + i * ROW_H)
		l.size = Vector2(row_width(), ROW_H)
		l.clip_text = true
		add_child(l)
		_rows.append(l)
	_paint(false)


## 收起 / 展开（教程局收起）。每局由 `CWMatch._prepare_ui` 设一次 —— 这只控件是**跨局复用**的，
## 上一局教程留下的收起状态不撤，下一局正式对局就少了两行日志。
## 收起时：只剩「日志 L」，两行尾巴和聊天页标签一起藏；点击、L 键、展开的面板都不受影响。
func set_compact(on: bool) -> void:
	if _compact == on or _key == null:
		return
	_compact = on
	_text.text = COMPACT_TEXT if on else "对局日志"
	size = Vector2(PAD_X + _text.get_minimum_size().x + COMPACT_GAP + _key.size.x + 6.0, COMPACT_H) if on else SIZE
	_key.position = Vector2(size.x - 6.0 - _key.size.x, 5.0 + 6.0 - _key.size.y / 2.0)
	for l in _rows:
		l.visible = not on
	if _chat_tab != null:
		_chat_tab.visible = not on and _chat != null


func compact() -> bool:
	return _compact


## 聊天页：有新消息就切过来显示最近两条，CHAT_HOLD 秒后切回日志页。
## 标签上的未读数一直挂着，直到玩家开过框
func _refresh_chat(delta: float) -> void:
	var total := _chat.unread()
	if _chat.is_open():
		_chat_hold = 0.0
		_chat_seen = total
	elif total > _chat_seen:
		_chat_seen = total
		_chat_hold = CHAT_HOLD          ## 又有人说话：把这两行让给聊天
	elif _chat_hold > 0.0:
		_chat_hold -= delta
	_chat_tab.text = "聊天" if total <= 0 or _chat.is_open() else "聊天 %d" % total
	_chat_tab.add_theme_color_override("font_color",
		Color.WHITE if on_chat_tab() else
		(CWStyle.TEXT_HI if total > 0 and not _chat.is_open() else CWStyle.TEXT_DIM))
	_text.add_theme_color_override("font_color",
		CWStyle.TEXT_DIM if on_chat_tab() else CWStyle.TEXT_HI)
	if not on_chat_tab():
		return
	var lines := _chat.tail(ROWS)
	for i in ROWS:
		var idx: int = lines.size() - ROWS + i
		var l: Label = _rows[i]
		if idx < 0:
			l.text = ""
			continue
		l.text = CWChatBox.line_text(lines[idx])
		l.add_theme_color_override("font_color", CWChatBox.line_color(lines[idx]))
		l.modulate.a = 1.0


## 条的右缘（左侧那一列都按它对齐：事件列表 CWFeed 同 x 同宽）
static func right_edge() -> float:
	return CWLogPanel.RECT.position.x + SIZE.x


static func row_width() -> float:
	return SIZE.x - PAD_X * 2.0


## 每帧由 CWMatch 调（面板之后）：把日志尾巴的最后 ROWS 个显示行铺上去。
## 视角（filter / viewer）直接用面板那份 —— 别人抽到什么牌在这里也是公开替身。
## 联机局开局时由 CWMatch 装进来。可能在 _ready 之前被调（节点刚 new 出来就装），
## 所以标签的显隐推迟到 _process 里跟着状态一起刷
func set_chat(box: CWChatBox) -> void:
	_chat = box


## 聊天页的计时自己走，**不挂在 refresh 上** —— 那个由 CWMatch 每帧喂，
## 而聊天页该不该切回去跟对局状态没关系，挂上去只会多一条依赖
func _process(delta: float) -> void:
	if _chat_tab == null:
		return
	_chat_tab.visible = _chat != null and not _compact
	if _chat != null:
		_refresh_chat(delta)


## 此刻显示的是聊天页吗
func on_chat_tab() -> bool:
	return _chat != null and _chat_hold > 0.0


func refresh(game: CWGame, panel: CWLogPanel) -> void:
	if game == null or panel == null or _compact:
		return          ## 收起时没有尾巴可铺，连折行都省了
	if on_chat_tab():
		return          ## 聊天页占着这两行，日志那边先不折（省下每帧的折行）
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
