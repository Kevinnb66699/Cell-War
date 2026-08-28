extends Node2D

## 预加载组织块
const TISSUE = preload("res://scenes/Tissue.tscn")
const HEALTH = preload("res://assets/art/tissue_normal.png")
const CANCER = preload("res://assets/art/tissue_cancer.png")
const VESSEL = preload("res://assets/art/vessel.png")
const ENERGYH = preload("res://assets/art/energy_normal.png")
const MARROWH = preload("res://assets/art/marrow_normal.png")
const ENERGYC = preload("res://assets/art/energy_cancer.png")
const MARROWC = preload("res://assets/art/marrow_cancer.png")

var radius = CWData.BOARD_RADIUS + 1  ## 六边形每边的格数（= 最大环号 + 1）
var distance_x = 36 ## 块的横距离
var distance_y = 20 ## 块的纵距离
var first_x = -100 ## 第一个块x坐标
var first_y = -120 ## 第一个块y坐标
var map = {} ## 组织块位置

## 棋盘尺寸和特殊组织位置**一律读 CWData**，本文件不留第二份拷贝。
## 规则引擎用轴坐标 (q,r)，本文件画图用「行,列」下标，换算见 axial_to_rc()。
## 这里以前自己抄了一份行列下标，地图改版时两边对不上——2026-08-27 就是这么错的
## （抄的还是 5 个骨髓、代谢核心在半径 4 的旧版）。现在坐标只有 CWData 一处，改不错。
var vessel_position = []   ## 以下三个由 _ready() 从 CWData 的轴坐标换算填入
var energy_position = []
var marrow_position = []

## 轴坐标 (q,r) → 本文件的「行,列」下标。
## 中间那一行是 r=0，行内 q 自左向右递增；r 每 +1 往下走一行，整行同时右移半格。
func axial_to_rc(a: Vector2i) -> Vector2:
	var ring: int = CWData.BOARD_RADIUS
	var q_min: int = -ring if a.y >= 0 else -ring - a.y      ## 这一行最左边那格的 q
	return Vector2(a.y + ring + 1, a.x - q_min + 1)

## 贴图 34px 高，其中顶面只占上面 26px（下面 8px 是两侧的立面）。
## Sprite2D 是 centered=true，position 落在贴图中心，比顶面中心低 (34-26)/2 = 4px。
const TOP_FACE_DY := 4.0

## 轴坐标 → 该格「顶面中心」在本节点里的像素位置。
## 要把东西摆到某一格上（骰子、高亮、标记）一律走这里，别自己再算一遍（约定 #10）。
func tile_center(a: Vector2i) -> Vector2:
	var key := axial_to_rc(a)
	if not map.has(key):
		return Vector2.ZERO
	return map[key]["position"] - Vector2(0, TOP_FACE_DY)


## 没点中任何格子时 hex_at() 的返回值。轴坐标本身有负数，所以用哨兵而不是 -1。
const NO_TILE := Vector2i(9999, 9999)

## 像素 → 轴坐标，tile_center() 的逆运算；点在棋盘外返回 NO_TILE。
##
## 本文件的布局横距 36、纵距 20、隔行错半格，于是相邻格的偏移只有
## (±36, 0) 和 (±18, ±20) 两类 —— 把纵向按 36·√3/2 ÷ 20 ≈ 1.559 拉回去之后
## 这六个偏移的长度全等于 36，也就是说**这是一张被压扁的标准正六边形网格**。
## 所以在拉正的空间里找「最近的顶面中心」就等于真正的六边形命中判定
## （正六边形网格的最近点划分正是它自己），不用去解压扁投影的反函数。
##
## 比到自身外接圆半径 36/√3 还远就算没点中 —— 这一条挡掉棋盘外缘之外的点击，
## 否则边上的格子会把整个屏幕外侧都吸进来。
## 127 格全遍历，一次点击几微秒，没有建索引的必要。
func hex_at(p: Vector2) -> Vector2i:
	var squash: float = distance_x * sqrt(3.0) / 2.0 / distance_y
	var best := NO_TILE
	var best_d: float = distance_x / sqrt(3.0)
	for c in CWData.all_coords():
		var d: Vector2 = p - tile_center(c)
		var dist := Vector2(d.x, d.y * squash).length()
		if dist < best_d:
			best_d = dist
			best = c
	return best


## ── 点选输入 ────────────────────────────────────────────────────
## 「鼠标在哪一格」只有渲染层答得上来（hex_at 和格子的像素位置都在这儿），
## 所以输入落在这里，而不是让上层自己反算一遍投影。
## 棋盘只报「点了哪一格 / 停在哪一格」——**这一格能不能选、选了做什么，
## 全部由 CWUIBridge 决定**，棋盘不掺和规则。
signal tile_clicked(coord: Vector2i)
signal tile_hovered(coord: Vector2i)   ## 移出棋盘时给 NO_TILE

var hovered := NO_TILE


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouse):
		return
	## 坐标一律取事件自带的，别去问 get_global_mouse_position()——
	## 那读的是**真实光标**，模拟输入（截图工具、自动化测试）喂进来的位置它看不见。
	## make_input_local() 顺带把相机与画布变换也算进去了。
	var at: Vector2 = (make_input_local(event) as InputEventMouse).position
	if event is InputEventMouseMotion:
		var over := hex_at(at)
		if over != hovered:
			hovered = over
			tile_hovered.emit(over)
	elif event is InputEventMouseButton and event.pressed 			and event.button_index == MOUSE_BUTTON_LEFT:
		var hit := hex_at(at)
		if hit != NO_TILE:
			tile_clicked.emit(hit)


## ── 高亮层 ──────────────────────────────────────────────────────
## 高亮 = 在格子上叠一张同贴图的纯色剪影，alpha 即混合比例。
## 比例和颜色是从设计稿 board_pick.png 逐像素反解出来的：改动过的每个像素
## 都正好等于 lerp(原色, #30D1FA, 0.43)，而叠一层 alpha=0.43 的纯色就是这个 lerp。
## 所以高亮**不是描边**，是整格染色。
const SILHOUETTE := preload("res://assets/shaders/silhouette.gdshader")


## ── 站在格子上的东西该用什么 z_index ──────────────────────────
## 组织块自己是 z = 贴图中心的 y，**前一排是 +20**。所以 above 只能取 1..19：
## 比自己那格高（不会被脚下这块盖住），又低于前一排（会被前排正确遮住）。
##
## **别在别处自己算这个数。** tile_center() 给的是**顶面**中心，比贴图中心高 4px，
## 拿它的 y 直接当 z 用就会比自己那格低 4，东西会掉到棋盘后面去 ——
## 骰子就是这么掉下去的（2026-08-27，团队试玩时发现）。
const Z_MARK := 1    ## 高亮剪影
const Z_CELL := 2    ## 细胞
const Z_DICE := 3    ## 骰子


func tile_z(a: Vector2i, above: int) -> int:
	var key := axial_to_rc(a)
	if not map.has(key):
		return 0
	return int(map[key]["position"].y) + above

const MARK_MOVE := Color("30d1fa6e")     ## 可迁移/可移动：免疫青，0x6E ≈ 0.43
const MARK_ATTACK := Color("ffb03a6e")   ## 可攻击：癌方橙，同混合比例
const MARK_HOVER := Color("eaf8fc8f")    ## 鼠标所在格：提亮到 0.56
const MARK_SELF := Color("eaf8fc47")     ## 当前行动的细胞脚下：淡到 0.28

var _marks: Node2D                  ## 高亮剪影与过场用的临时叠层
var _mark_material: ShaderMaterial  ## 所有剪影共用一份

## 高亮的淡入淡出时长。**不能直接建/删节点**——候选格「啪」地整片出现太硬
## （团队 2026-08-27 反馈）。所以节点要复用：每帧重建的话补间永远走不完。
const MARK_FADE := 0.22

var _mark_nodes := {}    ## 轴坐标 -> Sprite2D
var _mark_target := {}   ## 轴坐标 -> 目标颜色；set_marks 传进来的那个
var _mark_tweens := {}   ## 轴坐标 -> 正在跑的补间


## 设置高亮：marks = { 轴坐标: 颜色 }。每次调用整体替换，传空字典即清空。
## 颜色的 alpha 就是与原格的混合比例（设计稿的候选格是 #30D1FA、alpha 0.43）。
##
## 一格一个节点、而不是一次性 _draw() 画完，是为了让高亮也吃组织块那套画家算法：
## 剪影的 z 只比自己那格高 1，仍然低于前一排，前排会正确盖住高亮的下半截 ——
## 高亮贴在棋盘上，而不是浮在整张棋盘上面。
##
## **本方法每帧都会被调用**（CWMatch 是全量刷新），所以目标没变时必须什么都不做，
## 否则补间会被无限重启、永远淡不完。
func set_marks(marks: Dictionary) -> void:
	for c: Vector2i in _mark_target.keys():
		if not marks.has(c):
			_mark_target.erase(c)
			var leaving: Sprite2D = _mark_nodes[c]
			_animate(c, Color(leaving.modulate.r, leaving.modulate.g,
				leaving.modulate.b, 0.0), true)
	for c: Vector2i in marks:
		var want: Color = marks[c]
		if _mark_target.get(c) == want:
			continue
		_mark_target[c] = want
		if not _mark_nodes.has(c):
			var made := _make_mark(c, want)
			if made == null:
				_mark_target.erase(c)
				continue
			_mark_nodes[c] = made
		_animate(c, want, false)


## 把癌性组织交叉淡回健康组织（返回主菜单时用）。
## 直接换贴图会「啪」地一下；而两种贴图的**图案**不同，单靠调色也淡不过去 ——
## 所以在每格上盖一张健康贴图、alpha 0→1，淡完再把底下那张换掉、撤掉盖的那张。
func fade_to_healthy(seconds: float) -> void:
	for c in CWData.all_coords():
		var key := axial_to_rc(c)
		if not map.has(key):
			continue
		var tile: Sprite2D = map[key]["instance"]
		var want: Texture2D = TISSUE_TEX[CWData.special_of(c)][0]
		if tile.texture == want:
			continue
		var over := Sprite2D.new()
		over.texture = want
		over.position = tile.position
		over.z_index = tile_z(c, Z_MARK)
		over.modulate.a = 0.0
		_marks.add_child(over)
		var tw := over.create_tween()
		tw.tween_property(over, "modulate:a", 1.0, seconds)
		tw.tween_callback(func() -> void:
			tile.texture = want
			over.queue_free())


func _make_mark(c: Vector2i, want: Color) -> Sprite2D:
	var key := axial_to_rc(c)
	if not map.has(key):
		return null
	var tile: Sprite2D = map[key]["instance"]
	var s := Sprite2D.new()
	s.texture = tile.texture
	s.material = _mark_material
	s.position = tile.position
	s.z_index = tile_z(c, Z_MARK)
	s.modulate = Color(want.r, want.g, want.b, 0.0)   ## 从全透明淡进来
	_marks.add_child(s)
	return s


func _animate(c: Vector2i, to: Color, leaving: bool) -> void:
	var s: Sprite2D = _mark_nodes[c]
	var running: Tween = _mark_tweens.get(c)
	if running != null and running.is_valid():
		running.kill()                ## 半路改目标（比如悬停）时接着当前值走
	var tw := s.create_tween()
	tw.tween_property(s, "modulate", to, MARK_FADE)
	_mark_tweens[c] = tw
	if leaving:
		tw.tween_callback(func() -> void:
			_mark_nodes.erase(c)
			_mark_tweens.erase(c)
			s.queue_free())


## ── 按对局状态换贴图 ────────────────────────────────────────────
## 贴图表：每种特殊组织一对 [健康, 癌性]。
## **固化癌组织暂时和普通癌组织同贴图**（硬化外壳还没画），靠 set_marks() 的色标区分；
## **癌变血管也没有贴图**，两种状态都用同一张 vessel.png。两处都等美术。
const TISSUE_TEX := {
	CWData.Special.NONE: [HEALTH, CANCER],
	CWData.Special.CORE: [ENERGYH, ENERGYC],
	CWData.Special.MARROW: [MARROWH, MARROWC],
	CWData.Special.VESSEL: [VESSEL, VESSEL],
}


## 贴图没变就什么都不做，所以对局那边可以每帧无脑全刷 127 格，不必自己记脏标记。
func set_tissue(a: Vector2i, tissue: int, special: int) -> void:
	var key := axial_to_rc(a)
	if not map.has(key):
		return
	var t: Sprite2D = map[key]["instance"]
	var tex: Texture2D = TISSUE_TEX[special][0 if tissue == CWData.Tissue.HEALTHY else 1]
	if t.texture != tex:
		t.texture = tex


func new_tissue(i, j, x, y):
	var new_t = TISSUE.instantiate()
	new_t.position = Vector2(x, y)
	new_t.z_index = y
	if Vector2(i, j) in vessel_position:
		new_t.texture = VESSEL
	elif Vector2(i, j) in energy_position:
		new_t.texture = ENERGYH
		##new_t.texture = ENERGYC
	elif Vector2(i, j) in marrow_position:
		new_t.texture = MARROWH
		##new_t.texture = MARROWC
	else:
		new_t.texture = HEALTH
		##new_t.texture = CANCER
	map[Vector2(i, j)] = {
		"instance": new_t,
   		"position": Vector2(x, y)
	}
	add_child(new_t)
	
func _ready():
	vessel_position = CWData.VESSELS.map(axial_to_rc)
	energy_position = CWData.CORES.map(axial_to_rc)
	marrow_position = CWData.MARROWS.map(axial_to_rc)
	for i in range(0, radius*2-1):
		if i < radius-1:
			for j in range(0, radius+i):
				new_tissue(i+1, j+1, first_x+distance_x*j, first_y+distance_y*i)
		else:
			for j in range(0, radius*3-i-2):
				new_tissue(i+1, j+1, first_x+distance_x*j, first_y+distance_y*i)
		if i < radius-1:
			first_x -= distance_x/2
		else:
			first_x += distance_x/2
	_mark_material = ShaderMaterial.new()
	_mark_material.shader = SILHOUETTE
	_marks = Node2D.new()
	_marks.name = "Marks"
	add_child(_marks)
