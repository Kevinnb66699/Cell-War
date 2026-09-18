## cw_recorder.gd —— 录制代理的账本与换件点（测试迁移规格 A-4 / C-1 步 13）
##
## 四个代理（cw_rec_world / cw_rec_actions / cw_rec_cardfx / cw_rec_worldfx）只做一件事：
## 进契约步之前 dump 一份 pre、出来之后 dump 一份 post，把差分交给这里。**规则一行都不在这条路上。**
##
## 六条硬规矩（A-4）落在哪：
##   1. 只覆写契约表的 S 族 —— `contract_mismatch()`，覆写集合的唯一出处是
##      `l0_contract_gate.gd:recorder_overrides()`（§0.6.4 第 4 条：kind = step ∧ status ∈
##      {OK, KNOWN_GAP, UNDEFINED} ∧ rec != "manual" 的 24 行的 `gd` 字段）。代理这边不另存一张表。
##   2. 深度计数，只在深度 0 落一条 —— `begin()` / `skip()` / `finish()` 与 `dropped`。
##   3. 协程性镜像父类 —— 在四个代理文件里逐个写死（父函数体内含 await 的才 `await super`）。
##   4. rng 一律走带子 —— `install()` 把 tests/xcheck_tape.gd 装进 g.rng，代理自己不调 rng。
##   5. 装不回去就不录 —— dump_world 返回 {} 就记 `UNLOADABLE`，**不产用例**（这条挡的就是闸一悄悄退化成半条）。
##   6. 正式设施 —— 落在 game/tests/rec/ 下并进 tools/run_tests.sh。
##
## op 名也只从契约表来（`gd` 字段 → `op`）：代理里写死的是 `文件名:方法名`，与规矩 1 反射核的是同一串，
## 表里改了 op 名这边跟着走，不会两头各存一份再慢慢漂。
##
## 不带 class_name（同 xcheck_* 的规矩），用 preload 取。
extends RefCounted

const Loader := preload("res://scripts/kernel/cw_world_loader.gd")
const Diff := preload("res://tests/cw_case_diff.gd")
const Gate := preload("res://tests/l0_contract_gate.gd")
const Tape := preload("res://tests/xcheck_tape.gd")
const OPS_PATH := "res://tests/contract_ops.json"

const RecWorld := preload("res://tests/rec/cw_rec_world.gd")
const RecActions := preload("res://tests/rec/cw_rec_actions.gd")
const RecCardFx := preload("res://tests/rec/cw_rec_cardfx.gd")
const RecWorldFx := preload("res://tests/rec/cw_rec_worldfx.gd")

## 契约表 `gd` 字段的文件名 → 负责它的代理类。**四个代理够不着 cw_game.gd**：
## `damage_hit` 住在 CWGame 上（immune_hit / cancer_hit），CWGame 不是 cw_game.gd:init() 换得掉的模块件 ——
## 表里给它挂了 `"rec": "manual"`（§0.6.4 第 2 条），所以它不在 recorder_overrides() 里，这张表也就是四行。
const AGENT_OF := {
	"cw_world.gd": RecWorld,
	"cw_world_fx.gd": RecWorldFx,
	"cw_actions.gd": RecActions,
	"cw_card_fx.gd": RecCardFx,
}

var game: CWGame
var tape                          ## xcheck_tape.gd 的带子（规矩 4）
var harvested_from := ""          ## 形如 "headless_test.gd:t_pressure"，写进草稿用例
var entries: Array = []           ## 录到的 cwxcase/2 草稿
var calls: Dictionary = {}        ## op → 深度 0 进来过几次（t_rec_shape 的对账口径）
var unloadable: Dictionary = {}   ## op → dump 不出来、没产用例的次数（规矩 5）
var dropped := 0                  ## 深度 >0 丢弃了几条（规矩 2）
var errors: PackedStringArray = []

var _depth := 0
var _cur: Dictionary = {}
var _op_of: Dictionary = {}       ## "cw_world.gd:_pressure" → "pressure"，开录前从契约表读一次
var _warned: Dictionary = {}      ## 同一个查不到 op 的 gd 只报一次（否则一遍 E 阶段刷几百条一样的）


## 唯一的换件点（A-4）：cw_game.gd:init() 是九个模块的**唯一**构造点，
## 代理在它之后、开跑之前换四个件并重挂 .game。全仓没有 `is CWWorld` 一类的类型判断，
## 也没有把 game.world 缓存进长寿局部变量的地方（已核）。
func install(g: CWGame) -> void:
	game = g
	_op_of = _op_table()
	if _op_of.is_empty():
		errors.append("读不到 %s 或表里一条可录的步都没有 —— 录出来的东西没有 op 名，不许开跑" % OPS_PATH)
	if tape == null:
		tape = Tape.new()
	## 接着原来那只 rng 的**状态**往下走：代理开着与不开着掷出的点数必须逐位相同（t_rec_transparent）
	tape.state = g.rng.state
	g.rng = tape
	var w := RecWorld.new()
	var a := RecActions.new()
	var cf := RecCardFx.new()
	var wf := RecWorldFx.new()
	for m in [w, a, cf, wf]:
		m.rec = self
		m.game = g
	g.world = w
	g.actions = a
	g.card_fx = cf
	g.world_fx = wf


## 手搭盘面从不跑 setup._assign_cancer_types()，癌席身上没有 cancer_type 键 —— _dump_players 会记一条
## UNLOADABLE 并返回截断的 players（规矩 5 形同虚设）。**每次 dump 之前现算**：取该席最后一只癌细胞的
## ctype（loader 互校用的就是 players[].cell_id 指的那一只），一只都没有就写 Osteosarcoma（§0.6.1 第 2 条）。
## players[].cancer_type 只被 cw_setup.gd 落子时消费，规则读的是 cells[].ctype，所以补它不改规则；
## 但它**进 state_hash**（CWStateCodec.snapshot 收整份 players）—— 留在世界里就是行为改动，
## t_rec_transparent「开代理与不开代理逐位相同」当场红。所以：dump 与 envelope 取完之后原样放回。
## 返回值是这一次改过的 [席位, 原值] 表，交给 _restore_cancer_types()。
func _fill_cancer_types() -> Array:
	var saved: Array = []
	for p in game.players:
		if int(p["faction"]) == CWData.Faction.IMMUNE:
			continue
		var ct := int(CWData.CancerType.OSTEO)
		for c in game.cells:
			if int(c["pid"]) == int(p["id"]) and int(c.get("ctype", -1)) >= 0:
				ct = int(c["ctype"])
		saved.append([p, p.get("cancer_type", null)])
		p["cancer_type"] = ct
	return saved


static func _restore_cancer_types(saved: Array) -> void:
	for pair in saved:
		var p: Dictionary = pair[0]
		if pair[1] == null:
			p.erase("cancer_type")
		else:
			p["cancer_type"] = pair[1]


## 返回 true = 这是深度 0 的一次，pre 已经落好；调用方跑完 super 之后必须调 finish()。
## 返回 false = 嵌套（规矩 2）或这一步没有 op 名，调用方跑完 super 之后必须调 skip()。
## `gd` 形如 "cw_world.gd:_pressure"，与契约表的 `gd` 字段逐字相同。
func begin(gd: String, args: Dictionary) -> bool:
	_depth += 1
	if _depth > 1:
		dropped += 1
		return false
	var op := str(_op_of.get(gd, ""))
	if op == "":
		if not _warned.has(gd):
			_warned[gd] = true
			errors.append("代理覆写了 %s，契约表里查不到它的 op —— 这一次不录（规矩 1 的 t_rec_contract_only 会同时红）" % gd)
		return false
	calls[op] = int(calls.get(op, 0)) + 1
	var saved := _fill_cancer_types()
	var loader = Loader.new()
	var pre: Dictionary = loader.dump_world(game)
	_cur = {
		"op": op, "args": args, "world": pre, "env": Diff.normalize(_envelope()),
		"bad": ("" if not pre.is_empty() else "pre：" + "; ".join(loader.errors)),
	}
	_restore_cancer_types(saved)
	if tape != null:
		tape.take()   ## 把游标推到这一步之前，finish() 取到的就只是这一步掷的
	return true


func skip() -> void:
	_depth -= 1


func finish() -> void:
	_depth -= 1
	if _cur.is_empty():
		return
	var op: String = _cur["op"]
	var saved := _fill_cancer_types()
	var loader = Loader.new()
	## 只为验「这个 post 世界也装得回去」；草稿里不留 post 的 spec
	var post: Dictionary = loader.dump_world(game)
	## envelope 必须在**放回之前**取：草稿的 world 写的是补过的癌种，
	## 装回去之后两侧算出的 $.g.players 也是补过的 —— 两头得是同一份
	var post_env: Dictionary = Diff.normalize(_envelope())
	_restore_cancer_types(saved)
	var bad: String = str(_cur["bad"])
	if bad == "" and post.is_empty():
		bad = "post：" + "; ".join(loader.errors)
	if bad != "":
		## 规矩 5：装不回去就不录 —— 报告里记一条 UNLOADABLE，**不产用例**
		unloadable[op] = int(unloadable.get(op, 0)) + 1
		errors.append("UNLOADABLE %s：%s" % [op, bad])
		_cur = {}
		return
	var changed: Dictionary = Diff.diff(_cur["env"], post_env)
	## 差分自己报硬错（同席多细胞的语义键歧义 / 命中 ask.options）时 `diff()` 返回 {} ——
	## 不查这一条就会落下一条「这一步什么都没改」的**假绿**用例（实测：
	## t_vessel_no_solid 三条固化 / t_balance_candidates 两条代谢全是这样掉出去的）。
	## 归进规矩 5 的同一档：记一条 UNLOADABLE，**不产用例**。
	if not Diff.errors.is_empty():
		unloadable[op] = int(unloadable.get(op, 0)) + 1
		errors.append("UNLOADABLE %s：差分 %s" % [op, "; ".join(Diff.errors)])
		_cur = {}
		return
	entries.append({
		"schema": "cwxcase/2",
		"id": "",                       ## harvest.gd 编号
		"op": op,                       ## S 族写 op、不写 probe（§0.6.2 第 1 条，二选一）
		"covers": [],                   ## ⚠ 人要过一遍：回指哪一条 check()（A-4 收割入口）
		"status": "OK",
		"harvested_from": harvested_from,
		"world": _cur["world"],
		"rolls": (tape.take() if tape != null else []),
		"args": _cur["args"],
		"expect": { "kind": "delta", "changed": changed, "ignore": [] },
	})
	_cur = {}


## 一个脚本「自己声明的方法集合」。
## ⚠ `Script.get_script_method_list()` **连父类的一起返回**，不是只返回自己的那些 ——
## 上一轮底稿按「只返回自己的」写，落地当天 t_rec_contract_only 会红出六十多条假差异。
## 实测（Godot 4.5，scratchpad 副本）：**覆写的那一个会出现两次**（子类一条、父类一条，
## 两条 MethodInfo 逐字相同，`flags` / `id` 都分不开）—— cw_rec_worldfx 14 条 / CWWorldFx 13 条、
## `tick_durations` 出现 2 次；一个覆写都没有的 cw_rec_cardfx 是 54 / 54。
## 所以判据是**条数**：子类里出现的次数 > 父类里出现的次数 = 这个脚本自己声明的
## （覆写是 2 > 1，父类没有的新方法是 1 > 0，同一条判据一起收）。不读源码、不硬编码名字。
static func declared_methods(s: GDScript) -> Dictionary:
	var sub := _method_counts(s)
	var base := _method_counts(s.get_base_script())
	var out := {}
	for n in sub:
		if int(sub[n]) > int(base.get(n, 0)):
			out[n] = true
	return out


static func _method_counts(s: GDScript) -> Dictionary:
	var out := {}
	if s == null:
		return out
	for m in s.get_script_method_list():
		var n := str(m["name"])
		if n.begins_with("@") or n == "_init":
			continue
		out[n] = int(out.get(n, 0)) + 1
	return out


## 规矩 1 的执行机构（§0.3 / 风险 R2）：四个代理**自己声明**的方法名，必须与
## `l0_contract_gate.gd:recorder_overrides()` 给的 24 条 `gd` 字段逐名相同，多一个少一个都报。
## 空数组 = 对得上。
func contract_mismatch() -> PackedStringArray:
	var out := PackedStringArray()
	var want_list: Array = Gate.recorder_overrides(OPS_PATH)
	if want_list.is_empty():
		out.append("读不到 %s，或表里一条可录的步都没有 —— 它是 op 的唯一白名单（§0.6.4），没有它代理不许开跑" % OPS_PATH)
		return out
	var want := {}
	for gd in want_list:
		var file := str(gd).get_slice(":", 0)
		if not AGENT_OF.has(file):
			out.append("契约表要录 %s，但 %s 不是四个可换模块件之一 —— 这一行要么挂 \"rec\": \"manual\"，要么补一个代理类" % [str(gd), file])
			continue
		want[str(gd)] = true
	var have := {}
	for file in AGENT_OF:
		for n in declared_methods(AGENT_OF[file] as GDScript):
			have["%s:%s" % [str(file), str(n)]] = true
	for k in want:
		if not have.has(k):
			out.append("契约表里有 %s，代理没覆写" % k)
	for k in have:
		if not want.has(k):
			out.append("代理覆写了 %s，契约表里没有 —— 私有分解不许进跨内核契约（§0.3）" % k)
	return out


## 全知 envelope，与闸二 2b（l0_pre_dump.gd）取的是同一份 —— delta 的根 `$` 就从它 normalize 出来
func _envelope() -> Dictionary:
	return CWObsCodec.encode(game, { "viewer": CWObsProto.VIEWER_OMNISCIENT })


## "cw_world.gd:_pressure" → "pressure"，只收 recorder_overrides() 认的那 24 行
func _op_table() -> Dictionary:
	var out := {}
	for gd in Gate.recorder_overrides(OPS_PATH):
		out[str(gd)] = ""
	for row in Gate.load_table(OPS_PATH):
		var gd := str((row as Dictionary).get("gd", ""))
		if out.has(gd):
			out[gd] = str((row as Dictionary).get("op", ""))
	for gd in out.keys():
		if str(out[gd]) == "":
			out.erase(gd)
	return out
