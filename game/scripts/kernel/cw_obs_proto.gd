## cw_obs_proto.gd —— 观测协议 v1 的字段白名单（口径二 · 批 0 步 8；正本是 docs/观测协议_v1.md，这里是 GD 侧唯一一份键表）
##
## 生产者（CWObsCodec）照它产、消费者（CWMirror）照它验：**未知键 = 硬错**；tier A 与状态键缺了 = 硬错；
## tier B（`*_B` 表）缺席合法 —— C# 生产者批 0 只交 tier A（envelope 的 produced_tiers 说明它交了哪几档）。
## 改字段：先改文档、再改这里与 C# 的 ObservationV1.cs、再升 P。
class_name CWObsProto
extends RefCounted

const P := 2   ## 2026-09-19 批 1 步 1：tier B 加三键 + cost_effects_for 批量形参 + InProc 可推 sync（观测协议 §九）
const VIEWER_WATCHER := -1
const VIEWER_OMNISCIENT := -2
const TIERS_GD := ["A", "B"]

const ENVELOPE := ["p", "ruleset", "rev", "obs_seq", "viewer", "open_hands", "produced_tiers", "full", "base", "state", "ask", "logs"]
const RULESET := ["host_abi", "rules_build", "digest"]
const STATE := ["board", "cells", "g"]
const BOARD := ["radius", "tiles"]
const POS := ["q", "r"]
## §二 · 14 键
const TILE := ["at", "tissue", "special", "solid", "necrosis", "mucus", "newborn", "ossify_at", "toxin_round", "prod",
	"store", "cards", "cell", "d"]
const TILE_D_A := ["pressure", "solid_fraction", "store_fraction", "proliferate_chance"]
const TILE_D_B := ["prod_left", "store_max", "solid_frozen", "store_pending"]
## §三 · 36 键（make_cell 32 + 动态 4）
const CELL := ["id", "pid", "faction", "pos", "itype", "ctype", "energy", "alive", "marked", "mark_left", "mark_round",
	"effector_used", "hand", "equipped", "mods", "play_n", "equip_seq", "fx_turn", "fx_round", "differentiated", "chemo_cd",
	"armor_used", "mutate_used", "toxin_used", "antibody_used", "metastasis_used", "jump_used", "draws_used", "attacks_used",
	"respawn_round", "camp_round", "camp_pos", "chain_left", "chain_bonus", "neutral_until", "chain_running", "d"]
const CELL_D_A := ["income", "antibody_damage", "overload_loss"]
const CELL_D_B := ["action_kinds", "status_rows", "pressure_lethal", "neutralized", "type_ability_on", "antibody_cost",
	"metastasis_cost_real", "ossify_cost_real", "attack_cap_left", "draw_cap_left", "homing_cost_real"]
const MOD := ["name", "uses", "until", "seq"]
const STATUS_ROW := ["kind", "name", "detail"]
## §四
const G := ["round_no", "phase", "current_pid", "asking_pid", "memory", "immune_level", "effector_round", "differentiated",
	"winner", "win_reason", "win_kind", "cancer_alarm", "chemo", "chemo_track", "events", "feed_log", "feed_seq", "chain_cell",
	"aborted", "is_over", "order", "players", "tune", "d"]
const G_D_A := ["solid_threshold", "tumor_stage", "cancer_phase", "phase_text", "is_world_event_round"]
const G_D_B := ["count_healthy", "count_cancer", "count_solid", "count_necrosis", "cancer_weighted", "level_thresholds", "memory_next_at", "next_event_round"]
const CANCER_ALARM := ["streak", "hold_rounds"]
const CHEMO := ["at", "left", "by", "cid"]
const TRACK := ["cid", "at", "left"]
const EVENTS := ["pool", "active", "double_next"]
const EFFECT := ["name", "left", "stacks", "doubled", "data", "d"]
const EFFECT_D := ["is_world_event"]
const FEED := ["seq", "kind", "pid", "faction", "card", "left"]
const PLAYER := ["id", "name", "faction", "cell_id", "cancer_type", "d"]
const PLAYER_D := ["income"]
const TUNE := ["world_events_on", "cancer_win_weighted", "cancer_win_hold_rounds", "limit_round", "limit_cancerous",
	"mucus_move_surcharge", "metastasis_cost", "osteo_ossify_cost", "solidify_threshold"]
## §六
const ASK := ["ask_id", "rev", "kind", "tag", "seat", "prompt", "mine", "stop_index", "options"]
const OPTION := ["index", "key", "label", "data", "cost", "cost_rows", "anchor", "is_stop", "is_attack", "blocked"]
const COST_ROW := ["name", "before", "after", "note"]
const LOGS := ["from", "lines"]

## GD 快照键 → envelope 落点（t_mirror_field_table 的反射护栏用）。豁免的三个是引擎私货，C# 天然产不出（规格 A-2.1）
const SNAPSHOT_EXEMPT := ["flow", "pending", "rng"]
const SNAPSHOT_TO_ENVELOPE := {
	"tiles": "state.board.tiles", "board_radius": "state.board.radius", "cells": "state.cells",
	"chemo_track": "state.g.chemo_track", "feed_log": "state.g.feed_log", "feed_seq": "state.g.feed_seq",
	"effector_round": "state.g.effector_round", "players": "state.g.players", "order": "state.g.order",
	"differentiated": "state.g.differentiated", "round_no": "state.g.round_no", "memory": "state.g.memory",
	"immune_level": "state.g.immune_level", "winner": "state.g.winner", "win_reason": "state.g.win_reason",
	"win_kind": "state.g.win_kind", "cancer_win_streak": "state.g.cancer_alarm.streak", "chemo": "state.g.chemo",
	"current_pid": "state.g.current_pid", "phase": "state.g.phase", "events": "state.g.events", "tune": "state.g.tune",
}
## 协议比快照多出来的（规格 A-1.5）：瞬态 / 派生
const EXTRA_IN_ENVELOPE := ["state.g.asking_pid", "state.g.chain_cell", "state.g.aborted", "state.g.is_over", "state.g.d"]


## 一个字典只许含 required + optional 里的键，且 required 齐全。返回 "" = 合格，否则一句错误（路径 + 键）
static func check(d: Dictionary, required: Array, optional: Array, path: String) -> String:
	for k in d.keys():
		if not (k in required or k in optional):
			return "%s 里有协议外的键「%s」" % [path, str(k)]
	for k in required:
		if not d.has(k):
			return "%s 缺键「%s」" % [path, str(k)]
	return ""


## 按 "a.b.c" 取 envelope 里的值；取不到返回 null（护栏用）
static func dig(e: Dictionary, path: String) -> Variant:
	var cur: Variant = e
	for part in path.split("."):
		if cur is Dictionary and (cur as Dictionary).has(part):
			cur = cur[part]
		else:
			return null
	return cur
