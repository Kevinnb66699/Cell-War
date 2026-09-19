extends SceneTree
## 新手教程 v2 · **各关盘面示意图 v2** —— 给 hxr 圈格子用的工具，不是测试。
##
## 出处：最终方案 §8.3 的 ★Q-05「第七关整张地图与 T 细胞站位要具体格子；第二、三关的
## 『凸的癌组织连通块』『向前 / 向周围延伸』也要圈定」；Kevin 2026-09-19「按默认走：
## 我方出示意图给 hxr 圈」。设计改动先出示意图是既定流程。
##
## **v3（Kevin 2026-09-19 第二轮，四条意见）改了什么**：
##   ① 第一、二关不动。
##   ② **第三关 = 3 格宽的整横带 + 右端一个「外突」的癌组织连通块，别的没有** ——
##      横带左边那条一格宽的尾巴铺平成三整排；连通块的柄末端 (5,-3) 突出横带之外；
##      v2 里第二关留在 (1,-1) 的那格孤立癌组织去掉。
##   ③ **第四关一次揭到整盘（半径 6 的 127 格）**，浮现动画按环错峰；
##      **第五关 / 间章 / 第七关都保持正常棋盘大小，不再逐关加格**。
##      第七关的几何在整盘上重算过：r=-1 走廊仍在，T (-5,-1) 直线、围完停 (4,-1) 距 9、
##      两轮「进 1 退 2」落 (6,-1) 距 11 = 5×2+1、两次【转移】(1,-1)→(-4,-1) 邻接、
##      击退顶死在盘边不出盘、复活固化格 (6,-2)、再生 T/B 落在半径 6 的真外环。
##   ④ **同阵营细胞两两至少隔 2 格**（能隔 3 更好），癌块之间也不许挨着 ——
##      `_check_spacing()` 一帧一报，贴太近当场 push_error。
##
## v2（第一轮）定下、v3 继续生效的那条骨架：**全部关卡是同一张不断生长的地图，
## 逐关活跃集是前一关的严格超集，已露出的格子一格都不挪位置**。
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
## 整盘（127 格）那四帧：13 排 × 纵距 20 = 260px，用 280 的可用高只剩 0.86 倍，
## 坐标标签会糊成一片。问题板压到 4 行、可用区往下放宽到 336，倍率回到 ~1.05。
const FULL_ANCHOR := Vector2(480, 282)
const FULL_AVAIL := Vector2(936, 336)

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
#  活跃格集合：**逐关严格超集**，v3 的第一条硬约束就写在这几行里
# ════════════════════════════════════════════════════════════════
#
#  坐标系：r = 常数是一条横排、+q 向右。
#  **v3（Kevin 09-19 第 ③ 条）：第四关一次揭到整盘（半径 6 的 127 格），
#  第五关 / 间章 / 第七关都保持正常棋盘大小，不再逐关加格。**
#  所以只有第一～三关是「长出来的」，第四关起活跃集恒等于全盘。
#
#  特殊组织（代谢核心 / 骨髓 / 血管）**全程按棋盘本来的样子，不摊平**：
#  第一～五关一律从 PlayerAction 中途开局、闸里不放「结束回合」⇒ 永远进不了 S 阶段
#  ⇒ 收入 / 存卡压根不结算，摊不摊平没有区别；而第四关起是正常棋盘，摊平反而失真。
#  （数据纪律 2 的口径：省略 type = 棋盘本来的特殊组织，正是我们要的默认。）

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


## 第一关（不动，Kevin 09-19 第 ① 条）：两个横向连接的健康组织（PRD:95）。
## 走 r=-1 排的最左端 —— q 从 -5 到 6 共 12 格、跨度 11，正好是第七关要的那条直线。
func _a1() -> Array:
	return [Vector2i(-5, -1), Vector2i(-4, -1)]

## 第二关（不动）：右延两格健康 + 两格癌（PRD:143），Step2 再延一格癌（PRD:187）。
func _a2() -> Array:
	return _rows({ -1: [-5, 1] })

## 第三关：**3 格宽的整横带**（r=-2 / r=-1 / r=0 三整排）+ 右端**外突**的那一格。
## v3 改动：横带左边不再留一条一格宽的尾巴（三排铺满），横带之外只剩 (5,-3) ——
## 它是右端那个癌组织连通块突出横带的那一格（Kevin 09-19 第 ② 条）。
func _a3() -> Array:
	return _rows({ -2: [-4, 6], -1: [-5, 6], 0: [-6, 6] }) + [Vector2i(5, -3)]

## 第四关起：**整盘**。PRD:291「地图自免疫细胞向周围延伸开来」= 一次揭到 127 格，
## 浮现动画按环错峰（board.ring_delays 本来就按重心排队）。
func _full() -> Array:
	return CWData.all_coords()


## 开跑前把账算一遍打到控制台：格数、超集缺口、**第四关起是否等于整盘**、第七关距离。
## 图是给人看的，这一段是给改图的人看的 —— 动一格坐标，这里立刻报出来。
func _audit() -> void:
	var sets: Array = [["第一关", _a1()], ["第二关", _a2()], ["第三关", _a3()],
		["第四关", _full()], ["第五关", _full()], ["第七关初始", _full()],
		["第七关第23步", _full()]]
	var prev: Array = []
	var full_n: int = _full().size()
	for s in sets:
		var lv: String = s[0]
		var cur: Array = s[1]
		var miss := _minus(prev, cur)          ## 超集缺口：上一关有、这一关没有的格
		var whole := "是" if cur.size() == full_n else "否"
		print("[盘面] %s：%d 格（新增 %d）；超集缺口 %d；整盘 %s"
			% [lv, cur.size(), cur.size() - prev.size(), miss.size(), whole])
		prev = cur
	## Kevin 09-19 第 ③ 条的闸：第四关起必须恰好是全盘
	for s in sets.slice(3):
		if s[1].size() != full_n:
			push_error("[盘面] %s 不是整盘（%d != %d）" % [s[0], s[1].size(), full_n])
	var t := Vector2i(-5, -1)
	print("[几何] 围圈终点(4,-1)→T%s 距离 %d；击退落点(6,-1)→T 距离 %d；转移两跳 (1,-1)/(-4,-1)，落点→T 距离 %d"
		% [t, CWData.hex_dist(Vector2i(4, -1), t), CWData.hex_dist(Vector2i(6, -1), t),
			CWData.hex_dist(Vector2i(-4, -1), t)])


## Kevin 09-19 第 ④ 条的闸：**同阵营细胞两两至少隔 2 格**（能隔 3 更好）。
## 一帧一报：贴太近的当场 push_error，顺带把最近的一对打出来好改。
func _check_spacing(tag: String, cells: Array) -> void:
	var side := { "immune": [], "cancer": [] }
	for e in cells:
		var key := "immune" if IMMUNE_KINDS.has(String(e["kind"])) else "cancer"
		side[key].append(e)
	for key in side:
		var arr: Array = side[key]
		var best := 99
		var pair := ""
		for i in arr.size():
			for j in range(i + 1, arr.size()):
				var a: Vector2i = arr[i]["at"]
				var b: Vector2i = arr[j]["at"]
				var d: int = CWData.hex_dist(a, b)
				if d < best:
					best = d
					pair = "%s(%d,%d) - %s(%d,%d)" % [arr[i]["name"], a.x, a.y,
						arr[j]["name"], b.x, b.y]
		if arr.size() < 2:
			continue
		print("[同阵营] %s · %s：%d 只，最近一对 %d 格（%s）" % [tag, key, arr.size(), best, pair])
		if best < 2:
			push_error("[同阵营] %s · %s 贴太近：%d 格（%s）" % [tag, key, best, pair])


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
	var z := _focus(active + ghost, cfg.get("anchor", BOARD_ANCHOR), cfg.get("avail", BOARD_AVAIL))

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
	_check_spacing(String(cfg.get("tag", "?")), cfg.get("cells", []))


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

## 第三关右端那个「外突」的癌组织连通块：横带中排 4 格 + 一条 2 格的柄，
## 柄的末端 (5,-3) **突出横带之外**（Kevin 09-19 第 ② 条）。全关只有这一块。
func _l3_block() -> Array:
	return [Vector2i(3, -1), Vector2i(4, -1), Vector2i(5, -1), Vector2i(6, -1),
		Vector2i(5, -2), Vector2i(5, -3)]

## 第四关四个癌组织连通块（块与块两两至少隔 3 格，Kevin 09-19 第 ④ 条）。
func _l4_blocks() -> Dictionary:
	return {
		"A": [Vector2i(3, -1), Vector2i(4, -1), Vector2i(5, -1), Vector2i(6, -1),
			Vector2i(5, -2), Vector2i(5, -3)],                              ## 第三关那块，原样留着
		"B": [Vector2i(0, -4), Vector2i(1, -4), Vector2i(1, -5), Vector2i(2, -5)],
		"C": [Vector2i(-4, 2), Vector2i(-3, 2), Vector2i(-4, 3), Vector2i(-3, 1)],
		"D": [Vector2i(1, 3), Vector2i(2, 3), Vector2i(1, 4), Vector2i(2, 2)],
	}

## 第五关 Step2：四块各长两格（PRD:361），其中三格转固化（PRD:363）。
func _l5_blocks() -> Dictionary:
	var b := _l4_blocks()
	b["A"] = b["A"] + [Vector2i(4, -2), Vector2i(6, -2)]
	b["B"] = b["B"] + [Vector2i(0, -5), Vector2i(2, -4)]
	b["C"] = b["C"] + [Vector2i(-2, 1), Vector2i(-4, 4)]
	b["D"] = b["D"] + [Vector2i(0, 4), Vector2i(2, 4)]
	return b

func _flat(d: Dictionary) -> Array:
	var out: Array = []
	for k in d:
		out += d[k]
	return out

## 第五关留到第七关的三格固化（都避开第七关围圈的那一环）。
func _l5_solid() -> Array:
	return [Vector2i(6, -1), Vector2i(1, -5), Vector2i(2, 3)]


## 第一关（PRD:91-137）。Kevin 09-19：第一、二关不动。
func _f1() -> void:
	_build({
		"tag": "第一关",
		"title": "第一关 免疫 —— 2 格（Kevin 09-19：第一、二关不动）",
		"ask": [
			"圈①　两格的位置：默认 (-5,-1) 起、(-4,-1) 落（深青）。摆在 r=-1 排的**最左端**是整套几何的地基 —— 这一排 q 从 -5 到 6 共 12 格、跨度 11，第七关的「距离 9 + 击退 2」正好用完它。",
			"圈②　玩家起点要不要和开场动画里细胞跌落的落点对上？（开场动画保留不动。）",
			"长期账：这两格到第七关还在原处 —— (-5,-1) 最后站着那只要杀死你的 T 细胞、(-4,-1) 是你最后一次【转移】的落点，首尾在同两格上收口。",
			"癌席按数据纪律 8 给一只 alive:false 的死细胞压在活跃集之外 (6,-1)，看不见也点不到，图上不画。",
			TIP_COLOR,
		],
		"active": _a1(),
		"marks": { Vector2i(-4, -1): _board.MARK_PLAN },
		"cells": [
			{ "kind": "immune", "at": Vector2i(-5, -1), "seat": 0,
				"name": "玩家·未分化免疫", "e": "∞（哨兵 99990）" },
		],
	})


## 第二关（PRD:139-215）。不动。
func _f2() -> void:
	var active := _a2()
	var cancer := [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1)]
	var marks := {}
	_paint(marks, cancer, _board.MARK_ATTACK)
	_paint(marks, _minus(active, _a1()), MARK_NEW)
	_build({
		"tag": "第二关",
		"title": "第二关 癌 —— 7 格（新增 5，同一排继续向右）",
		"ask": [
			"圈①　Step1 右延的两格健康 (-3,-1) (-2,-1) 与两格癌 (-1,-1) (0,-1)：位置与格数对吗？",
			"圈②　Step2 再延的一格癌 (1,-1)，1.0 能量癌细胞就站这一格 —— 对吗？",
			"圈③　免疫起点 (-4,-1)（承接第一关终点），往右四步正好净化两格癌、停在 (0,-1) 与癌细胞邻接，与 PRD:153「向右移动四格」严丝合缝。",
			"圈④　1.0 能量一击必杀 vs PRD:203「攻击癌细胞直到其死亡」：改文案为「击杀它」，还是把能量抬到 2.0、带子给两颗骰？",
			TIP_COLOR,
		],
		"active": active,
		"cancer": cancer,
		"marks": marks,
		"cells": [
			{ "kind": "immune", "at": Vector2i(-4, -1), "seat": 0,
				"name": "玩家·未分化免疫", "e": "∞（哨兵 99990）" },
			{ "kind": "osteo", "at": Vector2i(1, -1), "seat": 1,
				"name": "骨肉瘤（Step2 才现）", "e": "1.0" },
		],
	})


## 第三关（PRD:223-283）。v3：3 格宽的**整横带** + 右端**外突**的一个连通块，别的没有。
func _f3() -> void:
	var active := _a3()
	var block := _l3_block()
	var path := [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0),
		Vector2i(4, 0)]
	var marks := {}
	_paint(marks, path, _board.MARK_PLAN)               ## 2.5 那条唯一的最省路
	_paint(marks, block, _board.MARK_ATTACK)
	_paint(marks, _minus(active, _a2()), MARK_NEW)
	_build({
		"tag": "第三关",
		"title": "第三关 ATP —— 37 格（新增 30）：3 格宽整横带 + 右端一个外突的连通块",
		"ask": [
			"圈①　横带 = r=-2 / r=-1 / r=0 **三整排**（PRD:227「纵向宽度扩充为 3 格」）。v3 把横带左边那条一格宽的尾巴铺平了 —— 横带之外只剩一格：(5,-3)。",
			"圈②　右端那个**外突**的癌组织连通块：中排 (3,-1)(4,-1)(5,-1)(6,-1) 四格 + 一条柄 (5,-2)(5,-3)，柄末端 (5,-3) 突出横带之外。3.0 能量的癌细胞站 (5,-1)。形状 / 柄的方向要改吗？",
			"圈③　**全关只有这一个连通块** —— v2 里第二关留在 (1,-1) 的那格孤立癌组织已按 Kevin 意见去掉（第三关画成已净化）。",
			"圈④　最省路（深青）：绕 r=0 排 5 步全健康 = **2.5**，落点 (4,0)。直线 4 步要踩 (3,-1)(4,-1) 两格癌 = 3.0，超预算。能量 **6.1** = 2.5 + 攻击三次 3.0 + 失效自损 0.5 + 0.1；劝重置阈值 35（最省路剩 36 不劝、直线剩 31 当场劝）。",
			TIP_COLOR,
		],
		"active": active,
		"cancer": block,
		"marks": marks,
		"cells": [
			{ "kind": "immune", "at": Vector2i(0, -1), "seat": 0,
				"name": "玩家·未分化免疫", "e": "6.1" },
			{ "kind": "osteo", "at": Vector2i(5, -1), "seat": 1,
				"name": "骨肉瘤", "e": "3.0" },
		],
	})


## 第四关（PRD:287-328）。**v3：一次揭到整盘 127 格。**
func _f4() -> void:
	var cancer := _flat(_l4_blocks())
	var marks := {}
	_paint(marks, cancer, _board.MARK_ATTACK)
	_build({
		"tag": "第四关",
		"anchor": FULL_ANCHOR, "avail": FULL_AVAIL,
		"title": "第四关 抗原记忆 —— 整盘 127 格（PRD:291「向周围延伸开来」一次揭完）",
		"ask": [
			"圈①　「向周围延伸」= 把半径 6 的 127 格一次全揭开，浮现动画按环错峰（离重心近的先亮）。第五关 / 间章 / 第七关都保持这个大小，不再加格。",
			"圈②　四个癌组织连通块（橙）：A 右 6 格（第三关那块原样留着）/ B 上 4 格 / C 左下 4 格 / D 下 4 格，**块与块两两至少隔 3 格**。位置与形状对吗？",
			"圈③　癌细胞 4 只：(5,-1) 5.0 / (1,-4) 4.0 / (-3,2) 3.0 / (1,3) 3.0，**两两至少隔 4 格**。记忆账 = 净化 18 格 + 打掉 15.0 能量 = 33，升 III 只需 +10（起手 II 级 20 记忆）。",
			"圈④　整盘揭开后，11 格特殊组织（代谢核心 / 骨髓 / 血管）按棋盘本来的样子显示、**不摊平** —— 第一～五关永远进不到 S 阶段，收入与存卡都不结算，所以不影响任何数值。要改成全程摊平吗？",
			TIP_COLOR,
		],
		"active": _full(),
		"cancer": cancer,
		"marks": marks,
		"cells": [
			{ "kind": "immune", "at": Vector2i(4, 0), "seat": 0,
				"name": "玩家·未分化免疫", "e": "∞　II 级 20 记忆" },
			{ "kind": "osteo", "at": Vector2i(5, -1), "seat": 1, "name": "骨肉瘤", "e": "5.0" },
			{ "kind": "osteo", "at": Vector2i(1, -4), "seat": 2, "name": "骨肉瘤", "e": "4.0" },
			{ "kind": "osteo", "at": Vector2i(-3, 2), "seat": 3, "name": "骨肉瘤", "e": "3.0" },
			{ "kind": "osteo", "at": Vector2i(1, 3), "seat": 4, "name": "骨肉瘤", "e": "3.0" },
		],
	})


## 第五关 Step2（PRD:329-383）。整盘不变；四块各长两格 + 三格固化 + 各类免疫各一。
func _f5() -> void:
	var solid := _l5_solid()
	var cancer := _minus(_flat(_l5_blocks()), solid)
	var marks := {}
	_paint(marks, solid, _board.MARK_PLAN)
	_paint(marks, cancer, _board.MARK_ATTACK)
	_build({
		"tag": "第五关",
		"anchor": FULL_ANCHOR, "avail": FULL_AVAIL,
		"title": "第五关 分化 Step2 —— 整盘不变；癌块扩大 + 固化 + 9 席",
		"ask": [
			"圈①　四块各长两格（A 8 / B 6 / C 6 / D 6 格），块与块仍两两至少隔 3 格。",
			"圈②　固化癌组织三格（深青）：(6,-1) / (1,-5) / (2,3)，写 state:solid 不是 solid 计数。它们到第七关还在 —— 是「复活窗口必须有一格不被免疫占据的固化格」那条硬约束的余量，而且都**避开了第七关围圈的那一环**。",
			"圈③　「各种类免疫各一」：B (1,-2) / 巨噬 (6,-4) / 树突 (0,2) / **T (-5,-1)**，加玩家 (4,0) 共 5 只，**两两至少隔 4 格**。巨噬摆在离 (6,-2) 最近的位置 —— 间章「最近一个免疫细胞靠过来攻击」点名的就是它。",
			"圈④　癌细胞 4 只沿用第四关的格子（5.0 / 4.0 / 3.0 / 2.0），两两至少隔 4 格。9 席到顶（玩家 + 4 免疫 + 4 癌）。",
			TIP_COLOR,
		],
		"active": _full(),
		"cancer": cancer,
		"solid": solid,
		"marks": marks,
		"cells": [
			{ "kind": "immune", "at": Vector2i(4, 0), "seat": 0,
				"name": "玩家（Step1 自选分化）", "e": "∞　III 级" },
			{ "kind": "bcell", "at": Vector2i(1, -2), "seat": 1, "name": "B 细胞", "e": "1.0" },
			{ "kind": "macro", "at": Vector2i(6, -4), "seat": 2, "name": "巨噬细胞", "e": "1.0" },
			{ "kind": "dendritic", "at": Vector2i(0, 2), "seat": 3, "name": "树突细胞", "e": "1.0" },
			{ "kind": "tcell", "at": Vector2i(-5, -1), "seat": 4,
				"name": "T 细胞（走廊远端）", "e": "1.0" },
			{ "kind": "osteo", "at": Vector2i(5, -1), "seat": 5, "name": "骨肉瘤", "e": "5.0" },
			{ "kind": "osteo", "at": Vector2i(1, -4), "seat": 6, "name": "骨肉瘤", "e": "4.0" },
			{ "kind": "osteo", "at": Vector2i(-3, 2), "seat": 7, "name": "骨肉瘤", "e": "3.0" },
			{ "kind": "osteo", "at": Vector2i(1, 3), "seat": 8, "name": "骨肉瘤", "e": "2.0" },
		],
	})


## 第七关开局（PRD:415-461）。整盘不变；几何仍全挂 r=-1 走廊。
func _f7a() -> void:
	var solid := [Vector2i(6, -2)] + _l5_solid()
	var marks := {}
	marks[Vector2i(4, -1)] = _board.MARK_PLAN        ## 围完停这里 = 击退序列起点，距 T 9 格
	marks[Vector2i(6, -1)] = _board.MARK_PLAN        ## 两轮击退后的落点，距 T 11 = 5×2+1
	marks[Vector2i(1, -1)] = _board.MARK_PLAN        ## 第一次【转移】落点
	marks[Vector2i(-4, -1)] = _board.MARK_PLAN       ## 第二次【转移】落点，正好邻接 T
	_paint(marks, _ring(Vector2i(4, -2)), _board.MARK_ATTACK)
	_build({
		"tag": "第七关初始",
		"anchor": FULL_ANCHOR, "avail": FULL_AVAIL,
		"title": "第七关 初始 —— 整盘不变（地图没换，接着第五关 + 间章）",
		"ask": [
			"圈①　围一圈围的是间章里靠过来又被击退 1 格的那只巨噬 (4,-2)，一环 6 格（橙）。玩家从固化格 (6,-2) 出发 6 步：(5,-2)(5,-3)(4,-3)(3,-2)(3,-1)(4,-1)，收在 (4,-1)（深青）—— 到 T (-5,-1) 正好 9 格。",
			"圈②　几何锁（四个深青）：距 9 →「进 1 退 2」两轮 → 落 (6,-1) 距 11 = 5×2+1 → 两次【转移】(1,-1) → (-4,-1) 正好邻接 T。全程走 r=-1 排 —— 就是第一～三关走过的那条走廊；(6,-1) 是这一排的最右端，击退顶死在盘边、一格不多。",
			"圈③　免疫四只（T (-5,-1) / 巨噬 (4,-2) / B (1,-2) / 树突 (0,2)）两两至少隔 2 格。T 站的正是第一关玩家出生那格，也是真正的棋盘边缘（s=6 外环）。",
			"圈④　v3 改动：整盘揭开后没地方藏「预置在活跃集外」的再生席位了 ⇒ 第 23 步改成**一次重装把三只再生 T/B 加进来**（席位 5 → 8；PRD:499 本来写的就是「游戏状态变化」）。接受吗？",
			TIP_COLOR,
		],
		"active": _full(),
		"solid": solid,
		"marks": marks,
		"cells": [
			{ "kind": "sclc", "at": Vector2i(6, -2), "seat": 0,
				"name": "玩家·小细胞肺癌", "e": "Null（内部 ∞）" },
			{ "kind": "macro", "at": Vector2i(4, -2), "seat": 1,
				"name": "巨噬（要被围的那只）", "e": "3.0" },
			{ "kind": "bcell", "at": Vector2i(1, -2), "seat": 2, "name": "B 细胞", "e": "3.0" },
			{ "kind": "dendritic", "at": Vector2i(0, 2), "seat": 3, "name": "树突细胞", "e": "3.0" },
			{ "kind": "tcell", "at": Vector2i(-5, -1), "seat": 4,
				"name": "T 细胞（走廊远端）", "e": "3.0" },
		],
	})


## 第七关第 23 步（PRD:499）。整盘不变；边缘再生 T / B 之后的盘面。
func _f7b() -> void:
	var fresh := [Vector2i(6, -4), Vector2i(6, -6), Vector2i(4, -6)]
	var ring := _ring(Vector2i(4, -2))
	## 【黏液破裂】在 (-4,-1) 两环内转化的一片（示意，实际由带子钉死）
	var mucus := [Vector2i(-3, -1), Vector2i(-2, -1), Vector2i(-3, -2), Vector2i(-2, -2),
		Vector2i(-4, 1), Vector2i(-3, 0), Vector2i(-5, 1), Vector2i(-6, 1)]
	var solid := [Vector2i(6, -2)] + _l5_solid()
	var marks := {}
	_paint(marks, fresh, _board.MARK_ATTACK)
	marks[Vector2i(6, -2)] = _board.MARK_PLAN
	_build({
		"tag": "第七关第23步",
		"anchor": FULL_ANCHOR, "avail": FULL_AVAIL,
		"title": "第七关 第 23 步 —— 边缘再生 T / B 之后（整盘不变，全教程终盘）",
		"ask": [
			"圈①　「地图边缘再次生成若干 T 细胞和 B 细胞」= 棋盘**真正的边缘**（半径 6 的外环）：T (6,-4) / B (6,-6) / T (4,-6)（橙），三只两两至少隔 2 格，围着复活点 (6,-2)。",
			"圈②　复活站哪格固化（深青 (6,-2)）？默认回**出生那格**（间章冲击波在脚下生成的那一格）。代价：【黏液破裂】发生在 (-4,-1)，最后一幕整个搬回右边。另一条路是在 T 那一头另设一格固化就地收尾。",
			"圈③　左边那一片：T 的【细胞毒素】1 环转健康 + 坏死（灰纹 (-5,-1)(-4,-1)(-4,-2)(-5,0)(-6,0)），【黏液破裂】两环转癌（红，示意）。两片都靠录带子钉，要钉死范围吗？",
			"圈④　第 24 步「所有 T 细胞一齐效应应答」：原 T 在 (-5,-1)，与复活点 (6,-2) 不在一条直线上，它那一发只能是演出；真正结算的是右缘新生的两只 T。接受吗？",
			TIP_COLOR,
		],
		"active": _full(),
		"cancer": ring + mucus,
		"solid": solid,
		"necro": [Vector2i(-5, -1), Vector2i(-4, -1), Vector2i(-4, -2), Vector2i(-5, 0),
			Vector2i(-6, 0)],
		"marks": marks,
		"cells": [
			{ "kind": "signet", "at": Vector2i(6, -2), "seat": 0,
				"name": "玩家·印戒细胞癌（复活）", "e": "Null" },
			{ "kind": "tcell", "at": Vector2i(-5, -1), "seat": 4,
				"name": "T 细胞（原）", "e": "3.0" },
			{ "kind": "tcell", "at": Vector2i(6, -4), "seat": 5,
				"name": "T 细胞（再生）", "e": "3.0" },
			{ "kind": "bcell", "at": Vector2i(6, -6), "seat": 6,
				"name": "B 细胞（再生）", "e": "3.0" },
			{ "kind": "tcell", "at": Vector2i(4, -6), "seat": 7,
				"name": "T 细胞（再生）", "e": "3.0" },
		],
	})


## 第八帧：第一～三关生长 + 第四关整盘。格心数字 = 这格是第几关浮现的。
func _f8() -> void:
	var stages: Array = [[1, _a1()], [2, _a2()], [3, _a3()], [4, _full()]]
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
			marks[c] = Color(col, 0.42)
			numbers[c] = [str(lv), col]
		counts.append("%d关 +%d" % [lv, add.size()])
		seen = cur
	_build({
		"tag": "叠图",
		"anchor": FULL_ANCHOR, "avail": FULL_AVAIL,
		"title": "第一～三关生长 + 第四关整盘（格心数字 = 这格是第几关浮现的）",
		"ask": [
			"长　%s　= 127 格。**第五关 / 间章 / 第七关都不再加格** —— 第四关一次揭到正常棋盘大小之后就不动了。" % "　".join(counts),
			"长　颜色：青 1 关（2 格）　橙 2 关（+5）　绿 3 关（+30：3 格宽整横带 + 右端外突那一格 (5,-3)）　紫 4 关（+90：整盘）。每一关的活跃格都是前一关的严格超集，已露出的格子一格没挪过位置。",
			"长　走向：第一～三关沿 r=-1 排从最左端 (-5,-1) 向右长（第三关起宽到 3 整排），第四关一次揭完。第七关那条「距离 9 + 击退 2」的直线，就是第一～三关走出来的那条走廊。",
			"圈　这张生长图有没有哪一步看着不连贯？要改就在对应的那一帧上圈。",
			TIP_COLOR,
		],
		"active": _full(),
		"marks": marks,
		"numbers": numbers,
	})
