## tools/acceptance/step_base.gd —— 验收各项共用的驱动手段（等帧、开 / 收主场景、真人那一席怎么点、暂停菜单怎么选、限时跑外部进程）
##
## 三个步骤文件（steps_local / step_tutorial / steps_net）都 `extends` 它。不加 class_name：
## 这几个文件不在工程里（导出包的全局类表里没有它们），按路径继承、按路径 load。
##
## 每一项的 ctx（acceptance.gd 建）：
##   deadline  —— 这一项的截止时刻（毫秒）。所有等待都看它：到点就当作没等到，函数照常返回 ——
##                协程没法从外面杀掉，只能自己按时收手（acceptance.gd 那边另有一道兜底）
##   cancelled —— 驱动那边已经判了超时：还活着的循环见到它就收手
##   notes     —— 通过 / 失败那一行后面跟的说明（回合数、用时、core_build…）
##   main / clients —— 这一项建的主场景与联机客户端，跑完由驱动统一收掉（失败、超时也收）
extends RefCounted

const MAIN_SCENE := "res://scenes/Main.tscn"

var t: SceneTree   ## 验收驱动本体（acceptance.gd）：等帧、挂节点都经它
var server := ""   ## 命令行的 server=（联机两项用；本机几项不看）


## 一帧一帧等到 `cond` 成立；`each` 每帧先调一次（真人作答之类）。没等到（超时 / 这一项到点 / 被取消）返回 false
func until(ctx: Dictionary, cond: Callable, ms: int, each := Callable()) -> bool:
	var stop := mini(Time.get_ticks_msec() + ms, int(ctx["deadline"]))
	while true:
		if each.is_valid():
			each.call()
		if cond.call():
			return true
		if Time.get_ticks_msec() > stop or bool(ctx["cancelled"]):
			return false
		await t.process_frame
	return false


## 实例化真 Main.tscn 挂到树上（与玩家开游戏进的是同一个场景；Boot.tscn 只是挂补丁的启动器，这里不挂补丁）
func open_main(ctx: Dictionary, before_ready := Callable()) -> Node:
	var main_scene: Node = load(MAIN_SCENE).instantiate()
	if before_ready.is_valid():
		before_ready.call(main_scene)   ## 有的开关要在 _ready 之前拨（网页单机的 solo_via_server）
	t.root.add_child(main_scene)
	ctx["main"] = main_scene
	await t.process_frame
	return main_scene


## 主菜单「开始对局」：配置面板交出来的就是这份 cfg（CWConfigPanel.config()），菜单发 start_requested、main.gd:_begin 接
func begin_match(main_scene: Node, players: int, faction: int, ai: int, seed_value: int, seats: Array = []) -> void:
	main_scene.menu.start_requested.emit({ "players": players, "faction": faction, "ai": ai, "seed": seed_value,
		"cancer_types": [], "seats": seats })


## 进场过场走完、对局开起来了（镜头推进 + 绽开 = main.gd 的 `_entering` 放开，镜像到了）
func wait_entered(ctx: Dictionary, main_scene: Node, ms := 20000) -> bool:
	var m = main_scene.match_node
	return await until(ctx, func() -> bool: return not main_scene._entering and m.kernel != null and m.mirror != null, ms)


## 真人那一席这一帧点什么（同 headless_test 里那几支入口冒烟的作答，多一条兜底）：
## 热座换手遮罩先点掉；行动那一问按「结束回合」；有可选格（落子 / 复活）点第一格；
## 剩下只有按钮的那种（`_ask_generic`）点第一个选项
func play_human(m: Node) -> void:
	var b = m.bridge
	if b == null:
		return
	if b.handoff != null and b.handoff.active:
		b.handoff.confirm()
		return
	if b._pending == null:
		return
	if b.panel != null and b.panel._end.visible:
		b.panel.end_turn_pressed.emit()
	elif not b._tiles.is_empty():
		b._pending.fire(b._tiles.values()[0])
	else:
		b._pending.fire(0)


## 镜像上的世界回合（还没有镜像给 -1）
func round_of(m: Node) -> int:
	return int(m.mirror.round_no) if m != null and m.mirror != null else -1


## 真人那几席照 `play_human` 点、AI 席自己打，一直打到第 `target` 世界回合。到了返回 ""，否则返回为什么没到。
## 句柄中途换了 / 没了 / 坏了 / 这一局提前打完，都当场停下来报（不白等到超时）
func play_to_round(ctx: Dictionary, m: Node, target: int, ms := 150000) -> String:
	var k0 = m.kernel
	var t0 := Time.get_ticks_msec()
	var broke := func() -> bool:
		return m.kernel != k0 or m.kernel == null or m.kernel.state() in [CWKernel.State.FAULTED, CWKernel.State.ENDED, CWKernel.State.UNAVAILABLE]
	var ok := await until(ctx, func() -> bool: return round_of(m) >= target or broke.call(), ms, func() -> void: play_human(m))
	if ok and round_of(m) >= target:
		ctx["notes"].append("第 %d 世界回合（%.1f s）" % [round_of(m), (Time.get_ticks_msec() - t0) / 1000.0])
		return ""
	if m.kernel == null or m.kernel != k0:
		return "打到第 %d 回合时句柄换了 / 没了（现在是 %s）" % [round_of(m), _kernel_name(m.kernel)]
	if m.kernel.state() == CWKernel.State.ENDED:
		return "对局在第 %d 回合就打完了，没到第 %d 回合（换个种子？）" % [round_of(m), target]
	if m.kernel.state() != CWKernel.State.READY and m.kernel.state() != CWKernel.State.AWAITING:
		return "句柄在第 %d 回合坏了：状态 %d，%s" % [round_of(m), m.kernel.state(), str(m.kernel.last_error())]
	return "%.0f s 内没打到第 %d 回合（停在第 %d 回合；真人那一问挂着：%s）" % [(Time.get_ticks_msec() - t0) / 1000.0, target,
		round_of(m), str(m.bridge != null and m.bridge._pending != null)]


## 这一局的句柄是不是新内核（C# sidecar）、而且活着；是返回 ""。新开局 sidecar 起不来会**静默**退回 GD 内核（match.gd:start），
## 所以每一项开局后都要亲眼核一次
func expect_sidecar(m: Node) -> String:
	if not (m.kernel is CWKernelSidecar):
		return "句柄不是 CWKernelSidecar 而是 %s —— sidecar 没起来、退回了 GD 内核（start_failure=%s）" % [_kernel_name(m.kernel),
			str(CWKernelSidecar.start_failure)]
	if m.kernel.state() in [CWKernel.State.FAULTED, CWKernel.State.UNAVAILABLE]:
		return "sidecar 句柄状态 %d：%s" % [m.kernel.state(), str(m.kernel.last_error())]
	return ""


static func _kernel_name(k: Object) -> String:
	if k == null:
		return "null"
	if k is CWKernelSidecar:
		return "CWKernelSidecar"
	if k is CWKernelInProc:
		return "CWKernelInProc"
	if k is CWKernelRemote:
		return "CWKernelRemote"
	return k.get_class()


## 暂停菜单里选一项，要确认的再点「确定」—— 与玩家按 Esc 再点那一项走同一段 `_activate`（亮灭、确认页、发 chose 都在里头）
func pause_pick(pause: Node, id: String) -> bool:
	pause.open()
	var i := _item_index(pause, id)
	if i < 0:
		pause.close()
		return false
	pause._activate(i)
	if String(pause._confirming) == id:
		pause._activate(_item_index(pause, "yes"))
	return true


func _item_index(pause: Node, id: String) -> int:
	for i in (pause._list as Array).size():
		if String(pause._list[i]["id"]) == id:
			return i
	return -1


## 从对局回主菜单：暂停菜单「返回主菜单」→ 确定（main.gd:_on_pause_chose 演返场、拆局、菜单淡回来）
func back_to_menu(ctx: Dictionary, main_scene: Node) -> bool:
	var m = main_scene.match_node
	if m.kernel == null and not main_scene._entering:
		return true
	if not pause_pick(m.pause_menu, "menu"):
		return false
	return await until(ctx, func() -> bool: return not main_scene._entering and m.kernel == null and main_scene.menu.visible, 15000)


## 限时跑一个外部进程，收齐 stdout + stderr：`{code, out, timed_out}`。
## 不用 OS.execute：它一直堵到进程退出，sidecar 自检要是卡住，后面每一项都跟着卡死。
## 非阻塞管道 + 每帧读一次，到点就 kill
func run_bounded(ctx: Dictionary, path: String, args: Array, ms: int) -> Dictionary:
	var p: Dictionary = OS.execute_with_pipe(path, PackedStringArray(args), false)
	if p.is_empty():
		return { "code": -1, "out": "进程起不来：%s" % path, "timed_out": false }
	var pid := int(p["pid"])
	var io: FileAccess = p["stdio"]
	var err: FileAccess = p["stderr"]
	var buf := PackedByteArray()
	var stop := mini(Time.get_ticks_msec() + ms, int(ctx["deadline"]))
	while OS.is_process_running(pid):
		buf.append_array(_drain(io))
		buf.append_array(_drain(err))
		if Time.get_ticks_msec() > stop or bool(ctx["cancelled"]):
			OS.kill(pid)
			return { "code": -1, "out": buf.get_string_from_utf8(), "timed_out": true }
		await t.process_frame
	buf.append_array(_drain(io))
	buf.append_array(_drain(err))
	return { "code": OS.get_process_exit_code(pid), "out": buf.get_string_from_utf8(), "timed_out": false }


## 管道里此刻有多少读多少（非阻塞：没有就是空）
static func _drain(f: FileAccess) -> PackedByteArray:
	var out := PackedByteArray()
	if f == null:
		return out
	while true:
		var chunk := f.get_buffer(4096)
		out.append_array(chunk)
		if chunk.size() < 4096:
			break
	return out
