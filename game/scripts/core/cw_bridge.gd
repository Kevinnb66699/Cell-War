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
