## cw_rec_worldfx.gd —— CWWorldFx 的录制代理（测试迁移规格 A-4 / C-1 步 13）
##
## 第四个代理类是**必须的**（两份草案都漏了）：cw_world.gd:e_phase 的第 8 步
## `game.world_fx.tick_durations()` 住在 CWWorldFx 上，不覆它的话规矩 1 的双射当场红，
## 而且不是靠加用例能修的。
##
## 2026-09-19 世界事件整块删除之后 CWWorldFx 只剩 `tick_durations()` 一个方法，
## 这里也就只覆它一个（原来另说明的 `round_effects()` / `chaos_return` 随之作废）。
##
## 规矩 3：`tick_durations` 父函数体内**没有** await（只有一个 for 循环 + clear_mods），
## 所以这里也不许 await —— 加了它就变成协程，而 e_phase 那一行是不 await 它的。
extends CWWorldFx

var rec


func tick_durations() -> void:
	if not rec.begin("cw_world_fx.gd:tick_durations", {}):
		super.tick_durations()
		rec.skip()
		return
	super.tick_durations()
	rec.finish()
