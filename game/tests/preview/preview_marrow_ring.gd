extends SceneTree
## 骨髓积累进度条：游戏里真会出现的每一档停在哪 —— 给人看的工具，不是测试。
##
## **为什么非得出图**（issue #36：「骨髓进度条应当在角落截止而不是按照角度计算」）：
## 进度环是 shader 按纹素截的，2026-09-13 把「极角当弧长」改成**每条边摊 1/6 圈**的分段线性，
## 于是 1/6 的整数倍必然落在角上。骨髓真出现的档位只有 `prod / period`：
## 健康 3 回合一张（1/3、2/3、满）、癌化 2 回合一张（1/2、满）——
## 正好是 2/6、3/6、4/6，三档都该**停在角上**。是不是真停住了，只能放大了看。
##
## 画法：真起一块棋盘、走 `set_store()` 那条正路摆好六格骨髓；
## **一格一格地把棋盘挪到屏幕中央**再裁（棋盘比视口大，外圈那几格本来就在画面外，
## 第一版就这么白裁回来三张空的），最后把棋盘藏掉渲一帧当底，把放大 6 倍的六格贴回去。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview/preview_marrow_ring.gd -- <输出.png>
const ZOOM := 5
const TILE_W := 32
const TILE_H := 34
const PAD := 12                         ## 放大图四周留的空：六个角的刻度画在这圈空里
const CENTER := Vector2i(480, 270)      ## 裁剪位：每格挪到这儿来渲
const COL_X := 24
const COL_PITCH := 310
const ROW_Y := 68
const ROW_PITCH := 234
const SETTLE := 2                       ## 挪完等几帧再裁（渲染晚一帧）

## 六个角在贴图里的像素位置（顶点行 0 / 25，满宽行 8 / 17，左右边在 0 / 31 列）。
## 顺序 = shader 里 VERT 表的顺序：底 → 左下 → 左上 → 顶 → 右上 → 右下（从底角起顺时针）
const CORNERS: Array = [Vector2i(15, 25), Vector2i(0, 17), Vector2i(0, 8),
	Vector2i(15, 0), Vector2i(31, 8), Vector2i(31, 17)]
const CORNER_NAMES: Array = ["底", "左下", "左上", "顶", "右上", "右下"]

## 六格骨髓摆什么：[组织, prod（攒了几回合）, 有没有卡, 说明]
## 六格骨髓摆什么：[组织, prod, 有没有卡, 说明, 亮弧该停在第几个角（-1 = 不该有亮弧）]
const SHOW: Array = [
	[CWData.Tissue.HEALTHY, 0, false, "空仓 0/3 · 一点不亮", -1],
	[CWData.Tissue.HEALTHY, 1, false, "1/3 = 2/6 · 停在左上角", 2],
	[CWData.Tissue.HEALTHY, 2, false, "2/3 = 4/6 · 停在右上角", 4],
	[CWData.Tissue.HEALTHY, 3, true, "满 · 整圈亮（有卡）", 0],
	[CWData.Tissue.CANCER, 1, false, "癌化 1/2 = 3/6 · 停在顶角", 3],
	[CWData.Tissue.CANCER, 2, true, "癌化 满 · 整圈亮", 0],
]

var _out := "user://marrow_ring.png"
var _board: Node2D
var _frames := 0
var _i := 0                ## 正在裁第几格
var _wait := 0             ## 挪完之后还要等几帧
var _crops: Array[Image] = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	var bg := ColorRect.new()
	bg.color = CWStyle.GROUND
	bg.size = Vector2(960, 540)
	## **底色必须压到最底下**：格子的 `z_index` 就是它的 y 坐标（board.gd 的 `new_tissue`），
	## 上半张棋盘是负数 —— 默认 z=0 的底色会把它们整片盖掉，裁回来就是六张里空三张
	bg.z_index = -1000
	root.add_child(bg)
	_board = load("res://scenes/Board.tscn").instantiate()
	_board.position = Vector2(480, 300)
	root.add_child(_board)


## 摆盘**必须等 `_ready()` 跑完**：棋盘的 `map` 是在那儿建的，
## 在 `_initialize` 里调 `set_store()` 会全部静默返回
func _setup() -> void:
	for i in SHOW.size():
		var c: Vector2i = CWData.MARROWS[i]
		var tissue: int = int(SHOW[i][0])
		var stocked: bool = bool(SHOW[i][2])
		## 进度走**引擎那把尺**（`store_progress`），不在预览里自己算分数
		var t := { "special": CWData.Special.MARROW, "tissue": tissue,
			"cards": CWData.MARROW_STORE_MAX if stocked else 0, "prod": int(SHOW[i][1]) }
		_board.set_tissue(c, tissue, CWData.Special.MARROW, stocked)
		_board.set_store(c, CWData.store_progress(t), CWData.Special.MARROW, tissue)


## 把这一格挪到 CENTER：贴图是居中摆的，所以棋盘位置 = 目标 − 格子在棋盘里的位置
func _bring_to_center(c: Vector2i) -> void:
	var tile: Sprite2D = _board.map[_board.axial_to_rc(c)]["instance"]
	_board.position = Vector2(CENTER) - tile.position - tile.offset


func _label(text: String, at: Vector2, size: int, color: Color) -> void:
	var l := CWStyle.label(text, size, color)
	l.position = at
	root.add_child(l)


func _slot(i: int) -> Vector2i:
	@warning_ignore("integer_division")
	return Vector2i(COL_X + (i % 3) * COL_PITCH, ROW_Y + (i / 3) * ROW_PITCH)


## 六个角的刻度画在放大图四周那圈空里：普通角暗色，这一档该停的那个角亮色。
## **不画在图上**是有意的 —— 盖在环上就没法看环本身停在哪了
func _ticks(img: Image, at: Vector2i, lit_corner: int) -> void:
	for k in CORNERS.size():
		var c: Vector2i = CORNERS[k]
		var color: Color = CWStyle.IMMUNE if k == lit_corner else CWStyle.TEXT_OFF
		var r: Rect2i
		if c.x == 0:                      ## 左边两个角：刻度画在左侧空白里
			r = Rect2i(at.x + 2, at.y + PAD + c.y * ZOOM, 8, ZOOM)
		elif c.x == TILE_W - 1:           ## 右边两个角
			r = Rect2i(at.x + PAD * 2 + TILE_W * ZOOM - 10, at.y + PAD + c.y * ZOOM, 8, ZOOM)
		elif c.y == 0:                    ## 顶角
			r = Rect2i(at.x + PAD + c.x * ZOOM, at.y + 2, ZOOM * 2, 8)
		else:                             ## 底角
			r = Rect2i(at.x + PAD + c.x * ZOOM, at.y + PAD * 2 + TILE_H * ZOOM - 10, ZOOM * 2, 8)
		img.fill_rect(r, color)


func _process(_d: float) -> bool:
	_frames += 1
	if _frames == 2:
		_setup()
		return false
	if _frames < 4:
		return false
	## ① 一格一格地挪到中央再裁
	if _i < SHOW.size():
		if _wait == 0:
			_bring_to_center(CWData.MARROWS[_i])
			_wait = SETTLE
			return false
		_wait -= 1
		if _wait > 0:
			return false
		var shot := root.get_texture().get_image()
		_crops.append(shot.get_region(Rect2i(CENTER.x - TILE_W / 2, CENTER.y - TILE_H / 2,
			TILE_W, TILE_H)))
		_i += 1
		return false
	## ② 棋盘藏掉，换成说明文字当底（放大图压在一整张棋盘上什么都看不清）
	if _board.visible:
		_board.visible = false
		_label("骨髓积累进度条 · 游戏里真会出现的档位（贴图 32×34，放大 %d 倍；右下角是原大）" % ZOOM,
			Vector2(16, 12), CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
		_label("每条边摊 1/6 圈，所以 1/6 的整数倍正好停在角上。四周的短刻度 = 六个角，"
			+ "亮色那一根 = 这一档的亮弧该停在哪（从底角起顺时针：底 → 左下 → 左上 → 顶 → 右上 → 右下）",
			Vector2(16, 40), CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
		for i in SHOW.size():
			var at: Vector2i = _slot(i)
			_label(str(SHOW[i][3]), Vector2(at.x, at.y - 16), CWStyle.SIZE_LABEL, CWStyle.TEXT_HI)
		return false
	if _frames < 40:
		return false
	var out := root.get_texture().get_image()
	for i in _crops.size():
		var at: Vector2i = _slot(i)
		var big := Image.create(TILE_W, TILE_H, false, _crops[i].get_format())
		big.copy_from(_crops[i])
		big.resize(TILE_W * ZOOM, TILE_H * ZOOM, Image.INTERPOLATE_NEAREST)
		out.blit_rect(big, Rect2i(0, 0, big.get_width(), big.get_height()), at + Vector2i(PAD, PAD))
		_ticks(out, at, int(SHOW[i][4]))
		## 原大摆在放大图右边，方便对着看游戏里到底多大
		out.blit_rect(_crops[i], Rect2i(0, 0, TILE_W, TILE_H),
			at + Vector2i(TILE_W * ZOOM + PAD * 2 + 8, TILE_H * ZOOM - TILE_H))
	out.save_png(_out)
	print("已保存 ", _out)
	return true
