extends SceneTree
## 回放面板的排版对照图 —— 给人看的工具，不是测试。
##
## **为什么非得出图**：这块面板压在主菜单那块地上，右边就是**菜单机位下的棋盘**
## （装饰细胞那一片）。新加的「来源两栏 + 翻页」占的是标题与列表之间那一行，
## 挤没挤、伸不伸进棋盘，只能把真棋盘摆进来看 ——
## 前两次栽的都是「预览没画常驻件」，所以这儿按 CWView.MENU_* 摆真机位。
##
## 三张：本机（7 份 = 两页）/ 服务器（12 局 = 三页）/ 本机空列表（要指路到另一栏）。
##
## 本机那几份是**临时造的**，最后一帧自己删掉 —— 预览不该动玩家真的回放柜。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview_replay_panel.gd -- <输出前缀>
const WARMUP := 16
const N_LOCAL := 7
const N_SERVER := 12

var _out := "user://replay_panel"
var _panel: CWReplayPanel
var _board: Node2D
var _cam: Camera2D
var _frames := 0
var _shot := 0
var _made: Array[String] = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	var bg := ColorRect.new()
	bg.color = CWStyle.GROUND
	bg.size = Vector2(960, 540)
	root.add_child(bg)
	_board = load("res://scenes/Board.tscn").instantiate()
	root.add_child(_board)
	_cam = Camera2D.new()
	root.add_child(_cam)
	_fake_local()
	## 面板挂 CanvasLayer：直接挂 root 的话会跟着 Camera2D 一起被搬走
	## （棋盘的菜单机位 zoom 3.2，面板会整个飞出屏幕）
	var ui := CanvasLayer.new()
	root.add_child(ui)
	_panel = CWReplayPanel.new()
	ui.add_child(_panel)


func _process(_d: float) -> bool:
	_frames += 1
	## 机位每帧摆一次：_initialize 里棋盘还没跑过 _ready，那时算不出原点
	CWView.apply(_cam, _board, CWView.MENU_ZOOM, CWView.MENU_LOOK_AT, CWView.MENU_ANCHOR)
	if _frames == 2:
		_panel.open()
	if _frames == 4:
		## 手工点一行的悬停：**无头视口不跟踪悬停控件**，鼠标位置驱动不了，
		## 只能自己发信号（同护栏里的做法）。图里第 2 行就是悬停态
		_panel._rows[1].mouse_entered.emit()
	## **等淡入真的走完再拍**，别数帧：`open()` 是 0.32 秒的**时间**补间，
	## 而这个循环不吃 vsync，一帧可能只有几毫秒 —— 数十几帧只等到 0.1 秒，
	## 拍下来整块 `modulate.a` 才 0.3，图里的字全是半透明的
	## （2026-09-09 Kevin 一句「为什么这图片里面的字这么淡」才揭穿）
	if _frames < WARMUP or _panel.modulate.a < 1.0:
		return false
	var img := root.get_texture().get_image()
	match _shot:
		0:
			img.save_png(_out + "_local.png")
			print("已保存 ", _out, "_local.png（本机 %d 份 = 两页）" % N_LOCAL)
			## 服务器那一栏：直接塞摘要，不连服务器（连不连是 t_net_replay_download 的事）
			_panel._src = CWReplayPanel.Src.SERVER
			_panel._server = []
			for i in N_SERVER:
				_panel._server.append({ "id": N_SERVER - i, "code": "K%05d" % (i * 7),
					"players": [2, 4, 6][i % 3], "round": 9 + i * 13,
					"winner": i % 3 - 1 })
			_panel._page = 0
			_panel._sel = 1
			_panel._repaint()
			## 预览不真去连服务器，所以副标题开头那一段手工换成连上之后的样子；
			## 后面的页码仍是真代码算的
			_panel._sub.text = _panel._sub.text.replace("没有连接",
				"服务器上有 %d 局" % N_SERVER)
		1:
			img.save_png(_out + "_server.png")
			print("已保存 ", _out, "_server.png（服务器 %d 局 = 三页）" % N_SERVER)
			_panel._src = CWReplayPanel.Src.LOCAL
			_panel._files = PackedStringArray()
			_panel._repaint()
		2:
			img.save_png(_out + "_empty.png")
			print("已保存 ", _out, "_empty.png（本机空列表）")
			_wipe_fake()
			return true
	_shot += 1
	_frames = WARMUP - 3      ## 再等几帧让布局落定
	return false


## 造几份**能读得出来**的本机回放（下标串随便，列表只看摘要那几个字段）
func _fake_local() -> void:
	DirAccess.make_dir_recursive_absolute(CWReplay.DIR)
	for i in N_LOCAL:
		var d := {
			"version": CWReplay.VERSION,
			"players": [2, 4, 6][i % 3],
			"seed": 1000 + i,
			"rules": {},
			"cancer_types": [],
			"answers": PackedInt32Array([0, 1, 0]),
			"round": 6 + i * 9,
			"winner": i % 3 - 1,
			"win_reason": "预览",
			"at": "2026-09-0%d 2%d:1%d:07" % [(i % 9) + 1, i % 3, i % 9],
		}
		var path := "%s/zz_preview_%02d%s" % [CWReplay.DIR, i, CWReplay.EXT]
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			continue
		f.store_string(var_to_str(d))
		f.close()
		_made.append(path)


func _wipe_fake() -> void:
	for path in _made:
		DirAccess.remove_absolute(path)
