## cw_replay.gd —— 对局回放：录下来、存下来、放回去
##
## ## 为什么不用存快照
##
## **一局 = 开局参数 + 一串下标。** 客户端发给服务器的本来就只是 `answer{ask_id, index}`，
## 而引擎给定种子后完全确定（`t_determinism` 一直盯着这条）。所以录下「每次询问选了第几项」
## 就够复现整局 —— 一局几 KB，不是几 MB。
##
## 录在 `CWGame.ask()`：那是**引擎与决策者之间的唯一通道**（见 cw_bridge.gd 的文件头），
## 人类、AI、离线代打、超时代打全从那儿过，一个都漏不掉。录的是**钳位之后**的值，
## 因为回放要复现的是引擎真正用了哪一项，而不是谁报了什么。
##
## ## 开局参数为什么是这几样
##
## `init(factions, seed)` + `tune` + `setup.begin()` 就决定了一局的全部起点：
## · `players` → `CWData.FACTION_ORDER[players]`，行动顺序由它定死
## · `seed` → `rng.seed`，之后所有掷骰、抽卡、癌种分配都从它派生
## · `rules` → `tune.rules_state()`，所有会改变结算的旋钮
## · `cancer_types` → **单独存**：它不在 `RULE_FIELDS` 里（不改结算，只是钉死抽哪几种），
##   但 `setup._assign_cancer_types()` 要消费它，不存的话自定义对局回放出来癌种会变
##
## ## 放回去 = 在本地重建一局，然后像观众一样看
##
## 播放器就是一个「按顺序念下标」的桥（`CWReplay.Bridge`）。它注册给所有 pid，
## 于是 `run_game()` 每问一次就吃掉一个下标。表现层什么都不用改 ——
## 对它来说这就是一局没有真人的对局，和观战、和 AI 互搏走同一条路。
class_name CWReplay
extends RefCounted

const VERSION := 1
const DIR := "user://replays"
const EXT := ".cwr"
const KEEP := 20        ## 最多留几份；再多就从最旧的开始删（回放很小，但也不该无限长）


## 从一局（已结束或进行中都行）取出可以存盘的那份东西
static func of(game: CWGame) -> Dictionary:
	return {
		"version": VERSION,
		"players": game.order.size(),
		"seed": int(game.rng.seed),
		"rules": game.tune.rules_state(),
		## 不在 RULE_FIELDS 里，但开局要用 —— 见文件头
		"cancer_types": Array(game.tune.cancer_types),
		"answers": game.replay.duplicate(),
		"round": game.round_no,
		"winner": game.winner,
		"win_reason": game.win_reason,
		"at": Time.get_datetime_string_from_system(false, true),
	}


## 这份数据看着像不像一份能放的回放。**读盘那一侧一律先过这道** ——
## 回放文件会被人拷来拷去，坏一个字段就该当没有，而不是半路崩在引擎里。
static func valid(d: Dictionary) -> bool:
	if int(d.get("version", 0)) != VERSION:
		return false
	if not (int(d.get("players", 0)) in CWData.FACTION_ORDER):
		return false
	if typeof(d.get("answers")) != TYPE_PACKED_INT32_ARRAY:
		return false
	return typeof(d.get("rules")) == TYPE_DICTIONARY


## 按这份数据重建一局，并把「念下标」的桥装给所有席位。
## 返回的是**没有推进过**的对局：调用方自己 `await g.run_game()`（界面那边要一步步演）。
static func build(d: Dictionary) -> CWGame:
	if not valid(d):
		return null
	var g := CWGame.new()
	g.init(CWData.FACTION_ORDER[int(d["players"])], int(d["seed"]))
	g.tune.restore_rules_state(d["rules"])
	g.tune.cancer_types = Array(d.get("cancer_types", []))
	var b := Bridge.new()
	b.answers = d["answers"]
	b.game = g
	for pid in g.order:
		g.bridges[pid] = b        ## 一个桥服务所有席位：回放没有「谁在决策」这回事
	return g


# ============ 存取 ============

static func _ensure_dir() -> void:
	if not DirAccess.dir_exists_absolute(DIR):
		DirAccess.make_dir_recursive_absolute(DIR)


## 存一份，返回落盘路径；存不下返回空串。
## 文件名带时间戳 —— 一局一份，不覆盖（覆盖就等于「上一局白打了」）。
static func save(game: CWGame) -> String:
	if game == null or game.replay.is_empty():
		return ""
	return write(of(game))


## 把**已经成形**的一份回放落盘。联机那条路走这里：服务器随终局把它发下来，
## 客户端拿到的就是一份现成的字典，没有 CWGame 可取。
static func write(d: Dictionary) -> String:
	if not valid(d) or PackedInt32Array(d["answers"]).is_empty():
		return ""
	_ensure_dir()
	var path := "%s/%s%s" % [DIR, Time.get_datetime_string_from_system(false, false)
		.replace(":", "").replace("-", "").replace("T", "_"), EXT]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(var_to_str(d))
	f.close()
	_trim()
	return path


## 读一份；读不出 / 认不出一律返回 {}（调用方按「没这份回放」处理）
static func read(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var raw: Variant = str_to_var(f.get_as_text())
	f.close()
	if typeof(raw) != TYPE_DICTIONARY or not valid(raw):
		return {}
	return raw


## 已存的回放，**新的在前**
static func list_files() -> PackedStringArray:
	var out := PackedStringArray()
	if not DirAccess.dir_exists_absolute(DIR):
		return out
	for f in DirAccess.get_files_at(DIR):
		if f.ends_with(EXT):
			out.append("%s/%s" % [DIR, f])
	out.sort()
	out.reverse()
	return out


## 超过 KEEP 份就从最旧的删起
static func _trim() -> void:
	var files := list_files()
	for i in range(KEEP, files.size()):
		DirAccess.remove_absolute(files[i])


# ============ 播放用的桥 ============

## 按顺序念下标。念完了一律返回 0 —— 那是「停止 / 放弃」那一项的位置
## （cw_bridge.gd 的约定），所以录漏了尾巴也只会安静收场，不会乱走。
class Bridge extends CWBridge:
	var answers: PackedInt32Array = []
	var at := 0

	func ask(_req: Dictionary) -> int:
		if at >= answers.size():
			return 0
		var i: int = answers[at]
		at += 1
		return i

	## 还剩几步没放（进度条要用）
	func left() -> int:
		return maxi(answers.size() - at, 0)
