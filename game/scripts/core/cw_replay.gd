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

# ============ 播放器：暂停 / 单步 / 快进 / 快退 ============

## **引擎只能往前跑，退不回去** —— `step()` 是一次结算，没有逆运算。
## 所以「快退」的真身是**还原到之前某个状态，再快进到目标步**。
##
## 从头重跑当然也行，但一局几百步、每步都要走一遍完整结算，拖进度条会明显卡。
## 所以每 `KEY_EVERY` 步存一个**关键帧**（`game.snapshot()`），
## 往回跳时先还原最近那一帧，再往前推剩下几步。
##
## 关键帧敢这么存，是因为**引擎的流程位置是数据而不是调用栈**
## （见 cw_game.gd 流程状态机那段注释：「快照永远取在 pending 边界上，
## 那时没有悬着的协程」）。这条设计当初是为 AI 推演做的，回放白捡。
##
## 速度不在这儿管：播放器只提供「往前一步」，隔多久走一步是界面的事
## （倍速 = 一帧里多走几步；暂停 = 干脆不走）。这样播放器无关帧率，测试里也好驱动。
class Player extends RefCounted:
	const KEY_EVERY := 25        ## 每多少步存一个关键帧

	var data := {}
	var game: CWGame
	## 念下标的那个桥。无头那条路用 `CWReplay.Bridge`；
	## **界面那条路用 `CWUIBridge`** —— 掷骰演出、通报、过场全是走桥的，
	## 换成纯数据桥回放就成了没有任何演出的哑剧（见 CWUIBridge.ask 的注释）。
	## 两者的游标字段名不同（`at` / `replay_at`），所以这儿留一个口味标记。
	var bridge: Object
	var total := 0               ## 一共几步
	var _ui_flavor := false
	var _keys: Array = []        ## [{at, snap}]，按 at 升序

	## 开一份回放；数据不合法返回 null
	static func open(d: Dictionary) -> Player:
		var g := CWReplay.build(d)
		if g == null:
			return null
		var p := Player.new()
		p.data = d
		p.game = g
		p.bridge = g.bridges[g.order[0]]
		p.total = PackedInt32Array(d["answers"]).size()
		## 第 0 帧一定要有 —— 有了它 `_rewind_to` 永远找得到落脚点，
		## 就不必在半路重建对局（重建会换掉 `game` 这个对象，界面那头还拿着旧引用）
		p._keys = [{ "at": 0, "snap": g.snapshot() }]
		return p

	## 换一个桥来念（界面那条路：`CWMatch` 把自己的 `CWUIBridge` 装进来）。
	## 下标串与当前进度一起交接，快退时拨的也是它。
	func attach(b: Object) -> void:
		var was := at()
		bridge = b
		_ui_flavor = not (b is Bridge)
		if _ui_flavor:
			b.replay_answers = PackedInt32Array(data["answers"])
		else:
			b.answers = PackedInt32Array(data["answers"])
		for pid in game.order:
			game.bridges[pid] = b
		_set_at(was)


	## 放到第几步了
	func at() -> int:
		return int(bridge.replay_at if _ui_flavor else bridge.at)


	func _set_at(n: int) -> void:
		if _ui_flavor:
			bridge.replay_at = n
		else:
			bridge.at = n

	func done() -> bool:
		return game.is_over() or at() >= total

	## 往前一步。放完 / 放到终局返回 false
	func step_once() -> bool:
		if game.is_over():
			return false
		var req: Dictionary = await game.pending()
		if req.is_empty():
			return false
		var idx: int = await game.ask(req["pid"], req)
		if game.aborted or game.winner >= 0:
			return false
		await game.step(idx)
		_maybe_key()
		return true

	## 跳到「已经放了 n 步」的位置。往前接着推，往回先还原关键帧再推
	func seek(n: int) -> void:
		n = clampi(n, 0, total)
		if n < at():
			_rewind_to(n)
		while at() < n:
			if not await step_once():
				break

	func _maybe_key() -> void:
		if at() % KEY_EVERY != 0:
			return
		for k: Dictionary in _keys:
			if int(k["at"]) == at():
				return          ## 这一帧存过了（往回跳之后再推回来会重走同一段）
		_keys.append({ "at": at(), "snap": game.snapshot() })
		_keys.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
			return int(x["at"]) < int(y["at"]))

	## 还原到不晚于 n 的那个关键帧。`restore` 是**就地改**这个 game 对象，
	## 所以桥还挂着、界面那头的引用也不用换 —— 只要把桥的游标一起拨回去
	func _rewind_to(n: int) -> void:
		var best: Dictionary = _keys[0]
		for k: Dictionary in _keys:
			if int(k["at"]) <= n:
				best = k
		game.restore(best["snap"])
		_set_at(int(best["at"]))
