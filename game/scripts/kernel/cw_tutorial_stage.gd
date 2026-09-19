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
	if kernel != null:
		kernel.abort()
	if queue != null:
		queue.stop()
	if kernel != null:
		kernel.close()
	dispose()
	return _open(wid)


## 收摊：收养模式的 `close()` 不 dispose，谁装配谁收摊 —— 不收的话模块↔对局、桥↔对局两个引用环每换一关漏一份。
func dispose() -> void:
	if _game != null:
		_game.dispose()
		_game = null
	kernel = null
	tape = null


## 这一关声明的活跃格（棋盘遮罩的唯一口径，方案 §1.3：半径恒 6，小棋盘靠集合不靠半径）
func active_tiles() -> Array:
	return coords_of(level.get("active_tiles", []))


## `["q,r", …]` → `[Vector2i, …]`。数据侧的坐标写法只有这一种，解析也只有这一处
static func coords_of(list: Array) -> Array:
	var out: Array = []
	for s in list:
		out.append(DATA.parse_at(str(s)))
	return out


func _open(wid: String) -> CWKernel:
	errors = PackedStringArray()
	world_id = wid
	var d = DATA.new()
	var spec: Dictionary = d.resolve(level, wid)
	if spec.is_empty():
		errors.append("关「%s」里没有名为「%s」的 world" % [str(level.get("id", "(无 id)")), wid])
		return null
	var loader = LOADER.new()
	var g: CWGame = loader.load_world(spec)
	if g == null:
		errors.append_array(loader.errors)
		return null

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


## 这一关的预设骰子（`cwtut/2` 的 `rolls`）。`[[from, to, value], …]`，与 `cwxcase/2` 的 `rolls` 同形。
## **`rolls: []` ≠ 省略**：空带子 = 「这一关一次 rng 都不许消耗」的断言（方案 §2.2）。
## **逐个转 int**：`JSON.parse_string` 把数字一律读成 float，带子的记账（`bad_range`）与调用方的比对
## 都按整数写的，留着 1.0 / 6.0 会让「这条带子对不对」变成浮点比较
func _rolls() -> Array:
	var out: Array = []
	for e in level.get("rolls", []):
		out.append([int((e as Array)[0]), int((e as Array)[1]), int((e as Array)[2])])
	return out
