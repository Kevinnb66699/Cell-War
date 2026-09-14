extends SceneTree
## 画 exe 图标 —— 主体是 **T 细胞**（Kevin 2026-09-14 定）。开发工具，不是测试。
##
## **用游戏里那张真图**（`assets/art/cells/tcell.png`，24×24、4 色），不另画一只：
## 图标和棋盘上站着的那只是同一只，才叫一家人；而且生成模型画不出这种带尖刺的剪影
## （上一轮 A 方案就是栽在形状上）。
##
## **就是那只细胞本身**（Kevin 2026-09-14 拍板：不要六边格底板、不要青色描边）——
## 原图一个像素不动，只是摆进方画布、按整数倍放大。
##
## **每个尺寸各自成图**，不是画大再缩：32 是正身（细胞 24×24 居中、四周留 4px），
## 64 / 128 / 256 由它整数倍放大（最近邻）；48 先 ×3 再半采样；
## **16 单独降采样 + 手修** —— 24 降到 16 是 2:3，直接缩会把尖刺削没，所以按 3×3 块投票，
## 再把四根主刺手工补回来（见 `_c16`）。
##
## 跑（可以 --headless）：
##   godot --headless --path game --script res://tests/make_icon.gd -- <输出目录> [<对照图.png>]
## **对照图别往 assets 里写** —— 那是给人看的，写进去会跟着客户端包一起发出去
## 产出：c1_16/32/48/64/128/256.png、c2_同上、sheet.png（两变体 × 深浅两底 × 三档尺寸）
const CELL := preload("res://assets/art/cells/tcell.png")
const INK := Color("1a1a2e")          ## 原图那圈描边色，16px 重画时也用它
const CLEAR := Color(0, 0, 0, 0)

var _out := "user://icon"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	DirAccess.make_dir_recursive_absolute(_out)
	var i16 := _c16_ball()
	var i32 := _c32()
	i16.save_png("%s/icon_16.png" % _out)
	i32.save_png("%s/icon_32.png" % _out)
	for n in [48, 64, 128, 256]:
		_scaled(i32, n).save_png("%s/icon_%d.png" % [_out, n])
	if args.size() > 1:
		_sheet(i16, i32).save_png(args[1])
	print("图标已写到 ", _out)
	quit()


## 最近邻放大；48 不是 32 的整数倍，先 ×3 到 96 再半采样，比直接 1.5 倍少糊得多
static func _scaled(src: Image, n: int) -> Image:
	var big := Image.create(src.get_width(), src.get_height(), false, Image.FORMAT_RGBA8)
	big.copy_from(src)
	if n == 48:
		big.resize(96, 96, Image.INTERPOLATE_NEAREST)
		big.resize(48, 48, Image.INTERPOLATE_BILINEAR)
	else:
		big.resize(n, n, Image.INTERPOLATE_NEAREST)
	return big


## 剪影外一圈：**只描不透明像素的四邻**，斜角不描（斜角一描，尖刺就变成钝角的团）
static func _rim(img: Image, color: Color) -> void:
	var w := img.get_width()
	var add: Array[Vector2i] = []
	for y in w:
		for x in w:
			if img.get_pixel(x, y).a > 0.0:
				continue
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n: Vector2i = Vector2i(x, y) + d
				if n.x >= 0 and n.y >= 0 and n.x < w and n.y < w and img.get_pixelv(n).a > 0.0:
					add.append(Vector2i(x, y))
					break
	for p in add:
		img.set_pixelv(p, color)


## ---- 32×32 正身 ----
func _c32() -> Image:
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	img.fill(CLEAR)
	## 24×24 原图居中，四周留 4px —— 图标都要留白，贴边反而显小
	img.blend_rect(CELL.get_image(), Rect2i(0, 0, 24, 24), Vector2i(4, 4))
	return img


## ---- 16×16：按几何画一颗「带刺的球」 ----
## **不是把 24×24 缩下来**（2:3 缩放必然把一格宽的尖刺整根削掉，缩完只剩一个紫团），
## 也不是照着原图手抠（试过，胞体一扁就读成「眼睛」）。
## 16 格里能表达的只有一件事：**圆胞体 + 几根戳出去的刺**。所以刺少而粗（6 根、各 2 格长），
## 胞体压到直径 9，亮面在内、暗面在外一圈，左上两格高光 —— 这是原图那只 T 细胞的「骨架」。
const SPIKES := 6                     ## 6 根：16 格里再多就糊成一圈毛边
const R_IN := 3.4                     ## 亮面半径
const R_OUT := 4.6                    ## 暗面外沿
const R_TIP := 7.2                    ## 刺尖

func _c16_ball() -> Image:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(CLEAR)
	var body := Color("2b2a88")
	var lit := Color("6564e8")
	var c := Vector2(7.5, 7.5)
	## 六根刺：从暗面外沿一路点到刺尖。**先画刺再画胞体**，胞体盖住刺根，看着才像长出来的
	for i in SPIKES:
		var ang: float = -PI / 2.0 + TAU * float(i) / float(SPIKES)
		var dir := Vector2(cos(ang), sin(ang))
		var r := R_OUT - 0.6
		while r <= R_TIP:
			var p := c + dir * r
			var q := Vector2i(int(roundf(p.x)), int(roundf(p.y)))
			if q.x >= 0 and q.y >= 0 and q.x < 16 and q.y < 16:
				img.set_pixelv(q, body)
			r += 0.8
	for y in 16:
		for x in 16:
			var d := Vector2(x, y).distance_to(c)
			if d <= R_IN:
				img.set_pixel(x, y, lit)
			elif d <= R_OUT:
				img.set_pixel(x, y, body)
	## 左上两格高光 —— 和原图同一个方向（那只 T 细胞的光也在左上）
	img.set_pixel(6, 6, Color("e8e6f8"))
	img.set_pixel(5, 7, Color("e8e6f8"))
	## 描边：紫蓝在浅色底上会糊，靠这圈深色把形咬出来（原图自己也有这圈）
	_rim(img, INK)
	return img


## ---- 对照图：四档尺寸 × 深浅两底 ----
func _sheet(i16: Image, i32: Image) -> Image:
	var sheet := Image.create(620, 300, false, Image.FORMAT_RGBA8)
	sheet.fill_rect(Rect2i(0, 0, 620, 150), Color("202020"))     # Windows 深色文件管理器
	sheet.fill_rect(Rect2i(0, 150, 620, 150), Color("f3f3f3"))   # 浅色
	var x := 24
	## 16 原大（就是文件列表里那个大小）、16 放大 4 倍看清、32 原大、32 放大 4 倍
	for pair in [[i16, 16], [i16, 64], [i32, 32], [i32, 128], [_scaled(i32, 48), 48]]:
		var n: int = int(pair[1])
		var src: Image = pair[0]
		var big: Image = src if src.get_width() == n else _scaled(src, n)
		for row in 2:
			sheet.blend_rect(big, Rect2i(0, 0, n, n), Vector2i(x, row * 150 + 75 - n / 2))
		x += n + 30
	return sheet
