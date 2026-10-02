## tools/acceptance/steps_local.gd —— 本机那几项：unpack / hotseat / solo_normal / solo_intent / solo_search / spectate / save_continue
##
## 对局一律从真 Main.tscn 的主菜单入口开（菜单发 start_requested → main.gd:_begin，镜头推进、绽开都照演），
## 回主菜单走暂停菜单「返回主菜单」→「确定」。作答只碰界面桥（同 headless_test.gd 那几支入口冒烟）。
## 种子沿用那几支测试的（热座 77、单机 91）：打到第 3 世界回合之前不会有人赢，换种子要先确认这一点
extends "step_base.gd"

const HOTSEAT_SEED := 77
const SOLO_SEED := 91
## 单机三档开 4 人局：AI 两边都要打（一只免疫队友 + 两只癌），2 人局里 AI 只坐癌那一席
const SOLO_PLAYERS := 4
const SPECTATE_SEED := 4242


## sidecar 从包里解出来、起得来：清掉 user://sidecar → locate() 现解 → 解出来的 dotnet 跑 `--version` 与 `--selftest`。
## 导出包里另核三件：解到的确实是用户目录里那一份（不是环境变量 / 本机装的 dotnet）、是这次现解的、
## `--version` 读回的 core_build 与包里 payload.json 记的同一个（同 tools/patch_sidecar_probe.gd 的口径）
func step_unpack(ctx: Dictionary) -> String:
	var Loc = load("res://scripts/kernel/cw_sidecar_locator.gd")
	var template := OS.has_feature("template")
	ctx["notes"].append("rid %s" % Loc.host_rid())
	if template and OS.get_environment("CW_SIDECAR_DLL") != "":
		return "环境变量 CW_SIDECAR_DLL=%s 盖过了包里那一份 —— 先清掉再验" % OS.get_environment("CW_SIDECAR_DLL")
	Loc._rm_rf(Loc.USER_DIR)
	if DirAccess.dir_exists_absolute(Loc.USER_DIR):
		return "删不掉上一次解出来的 %s（有进程还攥着它？）" % ProjectSettings.globalize_path(Loc.USER_DIR)
	var t0 := Time.get_ticks_msec()
	var loc: Dictionary = CWKernelSidecar.locate()
	var ms := Time.get_ticks_msec() - t0
	if loc.has("error"):
		return "定位 / 解包失败：%s" % String(loc["error"])
	var dotnet := String(loc["dotnet"])
	var dll := String(loc["dll"])
	if template:
		var root := ProjectSettings.globalize_path(Loc.USER_DIR)
		if not dotnet.begins_with(root) or not dll.begins_with(root):
			return "定位到的不是从包里解到 %s 的那一份：dotnet=%s，dll=%s" % [root, dotnet, dll]
		ctx["notes"].append("从 pck 解到 %s 用了 %d ms" % [root, ms])
	else:
		ctx["notes"].append("编辑器里跑：用开发产物 %s（没有解包这一步）" % dll)
	var ver: Dictionary = await run_bounded(ctx, dotnet, ["exec", dll, "--version"], 30000)
	var info := _json_line(String(ver["out"]))
	if int(ver["code"]) != 0 or info.is_empty():
		return "`--version` 没跑通（退出码 %d%s）：%s" % [int(ver["code"]), "，超时" if bool(ver["timed_out"]) else "",
			String(ver["out"]).strip_edges().right(300)]
	var core_build := String(info.get("core_build", ""))
	ctx["notes"].append("core_build %s · rules_build %s" % [core_build, String(info.get("rules_build", ""))])
	if template:
		var packed = JSON.parse_string(FileAccess.get_file_as_string(Loc.PACK_DIR + "/payload.json"))
		var want := String(packed.get("core_build", "")) if packed is Dictionary else ""
		if core_build != want:
			return "解出来的规则 dll 读回 core_build「%s」，包里 payload.json 记的是「%s」" % [core_build, want]
	var st: Dictionary = await run_bounded(ctx, dotnet, ["exec", dll, "--selftest"], 90000)
	var sti := _json_line(String(st["out"]))
	if int(st["code"]) != 0 or not bool(sti.get("ok", false)):
		return "`--selftest` 没过（退出码 %d%s）：%s" % [int(st["code"]), "，超时" if bool(st["timed_out"]) else "",
			String(st["out"]).strip_edges().right(300)]
	ctx["notes"].append("自检一小局 %d 问 / %d 条" % [int(sti.get("answers", 0)), int(sti.get("entries", 0))])
	return ""


## 输出里第一行 JSON 对象（sidecar 的 `--version` / `--selftest` 各打一行）；没有给空字典
static func _json_line(text: String) -> Dictionary:
	for line in text.split("\n"):
		if line.strip_edges().begins_with("{"):
			var v = JSON.parse_string(line)
			if v is Dictionary:
				return v
	return {}


## 两人全真人（本地多人 = 热座）：换手遮罩点掉、各席轮流作答，打到第 3 世界回合
func step_hotseat(ctx: Dictionary) -> String:
	var main_scene := await open_main(ctx)
	var m = main_scene.match_node
	begin_match(main_scene, 2, CWConfigPanel.HOTSEAT, CWMatch.AI_NORMAL, HOTSEAT_SEED, [true, true])
	if not await wait_entered(ctx, main_scene):
		return "开局过场没走完 / 对局没开起来"
	var why := expect_sidecar(m)
	if why != "":
		return why
	if not m.bridge.hotseat or m.human_players != [0, 1]:
		return "没走到热座分叉（hotseat=%s，真人席 %s）" % [str(m.bridge.hotseat), str(m.human_players)]
	why = await play_to_round(ctx, m, 3)
	if why != "":
		return why
	return "" if await back_to_menu(ctx, main_scene) else "打完回不到主菜单"


## 一位真人（免疫）带三席 AI，三档各一项：AI 席交给 sidecar 里的 C# AI（match.gd:_sidecar_ai），真人只结束回合
func step_solo_normal(ctx: Dictionary) -> String:
	return await _solo(ctx, CWMatch.AI_NORMAL)


func step_solo_intent(ctx: Dictionary) -> String:
	return await _solo(ctx, CWMatch.AI_INTENT)


func step_solo_search(ctx: Dictionary) -> String:
	return await _solo(ctx, CWMatch.AI_ABS)


func _solo(ctx: Dictionary, level: int) -> String:
	var main_scene := await open_main(ctx)
	var m = main_scene.match_node
	begin_match(main_scene, SOLO_PLAYERS, CWData.Faction.IMMUNE, level, SOLO_SEED)
	if not await wait_entered(ctx, main_scene):
		return "开局过场没走完 / 对局没开起来"
	var why := _expect_ai_seats(ctx, m, level)
	if why != "":
		return why
	why = await play_to_round(ctx, m, 3)
	if why != "":
		return why
	return "" if await back_to_menu(ctx, main_scene) else "打完回不到主菜单"


## sidecar 句柄、AI 一帧推一步（ai_paced），非真人席都交给了这一档对应的 C# AI
func _expect_ai_seats(ctx: Dictionary, m: Node, level: int) -> String:
	var why := expect_sidecar(m)
	if why != "":
		return why
	var tier := String(CWMatch.SIDECAR_AI_TIERS.get(level, ""))
	var seats: Dictionary = m._sidecar_ai()
	if not m._ai_paced or seats.is_empty() or seats.values().any(func(v) -> bool: return String(v) != tier):
		return "AI 席没按「%s」交给 sidecar（ai_paced=%s，席位 %s）" % [tier, str(m._ai_paced), str(seats)]
	ctx["notes"].append("AI 席 %s" % str(seats))
	return ""


## 观战：一个真人都没有（配置面板「我的阵营」= 观战），四席 AI 互搏打到第 3 世界回合
func step_spectate(ctx: Dictionary) -> String:
	var main_scene := await open_main(ctx)
	var m = main_scene.match_node
	begin_match(main_scene, 4, -1, CWMatch.AI_NORMAL, SPECTATE_SEED)
	if not await wait_entered(ctx, main_scene):
		return "开局过场没走完 / 对局没开起来"
	if not m.human_players.is_empty():
		return "观战局里有真人席：%s" % str(m.human_players)
	var why := _expect_ai_seats(ctx, m, CWMatch.AI_NORMAL)
	if why != "":
		return why
	why = await play_to_round(ctx, m, 3)
	if why != "":
		return why
	return "" if await back_to_menu(ctx, main_scene) else "打完回不到主菜单"


## 存档 → 继续：单机对 AI 打到第 2 世界回合真人那一问上，暂停菜单「保存并退出」（main.gd 写 CWSave、返场）；
## 回到主菜单点「继续对局」（main.gd:_continue 读档、按存档里的内核标记开回 sidecar）；
## 核回合与每只细胞的位置 / 能量 / 死活逐个相同，再接着打满一个世界回合
func step_save_continue(ctx: Dictionary) -> String:
	var main_scene := await open_main(ctx)
	var m = main_scene.match_node
	begin_match(main_scene, 2, CWData.Faction.IMMUNE, CWMatch.AI_NORMAL, SOLO_SEED)
	if not await wait_entered(ctx, main_scene):
		return "开局过场没走完 / 对局没开起来"
	var why := expect_sidecar(m)
	if why != "":
		return why
	var at_save := func() -> bool:
		return round_of(m) >= 2 and m.bridge._pending != null and m.bridge.panel._end.visible and m.can_save_now()
	if not await until(ctx, at_save, 150000, func() -> void:
			if not at_save.call():
				play_human(m)):
		return "没打到第 2 世界回合真人行动那一问上（停在第 %d 回合）" % round_of(m)
	var round_before := round_of(m)
	var cells_before := _cells_digest(m)
	if not pause_pick(m.pause_menu, "save_quit"):
		return "暂停菜单里没有「保存并退出」"
	if not await until(ctx, func() -> bool: return not main_scene._entering and m.kernel == null and main_scene.menu.visible, 15000):
		return "「保存并退出」之后没回到主菜单（存档写失败会留在对局里）"
	var data := CWSave.read()
	if data.is_empty() or String((data["snap"] as Dictionary).get("kernel", "")) != CWKernelSidecar.SAVE_KERNEL:
		return "存档没写上，或存的不是 C# 检查点（%s）" % str((data.get("snap", {}) as Dictionary).keys())
	main_scene.menu.continue_requested.emit()
	if not await wait_entered(ctx, main_scene):
		return "「继续对局」没开起来（%s）" % (m.lost_reason() if m.kernel != null else "句柄没建")
	why = expect_sidecar(m)
	if why != "":
		return "读档：" + why
	if round_of(m) != round_before or _cells_digest(m) != cells_before:
		return "读回来的局面与存档那一刻不同：第 %d → %d 回合，细胞 %s → %s" % [round_before, round_of(m), cells_before, _cells_digest(m)]
	ctx["notes"].append("第 %d 世界回合存档、读回来回合与细胞逐个相同" % round_before)
	why = await play_to_round(ctx, m, round_before + 1)
	if why != "":
		return "读档之后：" + why
	return "" if await back_to_menu(ctx, main_scene) else "打完回不到主菜单"


## 每只细胞的 [位置, 能量, 死活]（同 t_entry_smoke_sidecar 比读档前后的那一串）
static func _cells_digest(m: Node) -> String:
	if m.mirror == null:
		return ""
	return str(m.mirror.cells.map(func(c): return [c["pos"], c["energy"], c["alive"]]))
