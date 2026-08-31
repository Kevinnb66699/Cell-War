## cw_turn.gd —— 玩家行动回合的开场与收尾
##
## **回合循环本身已经不在这里了** —— 它是 CWGame 的流程状态机（advance/_advance_turn）的一部分。
## 原因见 CWGame「流程状态机」那段注释：循环写成函数栈的话，AI 没法从中途快照续跑。
##
## 这里只剩两件事：进回合时该重置什么、出回合时该记什么。
class_name CWTurn
extends RefCounted

## 一个回合内最多行动多少次。防的是桥实现异常导致的死循环，正常对局远达不到。
const MAX_ACTIONS_PER_TURN := 80

var game: CWGame


func begin_turn(pid: int, cell: Dictionary) -> void:
	cell["draws_used"] = 0   ## 【基因表达】的 3 次上限是「每回合」，在这里重置
	cell["attacks_used"] = 0 ## 攻击次数上限同为「每回合」（默认不限，见 CWTuning）
	cell["fx_turn"] = {}     ## 永久技能「每行动回合第一次」的闸门
	game.log_msg("▶ %s 的回合（能量 %s）" % [game.player(pid)["name"], CWData.fmt(cell["energy"])])


func end_turn(pid: int, cell: Dictionary) -> void:
	## 「效果持续至本回合结束」的修饰卡（补体调理/穿孔素/趋化折扣…）在这里过期。
	## 修饰全是打给自己的，所以只清本人的条目就够
	game.clear_mods(cell, "turn")
	game.log_msg("　%s 结束回合（能量 %s）" % [game.player(pid)["name"], CWData.fmt(cell["energy"])])
