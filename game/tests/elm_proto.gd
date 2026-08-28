## elm_proto.gd —— Elm 化原型跑通验证（headless）
##
## 运行：
##   "C:/.../Godot_v4.4-stable_win64_console.exe" --headless --path game --import
##   "C:/.../Godot_v4.4-stable_win64_console.exe" --headless --path game --script res://tests/elm_proto.gd
##
## 验证七件事（迁移版 ElmGame/ElmShell 上的 msg 驱动回路）：
##   1. msg 驱动回路能跑完（shell 读 state 发 step/decision 到 DONE）
##   2. 同种子两跑一致（确定性）
##   3. 状态链可回溯
##   4. 从旧 state 分叉独立推进（duplicate 隔离，原链不变）
##   5. 不同决策走不同链
##   6. 演出不阻塞：多次 roll 一口气结算完，演出只进队列
##   7. 状态机不自走：state 停在 ask 时发 step，state 不变（靠外界 decision 才动）
extends SceneTree


class DummyBridge:
	func ask(_req: Dictionary) -> int:
		return 0


class LastBridge:
	func ask(req: Dictionary) -> int:
		return req["options"].size() - 1


func _init():
	print("========================================")
	print("  Elm 原型 · 迁移版 msg 驱动回路（step / decision）")
	print("========================================")
	var faction_list: Array = CWData.FACTION_ORDER[4]
	var tune := CWTuning.new()

	print("\n--- 1. 跑通：DummyBridge ---")
	var r := _run_full(12345, faction_list, tune, DummyBridge.new())
	_dump(r)

	print("\n--- 2. 确定性验证：同种子两跑应一致 ---")
	var r2 := _run_full(12345, faction_list, tune, DummyBridge.new())
	print("  rng_state: %d vs %d" % [r.state.rng_state, r2.state.rng_state])
	print("  logs 数:   %d vs %d" % [r.state.logs.size(), r2.state.logs.size()])
	print("  一致: %s" % [_equal(r.state, r2.state)])

	print("\n--- 3. 回溯验证：链可取旧 state ---")
	print("  链长度: %d（每个 msg 一步）" % r.chain.size())
	if r.chain.size() >= 2:
		var early: Dictionary = r.chain[1]
		print("  chain[1] pc=%s pending=%s（应停在第一个 ask 处）" % [
			early.pc, early.pending != null])

	print("\n--- 4. 分叉验证：从 chain[1] 换 LastBridge 接跑，原链应不变 ---")
	var before_cells: int = r.state.cells.size()
	var before_rng: int = r.state.rng_state
	var fr := _run_from(r.chain[1].duplicate(true), faction_list, tune, LastBridge.new())
	print("  分叉后 cells=%d steps=%d rng=%d" % [
		fr.state.cells.size(), fr.steps, fr.state.rng_state])
	print("  原链终态 cells=%d->%d rng=%d->%d（应不变）" % [
		before_cells, r.state.cells.size(), before_rng, r.state.rng_state])

	print("\n--- 5. 对照：全程 Dummy vs Last 落子序列应不同 ---")
	var r3 := _run_full(12345, faction_list, tune, LastBridge.new())
	print("  Dummy 落子: %s" % [str(_cell_poses(r.state))])
	print("  Last  落子: %s" % [str(_cell_poses(r3.state))])
	print("  两者不同: %s" % [_cell_poses(r.state) != _cell_poses(r3.state)])

	print("\n--- 6. 演出不阻塞：多次 roll 一口气结算，演出只进队列 ---")
	print("  rolls 队列: %d 个 roll_show（pc=%s 已跑完，逻辑不等动画）" % [r.rolls.size(), r.state.pc])
	var all_in_range := true
	for i in r.rolls.size():
		var fx: Dictionary = r.rolls[i]
		if int(fx.value) < 1 or int(fx.value) > int(fx.sides):
			all_in_range = false
		print("    roll[%d] value=%d sides=%d at=%s" % [i, fx.value, fx.sides, str(fx.at)])
	print("  所有掷骰落在 1..面数: %s" % all_in_range)

	print("\n--- 7. 状态机不自走：停在 ask 时发 step，state 不变 ---")
	var s_ask: Dictionary = r.chain[1]
	print("  chain[1] pending=%s pc=%s" % [s_ask.pending != null, s_ask.pc])
	var step_r := ElmGame.update(s_ask, { "kind": "step" })
	var same_pending: bool = step_r.state.pending != null
	var same_cells: bool = step_r.state.cells.size() == s_ask.cells.size()
	var same_hash: bool = ElmGame.state_hash(step_r.state) == ElmGame.state_hash(s_ask)
	print("  发 step 后: pending 仍在=%s, cells 不变=%s, hash 不变=%s" % [
		same_pending, same_cells, same_hash])
	print("  （状态机不等，靠外界发 decision 才动）")

	print("\n========================================")
	var ok: bool = r.state.pc == "DONE" \
		and r2.state.rng_state == r.state.rng_state \
		and r.rolls.size() > 0 and all_in_range \
		and r.state.cells.size() == before_cells \
		and same_pending and same_cells and same_hash
	print("  原型跑通 " + ("✓" if ok else "✗"))
	print("========================================")
	quit()


## 完整驱动一局（run_full 的独立实现，供分叉/确定性复用）
func _run_full(seed_value: int, faction_list: Array, tune, br) -> Dictionary:
	var state := ElmGame.make_initial_state(seed_value, faction_list, tune)
	var chain: Array = [state]
	var rolls: Array = []
	var steps := 0
	while String(state["pc"]) != "DONE" and steps < 30000:
		var msg: Dictionary
		if state["pending"] != null:
			var idx: int = br.ask(state["pending"]["req"])
			msg = { "kind": "decision", "idx": idx }
		else:
			msg = { "kind": "step" }
		var r := ElmGame.update(state, msg)
		state = r["state"]
		chain.append(state)
		for fx in r["effects"]:
			if fx["kind"] == "roll_show":
				rolls.append(fx)
		steps += 1
	return { "state": state, "chain": chain, "steps": steps, "rolls": rolls }


# 从一个已有 state 接着跑（分叉验证用）。shell 驱动逻辑的独立实现。
func _run_from(state: Dictionary, faction_list: Array, tune, br) -> Dictionary:
	var s: Dictionary = state.duplicate(true)
	var rolls: Array = []
	var steps := 0
	while String(s["pc"]) != "DONE" and steps < 30000:
		var msg: Dictionary
		if s["pending"] != null:
			var idx: int = br.ask(s["pending"]["req"])
			msg = { "kind": "decision", "idx": idx }
		else:
			msg = { "kind": "step" }
		var r := ElmGame.update(s, msg)
		s = r["state"]
		for fx in r["effects"]:
			if fx["kind"] == "roll_show":
				rolls.append(fx)
		steps += 1
	return { "state": s, "steps": steps, "rolls": rolls }


func _dump(r: Dictionary) -> void:
	print("  steps: %d（= msg 数）" % r.steps)
	print("  cells: %d" % r.state.cells.size())
	print("  落子序列: %s" % [str(_cell_poses(r.state))])
	print("  日志:")
	for l in r.state.logs:
		print("    %s" % l)
	print("  rolls 队列: %d 个" % r.rolls.size())
	print("  最终 rng_state: %d" % r.state.rng_state)


func _cell_poses(state: Dictionary) -> Array:
	var out: Array = []
	for c in state.cells:
		out.append(str(c["pid"]) + ":" + str(c["pos"]))
	return out


func _equal(a: Dictionary, b: Dictionary) -> bool:
	if a.cells.size() != b.cells.size():
		return false
	if a.rng_state != b.rng_state:
		return false
	if a.logs.size() != b.logs.size():
		return false
	for i in a.cells.size():
		if a.cells[i]["pos"] != b.cells[i]["pos"]:
			return false
	return true
