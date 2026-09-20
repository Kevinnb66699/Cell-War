## replay_dump.gd —— 回放磁带语义导出器（AI 实测分析用）
## 用法：<godot> --headless --path game --script res://tests/replay_dump.gd -- <回放路径或文件名>
## 原理：CWReplay.build 重建对局，换上 DumpDecider 念磁带，把每个决策点的
##       回合/阶段/席位/阵营/所选选项的 label+data 记成 JSONL 落盘，stdout 出摘要。
extends SceneTree

class DumpDecider extends CWBridge:
	var answers := PackedInt32Array()
	var at := 0
	var trace: Array = []
	var fname := ""

	func ask(req: Dictionary) -> int:
		var i := 0
		if at < answers.size():
			i = answers[at]
		at += 1
		var opts: Array = req.get("options", [])
		var label := ""
		var data := {}
		if i < opts.size():
			label = str(opts[i].get("label", ""))
			data = opts[i].get("data", {})
		var fac := -1
		var rnd := -1
		if game != null and int(req.get("pid", -1)) >= 0:
			fac = int(game.player(req["pid"])["faction"])
			rnd = game.round_no
		trace.append({
			"file": fname, "seq": at, "round": rnd,
			"phase": CWCardData.cancer_phase(rnd) if rnd > 0 else "",
			"kind": str(req.get("kind", "")), "pid": int(req.get("pid", -1)), "fac": fac,
			"label": label, "data": data,
		})
		return i

	func left() -> int:
		return maxi(answers.size() - at, 0)


func _initialize() -> void:
	_run()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		printerr("用法: -- <回放文件名或完整路径>")
		quit(1)
	var arg := args[0]
	var path := arg
	if not path.begins_with("C:") and not path.contains("/"):
		path = "user://replays/" + arg
	if not path.ends_with(".cwr"):
		path += ".cwr"
	var d := CWReplay.read(path)
	if d.is_empty():
		printerr("回放读不出/规则指纹不符: " + path)
		quit(1)
	var k := CWReplay.build(d, false)
	if k == null:
		printerr("重建失败")
		quit(1)
	var dec := DumpDecider.new()
	dec.answers = PackedInt32Array(d["answers"])
	dec.game = k.game
	dec.fname = path.get_file()
	k.set_decider(dec)
	var n := 0
	while true:
		var ok: bool = await k.step_once()
		if not ok:
			break
		n += 1
	var g = k.game
	print("=== 摘要 %s ===" % path.get_file())
	print("步数=%d 回合=%d winner=%d win_kind=%s" % [n, g.round_no, g.winner, String(g.win_kind)])
	# 席位表
	for pid in g.order:
		var p: Dictionary = g.player(pid)
		print("  pid=%d faction=%d name=%s" % [pid, int(p["faction"]), String(p.get("name", ""))])
	# 落盘 JSONL
	var out := "user://replay_dump_%s.jsonl" % path.get_file().get_basename()
	var f := FileAccess.open(out, FileAccess.WRITE)
	for t in dec.trace:
		f.store_line(JSON.stringify(t))
	f.close()
	print("WROTE %s (%d 行)" % [ProjectSettings.globalize_path(out), dec.trace.size()])
	quit(0)
