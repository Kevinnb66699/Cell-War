## tools/acceptance/step_tutorial.gd —— 新手教程整套走一遍：七段（c1_l1 … c2_l5、间章、c3_l6）在 C# 内核上一口气打到「全部通关」回主菜单
##
## 入口是主菜单「新手引导」（菜单发 tutorial_requested → main.gd:_begin_tutorial）：用户目录是新清的，
## 所以开场动画照演一遍（约 11 s，演完自己收）、进度从第一关起。打完由 match.gd 发 tutorial_done、main.gd 返场。
##
## 作答逻辑**抄自** game/tests/headless_test.gd（导出包里没有 res://tests，只能抄，不能 load）：
##   · 第一关 → 间章：`_tutor_key_chain` / `_tutor_key_pick` / `_tutor_key_hunt` / `TUTOR_KEY_ROUTES` —— 按语义键作答，
##     t_tutor_sidecar_chain_c1c2 / t_tutor_sidecar_chain_c2l5 两支在 C# 内核上跑的就是它；
##   · 第六关：`_tutor_think_answer`（闸放行的第一条，view 下标 0）—— t_tutor_sidecar_c3_drive 的作答。
##   两边都按「同一问在界面上挂满几帧才答」（`_thought`），理由见那个函数。那边改了作答口径，这里跟着抄一遍。
## 「继续」亮着就点（真机是玩家点）。
extends "step_base.gd"

const LEVELS := ["c1_l1", "c1_l2", "c1_l3", "c2_l4", "c2_l5", "interlude", "c3_l6"]
## 剧本只写了前缀的那几行要走的格（「关:游标」→ 依次要命中的键前缀）。抄自 headless_test.gd 的 TUTOR_KEY_ROUTES：
## 第三关 Step1 是最省路（走歪了 6.6 能量不够）；第四关是净化 10 格那条；第五关 Step1 分化成 B 细胞
const KEY_ROUTES := {
	"c1_l2:6": ["k=action|act=move|to=-3,-1", "k=action|act=move|to=-2,-1", "k=action|act=move|to=-1,-1"],
	"c1_l3:3": ["k=action|act=move|to=1,-1", "k=action|act=move|to=2,-1", "k=action|act=move|to=3,-1", "k=action|act=move|to=4,-1"],
	"c2_l4:8": ["k=action|act=move|to=4,0", "k=action|act=move|to=5,0", "k=action|act=move|to=6,0", "k=action|act=move|to=6,-1",
		"k=action|act=move|to=6,-2", "k=action|act=move|to=6,-3", "k=action|act=move|to=5,-3", "k=action|act=move|to=5,-2",
		"k=action|act=move|to=4,-2", "k=action|act=move|to=4,-3", "k=action|act=move|to=4,-4", "k=action|act=move|to=3,-4",
		"k=action|act=move|to=3,-5", "k=action|act=move|to=2,-5"],
	"c2_l5:4": ["k=action|act=differentiate|type=1"],
}
## 自由游玩的那几行（第五关 Step2）：剧本不点名格子，要自己把癌细胞清干净
const KEY_HUNT := ["c2_l5:9"]
## 第六关按「闸放行的第一条」答（t_tutor_sidecar_c3_drive 的口径），不走键路线
const INDEX0_LEVEL := "c3_l6"
const THINK_FRAMES := 4
## 既没翻页也没作答这么久 = 卡住了（测试那边是 20 s；Windows ARM 上模拟跑，放宽一些）
const STUCK_MS := 40000


func step_tutorial(ctx: Dictionary) -> String:
	CWGuideProgress.clear()   ## 用户目录是新清的，这两句只为同一次运行里重跑这一项
	CWTutorLayers.reset()
	var main_scene := await open_main(ctx)
	var m = main_scene.match_node
	var done := [0]   ## lambda 抓局部变量按值抓，计数放容器里
	m.tutorial_done.connect(func() -> void: done[0] += 1)
	main_scene.menu.tutorial_requested.emit(0)
	var r: Dictionary = await _drive(ctx, main_scene, done)
	ctx["notes"].append("经过 %s，作答 %d 次" % [" → ".join(PackedStringArray(r["levels"])), int(r["answers"])])
	if String(r["stuck"]) != "":
		return String(r["stuck"])
	if r["levels"] != LEVELS:
		return "七段没按次序走完：实际 %s" % str(r["levels"])
	if int(r["not_sidecar"]) > 0:
		return "有 %d 帧句柄不是 CWKernelSidecar（第一次在 %s）—— 教程舞台换盘时退回了 GD 内核" % [int(r["not_sidecar"]), String(r["first_not_sidecar"])]
	if done[0] != 1 or not CWGuideProgress.all_done():
		return "通关信号 / 进度不对：tutorial_done 发了 %d 次，进度 done=%d/%d" % [done[0], CWGuideProgress.done_count(), CWGuideProgress.level_count()]
	return ""


## 一路作答到通关返场（tutorial_done 发了、对局拆了、主菜单回来了）。返回 { levels, answers, not_sidecar, first_not_sidecar, stuck }
func _drive(ctx: Dictionary, main_scene: Node, done: Array) -> Dictionary:
	var m = main_scene.match_node
	var out := { "levels": [], "answers": 0, "not_sidecar": 0, "first_not_sidecar": "", "stuck": "" }
	var routes_at := {}
	var think := { "held": null, "frames": 0 }
	var last_sig := ""
	var since := Time.get_ticks_msec()
	while true:
		await t.process_frame
		if Time.get_ticks_msec() > int(ctx["deadline"]) or bool(ctx["cancelled"]):
			out["stuck"] = "超时：停在 %s" % _where(m)
			break
		if done[0] > 0 and m.kernel == null and not main_scene._entering and main_scene.menu.visible:
			break   ## 通关横幅停完、返场走完
		var dd = m._director
		if dd == null or m.kernel == null:
			continue
		var lid := str(m._tutor_level.get("id", ""))
		if (out["levels"] as Array).is_empty() or (out["levels"] as Array).back() != lid:
			(out["levels"] as Array).append(lid)
		if not (m.kernel is CWKernelSidecar):
			out["not_sidecar"] += 1
			if String(out["first_not_sidecar"]) == "":
				out["first_not_sidecar"] = "%s（%s）" % [lid, _kernel_name(m.kernel)]
		if m._tutor_view is CWTutorViewBubble and m._tutor_view._next_armed():
			m._tutor_view.advance()
		## 卡住：游标与钩子深度都不动、也没作答。最后一关剧本走完之后在等通关横幅（5 s），不算
		var sig := "%s|%d|%d" % [lid, int(dd._at), int(dd._hook_depth)]
		var finished: bool = lid == LEVELS.back() and not dd.active and int(dd._at) >= (m._tutor_level.get("flow", []) as Array).size()
		if sig != last_sig or finished:
			last_sig = sig
			since = Time.get_ticks_msec()
		elif Time.get_ticks_msec() - since > STUCK_MS:
			out["stuck"] = "卡住了 %d s（没翻页也没作答）：%s" % [STUCK_MS / 1000, _where(m)]
			break
		if not _thought(m, think):
			continue
		var asking: Dictionary = m.kernel._open_ask
		if asking.is_empty():
			continue
		var j := _choose(m, dd, asking["req"], routes_at, lid)
		if j < 0:
			continue
		out["answers"] += 1
		since = Time.get_ticks_msec()
		m.bridge._pending.fire(j)
		for _i in 2:
			await t.process_frame
	return out


## 这一问交 view 里第几条（view = 闸放行的那几条在 req 里的下标）。第六关取第一条；别的关按键挑（三级挑法见 `_pick_key`）
func _choose(m: Node, dd, req: Dictionary, routes_at: Dictionary, lid: String) -> int:
	if lid == INDEX0_LEVEL:
		return 0
	var gate = m.bridge
	var view: Array = range((req["options"] as Array).size()) if gate.allow() == null else gate._keep(req)
	var key := _pick_key(m, dd, req, view, routes_at)
	for n in view.size():
		if CWSemKey.key(req, req["options"][view[n]]["data"]) == key:
			return n
	return -1


## 闸桥那一问在界面上挂满 THINK_FRAMES 帧了吗（抄 `_tutor_thought`）。**为什么要等**：导演的谓词与钩子逐帧推进，
## 下一问可能在上一步演出播完的那一帧就到了 —— 闸那一刻还停在上一条。C# 内核不等动画，当帧就答会抢在导演翻页之前多走一步
func _thought(m: Node, think: Dictionary) -> bool:
	var gate = m.bridge
	if gate == null or not gate._prompting or gate._pending == null:
		think["held"] = null
		return false
	if gate._pending != think["held"]:
		think["held"] = gate._pending
		think["frames"] = 0
	think["frames"] = int(think["frames"]) + 1
	return int(think["frames"]) >= THINK_FRAMES


## 挑哪个键（抄 `_tutor_key_pick`）：① 这一行在 KEY_ROUTES 里有路线就走路线的下一格；② 第五关自由游玩：打相邻的癌细胞、
## 没有就朝最近那只走一格；③ 其余按剧本 `allow` 的次序，取第一条命中的（同一前缀命中多条取键最小的 —— 不依赖内核的枚举序）
func _pick_key(m: Node, dd, req: Dictionary, view: Array, routes_at: Dictionary) -> String:
	var keys: Array = []
	for i in view:
		keys.append(CWSemKey.key(req, req["options"][i]["data"]))
	var in_hook := int(dd._hook_depth) > 0 and dd._beat_row is Dictionary
	var row: Dictionary = dd._beat_row if in_hook else dd._row()
	var rid := "%s:%d" % [str(m._tutor_level.get("id", "")), int(dd._at)]
	if not in_hook and KEY_ROUTES.has(rid):
		var route: Array = KEY_ROUTES[rid]
		var at := int(routes_at.get(rid, 0))
		if at < route.size():
			var hit := _key_min(keys, str(route[at]))
			if hit != "":
				routes_at[rid] = at + 1
				return hit
	if not in_hook and rid in KEY_HUNT:
		var hunt := _key_hunt(m, req, view)
		if hunt != "":
			return hunt
	for a in row.get("allow", []):
		var hit := _key_min(keys, str(a))
		if hit != "":
			return hit
	return _key_min(keys, "")


## 以 `prefix` 开头的键里取字典序最小的一条；一条都没有给 ""
static func _key_min(keys: Array, prefix: String) -> String:
	var best := ""
	for k in keys:
		var s := str(k)
		if s.begins_with(prefix) and (best == "" or s < best):
			best = s
	return best


## 自由游玩（抄 `_tutor_key_hunt`）：相邻有癌细胞就打（攻击 = 迁进它那一格），否则朝最近那只癌细胞走一格（同距取键最小的）
func _key_hunt(m: Node, req: Dictionary, view: Array) -> String:
	if m.mirror == null:
		return ""
	var me: Dictionary = m.mirror.cell_of(int(req.get("pid", 0)))
	var foes: Array = m.mirror.living_cells(CWData.Faction.CANCER)
	if foes.is_empty():
		return ""
	var goal: Vector2i = (foes[0] as Dictionary)["pos"]
	for f in foes:
		if CWData.hex_dist((f as Dictionary)["pos"], me["pos"]) < CWData.hex_dist(goal, me["pos"]):
			goal = (f as Dictionary)["pos"]
	var best := ""
	var best_d := 1 << 30
	for i in view:
		var data: Dictionary = req["options"][i]["data"]
		if str(data.get("act", "")) != "move" or not data.has("to"):
			continue
		var k := CWSemKey.key(req, data)
		var d := CWData.hex_dist(data["to"], goal)
		if d < best_d or (d == best_d and k < best):
			best_d = d
			best = k
	return best


## 卡住 / 超时时报这一刻在哪儿：关、游标、剧本那一行、句柄在问谁、闸（放行 / 遮挡）、播放队列追没追上
func _where(m: Node) -> String:
	var dd = m._director
	if dd == null:
		return "导演不在（关 %s，句柄 %s）" % [str(m._tutor_level.get("id", "")), _kernel_name(m.kernel)]
	var gate = m.bridge
	var asking: Dictionary = m.kernel._open_ask if m.kernel != null else {}
	var req: Dictionary = asking.get("req", {})
	return "关 %s 游标 %d 钩子 %d：row=%s；句柄在问 %s（席 %s · %s）；界面在问 %s；闸 %s%s；队列 %s/%s；句柄 %s；第 %d 回合" % [
		str(m._tutor_level.get("id", "")), int(dd._at), int(dd._hook_depth), str(dd._row()).substr(0, 160),
		str(not asking.is_empty()), str(req.get("pid", "-")), str(req.get("kind", "-")),
		str(gate != null and gate._prompting and gate._pending != null),
		str(gate.allow()).substr(0, 80) if gate != null else "-", "（遮挡中）" if gate != null and gate.blocked else "",
		str(m.queue.since) if m.queue != null else "-", str(m.kernel.entry_seq()) if m.kernel != null else "-",
		_kernel_name(m.kernel), round_of(m)]
