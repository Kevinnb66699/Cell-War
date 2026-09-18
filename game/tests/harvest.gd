## harvest.gd —— 把一个既有的无头测试函数跑一遍，收割成 cwxcase/2 草稿（测试迁移规格 A-4 收割入口 / C-1 步 13）
##
##   Godot_v4.5-stable_win64_console.exe --headless --path game --script res://tests/harvest.gd -- fn=t_pressure out=D:/path/draft.json
##
## 产物是**草稿**，`expect.changed` 是 dump 前后的整份差分，**不自动进仓库**：
## 人要过一遍 `covers`（回指哪一条 check()）与 `ignore`（逐条豁免，不是整片裁掉）。
## 裁掉噪声字段的那一刀正是覆盖面漏出去的地方，所以这一步不给机器做。
##
## 挂法：headless_test.gd 的 `on_game_made` —— make_game() 是套件里造对局的唯一口，
## 在它那儿把四个模块件换成代理（A-4 的「唯一换件点」）。
##
## ⚠ 语言层假设（规格 §0.6.5 第 8 条）：`preload("res://tests/headless_test.gd").new()` 造出来的是一个
## **非主循环**的 SceneTree 实例，引擎不会调它的 _initialize() / _process()，我们直接 `await suite.call(fn)`。
## 落地前已在 scratchpad 副本上实跑验过（见步 13 计划的 notes）。
extends SceneTree

const SUITE := preload("res://tests/headless_test.gd")
const REC := preload("res://tests/rec/cw_recorder.gd")


func _initialize() -> void:
	var fn := ""
	var out_path := "user://harvest.json"
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.split("=")
		if kv.size() != 2:
			continue
		if kv[0] == "fn":
			fn = kv[1]
		elif kv[0] == "out":
			out_path = kv[1]
	if fn == "":
		printerr("要收割哪个测试函数？用 fn=t_pressure")
		quit(1)
		return

	## 规矩 1 先过：契约表对不上就整条中止，别录出一堆要重来的东西
	var probe = REC.new()
	var bad: PackedStringArray = probe.contract_mismatch()
	if not bad.is_empty():
		for b in bad:
			printerr(b)
		quit(1)
		return

	var suite = SUITE.new()
	if not suite.has_method(fn):
		printerr("headless_test.gd 上没有这个函数：%s" % fn)
		suite.free()
		quit(1)
		return
	var recs: Array = []
	suite.on_game_made = func(g: CWGame) -> void:
		var r = REC.new()
		r.harvested_from = "headless_test.gd:%s" % fn
		r.install(g)
		recs.append(r)
	var t0 := Time.get_ticks_msec()
	await suite.call(fn)
	var ms := Time.get_ticks_msec() - t0

	var cases: Array = []
	var n_unloadable := 0
	var n_dropped := 0
	var notes := PackedStringArray()
	for r in recs:
		n_dropped += int(r.dropped)
		for k in r.unloadable:
			n_unloadable += int(r.unloadable[k])
		for e in r.errors:
			notes.append(str(e))
		for c in r.entries:
			c["id"] = "%s/%s/%03d" % [str(c["op"]), fn, cases.size()]
			cases.append(c)

	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		printerr("无法写 ", out_path, " err=", FileAccess.get_open_error())
		suite.on_game_made = Callable()
		suite.free()
		quit(1)
		return
	f.store_string(JSON.stringify(cases, "  "))
	f.close()
	var suite_fails := int(suite.fails)
	suite.on_game_made = Callable()
	suite.free()

	print("HARVEST: %d 条草稿写到 %s（%s 跑了 %d ms，套件自己红了 %d 条）" % [
		cases.size(), out_path, fn, ms, suite_fails])
	## 规矩 2 的对账：丢弃数要说出来，人才知道嵌套有没有多到不正常
	print("　丢弃嵌套 %d 条；UNLOADABLE %d 条" % [n_dropped, n_unloadable])
	for s in notes:
		print("　%s" % s)
	print("⚠ 这是草稿：covers 与 ignore 要人过一遍才许进仓库（A-4）")
	quit(0)
