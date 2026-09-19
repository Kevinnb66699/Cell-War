## cw_tutorial_npc.gd —— 新手引导里 NPC 席位的脚本作答（docs/archive/新手引导_实现方案_v1_2026-09-19.md §1.8 / S3 建骨架、S8 接席位）
##
## **S8 起真接到席位上**：第五关 Step2 一关就有 8 个非人类席位（五种免疫各一 + 三只癌），
## 不给它们装 decider 的话，任何一次问到它们头上的询问都会落进界面桥 ——
## 而界面桥对非人类席位是「转给 AI」（`ui_bridge.gd:190-196`），教程局里等于让 AI 替摆拍的 NPC
## 走一步（PRD 通用规则 11：生成的细胞都是 npc、**无 ai 控制**）。
## 装上之后这几席根本不产 `ask` 条目（`cw_kernel_inproc.gd:399-400`），演出也不会多出一拍。
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


## 语义键 → 这一问的下标。找不到（脚本写歪了 / 局面变了）返回 **-1**，
## 由调用方落第三级兜底（下标 0）—— 这里不自己落，是为了让「没命中」看得见（护栏要它）
static func index_of(ask_view: Dictionary, key: String) -> int:
	if key == "":
		return -1
	var opts: Array = ask_view.get("options", [])
	for i in opts.size():
		if CWSemKey.key(ask_view, (opts[i] as Dictionary).get("data", {})) == key:
			return i
	return -1


## Adapter A（InProc，方案 §1.8）：一席一只，挂在 `cfg["deciders"][seat]` 上。
##
## 它**只**做三件事：拿一份镜像、问 `decide()` 要一个语义键、把键换回下标。
## 规则判断一行都不在这儿 —— 那是 `decide()` 的事，而 `decide()` 只读镜像
## （护栏扫的「零 `game.`」扫的是整个文件，包含这只 adapter）。
##
## `mirror_of` 是取「此刻那一份镜像」的一条线（`CWMatch` 给自己的 `mirror`）。
## **不存镜像、只存取法**：教程一关之内会换好几次局（`reload_world` / 切换种类），
## 存下来的那一份换局就过期了，而过期镜像会让 `approach` 朝着一只早就不在那儿的细胞走。
class Decider extends CWBridge:
	## 自引用 preload：内部类够不着外层的静态函数，而这个文件没有 class_name（热更，见文件头）
	const NPC := preload("res://scripts/kernel/cw_tutorial_npc.gd")

	var seat := -1
	## 这一席的脚本（`[{key: …} | {policy: …}]`）。第二章两关都是空表 = 纯兜底；
	## 第七关（S10）才由剧本喂真脚本进来。
	## **叫 `plan` 不叫 `script`**：`script` 是 `Object` 自带的成员，同名会当场编译不过
	var plan: Array = []
	var memo := {}
	var mirror_of: Callable = Callable()

	func ask(req: Dictionary) -> int:
		var m: CWMirror = null
		if mirror_of.is_valid():
			m = mirror_of.call() as CWMirror
		var idx: int = NPC.index_of(req, NPC.decide(req, m, plan, memo))
		return idx if idx >= 0 else 0    ## 第三级兜底：下标 0（基类默认，scripts/core/cw_bridge.gd:17-18）
