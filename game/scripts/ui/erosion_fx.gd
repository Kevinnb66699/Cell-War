## erosion_fx.gd —— 【E-侵蚀】把健康组织吞成癌组织的两帧过场
##
## 【E-侵蚀】是**世界自动结算**：没有人掷骰、没有人点，玩家的视线也不在那一格上，
## 于是改动只体现为「某一格忽然从健康变成了癌」。美术 2026-09-03 交付了 6 个方向 × 2 帧
## （p33 / p66）的过场图，这里把它接上 —— 让玩家看见**癌是从哪一侧漫过来的**。
##
## **6 个方向对应 6 个轴向邻居**，顺序与 `CWData.DIRS` 严格一致：
##   DIRS[0]=(1,0)→E   DIRS[1]=(1,-1)→NE   DIRS[2]=(0,-1)→NW
##   DIRS[3]=(-1,0)→W  DIRS[4]=(-1,1)→SW   DIRS[5]=(0,1)→SE
## 这套对应是**按像素验过的**，不是猜的：棋盘布局横距 36、纵距 20、隔行错半格，
## 六个邻居的像素偏移是 (±36,0) 与 (±18,±20)；把每张过场图的「已癌变像素」重心
## 与健康贴图逐像素比出来，E 在 x=+7.8、NW 在 (-8.8,-5.2)，与上表逐一吻合。
## **方向名 = 癌来的那一侧**（不是空出来的那一侧）。
##
## **不是 Node**：过场只是「这一格这一帧画哪张图」，没有自己的变换、没有子节点，
## 做成节点反而要处理 z 序（会和高亮剪影抢同一层）。`frame_of()` 是纯函数，
## 无头测试直接核对帧序，不用起画面。
class_name CWErosionFx
extends RefCounted

## 每帧停多久。两帧共 0.32 秒 —— 和 `CWMatch.CELL_POP` 同长：
## 都属于「这里刚发生了一件事」的提示，节奏一致才不显得零散。
const FRAME_TIME := 0.16
const FRAMES := 2

## 下标 = CWData.DIRS 的下标；每项 [p33, p66]
const ART: Array = [
	[preload("res://assets/art/erosion/transition_E_p33.png"),
	 preload("res://assets/art/erosion/transition_E_p66.png")],
	[preload("res://assets/art/erosion/transition_NE_p33.png"),
	 preload("res://assets/art/erosion/transition_NE_p66.png")],
	[preload("res://assets/art/erosion/transition_NW_p33.png"),
	 preload("res://assets/art/erosion/transition_NW_p66.png")],
	[preload("res://assets/art/erosion/transition_W_p33.png"),
	 preload("res://assets/art/erosion/transition_W_p66.png")],
	[preload("res://assets/art/erosion/transition_SW_p33.png"),
	 preload("res://assets/art/erosion/transition_SW_p66.png")],
	[preload("res://assets/art/erosion/transition_SE_p33.png"),
	 preload("res://assets/art/erosion/transition_SE_p66.png")],
]

var _live := {}    ## 格子 → { "dir": int, "t": float }


## 开演。`dir` 是 `CWData.DIRS` 的下标（癌从哪一侧来）；越界就当没这回事 ——
## 引擎那边取不到癌性邻居时会传 -1，静默跳过比崩掉好。
## 同一格重复调用会**从头再演**：一个世界回合里同一格不会被侵蚀两次，
## 真撞上了（存档回滚、联机补包）也该以最后一次为准。
func play(at: Vector2i, dir: int) -> void:
	if dir < 0 or dir >= ART.size():
		return
	_live[at] = { "dir": dir, "t": 0.0 }


## 这一格此刻该画哪张过场图；没在演返回 null。**纯函数（只读 _live）**。
func frame_of(c: Vector2i) -> Texture2D:
	if not _live.has(c):
		return null
	var e: Dictionary = _live[c]
	var i := int(float(e["t"]) / FRAME_TIME)
	if i < 0 or i >= FRAMES:
		return null
	return ART[int(e["dir"])][i]


## 推进计时，演完的自己退场。keys() 是副本，所以循环里 erase 是安全的。
func advance(delta: float) -> void:
	for c: Vector2i in _live.keys():
		_live[c]["t"] = float(_live[c]["t"]) + delta
		if float(_live[c]["t"]) >= FRAME_TIME * FRAMES:
			_live.erase(c)


func busy() -> bool:
	return not _live.is_empty()


## 拆局 / 重开一局：**必须清**。过场是按格子记的，
## 留着的话下一局同一格会凭空闪一下（`_flash` 当年就是这么漏的）。
func clear_all() -> void:
	_live.clear()
