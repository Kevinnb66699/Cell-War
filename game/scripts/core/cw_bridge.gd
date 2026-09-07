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
## linger = 不是紧跟骰子的说明（事件卡效果、复活失败、次数用尽……）：要停得久些、且不该被下一条顶掉
## （Kevin 2026-09-06：骰子那档时长不动，只拉长这种）。
func show_result(_text: String, _at: Vector2i, _linger := false) -> void:
	pass


## 某位玩家打出了一张卡（即时 / 永久）。给**别人**看的弹窗（Kevin 2026-09-06）：
## 界面桥按「屏幕前这位真人是不是 pid 本人」决定弹不弹，并按阵营标「对手 / 队友」。
## info = { cell_id, pos, faction, card }，联机桥原样转发，客户端拿它演头顶飞卡 / 右栏历史小卡。
func show_card_played(_pid: int, _text: String, _info := {}) -> void:
	pass


## 某位玩家抽到了一张**立即结算的事件卡**。info = { cell_id, pos, faction, card }。
## 联机桥原样转发，客户端据此把小卡记进右栏的回合数那一栏。
func show_event_drawn(_pid: int, _info := {}) -> void:
	pass


## 某位玩家抽到了一张卡（不说是哪张）。info = { cell_id, pos, source }。
## 给头顶的抽卡演出用；联机桥原样转发。
func show_card_drawn(_pid: int, _info := {}) -> void:
	pass


## 癌吞掉一格健康组织的过场（【侵蚀】【增生】【定殖】共用，名字沿用最早接上的侵蚀）：
## `_at` 变癌了，癌是从 `_dir`（CWData.DIRS 的下标）那一侧来的。纯演出，不 await —— 不该为了演出卡住结算。
func show_erosion(_at: Vector2i, _dir: int) -> void:
	pass


## 全局通报：不挂在哪一格上的大事（目前只有「抽到世界事件」）。
## 与 show_result 分开是因为展示方式不同 —— 那个贴着骰子、1 秒多就走；这个要在棋盘上方停够看完一句话的时间。
func show_notice(_text: String) -> void:
	pass
