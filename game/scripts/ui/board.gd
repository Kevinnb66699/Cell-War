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
