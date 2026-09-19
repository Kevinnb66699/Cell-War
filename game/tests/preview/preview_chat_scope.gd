extends SceneTree
## 等待室聊天的「己方」标签：切过去之后移开鼠标不该变白（issue #51）—— 给人看的工具，不是测试。
##
## **为什么非得出图**：这条 bug 的现场是**三步之后**的静止态（鼠标移上去 → 悬停着点一下换成己方
## → 移开）。单看任何一步都是对的 —— 悬停该白、切过去那一瞬该是阵营色 ——
## 只有把「移开之后」那一帧摆出来，才看得见 5yntaxEr 报的那个白字。
##
## 面板照 `preview_online_lan` 的做法连棋盘 + 菜单机位一起画（排版预览用平底色会骗人）。
##
## 两帧，同一页、同一条路径，只有那一个标签不同：
##   `<输出>_改前.png`  旧路径（直写 font_color，`link_hot` 的静止色仍记着 TEXT_HI）→ 移开变白
##   `<输出>_改后.png`  现在走 `CWStyle.paint_link`（静止色本身跟着换）→ 移开还是阵营色
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview/preview_chat_scope.gd -- <输出.png>
const WARMUP := 14
## 放大镜对准聊天板标题栏右端那两个字（CHAT_X + CHAT_W - 60, CHAT_Y - 18 一带）
const ZOOM_AT := Vector2i(820, 194)
const ZOOM_SIZE := Vector2i(100, 20)

var _out := "user://chat_scope.png"
var _board: Node2D
var _cam: Camera2D
var _panel: CWOnlinePanel
var _cap: Label
var _sub: Label
var _frames := 0
var _stage := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	var bg := ColorRect.new()
	bg.color = Color("0d1620")
	bg.size = CWView.screen_size()
	root.add_child(bg)
	_board = load("res://scenes/Board.tscn").instantiate()
	root.add_child(_board)
	_cam = Camera2D.new()
	root.add_child(_cam)
	_cam.make_current()
	var ui := CanvasLayer.new()
	root.add_child(ui)
	_panel = CWOnlinePanel.new()
	ui.add_child(_panel)
	_cap = CWStyle.label("", CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
	_cap.position = Vector2(16, 12)
	ui.add_child(_cap)
	_sub = CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	_sub.position = Vector2(16, 42)
	ui.add_child(_sub)


## 不连服务器，直接喂视图（同 t_online_panel 那一套）
func _fake_room() -> void:
	_panel.client = CWNetClient.new()
	var seats: Array = []
	for i in 4:
		seats.append({ "kind": "empty", "nick": "", "ready": false, "tier": "", "online": false,
			"faction": CWData.FACTION_ORDER[4][i] })
	seats[0] = { "kind": "human", "nick": "Kevin", "ready": true, "tier": "", "online": true,
		"faction": CWData.Faction.IMMUNE }
	seats[1] = { "kind": "human", "nick": "HXR", "ready": true, "tier": "", "online": true,
		"faction": CWData.Faction.CANCER }
	_panel.client.room = { "t": "room", "code": "ABCDEF", "public": true, "timer": 60, "players": 4,
		"state": "waiting", "host": "Kevin", "you_host": true, "you_seat": 0, "token": "x",
		"seats": seats, "members": ["Kevin", "HXR"], "games": 0 }
	_panel.client.code = "ABCDEF"
	_panel.client.my_seat = 0
	_panel.client.chat_log = [
		{ "nick": "Kevin", "text": "准备好了就开", "scope": "all", "seat": 0, "faction": CWData.Faction.IMMUNE },
		{ "nick": "HXR", "text": "等我看一眼卡池", "scope": "all", "seat": 1, "faction": CWData.Faction.CANCER },
	]
	_panel.open()
	_panel.modulate.a = 1.0
	_panel._show_page(CWOnlinePanel.Page.ROOM)


## 鼠标移上去 → 悬停着切到「己方」 → 移开。old = 走旧路径（直写 font_color）
func _sequence(old: bool) -> void:
	var scope: Label = _panel._chat_scope
	## 上一轮留下的 hot / rest 记号清掉，两轮各自从「全体、没碰过」起步
	scope.remove_meta("hot")
	scope.remove_meta("rest")
	_panel._chat_team = false
	_panel._repaint_chat()
	CWStyle.link_hot(scope, true)             ## ① 鼠标移上去
	if old:
		## ② 旧代码：直写 font_color —— 静止色（meta "rest"）还记着移上去那一刻的 TEXT_HI
		_panel._chat_team = true
		scope.text = "己方"
		scope.add_theme_color_override("font_color",
			CWChatBox.faction_color(_panel._my_faction()))
	else:
		_panel._toggle_chat_scope()           ## ② 现在这条路（_repaint_chat → paint_link）
	CWStyle.link_hot(scope, false)            ## ③ 鼠标移开
	_cap.text = "issue #51 · 切到「己方」再把鼠标移开：%s" % ("改前（变白，再移回也回不来）" if old else "改后（还是阵营色）")
	_sub.text = "看聊天板右上角那两个字。三步都一样：鼠标移上去 → 悬停着点一下换到己方 → 移开"


func _process(_d: float) -> bool:
	_frames += 1
	CWView.apply(_cam, _board, CWView.MENU_ZOOM, CWView.MENU_LOOK_AT, CWView.MENU_ANCHOR)
	if _frames == WARMUP:
		_fake_room()
		return false
	if _frames < WARMUP + 4:
		return false
	if _frames == WARMUP + 4:
		_sequence(true)
		return false
	if _frames < WARMUP + 8:
		return false
	var path := "%s_%s.png" % [_out.trim_suffix(".png"), "改前" if _stage == 0 else "改后"]
	var img := root.get_texture().get_image()
	## 那两个字只有 10px 高，差的又只是「白 #EAF8FC 还是免疫青 #30D1FA」——
	## 整屏图上瞄不出来。照 preview_level_bar 的做法把那一块放大三倍钉在右下角空地上
	var zoom := img.get_region(Rect2i(ZOOM_AT, ZOOM_SIZE))
	zoom.resize(ZOOM_SIZE.x * 3, ZOOM_SIZE.y * 3, Image.INTERPOLATE_NEAREST)
	img.blit_rect(zoom, Rect2i(Vector2i.ZERO, zoom.get_size()),
		Vector2i(960 - zoom.get_width() - 16, 540 - zoom.get_height() - 16))
	var err := img.save_png(path)
	print("已保存 %s (err=%d)" % [path, err])
	if _stage == 1:
		return true
	_stage = 1
	_sequence(false)
	_frames = WARMUP + 4
	return false
