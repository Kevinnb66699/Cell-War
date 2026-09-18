## cw_obs_codec.gd —— 观测协议 v1 的 GD 生产者（口径二 · 批 0 步 8；正本 docs/观测协议_v1.md，键表 cw_obs_proto.gd）
##
## 只读一份 CWGame 产出一份 envelope（字典，可直接 JSON.stringify）。恒交 tier A + B。
## 口径：能量 / 费用 / 固化计数是十分位整数，比例是千分点，枚举是 GD 的整数值，细胞引用是 cell id，坐标是 {q, r}。
## 派生量一律**转手引擎现成的查询**（拍板 9：UI 一个规则数值都不留，这里也一样不许自己算）。
## 按席位裁剪在这里做（§七 三档）：viewer >= 0 本席 / -1 观众（open_hands 照实）/ -2 全知（禁止过网）。
class_name CWObsCodec
extends RefCounted

const RULES_BUILD := "gd-inproc"


## ctx = { viewer, open_hands, logs_from, ask（询问 req 字典；缺省取 game.pending()）, ask_id, rev, obs_seq }
static func encode(game: CWGame, ctx: Dictionary = {}) -> Dictionary:
	var viewer := int(ctx.get("viewer", CWObsProto.VIEWER_OMNISCIENT))
	var open_hands := viewer == CWObsProto.VIEWER_WATCHER and bool(ctx.get("open_hands", false))
	var req: Dictionary = ctx.get("ask", game._pending)   ## 不用 pending()：那是会推进流程的协程
	var rev := int(ctx.get("rev", 0))
	return {
		"p": CWObsProto.P,
		"ruleset": { "host_abi": 1, "rules_build": RULES_BUILD, "digest": game.tune.signature() },
		"rev": rev, "obs_seq": int(ctx.get("obs_seq", 0)),
		"viewer": viewer, "open_hands": open_hands,
		"produced_tiers": CWObsProto.TIERS_GD.duplicate(), "full": true, "base": null,
		"state": { "board": _board(game), "cells": _cells(game, viewer, open_hands), "g": _global(game, req) },
		"ask": _ask(game, req, int(ctx.get("ask_id", 0)), rev, viewer),
		"logs": _logs(game, viewer, open_hands, int(ctx.get("logs_from", 0))),
	}


static func pos(v: Vector2i) -> Dictionary:
	return { "q": v.x, "r": v.y }


# ---- §二 棋盘 ----
static func _board(game: CWGame) -> Dictionary:
	var keys: Array = game.tiles.keys()
	keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.x < b.x or (a.x == b.x and a.y < b.y))
	var threshold := game.solidify_threshold()
	var tiles: Array = []
	for c: Vector2i in keys:
		var t: Dictionary = game.tiles[c]
		var occ: Array = game.cells_at(c)
		tiles.append({
			"at": pos(c), "tissue": int(t["tissue"]), "special": int(t["special"]), "solid": int(t["solid"]),
			"necrosis": int(t["necrosis"]), "mucus": bool(t["mucus"]), "newborn": bool(t["newborn"]),
			"ossify_at": int(t["ossify_at"]), "toxin_round": int(t["toxin_round"]), "prod": int(t["prod"]),
			"store": int(t["store"]), "cards": int(t["cards"]),
			"cell": (int(occ[0]["id"]) if not occ.is_empty() else -1),
			"d": {
				"pressure": game.world.pressure_at(c),
				"solid_fraction": _permille(CWData.solid_progress(t, threshold)),
				"store_fraction": _permille(CWData.store_progress(t)),
				"proliferate_chance": game.world.proliferate_chance(c),
				"prod_left": _prod_left(t), "store_max": _store_max(t), "solid_frozen": _solid_frozen(game, c),
			},
		})
	return { "radius": game.board_radius, "tiles": tiles }


static func _permille(f: float) -> int:
	return 0 if f < 0.0 else int(round(f * 1000.0))


static func _prod_left(t: Dictionary) -> int:
	var healthy := int(t["tissue"]) == CWData.Tissue.HEALTHY
	match int(t["special"]):
		CWData.Special.CORE:
			return maxi(CWData.CORE_HEALTHY_PERIOD - int(t["prod"]), 0) if healthy else 0   ## 癌性核心每回合都产
		CWData.Special.MARROW:
			var period: int = CWData.MARROW_HEALTHY_PERIOD if healthy else CWData.MARROW_CANCER_PERIOD
			return maxi(period - int(t["prod"]), 0)
	return 0


static func _store_max(t: Dictionary) -> int:
	match int(t["special"]):
		CWData.Special.CORE:
			return CWData.CORE_STORE_MAX
		CWData.Special.MARROW:
			return CWData.MARROW_STORE_MAX
	return 0


## 【TNF-α局部炎症】的冻结名单挂在全局条目的 data 上（cw_card_fx.gd _tnf），键是 Vector2i
static func _solid_frozen(game: CWGame, c: Vector2i) -> bool:
	for e: Dictionary in game.events["active"]:
		if str(e["name"]) == "TNF-α局部炎症" and (e.get("data", {}) as Dictionary).has(c):
			return true
	return false


# ---- §三 细胞 ----
static func _cells(game: CWGame, viewer: int, open_hands: bool) -> Array:
	var out: Array = []
	for cell: Dictionary in game.cells:
		var mine := viewer == CWObsProto.VIEWER_OMNISCIENT or (viewer >= 0 and int(cell["pid"]) == viewer) \
			or (viewer == CWObsProto.VIEWER_WATCHER and open_hands)
		var hand: Array = []
		for c in cell["hand"]:
			hand.append(str(c) if mine else CWNet.HIDDEN_CARD)   ## 换占位、张数保留（cw_net.gd view_for）
		var equipped: Array = []
		for e in cell["equipped"]:
			equipped.append(str(e))
		var mods: Array = []
		for m: Dictionary in cell["mods"]:
			mods.append({ "name": str(m["name"]), "uses": int(m.get("uses", 0)), "until": str(m.get("until", "")), "seq": int(m.get("seq", 0)) })
		var eq := {}
		for k in cell["equip_seq"]:
			eq[str(k)] = int(cell["equip_seq"][k])
		var fxt := {}
		for k in cell["fx_turn"]:
			fxt[str(k)] = int(cell["fx_turn"][k])
		var fxr: Array = []
		for k in cell["fx_round"].keys():
			fxr.append(str(k))
		out.append({
			"id": int(cell["id"]), "pid": int(cell["pid"]), "faction": int(cell["faction"]), "pos": pos(cell["pos"]),
			"itype": int(cell["itype"]), "ctype": int(cell["ctype"]), "energy": int(cell["energy"]), "alive": bool(cell["alive"]),
			"marked": bool(cell["marked"]), "mark_left": int(cell["mark_left"]), "mark_round": int(cell["mark_round"]),
			"effector_used": bool(cell["effector_used"]), "hand": hand, "equipped": equipped, "mods": mods,
			"play_n": int(cell["play_n"]), "equip_seq": eq, "fx_turn": fxt, "fx_round": fxr,
			"differentiated": bool(cell["differentiated"]), "chemo_cd": int(cell["chemo_cd"]),
			"armor_used": bool(cell["armor_used"]), "mutate_used": bool(cell["mutate_used"]), "toxin_used": int(cell["toxin_used"]),
			"antibody_used": int(cell["antibody_used"]), "metastasis_used": bool(cell["metastasis_used"]), "jump_used": int(cell["jump_used"]),
			"draws_used": int(cell["draws_used"]), "attacks_used": int(cell["attacks_used"]),
			"respawn_round": int(cell["respawn_round"]), "camp_round": int(cell["camp_round"]),
			"camp_pos": (pos(cell["camp_pos"]) if int(cell["camp_round"]) >= 0 else null),
			## 动态 4 键（不在 make_cell 里）：没写过就给默认值；neutral_until 从没被中和 = -1
			"chain_left": int(cell.get("chain_left", 0)), "chain_bonus": int(cell.get("chain_bonus", 0)),
			"neutral_until": int(cell.get("neutral_until", -1)), "chain_running": bool(cell.get("chain_running", false)),
			"d": _cell_d(game, cell),
		})
	return out


static func _cell_d(game: CWGame, cell: Dictionary) -> Dictionary:
	var alive := bool(cell["alive"])
	var immune := int(cell["faction"]) == CWData.Faction.IMMUNE
	var is_b := int(cell["itype"]) == CWData.ImmuneType.B_CELL
	return {
		## tier A（C# 也产）—— match_panel.gd income_text 的同一对函数
		"income": ((game.world.aerobic_income(cell) if immune else game.world.anaerobic_gain_for(cell)) if alive else 0),
		"antibody_damage": (game.actions.antibody_damage(cell) if alive and is_b else 0),
		"overload_loss": (game.world.overload_loss(cell) if alive else 0),
		## tier B（批 0 只有 GD 产）
		"action_kinds": (Array(game.actions.action_kinds(cell)) if alive else []),
		"status_rows": (game.damage.status_rows(cell) if alive else []),
		"pressure_lethal": (game.world.pressure_lethal(cell) if alive else false),
		"neutralized": game.neutralized(cell), "type_ability_on": game.type_ability_on(cell),
		"antibody_cost": (game.actions.antibody_cost(cell) if is_b else 0),
		"metastasis_cost_real": (game.actions.skill_move_cost(cell, game.tune.metastasis_cost) if int(cell["ctype"]) == CWData.CancerType.SCLC else 0),
		"ossify_cost_real": (int(game.tune.osteo_ossify_cost) if int(cell["ctype"]) == CWData.CancerType.OSTEO else 0),   ## ui_bridge.gd 读旋钮不写死
		"attack_cap_left": maxi(int(game.tune.attack_max_per_turn) - int(cell["attacks_used"]), 0),
		"draw_cap_left": maxi(CWData.DRAW_MAX_PER_TURN - int(cell["draws_used"]), 0),
	}


# ---- §四 顶层 ----
static func phase_word(game: CWGame) -> String:
	## 与 tests/xcheck_export.gd phase_of 同一张表（L1 视图的词）
	if game.is_over():
		return "finished"
	match str(game.flow["stage"]):
		"init", "setup_place":
			return "setup"
		"round_start", "revive_immune", "revive_cancer":
			return "s"
		"turn":
			return "turn"
		"e_phase":
			return "e"
	return str(game.flow["stage"])


static func _global(game: CWGame, req: Dictionary) -> Dictionary:
	var word := phase_word(game)
	var diff: Array = game.differentiated.duplicate()
	diff.sort()
	var chain_cell := -1
	for cell: Dictionary in game.cells:
		if bool(cell.get("chain_running", false)):
			chain_cell = int(cell["id"])
			break
	var pool: Array = []
	for n in game.events["pool"]:
		pool.append(str(n))
	var active: Array = []
	for e: Dictionary in game.events["active"]:
		active.append({ "name": str(e["name"]), "left": int(e["left"]), "stacks": int(e.get("stacks", 1)),
			"doubled": str(e.get("doubled", "")), "data": _effect_data(e.get("data", {})),
			"d": { "is_world_event": game.world_fx.is_world_event(e) } })
	var feed: Array = []
	for f: Dictionary in game.feed_log:
		feed.append({ "seq": int(f["seq"]), "kind": str(f["kind"]), "pid": int(f["pid"]), "faction": int(f["faction"]),
			"card": str(f["card"]), "left": int(f.get("left", 0)) })
	var players: Array = []
	for p: Dictionary in game.players:
		var pid := int(p["id"])
		var income := 0
		for cell: Dictionary in game.living_cells():
			if int(cell["pid"]) == pid:
				income += game.world.aerobic_income(cell) if int(cell["faction"]) == CWData.Faction.IMMUNE else game.world.anaerobic_gain_for(cell)
		players.append({ "id": pid, "name": str(p.get("name", "")), "faction": int(p["faction"]),
			"cell_id": (int(p.get("cell_id", -1)) if int(p.get("cell_id", -1)) < game.cells.size() else -1),   ## 落子前细胞还不存在
			"cancer_type": int(p.get("cancer_type", -1)), "d": { "income": income } })
	var chemo: Dictionary = game.chemo
	var track: Dictionary = game.chemo_track
	var thresholds: Array = Array(CWData.level_min_memory(game.order.size()))
	var next_at := -1
	for th in thresholds:
		if int(th) > game.memory:
			next_at = int(th)
			break
	return {
		"round_no": int(game.round_no), "phase": word,
		"current_pid": (int(game.current_pid) if word == "turn" else -1),   ## GD 换阶段不清零，协议按 L1 视图口径
		## 正在问的那一席：有问就是问的 pid（game.asking_pid 要到 ask() 才写、在 pending 边界上是上一问的）
		"asking_pid": (int(req.get("pid", -1)) if not req.is_empty() else int(game.asking_pid)),
		"memory": int(game.memory), "immune_level": int(game.immune_level), "effector_round": int(game.effector_round),
		"differentiated": diff,
		"winner": int(game.winner), "win_reason": str(game.win_reason), "win_kind": str(game.win_kind),
		"cancer_alarm": { "streak": int(game.cancer_win_streak), "hold_rounds": int(game.tune.cancer_win_hold_rounds) },
		"chemo": (null if chemo.is_empty() else { "at": pos(chemo["at"]), "left": int(chemo["left"]), "by": int(chemo["by"]), "cid": int(chemo.get("cid", -1)) }),
		"chemo_track": (null if track.is_empty() else { "cid": int(track.get("cid", -1)), "at": pos(game.chemo_track_at()), "left": int(track.get("left", 0)) }),
		"events": { "pool": pool, "active": active, "double_next": bool(game.events["double_next"]) },
		"feed_log": feed, "feed_seq": int(game.feed_seq),
		"chain_cell": chain_cell, "aborted": bool(game.aborted), "is_over": game.is_over(),
		"order": Array(game.order),
		"players": players,
		"tune": {
			"world_events_on": bool(game.tune.world_events_on), "cancer_win_weighted": int(game.tune.cancer_win_weighted),
			"cancer_win_hold_rounds": int(game.tune.cancer_win_hold_rounds), "limit_round": int(game.tune.limit_round),
			"limit_cancerous": int(game.tune.limit_cancerous), "mucus_move_surcharge": int(game.tune.mucus_move_surcharge),
			"metastasis_cost": int(game.tune.metastasis_cost), "osteo_ossify_cost": int(game.tune.osteo_ossify_cost),
			"solidify_threshold": Array(game.tune.solidify_threshold),
		},
		"d": {
			"solid_threshold": game.solidify_threshold(), "tumor_stage": game.tumor_stage() + 1, "cancer_phase": game.tumor_stage(),
			"phase_text": str(game.phase), "is_world_event_round": CWData.is_world_event_round(game.round_no),
			"count_healthy": game.count_tissue(CWData.Tissue.HEALTHY), "count_cancer": game.count_tissue(CWData.Tissue.CANCER),
			"count_solid": game.count_tissue(CWData.Tissue.SOLID), "count_necrosis": game.count_necrosis(),
			"cancer_weighted": game.count_tissue(CWData.Tissue.CANCER) + 2 * game.count_tissue(CWData.Tissue.SOLID),   ## cw_game.gd:1118 同式
			"level_thresholds": thresholds, "memory_next_at": next_at,
		},
	}


## 全局条目的 data：键统一成字符串（Vector2i 键 → "q,r"），值 bool → 1/0、Vector2i → {q,r}（C# 那边存的是 int）
static func _effect_data(data: Dictionary) -> Dictionary:
	var out := {}
	for k in data:
		var key: String = ("%d,%d" % [k.x, k.y]) if k is Vector2i else str(k)
		var v = data[k]
		if v is bool:
			out[key] = 1 if v else 0
		elif v is Vector2i:
			out[key] = pos(v)
		else:
			out[key] = v
	return out


# ---- §六 询问 ----
static func _ask(game: CWGame, req: Dictionary, ask_id: int, rev: int, viewer: int) -> Variant:
	if req.is_empty():
		return null
	var seat := int(req.get("pid", -1))
	var mine := viewer == CWObsProto.VIEWER_OMNISCIENT or (viewer >= 0 and viewer == seat)
	var tag_raw = req.get("tag", null)
	var tag: Variant = (str(tag_raw) if tag_raw != null and str(tag_raw) != "" else null)
	var cell := {}
	if seat >= 0 and seat < game.players.size() and int(game.players[seat].get("cell_id", -1)) < game.cells.size():
		cell = game.cell_of(seat)
	var opts: Array = req.get("options", [])
	var options: Array = []
	var stop_index := -1
	for i in opts.size():
		var o: Dictionary = opts[i]
		var data: Dictionary = o.get("data", {})
		var is_stop := bool(data.get("stop", false)) or bool(data.get("skip", false))
		if is_stop and stop_index < 0:
			stop_index = i
		if not mine:
			continue
		var is_attack := false
		if str(data.get("act", "")) == "move" and data.get("to", null) is Vector2i and not cell.is_empty():
			var enemy: int = CWData.Faction.CANCER if int(cell["faction"]) == CWData.Faction.IMMUNE else CWData.Faction.IMMUNE
			is_attack = not game.cells_at(data["to"], enemy).is_empty()
		options.append({
			"index": i, "key": CWSemKey.key(req, data), "label": str(o.get("label", "")), "data": _plain(data),
			"cost": (int(data["cost"]) if data.has("cost") else null),
			"cost_rows": _cost_rows(game, cell, data),
			"anchor": (pos(data["anchor"]) if data.has("anchor") else null),
			"is_stop": is_stop, "is_attack": is_attack, "blocked": null,
		})
	return { "ask_id": ask_id, "rev": rev, "kind": str(req.get("kind", "")), "tag": tag, "seat": seat,
		"prompt": str(req.get("prompt", "")), "mine": mine, "stop_index": stop_index, "options": options }


## 迁移选项的报价明细（CWCost.quote 的 breakdown 里真改了值的行）；其余选项空表
static func _cost_rows(game: CWGame, cell: Dictionary, data: Dictionary) -> Array:
	if cell.is_empty() or str(data.get("act", "")) != "move" or not (data.get("to", null) is Vector2i):
		return []
	var to: Vector2i = data["to"]
	var q: Dictionary = game.cost.quote(CWCost.context(cell, CWCost.Action.MOVE, game.actions._move_base_cost(cell, to), to))
	var rows: Array = []
	for s: Dictionary in q["breakdown"]:
		if s["before"] == s["after"] and str(s["note"]) == "":
			continue
		rows.append({ "name": str(s["name"]), "before": int(s["before"]), "after": int(s["after"]), "note": str(s["note"]) })
	return rows


## 选项 data 原样保留 GD 形状，只把 Vector2i 编成 {q,r}
static func _plain(v: Variant) -> Variant:
	if v is Vector2i:
		return pos(v)
	if v is Dictionary:
		var out := {}
		for k in v:
			out[str(k)] = _plain(v[k])
		return out
	if v is Array:
		var arr: Array = []
		for x in v:
			arr.append(_plain(x))
		return arr
	return v


# ---- 日志（§七：秘密行换公开替身，照 cw_net.gd logs_for）----
static func _logs(game: CWGame, viewer: int, open_hands: bool, from: int) -> Dictionary:
	var lines: Array = []
	if viewer == CWObsProto.VIEWER_OMNISCIENT:
		for i in range(maxi(from, 0), game.logs.size()):
			lines.append(game.logs[i])
	else:
		for l in CWNet.logs_for(game, viewer, maxi(from, 0), viewer == CWObsProto.VIEWER_WATCHER and open_hands):
			lines.append(l)
	return { "from": maxi(from, 0), "lines": lines }
