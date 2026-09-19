## cw_world_fx.gd —— 全局修饰容器的回合时钟
##
## 2026-09-19（Kevin：「我们不加入世界事件了」）：世界事件的事件表、抽取、三档加倍与
## 各事件的一次性结算整块删除，本文件只剩 E 阶段第 8 步的倒计时。**容器本身保留** ——
## 卡牌的修饰效果（对照 5.1 #26）往 game.events["active"] 里塞条目、复用全部挂接点，
## 已经住进来的**只剩两张**：【TGF-β释放】【TNF-α局部炎症】
## （【基质稳定】2026-09-19 issue #64 随「固化计数不再递减」整张删除 —— 它唯一的作用就是跳过那一步）。
##
## 修饰器容器 = game.events["active"]，条目 {name, left, stacks, data}：
##   - left   还能存活的世界回合数（含本回合）。回合末 -1，归零移除。
##   - stacks 叠加层数。卡牌条目一律 1。
##   - data   条目私有簿记，键一律用 cell["id"]，随快照深拷贝、进 state_hash。
##
## 各结算点读条目一律走 game.event_stacks(名字)。
class_name CWWorldFx
extends RefCounted

var game: CWGame


## E 阶段**第 8 步**「更新持续时间类状态」——全局修饰的倒计时与到期，
## 外加「本世界回合」时钟的修饰卡条目（I型干扰素护盾…）。
## 「坏死」的倒计时在 `CWWorld._tick_necrosis()`，同属第 8 步。
func tick_durations() -> void:
	var kept: Array = []
	for e in game.events["active"]:
		e["left"] -= 1
		if e["left"] > 0:
			kept.append(e)
			continue
		game.log_msg("【%s】效果结束" % e["name"])
	game.events["active"] = kept
	for cell in game.cells:
		game.clear_mods(cell, "round")
