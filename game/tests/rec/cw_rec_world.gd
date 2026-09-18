## cw_rec_world.gd —— CWWorld 的录制代理（测试迁移规格 A-4 / C-1 步 13）
##
## 覆写集合 = `l0_contract_gate.gd:recorder_overrides()` 里文件名是 cw_world.gd 的那 22 条，
## 一个不多一个不少（规矩 1，t_rec_contract_only 反射核）。**每个函数的形状都一样，别想着抽公共函数**：
## GDScript 的 `super` 只能写在方法体里，进不了 lambda —— 抽出去就只能走 callv 反射，
## 而反射正是 A-6 明令不要的那条（改名时静默换靶）。
##
## 规矩 3（协程性镜像父类）：cw_world.gd 里这 22 个函数中**只有** _resolve_camping /
## _tissue_production / _vessel_teleport 三个函数体内含 await（逐个数过，注释里的 await 不算）——
## 只有这三个写 `await super`，其余一律 `super.同名()`。给不含 await 的父函数加一个 await，
## 它就变成协程，调用方拿到的是 Signal 而不是返回值，而 e_phase 是不 await 它们的。
extends CWWorld

var rec


# ---- E 阶段 ----

func _anaerobic() -> void:
	if not rec.begin("cw_world.gd:_anaerobic", {}):
		super._anaerobic()
		rec.skip()
		return
	super._anaerobic()
	rec.finish()


func _cancer_upkeep() -> void:
	if not rec.begin("cw_world.gd:_cancer_upkeep", {}):
		super._cancer_upkeep()
		rec.skip()
		return
	super._cancer_upkeep()
	rec.finish()


func _pressure() -> void:
	if not rec.begin("cw_world.gd:_pressure", {}):
		super._pressure()
		rec.skip()
		return
	super._pressure()
	rec.finish()


func _proliferate() -> Array[Vector2i]:
	if not rec.begin("cw_world.gd:_proliferate", {}):
		var nested := super._proliferate()
		rec.skip()
		return nested
	var out := super._proliferate()
	rec.finish()
	return out


## 唯一一个入参不是「全在世界里」的 E 族步：fresh 是增生这一轮造出来的格子。
## 录进 args，C# 那边重放时照样给得出来。
## 形状是**一个串** `"q,r;q,r"`（空串 = 空表），与 C# `Steps.Args.Positions` 逐字相同：
## `args` 两侧都是「键 → 字符串」，录成数组会让整份用例文件反序列化失败。
func _erosion(fresh: Array[Vector2i] = []) -> void:
	var parts := PackedStringArray()
	for c in fresh:
		parts.append("%d,%d" % [c.x, c.y])
	var args := { "fresh": ";".join(parts) }
	if not rec.begin("cw_world.gd:_erosion", args):
		super._erosion(fresh)
		rec.skip()
		return
	super._erosion(fresh)
	rec.finish()


func _resolve_camping() -> void:
	if not rec.begin("cw_world.gd:_resolve_camping", {}):
		await super._resolve_camping()
		rec.skip()
		return
	await super._resolve_camping()
	rec.finish()


func _solidify() -> void:
	if not rec.begin("cw_world.gd:_solidify", {}):
		super._solidify()
		rec.skip()
		return
	super._solidify()
	rec.finish()


func _rooted() -> void:
	if not rec.begin("cw_world.gd:_rooted", {}):
		super._rooted()
		rec.skip()
		return
	super._rooted()
	rec.finish()


func _ossify() -> void:
	if not rec.begin("cw_world.gd:_ossify", {}):
		super._ossify()
		rec.skip()
		return
	super._ossify()
	rec.finish()


func _decay() -> void:
	if not rec.begin("cw_world.gd:_decay", {}):
		super._decay()
		rec.skip()
		return
	super._decay()
	rec.finish()


func _mark_adhesion() -> void:
	if not rec.begin("cw_world.gd:_mark_adhesion", {}):
		super._mark_adhesion()
		rec.skip()
		return
	super._mark_adhesion()
	rec.finish()


func _tick_necrosis() -> void:
	if not rec.begin("cw_world.gd:_tick_necrosis", {}):
		super._tick_necrosis()
		rec.skip()
		return
	super._tick_necrosis()
	rec.finish()


func _tick_chemo_cd() -> void:
	if not rec.begin("cw_world.gd:_tick_chemo_cd", {}):
		super._tick_chemo_cd()
		rec.skip()
		return
	super._tick_chemo_cd()
	rec.finish()


func _tick_chemo_track() -> void:
	if not rec.begin("cw_world.gd:_tick_chemo_track", {}):
		super._tick_chemo_track()
		rec.skip()
		return
	super._tick_chemo_track()
	rec.finish()


func _expire_marks() -> void:
	if not rec.begin("cw_world.gd:_expire_marks", {}):
		super._expire_marks()
		rec.skip()
		return
	super._expire_marks()
	rec.finish()


func _clear_newborn() -> void:
	if not rec.begin("cw_world.gd:_clear_newborn", {}):
		super._clear_newborn()
		rec.skip()
		return
	super._clear_newborn()
	rec.finish()


func _cap_energy() -> void:
	if not rec.begin("cw_world.gd:_cap_energy", {}):
		super._cap_energy()
		rec.skip()
		return
	super._cap_energy()
	rec.finish()


# ---- S 阶段 ----

func _reset_round_flags() -> void:
	if not rec.begin("cw_world.gd:_reset_round_flags", {}):
		super._reset_round_flags()
		rec.skip()
		return
	super._reset_round_flags()
	rec.finish()


func _tissue_production() -> void:
	if not rec.begin("cw_world.gd:_tissue_production", {}):
		await super._tissue_production()
		rec.skip()
		return
	await super._tissue_production()
	rec.finish()


func _vessel_teleport() -> void:
	if not rec.begin("cw_world.gd:_vessel_teleport", {}):
		await super._vessel_teleport()
		rec.skip()
		return
	await super._vessel_teleport()
	rec.finish()


## 覆的是 `_aerobic` / `_overload` 而不是公开的 `aerobic()` / `overload()` 那两层薄壳：
## 薄壳只是流程的调用口，真正的一步在下划线那个，直接调下划线的路才不会漏录。
## 契约表里这两条的 `gd` 也写 `cw_world.gd:_aerobic` / `:_overload`（§0.6.4 第 2 条已定）。
func _aerobic() -> void:
	if not rec.begin("cw_world.gd:_aerobic", {}):
		super._aerobic()
		rec.skip()
		return
	super._aerobic()
	rec.finish()


func _overload() -> void:
	if not rec.begin("cw_world.gd:_overload", {}):
		super._overload()
		rec.skip()
		return
	super._overload()
	rec.finish()
