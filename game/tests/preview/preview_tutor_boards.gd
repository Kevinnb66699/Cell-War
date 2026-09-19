extends SceneTree
## 新手教程 v2 · **各关盘面示意图 v2** —— 给 hxr 圈格子用的工具，不是测试。
##
## 出处：最终方案 §8.3 的 ★Q-05「第七关整张地图与 T 细胞站位要具体格子；第二、三关的
## 『凸的癌组织连通块』『向前 / 向周围延伸』也要圈定」；Kevin 2026-09-19「按默认走：
## 我方出示意图给 hxr 圈」。设计改动先出示意图是既定流程。
##
## **v2（Kevin 2026-09-19 三条意见）改了什么**：
##   ① **全部关卡是同一张不断生长的地图** —— 剧本从第一关起每关都写「地图延伸」，
##      第七关的「界面变化」只写了侧边栏与按钮、**没写换地图**，所以第七关必须接着
##      第五关 + 间章的盘面继续。逐关的活跃格集合是**前一关的严格超集**，
##      已露出的格子一格都不挪位置（v1 里第七关另起一张图，作废）。
##   ② **第四 / 第五关的地图大幅扩大**（v1 是半径 2 的 19 格；v2 第四关 38 格、
##      第五关 47 格）。右栏 9 席是**席位**上限，不是格子上限，别拿它限制地图。
##   ③ **第三关按 09-19 02:12 的 PRD:227 重画**：「地图自免疫细胞向前方横向延伸开来，
##      延伸部分纵向宽度扩充为 3 格」⇒ 3 格宽的横带 + 几格外一个凸的癌组织连通块。
##      横带一宽，「用最少能量走过去」才真的变成一道题（直线 4 步踩 2 格癌 = 3.0，
##      绕 r=0 排 5 步全健康 = 2.5），第三关的能量 6.1 就是照这张图算的。
##
## 每一关一帧，画的是**方案默认摆法**，不是定案：
##   · 格子按类型上真贴图（健康 / 癌组织 / 固化癌组织 / 坏死），不是平底色
##     （「界面预览必须画全常驻件 / 平底色会骗人」那条教训）
##   · 细胞上 `assets/art/cells/anim/*_breath.png` 的真贴图，脚底落在格顶面
##   · **每个活跃格中央下方叠一个 10 号字的轴坐标「q,r」** —— hxr 直接照着圈
##   · 左上角写关名 + 要 hxr 答的问题；底部一条图例列出本帧每只细胞的席位 / 坐标 / 能量
##   · 剪影：**淡青 = 本关新浮现的格**、**橙 = 要 hxr 圈的癌组织 / 固化格**、
##     **深青 = 几何锚点**（第三关最省路落点、第七关围圈终点 / 击退落点 / 转移落点）
##   · 最后一帧是**全关卡叠图**：同一张图上按关次上色 + 在格心写关号，一眼看出连续生长
##
## 镜头照教程小棋盘的口径：**按活跃格集合推近**（`CWMatch.tutorial_active_tiles()` →
## `board.set_active_tiles()`，半径全程 6、小棋盘只是遮罩），不重铺格网。
##
## 跑（**不能加 --headless**，要真渲染；新脚本先 `--import`）：
##   godot --path game --script res://tests/preview/preview_tutor_boards.gd -- <输出目录>

# ── 细胞贴图（同 preview_tut_v2_A.gd / tutorial_opening.gd 的那一族）──
const CELL_ART := {
	"immune": preload("res://assets/art/cells/anim/immune_breath.png"),
	"tcell": preload("res://assets/art/cells/anim/tcell_breath.png"),
	"bcell": preload("res://assets/art/cells/anim/bcell_breath.png"),
	"macro": preload("res://assets/art/cells/anim/macrophage_breath.png"),
	"dendritic": preload("res://assets/art/cells/anim/dendritic_breath.png"),
	"osteo": preload("res://assets/art/cells/anim/osteo_breath.png"),
	"sclc": preload("res://assets/art/cells/anim/sclc_breath.png"),
	"signet": preload("res://assets/art/cells/anim/signet_breath.png"),
}
const ICON_ART := {
	"immune": preload("res://assets/art/cells/immune.png"),
	"tcell": preload("res://assets/art/cells/tcell.png"),
	"bcell": preload("res://assets/art/cells/bcell.png"),
	"macro": preload("res://assets/art/cells/macrophage.png"),
	"dendritic": preload("res://assets/art/cells/dendritic.png"),
	"osteo": preload("res://assets/art/cells/osteo.png"),
	"sclc": preload("res://assets/art/cells/sclc.png"),
	"signet": preload("res://assets/art/cells/signet.png"),
}
const IMMUNE_KINDS := ["immune", "tcell", "bcell", "macro", "dendritic"]
const BREATH_FRAMES := 6
const CELL_FOOT_DY := 6.0      ## 同 CWMatch：脚底落在格顶面中心再往下 6px

## 坐标标签落在格顶面中心**下方** 8px。细胞贴图的下边缘正好是 +6（脚底），
## 所以 +8 起画的标签在任何倍率下都不会压到细胞身上（这是 8 而不是 6 的唯一理由）。
const LABEL_DY := 8.0
## 标签挂在棋盘里、z 取 `Z_MARK`（比同格细胞低一档）⇒ 前排细胞压得住后排标签；
## 再用 `scale = 1/zoom` 把它拉回**屏幕上恰好 10px**（CWStyle.SIZE_LABEL）。
## 放进 CanvasLayer 就做不到「被细胞压住」，那样密排的第四 / 五关会糊成一片。
const LABEL_COL := Color("f2fbff")

const HEAD_W := 924.0          ## 问题板的宽度：铺满一行，问题就很少折行，板子压不到棋盘
const BOARD_ANCHOR := Vector2(480, 294)
const BOARD_AVAIL := Vector2(906, 280)

const LATE := 0.26             ## 搭完场景等这么久再量标签（剪影补间 MARK_FADE = 0.22）
const GAP := 0.70              ## 每帧总时长

## 叠图那一帧：每一关一个颜色。剪影用 alpha 0.5 的同色，格心的关号用不透明的同色。
## 「本关新浮现的格」用一层**很淡**的青（0x33 ≈ 0.20），不用 board.MARK_MOVE（0x6E ≈ 0.43）——
## 第三 / 四关一次新增十几二十格，0.43 的青会把整张图刷成一片，组织颜色当场看不出来
## （「平底色会骗人」那条教训的同一个坑：示意图的底色必须仍然是真组织色）。
const MARK_NEW := Color("30d1fa33")

const LV_COLOR := {
	1: Color("30d1fa"),   ## 第一关 免疫青
	2: Color("ffb03a"),   ## 第二关 癌方橙
	3: Color("7ee787"),   ## 第三关 绿
	4: Color("c792ea"),   ## 第四关 紫
	5: Color("ff6b6b"),   ## 第五关 红
	7: Color("f2fbff"),   ## 第七关 白（含第 23 步的边缘再生格）
}

var _dir := "user://"
## Board.tscn 的实例。**不加类型注解**：board.gd 没有 class_name，
## 标成 Node2D 就够不着 tile_center / tile_z / MARK_MOVE 这些成员
var _board
var _cells: Node2D
var _labels: Node2D
var _cam: Camera2D
var _ui: CanvasLayer
var _frames := 0
var _t := 0.0
var _queue: Array = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_dir = args[0]
	if not _dir.ends_with("/"):
		_dir += "/"
	DirAccess.make_dir_recursive_absolute(_dir)

	var bg := ColorRect.new()
	bg.color = CWStyle.GROUND
	bg.size = CWView.screen_size()
	root.add_child(bg)
	_board = load("res://scenes/Board.tscn").instantiate()
	root.add_child(_board)
	_cells = Node2D.new()
	_board.add_child(_cells)
	_labels = Node2D.new()
	_board.add_child(_labels)
	_cam = Camera2D.new()
	root.add_child(_cam)
	_ui = CanvasLayer.new()
	root.add_child(_ui)

	_audit()

	var frames: Array = [
		["01_第一关_免疫", _f1],
		["02_第二关_癌", _f2],
		["03_第三关_ATP_三格宽横带", _f3],
		["04_第四关_抗原记忆", _f4],
		["05_第五关_分化_Step2", _f5],
		["06_第七关_初始", _f7a],
		["07_第七关_第23步_边缘再生", _f7b],
		["08_全关卡叠图_同一张图的生长", _f8],
	]
	var at := 0.05
	for f in frames:
		var shot_name: String = f[0]
		var build: Callable = f[1]
		_at(at, func() -> void:
			_reset()
			build.call())
		_at(at + GAP, func() -> void: _shot(shot_name))
		at += GAP + 0.05
	_at(at + 0.2, func() -> void: quit())


func _at(t: float, fn: Callable) -> void:
	_queue.append({ "at": t, "fn": fn })
	_queue.sort_custom(func(a, b) -> bool: return a["at"] < b["at"])


func _process(delta: float) -> bool:
	## 头两帧棋盘的 map 还没铺完（Board._ready 里才建 127 格），
	## 这时候 set_tissue / tile_center 全部落空（preview_solidify 踩过）
	_frames += 1
	if _frames < 3:
		return false
	_t += delta
	while not _queue.is_empty() and _t >= _queue[0]["at"]:
		var step: Dictionary = _queue.pop_front()
		step["fn"].call()
	return false


func _shot(shot_name: String) -> void:
	var path: String = _dir + shot_name + ".png"
	var err := root.get_texture().get_image().save_png(path)
	print("已保存 %s (err=%d)" % [path, err])


func _reset() -> void:
	for c in _ui.get_children():
		_ui.remove_child(c)
		c.queue_free()
	for c in _cells.get_children():
		_cells.remove_child(c)
		c.queue_free()
	for c in _labels.get_children():
		_labels.remove_child(c)
		c.queue_free()
	_board.set_necrosis([])


# ════════════════════════════════════════════════════════════════
#  活跃格集合：**逐关严格超集**，v2 的第一条硬约束就写在这七行里
# ════════════════════════════════════════════════════════════════
#
#  坐标系：r = 常数是一条横排、+q 向右。特殊组织的 r 只取 -3 / 0 / 3 / 6，
#  所以 r = -1 / -2 / -4 / -5 / 1 / 2 六整排一个特殊格都没有。
#  压到特殊格的活跃格逐格写 "type": "normal" 摊平（全教程共 5 格，见 _audit 打印）。

func _rows(spec: Dictionary) -> Array:
	var out: Array = []
	for r in spec:
		var lo: int = spec[r][0]
		var hi: int = spec[r][1]
		for q in range(lo, hi + 1):
			var c := Vector2i(q, int(r))
			if CWData.is_on_board(c):
				out.append(c)
	return out


## 第一关：两个横向连接的健康组织（PRD:95）。走 r=-1 排的最左端 —— 这一排
## 一个特殊格都没有，而且 q 从 -5 到 6 共 12 格、跨度 11，正好是第七关要的那条直线。
func _a1() -> Array:
	return [Vector2i(-5, -1), Vector2i(-4, -1)]

## 第二关：右延两格健康 + 两格癌（PRD:143），Step2 再延一格癌（PRD:187）。
func _a2() -> Array:
	return _rows({ -1: [-5, 1] })

## 第三关：自免疫细胞向前方横向延伸，**延伸部分纵向宽度 3 格**（PRD:227）。
func _a3() -> Array:
	return _a2() + _rows({ -1: [2, 6], -2: [0, 6], 0: [0, 6] })

## 第四关：自免疫细胞向周围延伸开来（PRD:291）。横带上下各长一排、左边补一格。
func _a4() -> Array:
	return _a3() + _rows({ -3: [1, 5], 0: [-1, -1], 1: [-1, 4] })

## 第五关 Step2：癌组织连通块扩大（PRD:361），地图跟着往外长一圈接住它。
func _a5() -> Array:
	return _a4() + _rows({ -4: [2, 5], 2: [-1, 3] })

## 第七关初始：只在**外缘**补一个左口袋 —— 把 T 细胞那一头从一格宽的死胡同
## 撑成 3 格宽，【黏液破裂】的两环转化与最后一幕才有地方演。已露出的格一格不动。
func _a7() -> Array:
	return _a5() + _rows({ -2: [-4, -1], 0: [-5, -2] })

## 第七关第 23 步：右缘再补三格，放「地图边缘再次生成」的 T / B（PRD:499）。
func _a7b() -> Array:
	return _a7() + _rows({ -3: [6, 6], -4: [6, 6], -5: [6, 6] })


## 开跑前把几何账算一遍打到控制台：格数、超集关系、特殊格、第七关距离。
## 图是给人看的，这一段是给改图的人看的 —— 动一格坐标，这里立刻报出来。
func _audit() -> void:
	var sets: Array = [["第一关", _a1()], ["第二关", _a2()], ["第三关", _a3()],
		["第四关", _a4()], ["第五关", _a5()], ["第七关初始", _a7()], ["第七关第23步", _a7b()]]
	var prev: Array = []
	for s in sets:
		var name: String = s[0]
		var cur: Array = s[1]
		var miss := _minus(prev, cur)
		var specials: Array = []
		for c: Vector2i in cur:
			if CWData.special_of(c) != CWData.Special.NONE:
				specials.append(c)
		print("[盘面] %s：%d 格（新增 %d）；超集缺口 %d；压到特殊格 %d"
			% [name, cur.size(), cur.size() - prev.size(), miss.size(), specials.size()])
		prev = cur
	var t := Vector2i(-5, -1)
	print("[几何] 围圈终点(4,-1)→T%s 距离 %d；击退落点(6,-1)→T 距离 %d；转移两跳 (1,-1)/(-4,-1)，落点→T 距离 %d"
		% [t, CWData.hex_dist(Vector2i(4, -1), t), CWData.hex_dist(Vector2i(6, -1), t),
			CWData.hex_dist(Vector2i(-4, -1), t)])


# ════════════════════════════════════════════════════════════════
#  坐标小工具
# ════════════════════════════════════════════════════════════════

func _row(r: int, q0: int, q1: int) -> Array:
	var out: Array = []
	for q in range(q0, q1 + 1):
		var c := Vector2i(q, r)
		if CWData.is_on_board(c):
			out.append(c)
	return out


func _ring(center: Vector2i) -> Array:
	var out: Array = []
	for d in CWData.DIRS:
		var c: Vector2i = center + d
		if CWData.is_on_board(c):
			out.append(c)
	return out


func _minus(a: Array, b: Array) -> Array:
	var out: Array = []
	for c in a:
		if not b.has(c):
			out.append(c)
	return out


## 一批格上同一个剪影色；已经有色的不覆盖（优先级由调用顺序定：深青 > 橙 > 淡青）
func _paint(marks: Dictionary, tiles: Array, col: Color) -> void:
	for c: Vector2i in tiles:
		if not marks.has(c):
			marks[c] = col


# ════════════════════════════════════════════════════════════════
#  一帧 = 铺组织 + 摆细胞 + 对机位 + 打坐标 + 写问题 + 列图例
# ════════════════════════════════════════════════════════════════

## cfg 的键：
##   title  ask[]                      左上角问题板
##   active[]                          活跃格（露出来的那几格）
##   ghost[]                           **活跃格之外**的预置格（第七关的再生席位），只进机位不铺组织
##   cancer[] solid[] necro[]          格子类型；其余活跃格一律健康
##   marks{}                           剪影：coord -> Color
##   numbers{}                         覆盖坐标标签：coord -> [文字, 颜色]（叠图那一帧用）
##   cells[]                           { kind, at, seat, name, e, ghost }
func _build(cfg: Dictionary) -> void:
	var active: Array = cfg.get("active", [])
	var cancer: Array = cfg.get("cancer", [])
	var solid: Array = cfg.get("solid", [])
	var ghost: Array = cfg.get("ghost", [])
	var numbers: Dictionary = cfg.get("numbers", {})

	_board.set_active_tiles(active, 0.0)
	for c: Vector2i in _minus(_minus(active, cancer), solid):
		_board.set_tissue(c, CWData.Tissue.HEALTHY, CWData.Special.NONE)
	for c: Vector2i in cancer:
		_board.set_tissue(c, CWData.Tissue.CANCER, CWData.Special.NONE)
	for c: Vector2i in solid:
		_board.set_tissue(c, CWData.Tissue.SOLID, CWData.Special.NONE, true, 1.0)
	_board.set_necrosis(cfg.get("necro", []))
	_board.set_marks(cfg.get("marks", {}))

	## 机位：活跃格 ∪ 预置格一起进包围盒，第七关两帧才框得一样大
	var z := _focus(active + ghost, BOARD_ANCHOR, BOARD_AVAIL)

	## 细胞贴图是从脚底往上长的，站得高的那只看上去压在**上一排**格子上。
	## 示意图要让 hxr 一眼分清「谁站哪格」⇒ 站了细胞的格，坐标改用阵营色写。
	var occ := {}
	for e in cfg.get("cells", []):
		_cell(e)
		occ[e["at"]] = CWStyle.IMMUNE if IMMUNE_KINDS.has(String(e["kind"])) else CWStyle.CANCER
	for c: Vector2i in active:
		if numbers.has(c):
			_tile_label(c, z, 1.0, numbers[c][1], String(numbers[c][0]))
		else:
			_tile_label(c, z, 1.0, occ.get(c, LABEL_COL))
	for c: Vector2i in ghost:
		_tile_label(c, z, 0.42, occ.get(c, LABEL_COL))

	_head(String(cfg.get("title", "")), cfg.get("ask", []))
	_legend(cfg.get("cells", []))


## 把这批格摆进屏幕上的一块可用区，棋盘小就自动推近；返回最终倍率（坐标标签要拿它反缩放）。
## 顶到 3.2 就不再放大（菜单机位的倍率），再近能看出贴图边缘的插值。
func _focus(tiles: Array, anchor: Vector2, avail: Vector2, max_zoom := 3.2) -> float:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for c: Vector2i in tiles:
		var p: Vector2 = _board.tile_center(c)
		## 上边多留 34：格子上站着的细胞比顶面高一整个身位；下边留 30 给坐标标签
		lo = Vector2(minf(lo.x, p.x - 20.0), minf(lo.y, p.y - 34.0))
		hi = Vector2(maxf(hi.x, p.x + 20.0), maxf(hi.y, p.y + 30.0))
	var span: Vector2 = hi - lo
	var z: float = minf(minf(avail.x / maxf(span.x, 1.0), avail.y / maxf(span.y, 1.0)), max_zoom)
	_cam.zoom = Vector2(z, z)
	_cam.position = CWView.camera_pos_for((lo + hi) * 0.5, anchor, z, CWView.screen_size())
	return z


func _cell(e: Dictionary) -> void:
	var kind := String(e["kind"])
	var c: Vector2i = e["at"]
	var tex: Texture2D = CELL_ART[kind]
	var s := Sprite2D.new()
	s.texture = tex
	s.hframes = BREATH_FRAMES
	s.frame = 2
	s.offset = Vector2(0, -tex.get_height() / 2.0)   ## 锚点从贴图中心挪到脚底中心
	s.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	s.position = _board.tile_center(c) + Vector2(0, CELL_FOOT_DY)
	s.z_index = _board.tile_z(c, _board.Z_CELL)
	if bool(e.get("ghost", false)):
		s.modulate = Color(1, 1, 1, 0.3)             ## 预置但还没揭示的席位
	_cells.add_child(s)


## 一个活跃格的标签（默认写轴坐标）。见 LABEL_DY / LABEL_COL 上的两段说明。
func _tile_label(c: Vector2i, z: float, alpha: float, col: Color, text := "") -> void:
	var txt := text if text != "" else "%d,%d" % [c.x, c.y]
	var lb := CWStyle.label(txt, CWStyle.SIZE_LABEL, Color(col, alpha))
	## 描边而不是垫块：垫块在密排的第四 / 五关会连成一片黑带，把组织颜色盖掉
	lb.add_theme_color_override("font_outline_color", Color(0.02, 0.05, 0.08, alpha * 0.95))
	lb.add_theme_constant_override("outline_size", 5)
	var w: float = CWStyle.FONT.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1,
		CWStyle.SIZE_LABEL).x
	lb.size = Vector2(w + 2.0, 14.0)
	lb.scale = Vector2(1.0 / z, 1.0 / z)
	lb.position = _board.tile_center(c) + Vector2(-(w + 2.0) * 0.5 / z, LABEL_DY)
	## 整层压在棋盘内容之上（同骰子层的理由）：坐标要盖住的是**别人格子**上的细胞 ——
	## 按排比大小的 tile_z 表达不了这件事。第四 / 五关密排时，斜下方那只细胞的贴图
	## 正好长到上一排的标签上，按 tile_z 排就会把「-1,-1」啃成「1,-1」（渲图逐帧确认过）。
	## 标签落在格心下方 8px、细胞贴图下边缘在 +6 ⇒ 自己那格的细胞永远不会被自己的标签压到。
	lb.z_index = _board.Z_DICE_TOP
	_labels.add_child(lb)


# ════════════════════════════════════════════════════════════════
#  左上角问题板 / 底部图例
# ════════════════════════════════════════════════════════════════

func _head(title: String, asks: Array) -> void:
	var pan := Panel.new()
	pan.add_theme_stylebox_override("panel", CWStyle.box(0.45, Color(CWStyle.PANEL, 0.92)))
	pan.position = Vector2(12, 8)
	var t := CWStyle.label(title, CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
	t.position = Vector2(12, 7)
	pan.add_child(t)
	var y := 35.0
	for a in asks:
		var s := String(a)
		var col: Color = CWStyle.TEXT
		if s.begins_with("圈"):
			col = CWStyle.CANCER
		elif s.begins_with("图例") or s.begins_with("长"):
			col = CWStyle.TEXT_DIM
		var lb := CWStyle.label(s, CWStyle.SIZE_LABEL, col)
		lb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		var one: float = CWStyle.FONT.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1,
			CWStyle.SIZE_LABEL).x
		var rows: int = maxi(1, int(ceil(one / (HEAD_W - 26.0))))
		lb.size = Vector2(HEAD_W - 26.0, rows * 15.0)
		lb.position = Vector2(12, y)
		pan.add_child(lb)
		y += rows * 15.0 + 3.0
	pan.size = Vector2(HEAD_W, y + 5.0)
	_ui.add_child(pan)


func _legend(cells: Array) -> void:
	if cells.is_empty():
		return
	var pan := Panel.new()
	pan.add_theme_stylebox_override("panel", CWStyle.box(0.45, Color(CWStyle.PANEL, 0.92)))
	pan.position = Vector2(12, 440)
	pan.size = Vector2(936, 90)
	for i in cells.size():
		var e: Dictionary = cells[i]
		var col: int = i / 3
		var rowi: int = i % 3
		var x: float = 12.0 + col * 310.0
		var y: float = 7.0 + rowi * 26.0
		var ic := TextureRect.new()
		ic.texture = ICON_ART[String(e["kind"])]
		ic.position = Vector2(x, y)
		ic.size = Vector2(22, 22)
		ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ic.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		if bool(e.get("ghost", false)):
			ic.modulate = Color(1, 1, 1, 0.45)
		pan.add_child(ic)
		var c: Vector2i = e["at"]
		var txt := "席%d　%s　(%d,%d)　E %s" % [int(e["seat"]), String(e["name"]), c.x, c.y,
			String(e["e"])]
		var lb := CWStyle.label(txt, CWStyle.SIZE_LABEL,
			CWStyle.TEXT_OFF if bool(e.get("ghost", false)) else CWStyle.TEXT)
		lb.position = Vector2(x + 27.0, y + 5.0)
		pan.add_child(lb)
	_ui.add_child(pan)


const TIP_COLOR := "图例　格色：绿 = 健康　红 = 癌组织　石 = 固化癌组织　灰纹 = 坏死　|　坐标色：青 = 这格站着免疫　橙 = 站着癌细胞　|　剪影：淡青 = 本关新浮现的格　橙 = 要圈的癌组织 / 固化格　深青 = 几何锚点"


# ════════════════════════════════════════════════════════════════
#  八帧
# ════════════════════════════════════════════════════════════════

## 第一关（PRD:91-137）。两个横向连接的健康组织，一格起、一格落。
func _f1() -> void:
	var active := _a1()
	var marks := {}
	marks[Vector2i(-4, -1)] = _board.MARK_PLAN
	_build({
		"title": "第一关 免疫 —— 同一张图的第 1 步（新增 2 格）",
		"ask": [
			"圈①　两格的位置：默认 (-5,-1) 起、(-4,-1) 落（深青）。摆在 r=-1 排的**最左端**是 v2 的骨架决定的 —— 这一排 q 从 -5 到 6 共 12 格、跨度 11，整个教程就沿着它向右长，第七关的「距离 9 + 击退 2」也正好用完这条线。",
			"圈②　玩家起点要不要和开场动画里细胞跌落的落点对上？（开场动画保留不动，落点可按这一关调。）",
			"长期账：**这两格到第七关还在原处**，而且 (-5,-1) 最后站着那只要杀死你的 T 细胞、(-4,-1) 是你最后一次【转移】的落点 —— 首尾在同两格上收口。不想要这个呼应就说，改 T 的落位即可。",
			"癌席按数据纪律 8 给一只 alive:false 的死细胞压在活跃集之外 (6,-1)，看不见也点不到，图上不画。",
			TIP_COLOR,
		],
		"active": active,
		"marks": marks,
		"cells": [
			{ "kind": "immune", "at": Vector2i(-5, -1), "seat": 0,
				"name": "玩家·未分化免疫", "e": "∞（哨兵 99990）" },
		],
	})


## 第二关（PRD:139-215）。Step1 右延两格健康 + 两格癌；Step2 再延一格癌 + 1.0 能量癌细胞。
func _f2() -> void:
	var active := _a2()
	var marks := {}
	_paint(marks, [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1)], _board.MARK_ATTACK)
	_paint(marks, _minus(active, _a1()), MARK_NEW)
	_build({
		"title": "第二关 癌 —— 第 2 步（新增 5 格，全在 r=-1 排上继续向右）",
		"ask": [
			"圈①　Step1 右延的两格健康 (-3,-1) (-2,-1) 与两格癌 (-1,-1) (0,-1)：位置与格数对吗？",
			"圈②　Step2 再延的一格癌 (1,-1)，1.0 能量癌细胞就站这一格 —— 对吗？",
			"圈③　免疫起点 (-4,-1)（承接第一关终点），往右四步正好净化两格癌、停在 (0,-1) 与癌细胞邻接，与 PRD:153「向右移动四格」严丝合缝。",
			"圈④（= Q2-4）1.0 能量 + 一次成功 1.0 伤害 = 一击必杀，而 PRD:203 写「攻击癌细胞直到其死亡」。改文案为「击杀它」，还是把能量抬到 2.0、带子给两颗骰？",
			TIP_COLOR,
		],
		"active": active,
		"cancer": [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1)],
		"cells": [
			{ "kind": "immune", "at": Vector2i(-4, -1), "seat": 0,
				"name": "玩家·未分化免疫", "e": "∞（哨兵 99990）" },
			{ "kind": "osteo", "at": Vector2i(1, -1), "seat": 1,
				"name": "骨肉瘤（Step2 才现）", "e": "1.0" },
		],
	})


## 第三关（PRD:223-283）。**09-19 02:12 的新描述**：向前方横向延伸、延伸部分纵向宽 3 格。
func _f3() -> void:
	var active := _a3()
	var cancer := [Vector2i(1, -1), Vector2i(4, -1), Vector2i(5, -1), Vector2i(6, -1),
		Vector2i(5, -2)]
	var marks := {}
	marks[Vector2i(4, 0)] = _board.MARK_PLAN            ## 唯一落在预算内的落点
	_paint(marks, [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0)],
		_board.MARK_PLAN)                                ## 2.5 那条最省路
	_paint(marks, cancer, _board.MARK_ATTACK)
	_paint(marks, _minus(active, _a2()), MARK_NEW)
	_build({
		"title": "第三关 ATP —— 第 3 步（新增 19 格：3 格宽的横带，PRD:227 新描述）",
		"ask": [
			"圈①　3 格宽的横带 = r=-2 / r=-1 / r=0 三排、q 从 0 到 6。横带里 (3,0) 是代谢核心、(6,0) 是血管，按数据纪律 2 显式写 type:normal 摊平。范围对吗？",
			"圈②　「凸的癌组织连通块」：默认 (4,-1)(5,-1)(6,-1) 一条，再由 (5,-2) 向上凸一格；3.0 能量的癌细胞站正中 (5,-1)。要不要改凸的方向？",
			"圈③　横带一宽，「用最少能量过去」才真是一道题：直线 4 步要踩 (1,-1) 与 (4,-1) 两格癌 = 3.0；绕 r=0 排 5 步全健康 = **2.5**（深青那条），落点 (4,0)。**能量 6.1 = 2.5 + 攻击三次 3.0 + 失效自损 0.5 + 0.1**，只有走深青这条才进得了预算。这三格一动，6.1 就要重算。",
			"圈④　(1,-1) 是第二关打完留在原地的那格癌组织（没被净化）。留着它，最省路才唯一；要在第二关末加一步净化掉吗？",
			TIP_COLOR,
		],
		"active": active,
		"cancer": cancer,
		"marks": marks,
		"cells": [
			{ "kind": "immune", "at": Vector2i(0, -1), "seat": 0,
				"name": "玩家·未分化免疫", "e": "6.1" },
			{ "kind": "osteo", "at": Vector2i(5, -1), "seat": 1,
				"name": "骨肉瘤", "e": "3.0" },
		],
	})


## 第四关（PRD:287-328）。向周围延伸 + 若干癌组织连通块 + 1~5 能量癌细胞，任务是升到 III 级。
func _f4() -> void:
	var active := _a4()
	var blk_a := [Vector2i(4, -1), Vector2i(5, -1), Vector2i(6, -1), Vector2i(5, -2),
		Vector2i(6, -2)]
	var blk_b := [Vector2i(1, -3), Vector2i(2, -3), Vector2i(3, -3), Vector2i(2, -2)]
	var blk_c := [Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1)]
	var cancer := blk_a + blk_b + blk_c + [Vector2i(1, -1)]
	var marks := {}
	_paint(marks, cancer, _board.MARK_ATTACK)
	_paint(marks, _minus(active, _a3()), MARK_NEW)
	_build({
		"title": "第四关 抗原记忆 —— 第 4 步（新增 12 格 → 38 格；v1 只有 19 格）",
		"ask": [
			"圈①　「向周围延伸」默认 = 横带上下各长一排（r=-3 的 q1~5、r=1 的 q-1~4）再往左补 (-1,0)，共 38 格。右侧顶到棋盘边缘（q=6 / s=-6），所以实际是向左、向上、向下三面长开。够大吗？",
			"圈②　三个癌组织连通块：右 5 格（第三关那块长出 (6,-2)）/ 上 4 格 / 下 4 格，外加第二关留下的孤格 (1,-1)。块数与形状对吗？",
			"圈③　癌细胞 4 只：(5,-1) 5.0 / (2,-3) 4.0 / (1,1) 3.0 / (0,1) 3.0。记忆账 = 净化 14 格得 14 + 打掉 15.0 能量得 15 = 29，升 III 只需 +10（起手 II 级 20 记忆）。增减细胞就是改这本账。",
			"长期账：右栏 9 席是**席位**上限不是格子上限 —— 本关只用 5 席（玩家 + 4 癌），地图大小与它无关。",
			TIP_COLOR,
		],
		"active": active,
		"cancer": cancer,
		"marks": marks,
		"cells": [
			{ "kind": "immune", "at": Vector2i(4, 0), "seat": 0,
				"name": "玩家·未分化免疫", "e": "∞　II 级 20 记忆" },
			{ "kind": "osteo", "at": Vector2i(5, -1), "seat": 1, "name": "骨肉瘤", "e": "5.0" },
			{ "kind": "osteo", "at": Vector2i(2, -3), "seat": 2, "name": "骨肉瘤", "e": "4.0" },
			{ "kind": "osteo", "at": Vector2i(1, 1), "seat": 3, "name": "骨肉瘤", "e": "3.0" },
			{ "kind": "osteo", "at": Vector2i(0, 1), "seat": 4, "name": "骨肉瘤", "e": "3.0" },
		],
	})


## 第五关 Step2（PRD:329-383）。连通块扩大 + 固化癌组织 + 各种类免疫各一；席位顶到 9。
func _f5() -> void:
	var active := _a5()
	var blk_a := [Vector2i(4, -1), Vector2i(5, -1), Vector2i(5, -2), Vector2i(6, -2),
		Vector2i(4, -2), Vector2i(5, -3)]
	var blk_b := [Vector2i(1, -3), Vector2i(2, -3), Vector2i(3, -3), Vector2i(2, -2),
		Vector2i(2, -4)]
	var blk_c := [Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1),
		Vector2i(0, 2)]
	var solid := [Vector2i(6, -1), Vector2i(3, -4), Vector2i(1, 2)]
	var marks := {}
	_paint(marks, solid, _board.MARK_PLAN)
	_paint(marks, blk_a + blk_b + blk_c, _board.MARK_ATTACK)
	_paint(marks, _minus(active, _a4()), MARK_NEW)
	_build({
		"title": "第五关 分化 Step2 —— 第 5 步（新增 9 格 → 47 格；9 席已到右栏上限）",
		"ask": [
			"圈①　连通块「扩大」到哪几格？默认三块各长到 7 / 6 / 6 格，地图跟着往外接一圈（r=-4 的 q2~5、r=2 的 q-1~3）—— 癌块长到哪，地图就长到哪。",
			"圈②　固化癌组织三格（深青）：(6,-1) / (3,-4) / (1,2)，写 state:solid 不是 solid 计数。它们到第七关还在，是「复活窗口必须有一格不被免疫占据的固化格」那条硬约束的余量。",
			"圈③　「各种类免疫各一」站哪几格？默认 B (1,-2) / 巨噬 (5,0) / 树突 (0,0) / **T (-5,-1)**。T 特意摆在走廊最远端 —— 它就是第七关那只「离癌细胞比较远且在一条直线上」的 T，从这一关起就在原处。不接受的话第七关得另生一只。",
			"圈④　玩家 Step2 起手站 (4,0)（关首那格）。第四 / 五关是自由行动，终局位置写不死，所以关与关之间按剧本重新指定格子（PRD 通用规则 2 静默换局）。",
			TIP_COLOR,
		],
		"active": active,
		"cancer": blk_a + blk_b + blk_c,
		"solid": solid,
		"marks": marks,
		"cells": [
			{ "kind": "immune", "at": Vector2i(4, 0), "seat": 0,
				"name": "玩家（Step1 自选分化）", "e": "∞　III 级" },
			{ "kind": "bcell", "at": Vector2i(1, -2), "seat": 1, "name": "B 细胞", "e": "1.0" },
			{ "kind": "macro", "at": Vector2i(5, 0), "seat": 2, "name": "巨噬细胞", "e": "1.0" },
			{ "kind": "dendritic", "at": Vector2i(0, 0), "seat": 3, "name": "树突细胞", "e": "1.0" },
			{ "kind": "tcell", "at": Vector2i(-5, -1), "seat": 4,
				"name": "T 细胞（走廊远端）", "e": "1.0" },
			{ "kind": "osteo", "at": Vector2i(5, -1), "seat": 5, "name": "骨肉瘤", "e": "5.0" },
			{ "kind": "osteo", "at": Vector2i(2, -3), "seat": 6, "name": "骨肉瘤", "e": "4.0" },
			{ "kind": "osteo", "at": Vector2i(1, 1), "seat": 7, "name": "骨肉瘤", "e": "3.0" },
			{ "kind": "osteo", "at": Vector2i(0, 2), "seat": 8, "name": "骨肉瘤", "e": "2.0" },
		],
	})


## 第七关开局（PRD:415-461）。几何锚：围完停 (4,-1) 距 T 9 格 → 两轮「进 1 退 2」→ 11 = 5×2+1。
func _f7a() -> void:
	var active := _a7()
	var ghost := [Vector2i(6, -3), Vector2i(6, -4), Vector2i(6, -5)]
	var solid := [Vector2i(6, -2), Vector2i(6, -1), Vector2i(3, -4), Vector2i(1, 2)]
	var marks := {}
	marks[Vector2i(4, -1)] = _board.MARK_PLAN        ## 围完停这里 = 击退序列起点，距 T 9 格
	marks[Vector2i(6, -1)] = _board.MARK_PLAN        ## 两轮击退后的落点，距 T 11 = 5×2+1
	marks[Vector2i(1, -1)] = _board.MARK_PLAN        ## 第一次【转移】落点
	marks[Vector2i(-4, -1)] = _board.MARK_PLAN       ## 第二次【转移】落点，正好邻接 T
	## 橙 = 玩家要走过去踩成癌组织的一环（把巨噬围死，第 4-5 步【微环境压迫】结算它）
	_paint(marks, _ring(Vector2i(4, -2)), _board.MARK_ATTACK)
	_paint(marks, _minus(active, _a5()), MARK_NEW)
	_build({
		"title": "第七关 初始 —— 第 6 步（只在外缘补 8 格左口袋 → 55 格；地图没换，接着第五关 + 间章）",
		"ask": [
			"圈①　围一圈围的是间章里靠过来又被击退 1 格的那只巨噬 (4,-2)，一环 6 格（橙）。玩家从固化格 (6,-2) 出发 6 步：(5,-2)(5,-3)(4,-3)(3,-2)(3,-1)(4,-1)，收在 (4,-1)（深青）—— 到 T (-5,-1) 正好 **9** 格。",
			"圈②　几何锁（四个深青）：距 9 →「进 1 退 2」两轮 → 落 (6,-1) 距 **11 = 5×2+1** → 两次【转移】(1,-1) → (-4,-1) 正好邻接 T（距离若是 5k 会落到 T 头上，非法）。全程走 r=-1 排 —— 就是第一～三关走过的那条走廊。",
			"圈③　T 细胞站 (-5,-1)，正是第一关玩家出生的那格；它的【效应应答-Excalibur】是沿一个方向打到棋盘边缘的主射线，所以「在一条直线上」是规则要求不只是演出。要不要换？",
			"圈④　左口袋 8 格（淡青，r=-2 的 q-4~-1 与 r=0 的 q-5~-2）是第七关唯一的新增：把 T 那一头从一格宽的死胡同撑成 3 格宽，【黏液破裂】的两环转化与最后一幕才有地方演。(-3,0) 是骨髓，摊平成普通格。不要的话说一声。",
			TIP_COLOR,
		],
		"active": active,
		"ghost": ghost,
		"solid": solid,
		"marks": marks,
		"cells": [
			{ "kind": "sclc", "at": Vector2i(6, -2), "seat": 0,
				"name": "玩家·小细胞肺癌", "e": "Null（内部 ∞）" },
			{ "kind": "macro", "at": Vector2i(4, -2), "seat": 1,
				"name": "巨噬（要被围的那只）", "e": "3.0" },
			{ "kind": "bcell", "at": Vector2i(1, -2), "seat": 2, "name": "B 细胞", "e": "3.0" },
			{ "kind": "dendritic", "at": Vector2i(0, 0), "seat": 3, "name": "树突细胞", "e": "3.0" },
			{ "kind": "tcell", "at": Vector2i(-5, -1), "seat": 4,
				"name": "T 细胞（走廊远端）", "e": "3.0" },
			{ "kind": "tcell", "at": Vector2i(6, -5), "seat": 5,
				"name": "T 细胞（预置）", "e": "第 23 步揭示", "ghost": true },
			{ "kind": "bcell", "at": Vector2i(6, -4), "seat": 6,
				"name": "B 细胞（预置）", "e": "第 23 步揭示", "ghost": true },
			{ "kind": "tcell", "at": Vector2i(6, -3), "seat": 7,
				"name": "T 细胞（预置）", "e": "第 23 步揭示", "ghost": true },
		],
	})


## 第七关第 23 步（PRD:499）。边缘再生 T / B 揭示之后的盘面。
func _f7b() -> void:
	var active := _a7b()
	var fresh := [Vector2i(6, -3), Vector2i(6, -4), Vector2i(6, -5)]
	var ring := _ring(Vector2i(4, -2))
	## 【黏液破裂】在 (-4,-1) 两环内转化的一片（示意，实际由带子钉死）
	var mucus := [Vector2i(-3, -1), Vector2i(-2, -1), Vector2i(-3, -2), Vector2i(-2, -2),
		Vector2i(-4, 0), Vector2i(-3, 0)]
	var solid := [Vector2i(6, -2), Vector2i(6, -1), Vector2i(3, -4), Vector2i(1, 2)]
	var marks := {}
	_paint(marks, fresh, _board.MARK_ATTACK)
	marks[Vector2i(6, -2)] = _board.MARK_PLAN
	_build({
		"title": "第七关 第 23 步 —— 边缘再生 T / B 揭示之后（新增 3 格 → 58 格，全教程终盘）",
		"ask": [
			"圈①　「地图边缘再次生成若干 T 细胞和 B 细胞」= 右缘 q=6 那一列的 (6,-3)(6,-4)(6,-5)（橙），T / B / T 三只。席位开局就预置好停在活跃集外，这一步只把三格加进活跃集 + 浮现，不新增席位。",
			"圈②　复活站哪格固化（深青 (6,-2)）？默认回**出生那格** —— 间章冲击波在脚下生成的那一格。代价：【黏液破裂】发生在 (-4,-1)、复活点在 11 格外的右缘，最后一幕整个搬回右边；好处是「回到原点」且不必另造固化格。要不要改成在 T 那一头另设一格固化，让第 22-25 步就地收尾？",
			"圈③　左边那一片：T 的【细胞毒素】1 环转健康 + 坏死（灰纹 (-5,-1)(-4,-1)(-4,-2)(-5,0)），【黏液破裂】两环转癌（红，示意）。两片都靠录带子钉，要钉死范围吗？",
			"圈④　第 24 步「所有 T 细胞一齐效应应答」：原 T 在 (-5,-1)，与复活点 (6,-2) 不在一条直线上，它那一发只能是演出；真正结算的是右缘新生的两只 T。接受吗？",
			TIP_COLOR,
		],
		"active": active,
		"cancer": ring + mucus,
		"solid": solid,
		"necro": [Vector2i(-5, -1), Vector2i(-4, -1), Vector2i(-4, -2), Vector2i(-5, 0)],
		"marks": marks,
		"cells": [
			{ "kind": "signet", "at": Vector2i(6, -2), "seat": 0,
				"name": "玩家·印戒细胞癌（复活）", "e": "Null" },
			{ "kind": "tcell", "at": Vector2i(-5, -1), "seat": 4,
				"name": "T 细胞（原）", "e": "3.0" },
			{ "kind": "tcell", "at": Vector2i(6, -5), "seat": 5,
				"name": "T 细胞（再生）", "e": "3.0" },
			{ "kind": "bcell", "at": Vector2i(6, -4), "seat": 6,
				"name": "B 细胞（再生）", "e": "3.0" },
			{ "kind": "tcell", "at": Vector2i(6, -3), "seat": 7,
				"name": "T 细胞（再生）", "e": "3.0" },
		],
	})


## 第八帧：全关卡叠图。同一张图上按关次上色 + 在格心写关号。
func _f8() -> void:
	var stages: Array = [[1, _a1()], [2, _a2()], [3, _a3()], [4, _a4()], [5, _a5()],
		[7, _a7b()]]
	var marks := {}
	var numbers := {}
	var seen: Array = []
	var counts: Array = []
	for s in stages:
		var lv: int = s[0]
		var cur: Array = s[1]
		var add := _minus(cur, seen)
		var col: Color = LV_COLOR[lv]
		for c: Vector2i in add:
			marks[c] = Color(col, 0.5)
			numbers[c] = [str(lv), col]
		counts.append("%d关 +%d" % [lv, add.size()])
		seen = cur
	_build({
		"title": "全关卡叠图 —— 一张图，七次生长（格心数字 = 这格是第几关浮现的）",
		"ask": [
			"长　%s　= 58 格（半径 6 的 127 格常驻，其余靠遮罩藏着）。第五关那 9 格是癌块扩大顶出来的；第七关那 11 格分两次：开局 8 格左口袋、第 23 步 3 格右缘。" % "　".join(counts),
			"长　颜色：青 1 关　橙 2 关　绿 3 关　紫 4 关　红 5 关　白 7 关。**每一关的活跃格都是前一关的严格超集，已露出的格子一格没挪过位置** —— 这就是 Kevin 09-19 第①条要的东西。",
			"长　走向：第一～三关沿 r=-1 排从最左端 (-5,-1) 向右长（第三关起宽到 3 排）；第四 / 五关在右半边向上下长成一大团；第七关只在两头的外缘各补一小块。第七关那条「距离 9 + 击退 2」的直线，就是第一～三关走过的那条走廊。",
			"圈　这张生长图有没有哪一步看着不连贯？要改就在对应的那一帧上圈。",
			TIP_COLOR,
		],
		"active": _a7b(),
		"marks": marks,
		"numbers": numbers,
	})
