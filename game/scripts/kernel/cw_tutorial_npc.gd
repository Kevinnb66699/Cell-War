## cw_tutorial_npc.gd —— 新手引导里 NPC 席位的脚本作答（docs/新手引导_实现方案.md §1.8 / S3 只建骨架）
##
## **本片还不接席位**：第一章两关都不结束回合（方案 §2.3），对手席永远轮不到，所以这里只有
## 纯函数 `decide()` 与它的三级兜底。真正挂上去是第二章（S8）与第七关（S10）的事。
##
## 形制（写死在这里，免得两条路以后打架）：
## - **纯函数**：只看「这一问的选项表」（已经按 `allow` 过滤过的 view）、`CWMirror` 与剧本给的 `script`，
##   返回要选的**语义键**；选不出返回 `""`。**零 `game.`** —— 它不碰引擎，护栏直接扫这个文件。
## - **两个 adapter 共用它**：
##   · A（InProc，今天）：一只 `CWBridge` 子类，`ask(req)` 里用 `CWSemKey.key(req, data)` 逐条算键、
##     返回匹配的下标。接线 = `cfg["decider"] = ui_bridge`（所有席位）后再
##     `cfg["deciders"] = {2: npc, …}` 逐席覆盖（`cw_kernel_inproc.gd:70-74` 的 `deciders.merge(…, true)`）。
##   · B（流式，sidecar 那天）：`queue.on_ask` 里对 `entry.req.options[].key` 做同样的匹配，
##     再 `kernel.answer(ask_id, {"key": k})`。同一个 `decide()`，换一层壳。
##   形制事实：**InProc 下有 decider 的席位不产 `ask` 条目**（`cw_kernel_inproc.gd:399-400`），
##   两条 adapter 天然互斥、不会打架。
##
## **兜底定死三级**（不这么定的话，一个没写到的席位会在 E 阶段里按下标 0 自己走一步，把摆拍演出走歪）：
##   ① 选项里 `data.stop` / `data.skip` 的第一条（判法同 `cw_obs_codec.gd:298-300`）；
##   ② 顶层 action 问（这一层没有 stop 选项）⇒ 选 `act=end`「结束回合」= 什么都不做；
##   ③ 都没有才回落下标 0（基类默认，`scripts/core/cw_bridge.gd:17-18`）—— 由调用方在拿到 `""` 时自己落。
##
## 不带 `class_name`、调用方 `preload`（同 `cw_tutorial_stage.gd`）。
extends RefCounted

## 剧本里认得的小策略（直给语义键之外的第二种写法）。
## PRD:453「向任意靠近癌细胞的方向移动一格，如果已经邻接就发动攻击」正好是前两条。
const POLICIES := ["approach", "attack_if_adjacent", "end_turn", "pass"]


## 这一问该答哪个语义键；选不出返回 ""。
##
## `ask_view` 是**过滤后**的那一问（`{kind, pid, options:[{label, data}…]}`）；
## `script` 是这一席剩下的脚本条目（`[{key: "k=action|…"} | {policy: "approach", …}, …]`），
## `memo` 是跨问的小账本（走到脚本第几条了）—— 调用方自己持有，纯函数不留状态。
static func decide(ask_view: Dictionary, mirror: CWMirror, script: Array, memo: Dictionary) -> String:
	var i := int(memo.get("at", 0))
	if i < script.size():
		var row: Dictionary = script[i]
		var key := str(row.get("key", ""))
		if key != "":
			memo["at"] = i + 1
			return key
		var policy := str(row.get("policy", ""))
		if policy in POLICIES:
			memo["at"] = i + 1
			return _by_policy(policy, ask_view, mirror, row)
	return fallback(ask_view)


## 三级兜底的前两级（第三级「下标 0」由调用方在拿到 "" 时自己落）
static func fallback(ask_view: Dictionary) -> String:
	var opts: Array = ask_view.get("options", [])
	for opt in opts:
		var d: Dictionary = (opt as Dictionary).get("data", {})
		if bool(d.get("stop", false)) or bool(d.get("skip", false)):
			return CWSemKey.key(ask_view, d)
	if str(ask_view.get("kind", "")) == "action":
		for opt in opts:
			var d: Dictionary = (opt as Dictionary).get("data", {})
			if str(d.get("act", "")) == "end":
				return CWSemKey.key(ask_view, d)
	return ""


## 小策略：在这一问的选项里现算目标，再拼成语义键。**只读 `CWMirror`**，不碰引擎
static func _by_policy(policy: String, ask_view: Dictionary, mirror: CWMirror, row: Dictionary) -> String:
	match policy:
		"end_turn":
			return _first_act(ask_view, "end")
		"pass":
			return fallback(ask_view)
		"attack_if_adjacent":
			return _toward(ask_view, mirror, int(row.get("target_seat", -1)), true)
		"approach":
			var hit := _toward(ask_view, mirror, int(row.get("target_seat", -1)), true)
			return hit if hit != "" else _toward(ask_view, mirror, int(row.get("target_seat", -1)), false)
	return ""


static func _first_act(ask_view: Dictionary, act: String) -> String:
	for opt in ask_view.get("options", []):
		var d: Dictionary = (opt as Dictionary).get("data", {})
		if str(d.get("act", "")) == act:
			return CWSemKey.key(ask_view, d)
	return ""


## 朝 `target_seat` 那只细胞挪 / 打：`adjacent_only` 为真时只认「落点上站着目标」那一条（= 攻击）。
## 选项表里攻击就是迁移（`act=move` 落到有敌方细胞的格），所以两件事同一支
static func _toward(ask_view: Dictionary, mirror: CWMirror, target_seat: int, adjacent_only: bool) -> String:
	if mirror == null or target_seat < 0 or target_seat >= mirror.players.size():
		return ""
	var goal: Dictionary = mirror.cell_of(target_seat)
	if goal.is_empty() or not bool(goal.get("alive", false)):
		return ""
	var best := ""
	var best_d := 1 << 30
	for opt in ask_view.get("options", []):
		var d: Dictionary = (opt as Dictionary).get("data", {})
		if str(d.get("act", "")) != "move" or not d.has("to"):
			continue
		var to: Vector2i = d["to"]
		if to == goal["pos"]:
			return CWSemKey.key(ask_view, d)
		if adjacent_only:
			continue
		var dist := CWData.hex_dist(to, goal["pos"])
		if dist < best_d:
			best_d = dist
			best = CWSemKey.key(ask_view, d)
	return best
