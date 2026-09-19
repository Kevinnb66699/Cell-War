extends SceneTree
## record_level_rolls.gd —— 教程关卡的**带子录制器**（新手引导 v2 方案 §4 那一行的
## 「`tools/record_level_rolls.gd` 无头录制」，S10，2026-09-19）。
##
## ⚠ **路径与方案 §4 写的不一样**：Godot 的 `--script` 只认 `res://`，而 `res://` 的根是 `game/`，
## 仓库根的 `tools/` 根本进不去。仓库里所有无头小工具（`dump_guide.gd` / `dump_tuning.gd` /
## `build_patch.gd`）都住 `game/tests/`，四个导出预设一律 `exclude_filter="tests/*"` ⇒ 不进包。
## 这一份照办。
##
## 为什么要有它：教程的「预设结果」只许写 `rolls`（方案 §0 边界③：规则代码一行不改）。
## 可有几条规则是**拧不掉的随机**——【根深蒂固】按 `pick_random` 挑相邻癌组织、
## 【黏液破裂】按 `pick_random` 挑 10 格健康组织。这些只能**先录一遍、再钉回数据**。
##
## 跑：
##   godot --headless --path game --script res://tests/record_level_rolls.gd -- \
##       --level=c3_l6 [--world=base] [--rounds=1] [--write]
##
## 不加 `--write` 只打印；加了就把 `data/tutorial/levels/<level>.json` 里那一段
## `"rolls": [...]` **原地换掉**（只动这一段，别的字节一个不碰，行尾照旧）。
##
## 录出来的带子与 `cw_roll_tape.gd` 同形（`[[from, to, value], …]`），**退化区间不记**：
## Godot 的 `randi_range(n, n)` 一个随机数都不消耗，带子上也不许留痕（两侧必须同口径）。

const TUTOR := preload("res://scripts/kernel/cw_tutor_script.gd")
const LOADER := preload("res://scripts/kernel/cw_world_loader.gd")
const LEVEL_DIR := "res://data/tutorial/levels/"


## 录制替身：照常掷，掷完记一笔。签名与 `cw_roll_tape.gd` 逐个对上（引擎那头只认这三个成员）
class RecRng extends RefCounted:
	var inner := RandomNumberGenerator.new()
	var rolls: Array = []

	var seed: int:
		set(v): inner.seed = v
		get: return inner.seed

	var state: int:
		set(v): inner.state = v
		get: return inner.state

	func randi_range(from: int, to: int) -> int:
		if from == to:
			return from   ## 退化区间消耗 0 个随机数（同 cw_roll_tape.gd 的头注）
		var v := inner.randi_range(from, to)
		rolls.append([from, to, v])
		return v

	func randi() -> int:
		return inner.randi()


func _initialize() -> void:
	var level_id := ""
	var world_id := "base"
	var rounds := 1
	var write := false
	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s.begins_with("--level="):
			level_id = s.substr(8)
		elif s.begins_with("--world="):
			world_id = s.substr(8)
		elif s.begins_with("--rounds="):
			rounds = maxi(1, int(s.substr(9)))
		elif s == "--write":
			write = true
	if level_id == "":
		print("用法：--level=<关 id> [--world=base] [--rounds=1] [--write]")
		quit(2)
		return
	_run(level_id, world_id, rounds, write)


func _run(level_id: String, world_id: String, rounds: int, write: bool) -> void:
	var d = TUTOR.new()
	var lv: Dictionary = d.load_level(level_id)
	if lv.is_empty():
		print("✘ 关表里读不出「%s」（data/tutorial/index.json）" % level_id)
		quit(1)
		return
	var spec: Dictionary = d.resolve(lv, world_id)
	if spec.is_empty():
		print("✘ 关「%s」里没有名为「%s」的 world" % [level_id, world_id])
		quit(1)
		return
	var loader = LOADER.new()
	var g: CWGame = loader.load_world(spec)
	if g == null:
		print("✘ world「%s」装不出来：%s" % [world_id, str(loader.errors)])
		quit(1)
		return
	## 录制替身必须挂在跑第一颗骰之前（同 `cw_tutorial_stage._open_spec`）
	var rec := RecRng.new()
	if g.rng is RandomNumberGenerator:
		rec.seed = int((g.rng as RandomNumberGenerator).seed)
	g.rng = rec

	for i in rounds:
		if i > 0:
			## 两次 E 之间照 `CWGame._pump` 的次序补一个 S 阶段（S 阶段也可能掷骰）
			g.round_no += 1
			g.world.round_start()
			g.world.aerobic()
			g.world.overload()
			g.cap_energy()
		await g.world.e_phase()
		if g.is_over():
			print("⚠ 第 %d 次 E 阶段之后已经终局（winner=%d / %s）—— 录到这里为止"
				% [i + 1, int(g.winner), str(g.win_kind)])
			break

	var out: Array = rec.rolls
	print("[%s / %s] 跑了 %d 个世界回合，消耗 %d 颗骰子" % [level_id, world_id, rounds, out.size()])
	print("ROLLS %s" % JSON.stringify(out))
	g.dispose()
	if write:
		_write_back(level_id, out)
	quit(0)


## 把 `"rolls": [...]` 那一段原地换掉。**只动这一段**：整份 JSON 重新序列化会把
## `_doc`、缩进、键序、行尾全洗一遍，diff 当场没法看
func _write_back(level_id: String, rolls: Array) -> void:
	var path := LEVEL_DIR + level_id + ".json"
	var src := FileAccess.get_file_as_string(path)
	if src == "":
		print("✘ 读不到 %s" % path)
		quit(1)
		return
	var key := "\"rolls\":"
	var i := src.find(key)
	if i < 0:
		print("✘ %s 里没有 \"rolls\" 那一段 —— 先手写一行 \"rolls\": [] 再来录" % path)
		quit(1)
		return
	var open_at := src.find("[", i)
	var depth := 0
	var close_at := -1
	for j in range(open_at, src.length()):
		var ch := src[j]
		if ch == "[":
			depth += 1
		elif ch == "]":
			depth -= 1
			if depth == 0:
				close_at = j
				break
	if close_at < 0:
		print("✘ %s 的 \"rolls\" 那一段括号不配对" % path)
		quit(1)
		return
	var body := "[]"
	if not rolls.is_empty():
		var rows := PackedStringArray()
		for e in rolls:
			rows.append("    [%d, %d, %d]" % [int(e[0]), int(e[1]), int(e[2])])
		body = "[\n" + ",\n".join(rows) + "\n  ]"
	var eol := "\r\n" if src.contains("\r\n") else "\n"
	body = body.replace("\n", eol)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		print("✘ 写不了 %s" % path)
		quit(1)
		return
	f.store_string(src.substr(0, open_at) + body + src.substr(close_at + 1))
	f.close()
	print("✔ 已写回 %s（%d 条）" % [path, rolls.size()])
