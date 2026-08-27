## cw_bridge.gd —— 询问桥基类：引擎与「决策者」（人类 UI / AI / 测试脚本）的唯一接口
##
## 引擎通过 game.ask(pid, req) 询问，桥返回所选选项的下标。
## req = { kind, pid, prompt, options:[{label, data}], (tag) }
## kind 取值：setup_place / action / attack_target / differentiate /
##           remodel_target / revive / confirm
## 基类默认永远选第 0 项（脚本化测试用）；UI 桥与 AI 桥各自重写 ask()。
class_name CWBridge
extends RefCounted

var game: CWGame


func ask(_req: Dictionary) -> int:
	return 0


## 展示一次掷骰：引擎会 await 这个方法，动画播完才继续结算。
## 基类立即返回 —— 无头测试和 AI 互搏不需要演出，所以它们完全不受影响。
## **注意 value 是引擎先用 rng 算好再传进来的，桥只负责演。演出无权决定结果**
## （架构约定 #2，也是将来确定性锁步联机的前提）。
func show_roll(_reason: String, _value: int, _sides: int, _pid: int) -> void:
	pass
