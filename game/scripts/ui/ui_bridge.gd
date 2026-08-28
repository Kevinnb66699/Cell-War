## ui_bridge.gd —— 表现层的询问桥：负责掷骰演出，将来还负责人类玩家的输入
##
## **为什么继承启发式 AI 而不是 CWBridge。** 一局里通常只有部分位置是人，
## 其余仍要 AI 来下。让同一个桥对象兼任两者有三个好处：
##
## ① 掷骰演出只需要注册一次 —— `CWGame.roll_shown()` 会把演出广播给所有桥、
##    并按**对象**去重，所以「一个对象注册给全部玩家」正好演一遍，
##    「人类看得见 AI 掷的骰」这件事自然成立，不用另设一个旁观者桥。
## ② 人类那一侧还没实现的询问种类可以直接退回 AI，界面能一块一块做。
## ③ 一个人都没有时（human_pids 为空）就是一局带演出的 AI 互搏，可以直接看。
##
## 演出**无权决定结果**：value 是引擎先用 game.rng 掷好再传进来的（架构约定 #11）。
class_name CWUIBridge
extends CWHeuristicBridge

var board: Node2D          ## 取格子像素位置只能问它（架构约定 #10）
var dice: CWDice
var human_pids: Array[int] = []

## 本桥希望棋盘上高亮哪些格子：{ 轴坐标: 颜色 }。
## 由 CWMatch 每帧读走、和「组织状态色标」合并后一起交给 board.set_marks()。
## 做成「桥单向暴露、对局去读」而不是桥直接改棋盘，是为了不让两处各自往
## set_marks() 里写、互相把对方擦掉。
var marks := {}


func ask(req: Dictionary) -> int:
	if req["pid"] in human_pids:
		return await _ask_human(req)
	return await super.ask(req)   ## 启发式 AI 的决策（delay_ms 的停顿也在里面）


## 人类玩家的询问界面。**还没实现** —— 先原样退回 AI，
## 这样对局能整局跑通，界面做一种就接一种。
func _ask_human(req: Dictionary) -> int:
	return await super.ask(req)


## 把骰子摆到目标格旁边演一次。AI 掷的骰走快档，免得旁观太磨。
func show_roll(_reason: String, value: int, sides: int, pid: int, at: Vector2i) -> void:
	if dice == null or board == null:
		return
	dice.place_at(board.tile_center(at))
	await dice.play(value, sides, pid not in human_pids)
