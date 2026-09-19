extends SceneTree
## 新手教程 v2 · **各关盘面示意图** —— 给 hxr 圈格子用的工具，不是测试。
##
## 出处：最终方案 §8.3 的 ★Q-05「第七关整张地图与 T 细胞站位要具体格子；第二、三关的
## 『凸的癌组织连通块』『向前 / 向周围延伸』也要圈定」；Kevin 2026-09-19「按默认走：
## 我方出示意图给 hxr 圈」。设计改动先出示意图是既定流程。
##
## 每一关一帧，画的是**方案默认摆法**，不是定案：
##   · 格子按类型上真贴图（健康 / 癌组织 / 固化癌组织 / 坏死），不是平底色
##     （「界面预览必须画全常驻件 / 平底色会骗人」那条教训）
##   · 细胞上 `assets/art/cells/anim/*_breath.png` 的真贴图，脚底落在格顶面
##   · **每个活跃格中央下方叠一个 10 号字的轴坐标「q,r」** —— hxr 直接照着圈
##   · 左上角写关名 + 要 hxr 答的问题；底部一条图例列出本帧每只细胞的席位 / 坐标 / 能量
##   · 青 / 橙剪影 = 几何锚点（围一圈的目标格、击退与转移的落点、复活格、再生格）
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

	var frames: Array = [
		["01_第一关_免疫", _f1],
		["02_第二关_癌", _f2],
		["03_第三关_ATP", _f3],
		["04_第四关_抗原记忆", _f4],
		["05_第五关_分化_Step2", _f5],
		["06_第七关_初始", _f7a],
		["07_第七关_第23步_边缘再生", _f7b],
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
#  坐标小工具
# ════════════════════════════════════════════════════════════════

func _row(r: int, q0: int, q1: int) -> Array:
	var out: Array = []
	for q in range(q0, q1 + 1):
		var c := Vector2i(q, r)
		if CWData.is_on_board(c):
			out.append(c)
	return out


## 以 center 为心、半径 rad 的整块（第四 / 五关的「向周围延伸」）
func _disc(center: Vector2i, rad: int) -> Array:
	var out: Array = []
	for c in CWData.all_coords():
		if CWData.hex_dist(c, center) <= rad:
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


# ════════════════════════════════════════════════════════════════
#  一帧 = 铺组织 + 摆细胞 + 对机位 + 打坐标 + 写问题 + 列图例
# ════════════════════════════════════════════════════════════════

## cfg 的键：
##   title  ask[]                      左上角问题板
##   active[]                          活跃格（露出来的那几格）
##   ghost[]                           **活跃格之外**的预置格（第七关的再生席位），只进机位不铺组织
##   cancer[] solid[] necro[]          格子类型；其余活跃格一律健康
##   marks{}                           几何锚点剪影
##   cells[]                           { kind, at, seat, name, e, ghost }
func _build(cfg: Dictionary) -> void:
	var active: Array = cfg.get("active", [])
	var cancer: Array = cfg.get("cancer", [])
	var solid: Array = cfg.get("solid", [])
	var ghost: Array = cfg.get("ghost", [])

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


## 一个活跃格的轴坐标标签。见 LABEL_DY / LABEL_COL 上的两段说明。
func _tile_label(c: Vector2i, z: float, alpha: float, col: Color) -> void:
	var txt := "%d,%d" % [c.x, c.y]
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
		elif s.begins_with("图例"):
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


const TIP_COLOR := "图例　格色：绿 = 健康　红 = 癌组织　石 = 固化癌组织　灰纹 = 坏死　|　坐标色：青 = 这格站着免疫　橙 = 站着癌细胞　|　剪影：橙 = 要圈的格　青 = 几何锚点"


# ════════════════════════════════════════════════════════════════
#  七帧
# ════════════════════════════════════════════════════════════════

## 第一关（PRD:91-137）。两个横向连接的健康组织，一格起、一格落。
func _f1() -> void:
	_build({
		"title": "第一关 免疫 —— 默认盘面（方案 §2.7）",
		"ask": [
			"圈①　两格的位置：默认 (-1,-1) 起、(0,-1) 落（青剪影）。走 r=-1 排，是因为这一排一个特殊组织都没有（核心/骨髓/血管的 r 只取 -3/0/3/6）。要换排或换朝向吗？",
			"圈②　玩家起点要不要和开场动画里细胞跌落的落点对上？",
			"癌席按数据纪律 8 给一只 alive:false 的死细胞压在活跃集之外 (6,-1)，看不见也点不到，图上不画。",
			TIP_COLOR,
		],
		"active": [Vector2i(-1, -1), Vector2i(0, -1)],
		"marks": { Vector2i(0, -1): _board.MARK_MOVE },
		"cells": [
			{ "kind": "immune", "at": Vector2i(-1, -1), "seat": 0,
				"name": "玩家·未分化免疫", "e": "∞（哨兵 99990）" },
		],
	})


## 第二关（PRD:139-215）。Step1 右延两格健康 + 两格癌；Step2 再延一格癌 + 1.0 能量癌细胞。
func _f2() -> void:
	var active := _row(-1, -1, 5)
	_build({
		"title": "第二关 癌 —— 默认盘面（Step1 + Step2 同一份，靠 reveal 揭示）",
		"ask": [
			"圈①　Step1 右延的两格健康 (1,-1) (2,-1) 与两格癌 (3,-1) (4,-1)：位置与格数对吗？",
			"圈②　Step2 再延的一格癌 (5,-1)，1.0 能量癌细胞就站这一格 —— 对吗？",
			"圈③　免疫起点：默认 (0,-1)（承接第一关终点），往右四步正好净化两格癌、停在 (4,-1) 与癌细胞邻接。起点若退回 (-1,-1) 就成五步。",
			TIP_COLOR,
		],
		"active": active,
		"cancer": [Vector2i(3, -1), Vector2i(4, -1), Vector2i(5, -1)],
		"cells": [
			{ "kind": "immune", "at": Vector2i(0, -1), "seat": 0,
				"name": "玩家·未分化免疫", "e": "∞（哨兵 99990）" },
			{ "kind": "osteo", "at": Vector2i(5, -1), "seat": 1,
				"name": "骨肉瘤（Step2 才现）", "e": "1.0" },
		],
	})


## 第三关（PRD:217-283）。凸的癌组织连通块 + 3.0 能量癌细胞 + 能量 6.1 精确标定。
func _f3() -> void:
	var active := _row(-1, 0, 6)
	active.append(Vector2i(5, -2))
	_build({
		"title": "第三关 ATP —— 默认盘面（方案 §2.8，能量 6.1 就是按这张图算的）",
		"ask": [
			"圈①　「凸的癌组织连通块」具体哪几格？默认 (4,-1) (5,-1) (6,-1) 一条，再由 (5,-2) 凸出一格。",
			"圈②　3.0 能量的癌细胞站哪格？默认连通块正中 (5,-1)。",
			"圈③　免疫起点哪格？默认 (0,-1)。最短路 = 3 格健康(0.5×3) + 1 格癌(1.0) = 2.5、落点 (4,-1)；能量 6.1 = 2.5 + 攻击三次 3.0 + 失效自损 0.5 + 0.1。这三格一动，6.1 就要重算。",
			TIP_COLOR,
		],
		"active": active,
		"cancer": [Vector2i(4, -1), Vector2i(5, -1), Vector2i(6, -1), Vector2i(5, -2)],
		"cells": [
			{ "kind": "immune", "at": Vector2i(0, -1), "seat": 0,
				"name": "玩家·未分化免疫", "e": "6.1" },
			{ "kind": "osteo", "at": Vector2i(5, -1), "seat": 1,
				"name": "骨肉瘤", "e": "3.0" },
		],
	})


## 第四关（PRD:285-328）。向周围延伸 + 若干癌组织连通块 + 1~5 能量癌细胞，任务是升到 III 级。
func _f4() -> void:
	var active := _disc(Vector2i(0, -1), 2)
	var blk_a := [Vector2i(1, -3), Vector2i(2, -3), Vector2i(1, -2), Vector2i(2, -2)]
	var blk_b := [Vector2i(-2, -1), Vector2i(-2, 0), Vector2i(-1, 0),
		Vector2i(-2, 1), Vector2i(-1, 1)]
	_build({
		"title": "第四关 抗原记忆 —— 默认盘面（19 格，Q-16 的记忆账就挂在这张图上）",
		"ask": [
			"圈①　「向周围延伸」默认 = 以免疫 (0,-1) 为心的半径 2、共 19 格。范围对吗？(0,-3) 压在代谢核心上，按数据纪律 2 显式写 type:normal 摊平成普通格。",
			"圈②　几个癌组织连通块、各几格？默认两块：右上 4 格 + 左下 5 格。",
			"圈③　癌细胞几只、各几能量？默认 4 只 5.0/4.0/3.0/3.0。记忆账 = 净化 9 格得 9 + 打掉 15.0 能量得 15 = 24，升 III 只需 +10（Q-16 起手 II 级 20 记忆）。增减细胞就是改这本账。",
			TIP_COLOR,
		],
		"active": active,
		"cancer": blk_a + blk_b,
		"cells": [
			{ "kind": "immune", "at": Vector2i(0, -1), "seat": 0,
				"name": "玩家·未分化免疫", "e": "∞　II 级 20 记忆" },
			{ "kind": "osteo", "at": Vector2i(1, -3), "seat": 1, "name": "骨肉瘤", "e": "5.0" },
			{ "kind": "osteo", "at": Vector2i(2, -2), "seat": 2, "name": "骨肉瘤", "e": "4.0" },
			{ "kind": "osteo", "at": Vector2i(-2, 0), "seat": 3, "name": "骨肉瘤", "e": "3.0" },
			{ "kind": "osteo", "at": Vector2i(-1, 1), "seat": 4, "name": "骨肉瘤", "e": "3.0" },
		],
	})


## 第五关 Step2（PRD:329-383）。连通块扩大 + 固化癌组织 + 各种类免疫各一；席位顶到 9。
func _f5() -> void:
	var active := _disc(Vector2i(0, -1), 2)
	var blk_a := [Vector2i(1, -3), Vector2i(2, -3), Vector2i(0, -2), Vector2i(1, -2),
		Vector2i(2, -2), Vector2i(2, -1)]
	var blk_b := [Vector2i(-2, -1), Vector2i(-2, 0), Vector2i(-1, 0),
		Vector2i(-2, 1), Vector2i(-1, 1), Vector2i(0, 1)]
	_build({
		"title": "第五关 分化 Step2 —— 默认盘面（9 席已到右栏上限）",
		"ask": [
			"圈①　连通块「扩大」到哪几格？默认在第四关两块上各加：右上 +(0,-2) +(2,-1)、左下 +(0,1)，两块各 6 格。",
			"圈②　固化癌组织几格、放哪？默认 (2,-3) 与 (-2,1) 两格（写 state:solid，不是 solid 计数）。",
			"圈③　「各种类免疫各一」站哪几格？默认 B (-1,-2) / T (1,-1) / 巨噬 (-1,-1) / 树突 (0,0)，各 1.0 能量、全站健康组织。",
			"硬约束：右栏实测 9 席底边 532 ≤ 540、10 席放不下。现在正好 9 席（玩家 + 4 免疫 + 4 癌），再加一只就要减一只。",
			TIP_COLOR,
		],
		"active": active,
		"cancer": blk_a + blk_b,
		"solid": [Vector2i(2, -3), Vector2i(-2, 1)],
		"cells": [
			{ "kind": "immune", "at": Vector2i(0, -1), "seat": 0,
				"name": "玩家（Step1 自选分化）", "e": "∞　III 级" },
			{ "kind": "bcell", "at": Vector2i(-1, -2), "seat": 1, "name": "B 细胞", "e": "1.0" },
			{ "kind": "tcell", "at": Vector2i(1, -1), "seat": 2, "name": "T 细胞", "e": "1.0" },
			{ "kind": "macro", "at": Vector2i(-1, -1), "seat": 3, "name": "巨噬细胞", "e": "1.0" },
			{ "kind": "dendritic", "at": Vector2i(0, 0), "seat": 4, "name": "树突细胞", "e": "1.0" },
			{ "kind": "osteo", "at": Vector2i(1, -3), "seat": 5, "name": "骨肉瘤", "e": "5.0" },
			{ "kind": "osteo", "at": Vector2i(2, -2), "seat": 6, "name": "骨肉瘤", "e": "3.0" },
			{ "kind": "osteo", "at": Vector2i(-2, 0), "seat": 7, "name": "骨肉瘤", "e": "4.0" },
			{ "kind": "osteo", "at": Vector2i(-1, 1), "seat": 8, "name": "骨肉瘤", "e": "2.0" },
		],
	})


## 第七关的活跃集：r=-1 / r=-2 两排走廊（零特殊格）+ 左端两格 r=0 把「围一圈」的环补全。
func _l7_active() -> Array:
	return _row(-1, -5, 6) + _row(-2, -4, 6) + [Vector2i(-5, 0), Vector2i(-4, 0)]


## 第七关开局（PRD:413-461）。几何锚：围完停 (-3,-1) 距 T 9 格 → 两轮「进 1 退 2」→ 11 = 5×2+1。
func _f7a() -> void:
	var ghost := [Vector2i(-1, -3), Vector2i(4, -3), Vector2i(5, -3)]
	## 橙 = 玩家还要走过去、把它踩成癌组织的 4 格；起点 (-3,-2) 本来就是癌（留着看石头贴图），
	## 环上最后一格 (-3,-1) 单独用强青标出来 —— 全关几何的锚点就是它
	var marks := {}
	for c: Vector2i in _ring(Vector2i(-4, -1)):
		if c != Vector2i(-3, -2) and c != Vector2i(-3, -1):
			marks[c] = _board.MARK_ATTACK
	marks[Vector2i(-3, -1)] = _board.MARK_PLAN       ## 围完停这里 = 击退序列起点，距 T 9 格
	marks[Vector2i(0, -1)] = _board.MARK_MOVE        ## 第一次【转移】落点
	marks[Vector2i(5, -1)] = _board.MARK_MOVE        ## 第二次【转移】落点，正好邻接 T
	_build({
		"title": "第七关 初始盘面 —— 默认摆法（方案 §2.9 的几何全挂在这张图上）",
		"ask": [
			"圈①　T 细胞与其余免疫的站位：默认 T (6,-1) 在 r=-1 直线远端、被围的未分化免疫 (-4,-1)、B (0,-2)、巨噬 (2,-1)。要几只、站哪？",
			"圈②　围一圈的目标格 = (-4,-1) 的一环。玩家从 (-3,-2) 起步，5 步踩完橙色 4 格 + 收尾格，停在 (-3,-1)（强青）—— 到 T 正好 9 格。方案写的「玩家 (-3,-1)」指的就是围完之后。",
			"圈③　再生 T/B 的边缘格（淡显三只）：默认 (-1,-3)/(4,-3)/(5,-3)。开局就预置、停在活跃格外（hex_at 只扫活跃集），第 23 步只 reveal、不新增席位。",
			"几何锁：距 9 →「进 1 退 2」两轮 → 落 (-5,-1) 距 11 = 5×2+1 → 两次【转移】(0,-1)→(5,-1)（淡青）正好邻接 T（5k 会落到 T 头上，非法）。起点不能用 (-5,-1)，击退要出盘。",
			TIP_COLOR,
		],
		"active": _l7_active(),
		"ghost": ghost,
		"solid": [Vector2i(-3, -2)],
		"marks": marks,
		"cells": [
			{ "kind": "sclc", "at": Vector2i(-3, -2), "seat": 0,
				"name": "玩家·小细胞肺癌", "e": "Null（内部 ∞）" },
			{ "kind": "immune", "at": Vector2i(-4, -1), "seat": 1,
				"name": "未分化免疫（被围）", "e": "3.0" },
			{ "kind": "bcell", "at": Vector2i(0, -2), "seat": 2, "name": "B 细胞", "e": "3.0" },
			{ "kind": "macro", "at": Vector2i(2, -1), "seat": 3, "name": "巨噬细胞", "e": "3.0" },
			{ "kind": "tcell", "at": Vector2i(6, -1), "seat": 4,
				"name": "T 细胞（直线远端）", "e": "3.0" },
			{ "kind": "tcell", "at": Vector2i(-1, -3), "seat": 5,
				"name": "T 细胞（预置）", "e": "第 23 步揭示", "ghost": true },
			{ "kind": "bcell", "at": Vector2i(4, -3), "seat": 6,
				"name": "B 细胞（预置）", "e": "第 23 步揭示", "ghost": true },
			{ "kind": "tcell", "at": Vector2i(5, -3), "seat": 7,
				"name": "T 细胞（预置）", "e": "第 23 步揭示", "ghost": true },
		],
	})


## 第七关第 23 步（PRD:499）。边缘再生 T / B 揭示之后的盘面。
func _f7b() -> void:
	var fresh := [Vector2i(-1, -3), Vector2i(4, -3), Vector2i(5, -3)]
	var ring := _ring(Vector2i(-4, -1))
	## 【黏液破裂】在 (5,-1) 一带随机转化的一片（示意，实际由带子钉死）
	var mucus := [Vector2i(2, -1), Vector2i(3, -1), Vector2i(4, -1),
		Vector2i(3, -2), Vector2i(4, -2), Vector2i(5, -2)]
	var marks := {}
	for c: Vector2i in fresh:
		marks[c] = _board.MARK_ATTACK
	_build({
		"title": "第七关 第 23 步 —— 边缘再生 T / B 揭示之后（默认摆法）",
		"ask": [
			"圈①　「地图边缘再次生成若干 T 细胞和 B 细胞」= 哪几格、各几只？默认 T (-1,-3) / B (4,-3) / T (5,-3)（橙）。席位开局就有，这一步只是把这三格加进活跃集。",
			"圈②　复活要站哪格固化癌组织？默认回起点 (-3,-2)（石头贴图那格，间章脚下留的）。硬约束：自毁到复活之间盘上必须有一格 state:solid 且不被免疫占据，否则当场弹结算屏。要在 T 那头另设一格吗？",
			"圈③　【黏液破裂】转化的一片（默认 (2,-1)(3,-1)(4,-1)(3,-2)(4,-2)(5,-2)）与【细胞毒素】烧出的坏死格（灰纹 (5,-1)(6,-2)：1 环内癌组织转健康 + 坏死两个世界回合）—— 这两片靠录带子钉，图上只是示意。要钉死范围吗？",
			TIP_COLOR,
		],
		"active": _l7_active() + fresh,
		"cancer": ring + mucus,
		"solid": [Vector2i(-3, -2)],
		"necro": [Vector2i(5, -1), Vector2i(6, -2)],
		"marks": marks,
		"cells": [
			{ "kind": "signet", "at": Vector2i(-3, -2), "seat": 0,
				"name": "玩家·印戒细胞癌（复活）", "e": "Null" },
			{ "kind": "tcell", "at": Vector2i(6, -1), "seat": 4,
				"name": "T 细胞（原）", "e": "3.0" },
			{ "kind": "tcell", "at": Vector2i(-1, -3), "seat": 5,
				"name": "T 细胞（再生）", "e": "3.0" },
			{ "kind": "bcell", "at": Vector2i(4, -3), "seat": 6,
				"name": "B 细胞（再生）", "e": "3.0" },
			{ "kind": "tcell", "at": Vector2i(5, -3), "seat": 7,
				"name": "T 细胞（再生）", "e": "3.0" },
		],
	})
