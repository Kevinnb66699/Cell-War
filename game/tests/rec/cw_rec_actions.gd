## cw_rec_actions.gd —— CWActions 的录制代理（测试迁移规格 A-4 / C-1 步 13）
##
## 只有 `enter_tile` 一条（契约面 S · 动作）。它是**深度计数最要紧的那一个**：
## cw_actions.gd 里对它的裸名自调 6 处、跨模块 `.enter_tile(` 11 处（cw_card_fx / cw_world / cw_world_fx）——
## 覆写是虚派发，这 17 处全打到这里。忘了深度计数，一次血管传送会录出嵌套三条，
## 每条的 pre/post 还都「对」，跑 C# 时跟着执行三次再在一个完全无关的字段上报差异。
## **这类假用例比不录更贵**（风险 R3）。
##
## 规矩 3：父函数体内含 await（purify_here / collect_special），所以是 `await super`。
extends CWActions

var rec


func enter_tile(cell: Dictionary, dest: Vector2i, paid: int = -1) -> void:
	var args := { "cell": int(cell["pid"]), "to": "%d,%d" % [dest.x, dest.y], "paid": paid }
	if not rec.begin("cw_actions.gd:enter_tile", args):
		await super.enter_tile(cell, dest, paid)
		rec.skip()
		return
	await super.enter_tile(cell, dest, paid)
	rec.finish()
