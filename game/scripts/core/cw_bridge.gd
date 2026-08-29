## cw_bridge.gd —— 询问桥基类：引擎与「决策者」（人类 UI / AI / 测试脚本）的唯一接口
##
## 引擎通过 game.ask(pid, req) 询问，桥返回所选选项的下标。
## req = { kind, pid, prompt, options:[{label, data}], (tag) }
## kind 取值：setup_place / immune_revive / revive / action（流程状态机的顶层询问），
##           free_move / pick_cell / pick_tile / pick（卡牌结算的中途选择，tag=卡名），
##           confirm（预留）。
## 基类默认永远选第 0 项 —— 中途选择把「停止/放弃」放在下标 0，正是为了这个默认安全。
## UI 桥与 AI 桥各自重写 ask()。
class_name CWBridge
extends RefCounted

var game: CWGame


func ask(_req: Dictionary) -> int:
	return 0


## 展示一次掷骰：引擎会 await 这个方法，动画播完才继续结算。
## 基类立即返回 —— 无头测试和 AI 互搏不需要演出，所以它们完全不受影响。
##
## **注意 value 是引擎先用 rng 算好再传进来的，桥只负责演。演出无权决定结果**
## （架构约定 #11，也是将来确定性锁步联机的前提）。
##
## at = 这次掷骰所指向的格子（攻击的目标格 / 技能发动者所在格）。
## 骰子要落在棋盘上那一格旁边，所以坐标必须由引擎给 —— 表现层猜不出来。
## pid = 掷骰的玩家，可用来显示「谁掷的」；**但不用来给骰子染色** ——
## 骰面颜色已经表示结果档位（1-2 红 / 3-5 青 / 6 金），再叠阵营色会两套语义打架
## （决策「甲」，2026-08-27 定）。
func show_roll(_reason: String, _value: int, _sides: int, _pid: int, _at: Vector2i) -> void:
	pass


## 一句话通报，目前只用于掷骰的结算说明（"攻击成功"、"突变：无事发生"…）。
## **文字由引擎给** —— 点数怎么判读是规则，表现层不许照着点数自己再判一遍
## （那等于把规则抄了第二份，改一处就会对不上）。
## at = 这件事发生在哪一格，表现层拿它决定提示浮在哪儿。
func show_result(_text: String, _at: Vector2i) -> void:
	pass
