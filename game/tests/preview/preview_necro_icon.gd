extends SceneTree
## issue #61（Kevin 2026-09-19）的对照图 —— 给人看的工具，不是测试。
##
## 无头断言（`t_issue31_fx`）只核得到「膜在图标那几十个像素上一笔不画」；
## 「图标露出来之后还认不认得出、这格还像不像坏死」只能把图摆出来看。
## 一排摆出来：代谢核心坏死 / 普通格坏死 / 骨髓坏死，两侧各留一格没坏死的核心与骨髓做对照。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview/preview_necro_icon.gd -- <输出.png>
const WARMUP := 12
const ZOOM := 3.0
## 取景中心（棋盘本地坐标）：r = −3 那一排从 (−2,−3) 到 (6,−3)，再往下三排带上 (3,0) 那个健康核心
const FOCUS := Vector2(36, -30)

var _out := "user://necro_icon.png"
var _board: Node2D
var _frames := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	var bg := ColorRect.new()
	bg.color = CWStyle.GROUND
	bg.size = Vector2(960, 540)
	## 底色必须沉到最底：格子的 z **就是它自己的贴图 y**，后排是负数（同 preview_fx_0919）
	bg.z_index = -4096
	root.add_child(bg)
	_board = load("res://scenes/Board.tscn").instantiate()
	_board.scale = Vector2(ZOOM, ZOOM)
	_board.position = Vector2(480, 270) - FOCUS * ZOOM
	root.add_child(_board)


## 棋盘的 map 要等它自己 _ready 之后才有，所以格子状态在 WARMUP 那一帧再摆
func _setup_scene() -> void:
	var core_bad := Vector2i(0, -3)      ## 代谢核心：癌变 + 坏死
	var marrow_bad := Vector2i(3, -3)    ## 骨髓：癌变 + 坏死（仓里有卡）
	var core_ok := Vector2i(3, 0)        ## 对照：没坏死的核心
	var marrow_ok := Vector2i(6, -3)     ## 对照：没坏死的骨髓
	var plain := [Vector2i(1, -3), Vector2i(2, -3)]   ## 对照：普通格坏死，膜照旧整格盖住
	_board.set_tissue(core_bad, CWData.Tissue.CANCER, CWData.Special.CORE)
	_board.set_store(core_bad, 0.0, CWData.Special.CORE, CWData.Tissue.CANCER)
	_board.set_tissue(marrow_bad, CWData.Tissue.CANCER, CWData.Special.MARROW)
	_board.set_store(marrow_bad, 0.0, CWData.Special.MARROW, CWData.Tissue.CANCER)
	_board.set_store(core_ok, 0.8, CWData.Special.CORE)
	_board.set_store(marrow_ok, 0.34, CWData.Special.MARROW)
	for c: Vector2i in plain:
		_board.set_tissue(c, CWData.Tissue.CANCER, CWData.Special.NONE)
	_board.set_necrosis([core_bad, marrow_bad] + plain)
	## 坏死那三格的储备与进度当场清零（引擎口径，见 t_necrosis ②），所以上面两个 set_store 给 0
	_caption(core_bad, "代谢核心坏死\n闪电照常露出")
	_caption(marrow_bad, "骨髓坏死\n卡牌 icon 照常露出")
	_caption(plain[0], "普通格坏死\n整格灰（没变）")
	_caption(core_ok, "对照：核心没坏死")
	_caption(marrow_ok, "对照：骨髓没坏死")
	var title := CWStyle.label("issue #61　坏死膜不再盖住特殊组织的图标", 10, CWStyle.TEXT_DIM)
	title.position = Vector2(12, 10)
	root.add_child(title)


## 在某格上方贴一行字（字不跟着棋盘放大，所以挂在 root 上、自己换算屏幕坐标）
func _caption(c: Vector2i, text: String) -> void:
	var l := CWStyle.label(text, 10, CWStyle.TEXT_DIM)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.size.x = 120
	l.position = _board.position + _board.tile_center(c) * ZOOM - Vector2(60, 24 * ZOOM + 20)
	root.add_child(l)


func _process(_d: float) -> bool:
	_frames += 1
	if _frames < WARMUP:
		return false
	if _frames == WARMUP:
		_setup_scene()
		return false
	root.get_texture().get_image().save_png(_out)
	return true
