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

## ---- Elm 化渲染（表现层只读 state，不驱动逻辑）----
## 由导演（elm_demo.gd）在每步 step 后调用 refresh() 重绘当前 state。
var _cells := {}   ## cell_id -> Node2D（圆 + 能量 Label）


## 组织块贴图选择：特殊格永远显示特殊贴图（血管/核心/骨髓），
## 其余按 tissue 状态（健康/癌变/固化）。固化暂无专属贴图，沿用癌变贴图。
func _tissue_texture(c: Vector2i) -> Texture2D:
	var key := axial_to_rc(c)
	if Vector2(key.x, key.y) in vessel_position:
		return VESSEL
	if Vector2(key.x, key.y) in energy_position:
		return ENERGYH
	if Vector2(key.x, key.y) in marrow_position:
		return MARROWH
	var tissue: int = map_tissue(c)
	match tissue:
		CWData.Tissue.HEALTHY: return HEALTH
		CWData.Tissue.CANCER: return CANCER
		CWData.Tissue.SOLID: return CANCER
	return HEALTH


var _state: Dictionary = {}
var _state_cells: Array = []

func map_tissue(c: Vector2i) -> int:
	if _state.has("tiles") and _state["tiles"].has(c):
		return _state["tiles"][c]["tissue"]
	return CWData.Tissue.HEALTHY


## 导演每步调用：刷新组织贴图 + 活细胞位置/能量。
func refresh(st: Dictionary) -> void:
	_state = st
	for c in st["tiles"]:
		var key := axial_to_rc(c)
		if not map.has(key):
			continue
		map[key]["instance"].texture = _tissue_texture(c)
	_refresh_cells(st)


func _refresh_cells(st: Dictionary) -> void:
	var seen := {}
	for c in st["cells"]:
		if not c["alive"]:
			continue
		var cid: int = c["id"]
		seen[cid] = true
		var node: Node2D = _cells.get(cid)
		if node == null:
			node = _make_cell_node(c)
			_cells[cid] = node
			add_child(node)
		var p := tile_center(c["pos"])
		node.position = p
		node.z_index = int(p.y) + 1  # 组织块之上
		node.get_node("Label").text = CWData.fmt(c["energy"])
	# 移除已死亡/消失的细胞
	for cid in _cells.keys():
		if not seen.has(cid):
			_cells[cid].queue_free()
			_cells.erase(cid)


func _circle_points(radius: float, segs: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in segs:
		var a := TAU * i / segs
		pts.append(Vector2(cos(a), sin(a)) * radius)
	return pts


## 细胞 = 圆（阵营色）+ 中央能量数字。免疫蓝、癌症红。
func _make_cell_node(c: Dictionary) -> Node2D:
	var node := Node2D.new()
	var body := Polygon2D.new()
	body.polygon = _circle_points(12.0, 28)
	body.color = (Color(0.35, 0.55, 1.0) if c["faction"] == CWData.Faction.IMMUNE
		else Color(1.0, 0.3, 0.25))
	node.add_child(body)
	var lbl := Label.new()
	lbl.name = "Label"
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.add_theme_color_override("font_color", Color(1, 1, 1))
	lbl.position = Vector2(-9, -7)
	node.add_child(lbl)
	return node

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
	## print(map)
