## elm_proto.gd -- Elm 化原型跑通验证（headless）
##
## 运行：
##   "C:/.../Godot_v4.5-stable_win64_console.exe" --headless --path game --import
##   "C:/.../Godot_v4.5-stable_win64_console.exe" --headless --path game --script res://tests/elm_proto.gd
##
## 验证六件事：
##   1. update -> shell -> feed msg 回路能跑完（setup + 攻击演示）
##   2. 同种子两跑一致（确定性 = rng 进 state 的直接收益）
##   3. 状态链可回溯（取旧 state 不被新 state 污染）
##   4. 从旧 state 分叉独立推进（duplicate 隔离，原链终态保持不变）
##   5. 不同决策走不同链（Dummy vs Last 落子序列不同）
##   6. 演出不阻塞：COMBAT 两次 roll 一口气结算完，演出只进队列、逻辑不等动画
extends SceneTree


class DummyBridge:
	func ask(_req: Dictionary) -> int:
		return 0


class LastBridge:
	func ask(req: Dictionary) -> int:
		return req["options"].size() - 1


func _init():
	print("========================================")
	print("  Elm 原型 · 切片 2（setup + 攻击掷骰）")
	print("========================================")

	print("\n--- 1. 跑通：DummyBridge ---")
	var shell := ElmShell.new()
	shell.bridge = DummyBridge.new()
	var r := shell.run(12345, 4)
	_dump(r)

	print("\n--- 2. 确定性验证：同种子两跑应一致 ---")
	var s2 := ElmShell.new()
	s2.bridge = DummyBridge.new()
	var r2 := s2.run(12345, 4)
	print("  cells 数:  %d vs %d" % [r.state.cells.size(), r2.state.cells.size()])
	print("  rng_state: %d vs %d" % [r.state.rng_state, r2.state.rng_state])
	print("  rolls 数:  %d vs %d" % [r.rolls.size(), r2.rolls.size()])
	print("  一致: %s" % [_equal(r.state, r2.state)])

	print("\n--- 3. 回溯验证：链可取旧 state ---")
	print("  链长度: %d" % r.chain.size())
	if r.chain.size() >= 2:
		var early: Dictionary = r.chain[1]
		print("  chain[1] pc=%s cells=%d（应停在 INIT 后、第一个 ask 处）" % [early.pc, early.cells.size()])

	print("\n--- 4. 分叉验证：从 chain[1] 换 LastBridge 接跑，原链应不变 ---")
	var before_cells: int = r.state.cells.size()
	var before_rng: int = r.state.rng_state
	var fork_state: Dictionary = r.chain[1].duplicate(true)
	var fr := _run_from(fork_state, LastBridge.new())
	print("  分叉后 cells=%d steps=%d rolls=%d rng=%d" % [
		fr.state.cells.size(), fr.steps, fr.rolls.size(), fr.state.rng_state])
	print("  原链终态 cells=%d->%d rng=%d->%d（应不变）" % [
		before_cells, r.state.cells.size(), before_rng, r.state.rng_state])

	print("\n--- 5. 对照：全程 Dummy vs Last 落子序列应不同 ---")
	var s3 := ElmShell.new()
	s3.bridge = LastBridge.new()
	var r3 := s3.run(12345, 4)
	print("  Dummy 落子: %s" % [str(_cell_poses(r.state))])
	print("  Last  落子: %s" % [str(_cell_poses(r3.state))])
	print("  两者不同: %s" % [_cell_poses(r.state) != _cell_poses(r3.state)])

	print("\n--- 6. 演出不阻塞验证：逻辑已结算完，演出仍在队列 ---")
	print("  rolls 队列: %d 个 roll_show（两次攻击，逻辑一口气结算完）" % r.rolls.size())
	for i in r.rolls.size():
		var fx: Dictionary = r.rolls[i]
		print("    roll[%d] value=%d at=%s" % [i, fx.value, str(fx.at)])
	var p1: Dictionary = _find_cell(r.state, 1)
	print("  免疫 P1 hp=%d（应 < 10，逻辑已结算不等动画）" % p1.hp)
	print("  逻辑终态 pc=%s（应 DONE）" % r.state.pc)

	print("\n========================================")
	var ok: bool = r.state.pc == "DONE" \
		and r2.state.rng_state == r.state.rng_state \
		and r.rolls.size() == 2 \
		and r.state.cells.size() == before_cells \
		and int(p1.hp) < 10
	print("  原型跑通 " + ("✓" if ok else "✗"))
	print("========================================")
	quit()


# 从一个已有 state 接着跑（分叉验证用）。起点若有 pending，先喂一个 decision。
func _run_from(state: Dictionary, br) -> Dictionary:
	var s: Dictionary = state.duplicate(true)
	var msg: Dictionary = {}
	var rolls: Array = []
	if s.pending != null:
		msg = { "kind": "decision", "idx": br.ask({ "options": s.pending["options"] }) }
	var steps := 0
	while s.pc != "DONE" and steps < 1000:
		var r := ElmCore.update(s, msg)
		s = r["state"]
		msg = {}
		for fx in r["effects"]:
			if fx["kind"] == "ask":
				msg = { "kind": "decision", "idx": br.ask(fx["req"]) }
			elif fx["kind"] == "roll_show":
				rolls.append(fx)
		steps += 1
	return { "state": s, "steps": steps, "rolls": rolls }


func _dump(r: Dictionary) -> void:
	print("  steps: %d" % r.steps)
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


func _find_cell(state: Dictionary, pid: int) -> Dictionary:
	for c in state.cells:
		if int(c["pid"]) == pid:
			return c
	return {}


func _equal(a: Dictionary, b: Dictionary) -> bool:
	if a.cells.size() != b.cells.size():
		return false
	if a.rng_state != b.rng_state:
		return false
	for i in a.cells.size():
		if a.cells[i]["pos"] != b.cells[i]["pos"]:
			return false
	return true
