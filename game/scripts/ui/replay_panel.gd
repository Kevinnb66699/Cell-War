## replay_panel.gd —— 对局回放：主菜单同一槽位的左侧面板，两栏来源 + 翻页
##
## 面板槽语法照配置面板与联机面板（CWConfigPanel / CWOnlinePanel）：主菜单淡出后
## 本面板在同一位置淡入，眉题 / 标题 / 行 / 按钮的坐标逐个照抄那两边，
## 所以三块面板换来换去时字不会跳。
##
## ## 两栏来源：本机 / 服务器
##
## **本机**是 `user://replays/`：单机局自己存的、联机局终局服务器推下来的、
## 从服务器目录下下来的，都落在这儿 —— 「本机」不等于「只有单机局」，
## 它是「这台机器手上有的」。
##
## **服务器**是服务器盘上留的最近 50 局（`CWNetServer.REPLAY_KEEP`），
## 包括你没参与的那些。取目录只拿摘要，点中某一行才去取正文 ——
## 正文一局几 KB，五十局全推下来等于每次开列表发几百 KB（见 `CWNetServer.replay_list`）。
##
## 连接是**懒的**：切到「服务器」那栏才连，用联机面板存下来的地址与昵称
## （`CWSettings`），所以这儿不必再摆一遍「昵称 / 地址」两行输入框。
## 走人（返回菜单 / 开始看某一份）就断开 —— 回放面板没理由挂着一条长连接。
##
## ## 为什么要翻页
##
## 一屏只放得下 5 行（296 起、26 一行，438 就是按钮），而本机留 20 份、
## 服务器留 50 局。上一版没有翻页 = **只够得到最新的 5 份**，剩下的点不到。
##
## 选中一份 → `picked`，main.gd 拿它建播放器、把镜头推进棋盘。
class_name CWReplayPanel
extends Control

signal cancelled                       ## Esc / 返回主菜单：菜单把自己淡回来
signal picked(data: Dictionary)        ## 选了一份要看的

enum Src { LOCAL, SERVER }

const SLOT_X := 120.0                  ## 槽位左缘（同另外两块面板）
const BTN_Y := 438.0
const FADE_IN := 0.32
const SRC_Y := 236.0                   ## 来源两栏 + 翻页共用这一行（标题与列表之间唯一的空行）
const LIST_Y0 := 296.0
const LIST_W := 400.0                  ## 一行定宽，超出加省略号（同大厅房间行）
const LIST_H := 26.0
const LIST_N := 5
const ROW_LABEL := Color("9fb6bd")

## 只在看「服务器」那栏时才有；本面板自己持有、自己断开
var client: CWNetClient
var _src := Src.LOCAL
var _page := 0
var _rows: Array[Label] = []
var _files: PackedStringArray = []
var _server: Array = []                ## 服务器目录（只有摘要，没有下标串）
var _sel := -1                         ## **全表下标**，不是行号 —— 页号只是它除以 LIST_N
var _asked := false                    ## 这条连接上已经要过一次目录了
var _last_status := ""                 ## 上一帧连接是什么状态（变了才重画）
var _sub: Label
var _note: Label
var _head: Label
var _tabs: Array[Label] = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP   ## 整层接管：底下淡掉的菜单项收不到点击
	visible = false
	_build()


func open() -> void:
	_apply_src()          ## 上次停在「服务器」那栏就接着连（连接是走人时断掉的）
	visible = true
	modulate.a = 0.0
	create_tween().tween_property(self, "modulate:a", 1.0, FADE_IN)


## 重取一遍当前这一栏。本机每次进来都扫盘 —— 刚打完一局回来就该看见它
func refresh() -> void:
	_note.text = ""
	if _src == Src.LOCAL:
		_files = CWReplay.list_files()
	else:
		_asked = false     ## 连上（或已经连着）就发 list_replays，见 _ask_list
		_ask_list()
	_page = 0
	_sel = 0 if _count() > 0 else -1
	_repaint()


func _process(_delta: float) -> void:
	if client == null:
		return
	client.poll()
	## poll 会当场派报文，而「正文取回来了」那一条在 _on_message 里**就把连接断掉了** ——
	## 所以这儿得重新看一眼，不能拿 poll 之前那次判空当准（跑套件时真踩到）
	if client == null:
		return
	_ask_list()
	## 只在**状态变了**那一帧重画：连上 / 断开会同时改副标题和空列表的说法，
	## 但没变的时候每帧重画一遍纯属白烧
	if client.status != _last_status:
		_last_status = client.status
		_repaint()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_back()
	elif event.is_action_pressed("ui_left") or event.is_action_pressed("ui_right"):
		## 左右换来源，同建房页「左右拨值」那一套（面板槽的通用语法）
		get_viewport().set_input_as_handled()
		_use(Src.LOCAL if _src == Src.SERVER else Src.SERVER)
	elif event.is_action_pressed("ui_down") or event.is_action_pressed("ui_up"):
		_move(1 if event.is_action_pressed("ui_down") else -1)
	elif event.is_action_pressed("ui_accept"):
		get_viewport().set_input_as_handled()
		_play(_sel)


func _back() -> void:
	_drop_client()
	visible = false
	cancelled.emit()


# ============ 两栏来源 ============

func _use(src: int) -> void:
	if _src == src:
		return
	_src = src
	_apply_src()


func _apply_src() -> void:
	_server = []
	refresh()
	## 连接放在 refresh 之后：连不上时 _ensure_client 把话写进 _note，
	## 而 refresh 开头就把 _note 清了 —— 反过来写这句话会当场被自己抹掉
	if _src == Src.SERVER:
		_ensure_client()
	else:
		_drop_client()


## 切到「服务器」那栏才连。地址与昵称用联机面板存下的那份 ——
## 连不上就在副标题里说清楚是**哪个地址**连不上，别只写「失败」
func _ensure_client() -> void:
	if client != null and client.status != "closed":
		return
	_drop_client()
	var addr := CWSettings.server.strip_edges()
	if addr == "":
		addr = "%s:%d" % [CWNet.DEFAULT_HOST, CWNet.DEFAULT_PORT]
	client = CWNetClient.new()
	client.message.connect(_on_message)
	var url := addr
	if not (addr.begins_with("ws://") or addr.begins_with("wss://")):
		url = "ws://" + addr
	if client.connect_to(url, CWNet.clean_nick(CWSettings.nick)) != OK:
		client = null
		_note.text = "服务器地址不合法：%s" % addr


func _drop_client() -> void:
	if client != null:
		client.dispose()
		client = null
	_asked = false
	_last_status = ""


## 连上之后要一次目录。**不能在 _ensure_client 里直接发** —— 那时候 WebSocket
## 还在握手，`CWNetClient.send` 只在 STATE_OPEN 时才真发，这一包会被安静丢掉。
## 所以每帧问一次「开了没、要过没」，开了就要。
func _ask_list() -> void:
	if _asked or _src != Src.SERVER or client == null or client.status != "open":
		return
	_asked = true
	client.fetch_replays()


func _on_message(m: Dictionary) -> void:
	match String(m.get("t", "")):
		"replays":
			_server = client.replay_list
			_page = 0
			_sel = 0 if _count() > 0 else -1
			_repaint()
		"replay":
			## 正文取回来了（CWNetClient 收到时已经顺手落到本机），直接开看
			if not client.replay_data.is_empty():
				var d: Dictionary = client.replay_data
				_drop_client()
				visible = false
				picked.emit(d)
		"error":
			_note.text = String(m.get("msg", m.get("code", "")))


# ============ 选择与翻页 ============

## 当前这一栏一共几份
func _count() -> int:
	return _files.size() if _src == Src.LOCAL else _server.size()


## 最后一页的页号（从 0 起）。**纯函数**，好直接测
static func last_page(count: int, per_page: int) -> int:
	if count <= 0 or per_page <= 0:
		return 0
	return (count - 1) / per_page


## 上下选行：**选到头就自己翻页**，所以不必再教玩家一套翻页键
func _move(d: int) -> void:
	if _count() <= 0:
		return
	_sel = clampi(_sel + d, 0, _count() - 1)
	_page = _sel / LIST_N
	_repaint()


## 滚轮翻页：面板上哪儿都行。**不摆「上一页 / 下一页」两个键** ——
## 标题与列表之间只有一行空位，摆在那儿正好压在主菜单的装饰细胞上（出图当场逮到），
## 往右挪又出了暗罩最实的那一段，字会直接糊在棋盘上。
## 页码写进副标题（y 200，一直在暗罩最实处），键盘上下选到头也会自己翻页。
func _wheel(event: InputEvent) -> bool:
	if not (event is InputEventMouseButton) or not event.is_pressed():
		return false
	match (event as InputEventMouseButton).button_index:
		MOUSE_BUTTON_WHEEL_DOWN:
			_flip(1)
			return true
		MOUSE_BUTTON_WHEEL_UP:
			_flip(-1)
			return true
	return false


## 落在面板空白处的滚轮（落在某一行上的由 _clicky 那头接）
func _gui_input(event: InputEvent) -> void:
	if _wheel(event):
		accept_event()


func _flip(d: int) -> void:
	var p := clampi(_page + d, 0, last_page(_count(), LIST_N))
	if p == _page:
		return
	_page = p
	_sel = mini(_page * LIST_N, _count() - 1)
	_repaint()


## 看第 i 份（**全表下标**）。本机的就地读盘，服务器的先去要正文。
## 本机那份读不出就地报错、不关面板 —— 回放文件会被人拷来拷去，
## 坏一份不该把人踢回主菜单
func _play(i: int) -> void:
	if i < 0 or i >= _count():
		return
	if _src == Src.SERVER:
		if client == null or client.status != "open":
			_note.text = "还没连上服务器"
			return
		_note.text = "取回放中…"
		client.fetch_replay(int(_server[i].get("id", 0)))
		return
	var d := CWReplay.read(_files[i])
	if d.is_empty():
		_note.text = "这份回放读不出来（版本不符或文件损坏）"
		return
	visible = false
	picked.emit(d)


# ============ 构建与呈现 ============

func _build() -> void:
	## 槽位自带一份左侧暗罩（同另外两块面板：菜单的 Scrim 跟着菜单整层淡走了）
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

	var fv := FontVariation.new()
	fv.base_font = CWStyle.FONT
	fv.spacing_glyph = 2
	var eyebrow := CWStyle.label("REPLAY", CWStyle.SIZE_BODY, CWStyle.IMMUNE)
	eyebrow.add_theme_font_override("font", fv)
	eyebrow.position = Vector2(SLOT_X, 127)
	add_child(eyebrow)
	var title := CWStyle.label("对局回放", CWStyle.SIZE_BIG, CWStyle.TEXT_HI)
	title.position = Vector2(SLOT_X, 160)
	add_child(title)
	_sub = CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	_sub.position = Vector2(SLOT_X, 200)
	add_child(_sub)

	## 来源两栏。左右方向键也能换（见 _unhandled_input）
	_tabs.append(_clicky("本机", Vector2(SLOT_X, SRC_Y), func() -> void: _use(Src.LOCAL)))
	_tabs.append(_clicky("服务器", Vector2(SLOT_X + 70, SRC_Y),
		func() -> void: _use(Src.SERVER)))

	_head = CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	_head.position = Vector2(SLOT_X, LIST_Y0 - 16)
	add_child(_head)
	for i in LIST_N:
		var row := _clicky("", Vector2(SLOT_X, LIST_Y0 + i * LIST_H),
			func() -> void: _play(_page * LIST_N + i))
		row.mouse_entered.connect(func() -> void:
			if _page * LIST_N + i < _count():
				_sel = _page * LIST_N + i
				_repaint())
		_rows.append(row)
	_note = CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.CANCER)
	_note.position = Vector2(SLOT_X, LIST_Y0 + LIST_N * LIST_H + 6)
	add_child(_note)

	_clicky("刷新", Vector2(SLOT_X, BTN_Y + 5), refresh)
	_clicky("返回主菜单", Vector2(SLOT_X + 80, BTN_Y + 5), _back)


## 副标题：本机数份数；服务器还要交代连没连上、连的是哪儿
func _repaint_sub() -> void:
	var head := ""
	if _src == Src.LOCAL:
		head = "共 %d 份（最多留 %d）" % [_files.size(), CWReplay.KEEP]
	elif client == null:
		head = "没有连接"
	elif client.status != "open":
		head = "连接 %s …" % CWSettings.server
	else:
		## 连上了就不再报地址：这一行还要挂页码，写全会一直伸到暗罩透明的那一段。
		## 地址只在「正在连」和「连不上」时才有用（那两句里都有）
		head = "服务器上有 %d 局" % _server.size()
	var last := last_page(_count(), LIST_N)
	## 页码只在真有第二页时才出现，顺带**把翻法说出来** ——
	## 没有可见的翻页键，这句就是唯一的告示
	_sub.text = head if last <= 0 else 		head + " · 第 %d/%d 页（滚轮翻页）" % [_page + 1, last + 1]


func _repaint() -> void:
	for i in _tabs.size():
		_tabs[i].add_theme_color_override("font_color",
			Color.WHITE if i == _src else CWStyle.TEXT_OFF)
	_head.text = "这台机器上的回放" if _src == Src.LOCAL else "服务器上最近的对局"
	_repaint_sub()
	for i in LIST_N:
		var idx: int = _page * LIST_N + i
		var l: Label = _rows[i]
		if idx >= _count():
			l.text = _empty_text() if i == 0 and _count() == 0 else ""
			l.mouse_filter = Control.MOUSE_FILTER_IGNORE
			l.add_theme_color_override("font_color", CWStyle.TEXT_OFF)
			## **裁字要关掉**：这一行上一轮可能列过某一份（换来源、刷新之后就会），
			## 那时开着 clip_text，而 clip_text 会让 get_minimum_size() 缩到近乎 0 ——
			## 于是空态那句话被自己裁没，整行一片空白（出图逮到的）
			l.clip_text = false
			l.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
			l.size = l.get_minimum_size()
			continue
		if _src == Src.LOCAL:
			l.text = summary_line(CWReplay.read(_files[idx]))
		else:
			l.text = server_line(_server[idx])
		l.mouse_filter = Control.MOUSE_FILTER_STOP
		l.add_theme_color_override("font_color",
			Color.WHITE if idx == _sel else CWStyle.TEXT_HI)
		l.clip_text = true
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		l.size = Vector2(LIST_W, l.get_minimum_size().y)


## 空列表说什么。本机空着要**指路**到另一栏 —— 没打过的人不是没得看
func _empty_text() -> String:
	if _src == Src.LOCAL:
		return "（本机还没有回放：切到「服务器」看别人的）"
	if client == null:
		return "（连不上服务器：地址在「联机对战」那页改）"
	if client.status != "open":
		return "（正在连服务器…）"
	return "（服务器上还没有打完的局）"


## 一行摘要。**纯函数**，好直接测。
##
## 年份与秒都不写：一行只有 LIST_W 宽，写全了尾巴上的胜方会被省略号吃掉 ——
## 上一版「2026-09-09 22:10:33  2 人局  第 7 回合  免疫胜」量出来 460 > 400，
## 被吃掉的恰好是最想知道的那一段。
static func summary_line(d: Dictionary) -> String:
	if d.is_empty():
		return "（这份读不出来）"
	return "%s  %d 人  %d 回合  %s" % [short_time(String(d.get("at", ""))),
		int(d.get("players", 0)), int(d.get("round", 0)), winner_text(d)]


## 服务器那一栏：用 **id + 房间码**认局，不写日期 ——
## 目录是新的在前，位置本身就是时间；而「我们那局是 ROOM01」才是玩家记得住的
static func server_line(d: Dictionary) -> String:
	return "#%d  %s  %d 人  %d 回合  %s" % [int(d.get("id", 0)),
		String(d.get("code", "??????")), int(d.get("players", 0)),
		int(d.get("round", 0)), winner_text(d)]


static func winner_text(d: Dictionary) -> String:
	match int(d.get("winner", -1)):
		CWData.Faction.IMMUNE: return "免疫胜"
		CWData.Faction.CANCER: return "癌症胜"
	return "未分胜负"


## "2026-09-09 22:10:33" → "09-09 22:10"；认不出就原样返回
static func short_time(at: String) -> String:
	if at.length() < 16 or at[4] != "-":
		return at
	return at.substr(5, 11)


func _clicky(text: String, at: Vector2, on_click: Callable) -> Label:
	var label := CWStyle.label(text, CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
	label.position = at
	label.size = label.get_minimum_size()
	label.mouse_filter = Control.MOUSE_FILTER_STOP
	label.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	label.gui_input.connect(func(e: InputEvent) -> void:
		## 行与按钮都是 MOUSE_FILTER_STOP，滚轮落在它们身上就不会再冒到面板 ——
		## 所以这儿也要接一手，否则「指着列表滚」这个最自然的动作反而没反应
		if _wheel(e):
			return
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			get_viewport().set_input_as_handled()
			on_click.call())
	add_child(label)
	return label
