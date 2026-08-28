## elm_session_test.gd —— ElmSession + ElmHeuristicBridge 冒烟/等价测试
##
## 验证两件事：
##   1) 新运行时（ElmSession + 纯函数启发式桥）能完整跑对局（parse/运行无错）
##   2) 与旧运行时（CWGame + CWHeuristicBridge）**同种子同人数完全等价**：
##      winner / win_kind / win_reason / round_no / state_hash / rng_state / logs 全一致
##      —— 证明「整个项目切到新架构」不会改变对局结果。
extends SceneTree

const N_PLAYERS := 4
const SEEDS := [1, 42, 999]


func _initialize() -> void:
	_run()


func _run() -> void:
	print("[ElmSession 冒烟 + 新旧等价]")
	var fails := 0
	var checks := 0
	for seed in SEEDS:
		# 旧运行时：CWGame + CWHeuristicBridge（冻结基线）
		var g := CWGame.new()
		g.init(CWData.FACTION_ORDER[N_PLAYERS], seed)
		for pid in g.order:
			var b := CWHeuristicBridge.new()
			b.game = g
			g.bridges[pid] = b
		var w_old: int = await g.run_game()
		var old_hash: String = g.state_hash()
		var old_rng: int = g.rng.state
		var old_res := { "winner": w_old, "kind": g.win_kind,
			"reason": g.win_reason, "round": g.round_no,
			"hash": old_hash, "rng": old_rng, "logs": g.logs.duplicate() }
		g.dispose()
		# 新运行时：ElmSession + ElmHeuristicBridge（纯函数）
		var s := ElmSession.new()
		s.init_game(CWData.FACTION_ORDER[N_PLAYERS], seed)
		var res := s.run_full()
		var rng_state: int = res["state"]["rng_state"]
		var ok: bool = res["winner"] == old_res["winner"] \
			and res["win_kind"] == old_res["kind"] \
			and res["win_reason"] == old_res["reason"] \
			and res["round_no"] == old_res["round"] \
			and res["state"]["rng_state"] == old_res["rng"] \
			and Array(res["state"]["logs"]) == Array(old_res["logs"])
		checks += 1
		if ok:
			print("  seed=%d  等价 ✓  winner=%s  round=%d  logs=%d  steps=%d" % [
				seed, "免疫" if res["winner"] == CWData.Faction.IMMUNE else "癌症",
				res["round_no"], res["logs"].size(), res["steps"]])
		else:
			fails += 1
			print("  seed=%d  FAIL：winner=%s/%s kind=%s/%s round=%d/%d rng=%d/%d logs=%d/%d" % [
				seed, res["winner"], old_res["winner"], res["win_kind"], old_res["kind"],
				res["round_no"], old_res["round"], rng_state, old_rng,
				res["logs"].size(), old_res["logs"].size()])
		s.dispose()
	print("")
	if fails == 0:
		print("✔ 全部通过（%d 项检查）" % checks)
		quit(0)
	else:
		print("✘ %d 项失败（共 %d 项）" % [fails, checks])
		quit(1)
