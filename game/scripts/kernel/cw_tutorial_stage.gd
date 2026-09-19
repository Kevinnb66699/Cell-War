## cw_tutorial_stage.gd —— 新手教程的「舞台」：一关数据 → 一份 cwxworld/3 → 一局，交出 **CWKernel**
## （docs/新手引导v2_实现方案.md §1.3，2026-09-19）
##
## **新手教程 v2 · S1 只改了三处**：① `const DATA` 指新门面 `cw_tutor_script.gd`（`cwtut/2`）；
## ② `_rolls()` 跟新 schema（字段名恰好没变，但口径改成了「空带子 ≠ 省略」那一条）；③ 文件头注释。
## **整份重写是陷阱**：它的价值全在下面那条四步拆装序列上（`abort → queue.stop → close → dispose`）。
##
## 它替掉了老的 `scripts/ui/guide_director.gd`：老导演住在 UI 层、直接 `CWGame.new()` 再往引擎状态上写字段，
## 所以结构闸 `t_no_engine_in_ui` 得给它整份豁免。舞台住 `scripts/kernel/`（闸只扫 `scripts/ui` 那一层目录），
## 而且**只把 `CWKernel` 交出去** —— `match.gd` 整份不再出现 `CWGame`，白名单从两条降到一条。
##
## 三条硬边界怎么守（方案 §0）：
## ① 盘面一律走 `cwxworld/3` 装载器（`scripts/kernel/cw_world_loader.gd`，与 C# 的 L0/WorldLoader 同一张键表），
##    教程不再需要任何「不在 cwxworld/3 里」的引擎字段 —— 老导演那句 `g.win_checks = false` 整条消掉了
##    （改用数据：第一 ~ 五关的 `allow` 里不放「结束回合」⇒ 永远进不了 E 阶段 ⇒ 胜负判定压根不跑，方案 §2.3）。
## ② UI 只读 `CWMirror`、只经 `CWKernel` 作答、演出走 `CWPlayQueue`：`open_level()` 的返回类型写 `CWKernel`。
##    **这个文件是产品代码里唯一持 `CWGame` 的地方**（`_game`）。
## ③ 规则代码一行不改：预设结果只写 `rolls`（带子 `cw_roll_tape.gd`），规则改动只写 `worlds.*.tuning`。
##
## **不带 `class_name`、调用方 `preload`**（同 `cw_world_loader.gd` / `cw_tutor_script.gd` 的理由：
## 补丁里新增的 `class_name` 认不出来，引导又是天天在改的东西）。
##
## 换 sidecar 那天要动的只有这一个文件：`adopt` 换成 `world_state` / `/restore`，
## UI 侧一个字都不改（它拿到的本来就是句柄）。
extends RefCounted

const DATA := preload("res://scripts/kernel/cw_tutor_script.gd")
const LOADER := preload("res://scripts/kernel/cw_world_loader.gd")
const TAPE := preload("res://scripts/kernel/cw_roll_tape.gd")

## 调用方的 `open()` 参数（`consumer` / `observe_viewer` / `autorun` / `decider` / `deciders` / `record_replay`）。
## 舞台只往里塞 `adopt` —— 收养那份对局的是它，`close()` 不 dispose、谁装配谁收摊（`cw_kernel_inproc.gd:102-114`）。
var cfg := {}
## 播放队列（`CWMatch._start_queue` 建的那一个）。`reload_world` 要按次序停它，见下面的四步。
var queue: CWPlayQueue = null

## 当前这一关的完整 JSON（`cw_tutor_script.load_level` 的产物）与正在跑的那份 world 的名字
var level := {}
var world_id := ""
## 这一局相对**关卡数据里写的坐标**已经累计平移了多少（`recenter` 每走一次就叠一次，S9a）。
## 零 = 没平移过。活跃格要跟着它走，否则遮罩与盘面错开一大截
var world_offset := Vector2i.ZERO
## 挂上去的带子（`rolls` 为空时也挂 —— 空带子 = 「这一关一次 rng 都不许消耗」的断言）
var tape = null
## 当前句柄。`reload_world` 与 `dispose` 都从它走
var kernel: CWKernel = null
## 装不出来时的原因（装载器的 `errors` 原样带出来）
var errors: PackedStringArray = []

## **产品代码里唯一的 CWGame 引用**（见文件头②）。收养给句柄，拆局由 `dispose()` 收摊
var _game: CWGame = null


## 开一关：`level` 是 `cw_tutor_script.load_level()` 读出来的那一份，`world_id` 指名用哪一份盘面。
## 装不出来返回 `null`（原因在 `errors` 里），调用方自己决定是回主菜单还是打日志。
func open_level(lv: Dictionary, wid := "base") -> CWKernel:
	level = lv
	world_offset = Vector2i.ZERO   ## 新的一关从关卡数据写的坐标起算
	return _open(wid)


## 关内换一份 world（第五关 Step2 的癌块扩大、第七关的击退 / 癌种切换 / 复活拨能量，方案 §1.4）。
##
## 它是 `CWMatch._advance_tutorial_chapter` 那条拆装序列的**短路版**：跳过「算关 / 换席位 / 重挂面板」三段，
## 次序一个字不能动 —— **`abort` 永远排在 `stop` 之前**（`match.gd` 的注释原文：只有 `abort()` 里的
## `_barrier_seq = 0` 能放掉正在等 ack 的那条 roll；先停队列就没人 ack，5 秒后内核报 barrier timeout）。
##
## 这里**不重挂引导面板**：重装不换桥（`decider` 还是 `cfg` 里那一个对象），
## 「换局会新建桥 ⇒ 必须重挂同一个 `_guide`」那个坑只在跨关换局那条路上（`match.gd:539-546`）。
func reload_world(wid: String) -> CWKernel:
	_teardown()
	return _open(wid)


## 间章分镜 2（PRD:395-397「地图以免疫细胞为中心向四周延伸，补齐缺失格子使其处于一个
## **完整棋盘的中央格**」，Kevin 2026-09-19 拍板走「重心平移」）。
##
## 不点名任何一份 world —— 装的是**此刻这一局自己**：
##   ① `dump_world` 把活局面导成一份 cwxworld/3（组织 / 固化 / 坏死 / 细胞 / 记忆 / 回合全在里头）；
##   ② 半径改成 `radius`（新盘子），再 `CWTutorScript.translate` 把每个坐标键平移 `delta`
##      （`delta = -P`，P = 锚点那只此刻那格 ⇒ 它落到 `(0,0)`）——**先改半径再平移**，
##      不然判界还按老半径走，平移到第 7 环的格会被当成出盘；
##   ③ 走关内换盘那条路（`reload_world` 的四步拆装），**不是跨关完整换局** ——
##      席位 / 面板 / 桥一律不动，间章是一段连续的演出。
##
## 新长出来的格是 `build_board` 铺的健康组织（装载器只改 spec 里点了名的格）。
## **cwxworld/3 装不下的运行期字段会丢**（`attacks_used` / `draws_used` / `mods` / `equipped` /
## `fx_turn` 等不在 CELL_KEYS 里的那些）—— 间章是强制演出、玩家不再操作，这一刀可以吃。
func reload_recentered(delta: Vector2i, radius: int) -> CWKernel:
	errors = PackedStringArray()
	if _game == null:
		errors.append("重心平移：此刻没有活着的对局可导出")
		return null
	var loader = LOADER.new()
	var spec: Dictionary = loader.dump_world(_game)
	if not loader.errors.is_empty():
		errors.append_array(loader.errors)
		return null
	_pin_specials(spec)          ## 必须在平移之前：这一步写的是**老**坐标上的器官
	spec["radius"] = radius
	var moved := DATA.translate(spec, delta)
	if not moved.is_empty():
		errors.append_array(moved)
		return null
	_fill_plain(spec, radius)
	_teardown()
	world_offset += delta
	return _open_spec(spec)


## 特殊组织（3 代谢核心 / 6 骨髓 / 2 血管）要**跟着世界一起搬**。
## `CWData.special_of` 是一张**绝对坐标**表，而 `dump_world` 按「与那张表一致就省略」写 `type`
## （装载器口径第 2 条）—— spec 里不显式写的话，装载器会拿**新**坐标去查那张表：
## 组织整体挪了位置、器官却钉在原地，真机上看着就是「器官瞬间换了位置」。
## 所以平移前给老盘**每一格**写死它此刻的 type（这一步之后 tiles 覆盖老盘全部格）。
func _pin_specials(spec: Dictionary) -> void:
	var tiles: Array = spec.get("tiles", [])
	var by_at := {}
	for t in tiles:
		by_at[str((t as Dictionary)["at"])] = t
	for c in CWData.all_coords(int(_game.board_radius)):
		var key := LOADER.at_text(c)
		var e: Dictionary = by_at.get(key, {})
		if e.is_empty():
			e = { "at": key }
			tiles.append(e)
		if not e.has("type"):
			e["type"] = LOADER._special_name(int((_game.tile(c) as Dictionary)["special"]))
	spec["tiles"] = tiles


## 平移之后四周空出来的那一圈：显式写成**普通**健康组织。
## 不写的话装载器照样按绝对坐标表往新格上铺器官 ⇒ 盘上会多出第二套核心 / 骨髓 / 血管
func _fill_plain(spec: Dictionary, radius: int) -> void:
	var tiles: Array = spec.get("tiles", [])
	var seen := {}
	for t in tiles:
		seen[str((t as Dictionary)["at"])] = true
	for c in CWData.all_coords(radius):
		var key := LOADER.at_text(c)
		if not seen.has(key):
			tiles.append({ "at": key, "type": "normal" })
	spec["tiles"] = tiles


## 收摊：收养模式的 `close()` 不 dispose，谁装配谁收摊 —— 不收的话模块↔对局、桥↔对局两个引用环每换一关漏一份。
func dispose() -> void:
	if _game != null:
		_game.dispose()
		_game = null
	kernel = null
	tape = null


## 这一关声明的活跃格（棋盘遮罩的唯一口径，方案 §1.3：小棋盘靠集合不靠半径）。
## **跟着 `world_offset` 一起平移**（S9a）：重心平移之后整份盘面挪了位置，
## 活跃集还停在关卡数据写的绝对坐标上的话，遮罩与盘面就错开一大截
func active_tiles() -> Array:
	var out: Array = []
	for c in coords_of(level.get("active_tiles", [])):
		out.append((c as Vector2i) + world_offset)
	return out


## `["q,r", …]` → `[Vector2i, …]`。数据侧的坐标写法只有这一种，解析也只有这一处
static func coords_of(list: Array) -> Array:
	var out: Array = []
	for s in list:
		out.append(DATA.parse_at(str(s)))
	return out


## `reload_world` / `reload_recentered` 共用的四步拆装。**次序一个字不能动**：
## `abort` 永远排在 `stop` 之前（只有 `abort()` 里的 `_barrier_seq = 0` 放得掉正在等 ack 的那条 roll）
func _teardown() -> void:
	if kernel != null:
		kernel.abort()
	if queue != null:
		queue.stop()
	if kernel != null:
		kernel.close()
	dispose()


func _open(wid: String) -> CWKernel:
	errors = PackedStringArray()
	world_id = wid
	var d = DATA.new()
	var spec: Dictionary = d.resolve(level, wid)
	if spec.is_empty():
		errors.append("关「%s」里没有名为「%s」的 world" % [str(level.get("id", "(无 id)")), wid])
		return null
	return _open_spec(spec)


## 一份现成的 cwxworld/3 → 一局（挂带子 → 收养 → 交句柄）。
## `_open`（按 world 名 resolve 出来的）与 `reload_recentered`（从活局面 dump 出来的）共用
func _open_spec(spec: Dictionary) -> CWKernel:
	var loader = LOADER.new()
	var g: CWGame = loader.load_world(spec)
	if g == null:
		errors.append_array(loader.errors)
		return null
	_point_cursor(g)

	## ★ 带子必须挂在 `open()` **之前**：`open()` 之后引擎随时可能掷第一颗骰，
	##   晚一步挂上去那一颗就走真 rng，整条带子当场错位（`cw_roll_tape.gd` 的 overrun 会静默回落）。
	var t = TAPE.new()
	t.tape = _rolls()
	if g.rng is RandomNumberGenerator:
		t.seed = int((g.rng as RandomNumberGenerator).seed)   ## 装载器的种子恒为 1；带子放完之后的兜底要接着它走
	g.rng = t
	tape = t
	_game = g

	var c := cfg.duplicate()
	c["adopt"] = g
	var k := CWKernelInProc.new()
	k.open(c)
	kernel = k
	return k


## 把行动游标对到 `seat` 那一席上（S9b）。
##
## cwxworld/3 的 `seat` 只写进 `g.current_pid`，而轮到谁实际上是
## `cw_game._advance_turn` 里的 `order[flow["i"]]` 说了算—— `flow["i"]` 装完恒为 0，
## 而 `order` 恒是 `[0, 1, 2, …]`，所以不补这一脚的话**永远是席 0 先行**，
## `seat: 1` 写了等于没写（真机上的表现：间章分镜 9 的巨噬根本不被问，
## 而玩家那一问挂在关死的闸上，演出当场停死）。
##
## **不改装载器**：它与 L0 / C# 对拍共用一张键表，L0 夹具里真有写着
## `seat: 2` 的世界，改掉就是两侧语义分叉。教程这一侧自己补：
## `current_pid > 0` 才动，而其余每一关的 world 写的都是 `seat: 0` ⇒ 行为一字不变。
##
## 顺带的语义：`current_pid == order[flow.i]` 之后 `_advance_turn` **不再走 `begin_turn`**
## —— `seat: N` 读成「正在 N 的回合中」，而不是「请开始 N 的回合」。
## 刚装出来的盘面里 `attacks_used` 本来就是 0，间章那三下不受影响
func _point_cursor(g: CWGame) -> void:
	if int(g.current_pid) <= 0 or int((g.flow as Dictionary).get("i", 0)) != 0:
		return
	var k: int = (g.order as Array).find(int(g.current_pid))
	if k > 0:
		g.flow["i"] = k


## 这一关的预设骰子（`cwtut/2` 的 `rolls`）。`[[from, to, value], …]`，与 `cwxcase/2` 的 `rolls` 同形。
## **`rolls: []` ≠ 省略**：空带子 = 「这一关一次 rng 都不许消耗」的断言（方案 §2.2）。
## **逐个转 int**：`JSON.parse_string` 把数字一律读成 float，带子的记账（`bad_range`）与调用方的比对
## 都按整数写的，留着 1.0 / 6.0 会让「这条带子对不对」变成浮点比较
func _rolls() -> Array:
	var out: Array = []
	for e in level.get("rolls", []):
		out.append([int((e as Array)[0]), int((e as Array)[1]), int((e as Array)[2])])
	return out
