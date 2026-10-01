## tools/export_check_sidecar.gd —— 导出包里验 C# sidecar（换内核 P7，发版前 / 改了打包脚本后跑一次）：
## 定位（首次把 pck 里的 .NET 运行时与载荷解到用户目录）→ 起进程 → 一路答下标 0 打到终局。
##   <导出的可执行文件> --headless --script <本文件的绝对路径>
## 最后一行 RESULT state=4（ENDED）才算过；PATH 里不该有 dotnet（要验的就是包里那份运行时）。
extends SceneTree
func _initialize() -> void:
	_run.call_deferred()
func _run() -> void:
	var Loc = load("res://scripts/kernel/cw_sidecar_locator.gd")
	print("template=", OS.has_feature("template"), " rid=", Loc.host_rid())
	var t0 := Time.get_ticks_msec()
	var loc: Dictionary = Loc.locate()
	print("locate ", Time.get_ticks_msec() - t0, " ms: ", loc)
	var t1 := Time.get_ticks_msec()
	var loc2: Dictionary = Loc.locate()
	print("locate again ", Time.get_ticks_msec() - t1, " ms")
	var k := CWKernelSidecar.new()
	var ok := k.open({ "factions": [0, 1], "seed": 3, "observe_viewer": -2 })
	print("open ok=", ok, " err=", k.last_error(), " pid=", k.process_id())
	var since := 0
	var answers := 0
	while answers < 600 and k.state() != CWKernel.State.ENDED and k.state() != CWKernel.State.FAULTED:
		for e in k.pull(-2, since, 1000):
			since = int(e["seq"])
			if e["t"] == "ask":
				k.answer(int(e["ask_id"]), { "index": 0 })
				answers += 1
		await process_frame
	print("RESULT state=", k.state(), " answers=", answers, " entries=", since, " winner=", k.winner)
	k.close()
	CWKernelSidecar.shutdown_idle_links()
	quit()
