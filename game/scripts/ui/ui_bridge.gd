## ui_bridge.gd —— 表现层的询问桥：人类玩家的界面 + 掷骰演出
##
## **为什么继承 AI 桥而不是 CWBridge。** 一局里通常只有部分位置是人，
## 其余仍要 AI 来下。让同一个桥对象兼任两者有三个好处：
##
## ① 掷骰演出只需要注册一次 —— `CWGame.roll_shown()` 会把演出广播给所有桥、
##    并按**对象**去重，所以「一个对象注册给全部玩家」正好演一遍，
##    「人类看得见 AI 掷的骰」这件事自然成立，不用另设一个旁观者桥。
## ② 没装界面时（无头测试、平衡模拟）整个退回 AI，对局照跑。
## ③ 一个人都没有时（human_pids 为空）就是一局带演出的 AI 互搏，可以直接看。
##
## 基类是**蒙特卡洛桥**（它自己又继承启发式）：`enabled` 就是对局配置面板的
## 「AI 强度」开关 —— 关着（默认）AI 走启发式，拨到「较强」AI 逐候选推演。
## 推演期间引擎的 bridges 会被临时换成同步代打，本桥不会在推演里被问到。
##
## 演出**无权决定结果**：value 是引擎先用 game.rng 掷好再传进来的（架构约定 #11）。
##
## **批 1 步 6+8（2026-09-19）：本桥成了内核的 decider。** 界面这一半再也不读 `CWGame` ——
## 盘面读 `mirror`（CWMirror，每问一份），规则算 `kernel.query()` 四条（决策 9：UI 不许自己算规则），
## 演出由 `CWPlayQueue` 按条目顺序喂进下面的 `show_*`。`game` 字段还留着，但**只给基类那几档 AI 推演用**，
## 由 `attach_engine()` 一处赋值（拍板 E-2 (a)：不拆 AI 继承）。
class_name CWUIBridge
extends CWMonteCarloBridge

var board: Node2D          ## 取格子像素位置、收点选事件都只问它（架构约定 #10）
var dice: CWDice
var bar: CWActionBar
var info: CWCardInfo   ## 悬停详情框：分化提问里停在种类按钮上时浮细胞种类详情；纯 AI 桥 / 测试里可为 null
var panel: CWMatchPanel
var toast: CWToast     ## 骰子旁边那行字

## ---- 批 1 步 6+8：盘面读镜像、规则问句柄 ----
## 当前这一份观测（条目流里的 sync 落地后就是新的一份），由 CWMatch 每帧赋。
## **一切「读盘面」都走它**；一切「算规则」都走下面的 kernel（决策 9）。
var mirror: CWMirror
## 内核句柄：四条纯查询（plan_next_dests / quote_path / cost_effects_for / move_block_reason）的唯一出口。
## InProc 同步就有答案；Remote 是 RPC + 按 rev 缓存，**第一次问必然返回 null** ——
## 所以每一处调用都要有「拿不到就不显示」的那一支，绝不许拿旧值或自己算一个顶上。
var kernel: CWKernel
## 条目播放器。只用来做一件事：出询问界面之前先等这一步的演出播完、盘面落地（见 _await_playback）。
var queue: CWPlayQueue
## 这一局是不是已经被放弃了。**不能用 mirror.aborted 代替** —— 镜像是「问人之前」那一份快照，
## 而换手遮罩 / _prompt 一等就是几十秒，拆局发生在那之后，快照上永远写着 false（规格 A-5.4）。
var _aborted := false
## 回放：录下来的下标串。非空 = 这一局是在放回放，`ask()` 按顺序念、谁也不问。
## 游标由 `CWReplay.Player` 拨（快退时会被拨回去），所以**别在这儿另存一份进度**。
var replay_answers: PackedInt32Array = []
var replay_at := 0

var hunt_fx: CWHuntFx
var mucus_fx: CWMucusFx
var seal_fx: CWSealFx
var beam_fx: CWBeamFx
var chain_fx: CWChainFx
var skill_fx: CWSkillFx   ## 一次性技能演出的合集（issue #15）
var attack_animation: Callable
var camera: Camera2D   ## 棋盘坐标 → 屏幕坐标要用它（提示挂在 CanvasLayer 上）
var erosion: CWErosionFx   ## 癌蔓延两帧过场（侵蚀 / 增生 / 定殖共用）；纯 AI 桥 / 测试里可为 null
var hand: CWHand       ## 手牌抽屉：方案甲的打出/弃置手势从这里来（无界面时为 null）
## 正在选迁移目标时，每一格的耗能（坐标 → 十分能量）。空 = 此刻不在迁移态。
## 由 `_pick_move` 从引擎算好的选项里抄来，`CWMatch` 每帧喂给悬停格子详情。
## **这里只是转手，不做任何计算**——价钱是规则，规则在引擎（架构约定 #11）。
var move_costs := {}
var move_verb := ""    ## 「迁移」还是「移动」：规则里免疫癌症用两个词，不能混用
var human_pids: Array[int] = []
## 热座（本地多人，2026-09-05）：>= 2 位真人共用一台电脑。换手遮罩由 CWMatch 注入；无界面 / 测试时为 null。
## current_human = 上一位「露过牌」的真人（遮罩确认过的那一席）；-1 = 此刻没人在看 ——
## CWMatch 每帧读它决定手牌抽屉给谁看、日志面板按谁的视角过滤。
var handoff: CWHandoff
var hotseat := false
var current_human := -1

## 开场绽开还没演完时，人类的询问界面先不出来 ——
## 团队定的三拍开场里，第三拍才把控制权交还玩家（CWMatch 演完后置回 false）。
var opening := false

## 本桥希望棋盘上高亮哪些格子：{ 轴坐标: 颜色 }。
## 由 CWMatch 每帧读走、和「组织状态色标」合并后一起交给 board.set_marks()。
## 做成「桥单向暴露、对局去读」而不是桥直接改棋盘，是为了不让两处各自往
## set_marks() 里写、互相把对方擦掉。
var marks := {}

## 紧跟骰子的结算说明（攻击 / 突变 / 抗体的结果文字）停多久。1.1 → 2.4（Kevin 2026-09-06：结果文字停久些，
## **骰子本身的演出不动** —— 那是 CWDice.play 的节拍，这里碰不到）。停久了就各自一只气泡，连着两次攻击才不会互相顶掉
const RESULT_HOLD := 2.4
## 不是紧跟骰子的说明（事件卡效果、复活失败、次数用尽……）停多久：各自一只气泡（CWToast.bubble_at），互不顶掉
const TEXT_HOLD := 4.0

## 行动栏按钮上的技能名。**费用一律现从 CWData 读，这里不写第二份数字**。
## 表本体 2026-09-04 挪进 `CWData.ACT_NAMES`（右栏固定详情也要用同一份），这里只留别名。
const ACT_TITLE := CWData.ACT_NAMES

var _tiles := {}       ## 当前这一问里，哪些格子可点 → 点了返回什么
var _enemy := -1       ## 当前提问者的敌对阵营，用来把「攻击格」标成橙色
## 「迁移」是**切换式**的：走完一步继续停在选目标格上，不必每步都重点一次按钮
## （团队 2026-08-27 要求）。退出条件只有三个：右键/Esc、能量不够没有可达格、换人。
var _sticky_move := false
var _sticky_pid := -1    ## 上面那个开关属于谁
var _sticky_round := -1  ## 属于哪个世界回合。**换人或换回合都作废** ——
                         ## 一个人每个世界回合只行动一次，所以「新回合」就是「这人的下一个回合」，
                         ## 不清掉的话新回合一开始就莫名其妙直接进了选目标格（团队反馈）
var _pending: Answer   ## 正卡在「等玩家作答」上的那一次询问
## 第三档「树搜索」/ 第四档「意图」的代打桥（CWMCTSBridge / MechBridge）。null = 不是这两档。
## 它与本类的基类（扁平 MC）**并列**，所以只能挂着用，不能继承。
## 泛化成 CWBridge：MCTS 与 Mech 都只认 game + ask（2026-09-20，原是 mcts: CWMCTSBridge）。
var ai_bridge: CWBridge = null

## ---- 路径规划器（2026-09-04 Kevin 要的）----
## 只在「选迁移目标」这一问里活着。规划态下棋盘的点击不再直接作答，
## 而是拖出一条路；账由引擎 `CWActions.quote_path()` 算（价钱逐步变，界面算不对，见那边头注）。
var _plan: Array[Vector2i] = []   ## 依次要落脚的格（不含起点）
## 规划器有没有句柄可问。联机（E-1 (a)，Kevin 2026-09-19 拍）走 query RPC + 按 rev 缓存：`kernel.query` 第一次问只发 RPC、当场返回 null，
## 报价 / 可达 / 灰格理由在下一份 `query_result` 到了之后由 `plan_tick()`（CWMatch._process 每帧调）补画 ——
## 线条立即画、价签回来再填（规格 D-9），提示行在那之前写「报价中…」，不会拖出一条按空报价配色的线。
var _plan_ok := false
var _plan_cell := {}              ## 正在规划的那只细胞（plan_tick 补画要用）
var _plan_pending := false        ## 上一次 query 还没回来（联机）
var _plan_want: Variant = null    ## 拖到了这一格但可达表还没回来：回来后补接（Vector2i / null）
var _block_want: Variant = null   ## 点了一个走不通的格、理由还没回来：回来后补弹（Vector2i / null）
var _planning := false            ## 规划器开着吗
var _plan_drag := false           ## 正按着左键拖
var _plan_quote := {}             ## 上一次的报价，给按钮文字和路径配色用


func _init() -> void:
	enabled = false   ## 人机默认普通 AI；「较强」由对局配置面板拨（CWMatch.ai_level）


## 一次交互的应答口。
## GDScript 的 await 只能等**一个**信号，而这里要同时等「点了棋盘上的格子」
## 和「点了行动栏的按钮」两路，所以两路都汇到这里的 done 上，谁先来算谁。
class Answer:
	extends RefCounted
	signal done(value: Variant)
	var _fired := false
	func fire(value: Variant) -> void:
		if _fired:
			return      ## 一次交互只认第一个答案
		_fired = true
		done.emit(value)


## 中途放弃这一局（返回主菜单）：把卡住的那次询问唤醒，好让 _prompt() 把信号断干净。
##
## 不这么做的话，`board.tile_hovered` 上会一直挂着那次询问的处理函数；
## 对局释放之后鼠标往棋盘上一动，它就去调用已经置空的 game ——
## **debug 模式下 Godot 会直接断在调试器里，表现就是「游戏卡死」**
## （2026-08-27 团队试玩报的就是这个）。
## 引擎那边由 CWGame.aborted 收摊，两边配合才能安全展开。
func abort() -> void:
	_aborted = true
	_clear_ui()
	if handoff != null:
		handoff.hide_now()   ## 遮罩期间拆局：放掉等在 pass_to 上的那次询问
	if _pending != null:
		var p := _pending
		_pending = null
		p.fire(null)


## 这一问被**别人**答掉了（服务器代打接管，issue #44）：像 abort() 那样收掉界面，
## 另外再把迁移那两样**跨问留存**的状态一起作废 ——
## · `_sticky_move`「上一步选的是迁移」：留着的话，下一问会直接跳回选目标态，
##   而代打刚刚替我走的多半是别的一步，玩家对着一屏高亮格不知道自己在选什么；
## · `_plan` 规划好的路线：留着的话 `_pick_move` 开头那句 `_plan_take_step` 会**不问自答**，
##   照着一条按旧盘面算出来的路继续走。
## abort() 自己不清这两样是对的：每一次新询问（含迁移的每一步）都要经过它，清了迁移就不再是切换式的。
func taken_over() -> void:
	_sticky_move = false
	_sticky_pid = -1
	_sticky_round = -1
	_plan_reset()
	move_costs.clear()
	abort()


## 该不该先弹换手遮罩：热座、且这次被问的真人不是上一位露过牌的真人（第一问时 current_human = -1，也弹 —— 宣布谁先手）。
## 同一人连续被问（复活选点、抽卡中途选择、迁移的多步）不弹；AI 席位不经此路。static 供测试直接核对。
static func needs_handoff(p_hotseat: bool, p_current_human: int, pid: int) -> bool:
	return p_hotseat and pid != p_current_human


## AI 拿真引擎的**唯一**口子（拍板 E-2 (a)：本桥同时是 AI 桥，不拆继承）。
## `CWKernelInProc.open()` 对每个 decider 试调这个鸭子方法，没有的（纯 AI 桥）才退回 `d.game = g`。
## 界面那一半**一个字也不读它**；留着只是为了基类的扁平 MC 与挂在旁边的 MCTS 还能推演（批 2 欠账）。
## 形参**故意不标类型**：标上 `CWGame` 就把引擎类名写回了 `game/scripts/ui/`，结构闸 `t_no_engine_in_ui` 当场红。
func attach_engine(g) -> void:   ## KERNEL-ENGINE-OK
	game = g
	if ai_bridge != null:
		ai_bridge.game = g


func ask(req: Dictionary) -> int:
	_aborted = false   ## 新的一问：上一次 abort() 的余波不该把这一问当场打掉
	## **回放**：按顺序念录下来的下标，谁也不问。
	##
	## 为什么让界面桥来念、而不是直接用 `CWReplay.Bridge`：掷骰演出、通报、过场
	## **全都是走桥的**（`show_roll` / `show_result` / `show_erosion` …），
	## 换成纯数据桥的话回放就成了一局没有任何演出的哑剧。
	## `CWReplay.Bridge` 留给无头那条路（测试、核对哈希），它不需要演出。
	if not replay_answers.is_empty():
		var i: int = replay_answers[replay_at] if replay_at < replay_answers.size() else 0
		replay_at += 1
		return i
	if req["pid"] in human_pids and bar != null and board != null:
		return await _ask_human(req)
	_clear_ui()   ## 轮到别人：按钮和高亮一起收掉（定稿如此）
	## 第三/四档「树搜索/意图」：转给挂在这儿的桥（CWMatch._wire_bridge 装的）。
	## 走组合而不是继承 —— 见那边的注释。挂着就整条 AI 路由都归它，
	## 包括非顶层询问（它自己回落到启发式），免得两只桥各答一半、行为拼不齐。
	if ai_bridge != null:
		return await ai_bridge.ask(req)
	return await super.ask(req)


func _ask_human(req: Dictionary) -> int:
	while opening and board != null and board.is_inside_tree():
		await board.get_tree().process_frame
	await _await_playback()
	if mirror == null:
		return 0                           ## 一份观测都还没到（拆局 / 句柄没起来）：引擎那边已在收摊
	## 热座换手：先把电脑交出去（遮罩），玩家点「开始回合」才出询问界面。
	## 换手期间 current_human = -1：CWMatch 据此收起手牌抽屉、日志切到无人视角。
	if handoff != null and needs_handoff(hotseat, current_human, req["pid"]):
		current_human = -1
		var pid: int = req["pid"]
		var at: Vector2i = CWHandoff.INVALID
		if pid < mirror.cells.size() and mirror.cell_of(pid)["alive"]:
			at = mirror.cell_of(pid)["pos"]   ## 开局布置阶段还没有细胞：光环不画
		await handoff.pass_to(pid, mirror.player(pid)["faction"], mirror.player(pid)["name"], at)
		if _aborted:
			return 0                       ## 遮罩期间拆局了：随便答一个，引擎那边已在收摊
		current_human = pid
	_enemy = CWData.Faction.CANCER if mirror.player(req["pid"])["faction"] \
		== CWData.Faction.IMMUNE else CWData.Faction.IMMUNE
	var picked: int
	if req["kind"] == "action":
		picked = await _ask_action(req)
	else:
		picked = await _ask_generic(req)
	_clear_ui()
	return picked


## 出询问界面之前，先等这一步的演出播完、这一问的那份 sync 落地。
##
## **为什么必须有它**：`CWKernelInProc._on_ask` 是「推 step_end + sync → 当场转交 decider」，
## 而条目是播放队列**异步**消费的。不等的话玩家会看到「行动栏已经属于新的一问、棋盘还停在上一步」——
## 价签、高亮格、可达格全取自过期的那一份镜像。拍板 2 说的「一步的 sync 在这一步的演出播完之后落地」，
## 消费侧的另一半就在这儿。
## 这个循环一定走得完：引擎此刻正卡在本函数上游的 await 里，队列只出不进。
## 没有队列 / 没有界面（无头测试、纯 AI 局、回放直放）直接返回。
func _await_playback() -> void:
	if queue == null or kernel == null or board == null or not board.is_inside_tree():
		return
	while queue != null and kernel != null and queue.running and not _aborted and queue.since < kernel.entry_seq():   ## 拆局会在等待中把 queue 置空
		await board.get_tree().process_frame


# ============ 「选行动」：两段式 ============
# 定稿的行动栏里「迁移」也是一个按钮，点了它才高亮可达格、再点格子确认。
# 引擎那边每个相邻格是一个独立选项，所以这里要把它们合成一个按钮，
# 选完格子再还原成对应的那个选项下标。

func _ask_action(req: Dictionary) -> int:
	var options: Array = req["options"]
	var pid: int = req["pid"]
	## **取一次就够**：整段 while 都跑在引擎 `ask()` 的 await 里，引擎挂着，这一份镜像不会再变（规格 §0.4 #13）
	var cell: Dictionary = mirror.cell_of(pid)
	if pid != _sticky_pid or mirror.round_no != _sticky_round:
		_sticky_pid = pid
		_sticky_round = mirror.round_no
		_sticky_move = false
	var moves: Array = []
	for i in options.size():
		if options[i]["data"]["act"] == "move":
			moves.append(i)
	if moves.is_empty():
		_sticky_move = false        ## 能量不够、一格也去不了，自己退回按钮栏
	while not _aborted:
		## 上一步选的就是迁移 → 直接回到选目标格，不再经过按钮栏
		if _sticky_move:
			var again: Variant = await _pick_move(cell, options, moves)
			if again == null:
				return 0            ## 这一局被中途放弃了（返回主菜单）
			if not (again is String):
				return again as int
			_sticky_move = false    ## 右键 / Esc / 「结束迁移」
			continue
		## **按钮不消失，只变暗**（团队 2026-08-28 定）。
		## 按钮集合来自 `CWActions.action_kinds()`（只看细胞种类和免疫等级），
		## 而不是来自当前合法选项 —— 否则花掉能量会让按钮凭空少一个，
		## 行动栏宽度跟着跳，连数字快捷键的编号都会变。
		var groups := {}
		var end_value: Variant = null
		for i in options.size():
			var a: String = options[i]["data"]["act"]
			if a == "end":
				end_value = i      ## 有右侧竖条时挪去面板底部，没有时下面补一个按钮
				continue
			if not groups.has(a):
				groups[a] = []
			groups[a].append(i)
		var buttons: Array = []
		var values: Array = []
		## 按钮集合与**顺序**由镜像给（tier B 的 cell.d.action_kinds）；这一档缺席就返回空数组 —— 只剩「结束回合」，不崩
		var kinds: Array = mirror.action_kinds_of(cell)
		## 「当前影响」一次批量问完（B-1 ④ 的 acts 形参）：一枚一枚问的话，联机那条就是八个 RPC 往返
		var effects_of := _cost_effects_batch(cell, kinds)
		var q := func(_qkind: String, args: Dictionary) -> Variant:
			return effects_of.get(String(args.get("act", "")), [])
		for act in kinds:
			var live: bool = groups.has(act)
			## 教程局把卡牌与【基因表达】整个关掉（方案 Q-18：`ui.hand=false` + 盘面 `hand: []`）——
			## 那几关连按钮都**不建**。正式局的「按钮不消失、只变暗」是为了「花掉能量不会让按钮
			## 凭空少一个」，而教程第一关压根没有能量这回事，灰着的那一颗只会把新手引过去点
			## （PRD:51 / 通用规则 9；09-19 真机截图抓到的）。`hand` 默认为真 ⇒ 非教程局读到的和今天一模一样
			if act == "draw" and not CWTutorLayers.on("hand"):
				continue
			buttons.append({
				"title": _move_title(cell) if act == "move" else ACT_TITLE.get(act, act),
				## **「移动 / 迁移」不带价签**（Kevin 2026-09-08）：它的价随目的地变，
				## 原来把所有档位列成「0.2 / 0.3 / 0.5 / 0.7 / 1.2」——五档之后这一枚按钮
				## 宽到把最后一个技能挤出屏幕，而那串数字玩家还对不上是哪一格。
				## 每一格实际要多少，悬停那一格的详情框里写着（CWTileInfo 的「迁移耗能」行）——
				## 那里才对得上「这一步值不值」，比按钮上一串无主的数字有用。
				"cost": "" if act == "move" else _cost_text(cell, act),
				"disabled": not live,
				## 悬停这枚按钮时浮出的 PRD 原文（2026-09-04 Kevin 要的「技能栏显示详细作用」）。
				## **灰掉的按钮也带** —— 想知道「这技能是干嘛的、我为什么用不了」正是那会儿最想问的
				"info": CWCardInfo.describe_act_for(q, cell, act),
			})
			values.append(act if live else "")
		## 没有右侧竖条时（纯行动栏形态），「结束回合」退回按钮栏占一格
		if panel == null and end_value != null:
			buttons.append({ "title": ACT_TITLE["end"], "cost": "" })
			values.append(end_value)
			end_value = null
		var got: Variant = await _prompt("", "", buttons, values, {}, end_value, -1, true)
		## 方案甲（团队 2026-08-29 定）：点手牌打出 / 右键弃置；中途点别的卡就换卡
		while got is Array:
			got = await _pick_hand(options, got)
		if got == null:
			return 0
		if not (got is String):
			return got as int          ## 「结束回合」或手牌流程选定的下标
		var act: String = got as String
		if act == "" or act == "cancel":
			continue               ## 灰按钮兜底 / 从手牌流程退回按钮栏
		if act == "move":
			_sticky_move = true
			continue
		## 只有一种打法时**要选格的才问**（issue #14，HXR-I 2026-09-10）：小细胞只剩一个可跃进的方向时，
		## 点「转移」不该当场跳过去 —— 玩家得看清跳去哪、还能反悔（第二段那一屏才带「取消 · 右键 / Esc」）。
		## **不用选格的**单打法（抽卡、突变、大招、只剩一种的分化…）直接执行，和 #14 之前一样 ——
		## 09-10 曾把整条「单打法直接执行」去掉，于是这些也进了第二段追问，按钮上还是一串 JSON
		## （Kevin 2026-09-11 截图：点【基因表达】跳出 `{ "act": "draw" }`）。
		var picks: Array = groups[act]
		if picks.size() == 1 and not confirm_single(options[picks[0]]["data"]):
			return picks[0] as int
		## 多种打法（分化选种类、裂解要不要顺带净化、血行转移/跃进选落点）→ 第二段
		var sub: Variant = await _pick_sub(act, options, picks)
		if sub == null:
			return 0
		if sub is String:
			continue                   ## 退出子选择，回到按钮栏
		return sub as int
	return 0                        ## 放弃这一局时从 while 条件退出来


## 手牌手势（方案甲，团队 2026-08-29 定；2026-09-01 改成全双击）。
## gesture = ["play" 或 "discard", 卡名]。
## 打出：有目标 → 棋盘点选（cid 目标高亮其所在格，敌橙友青沿用现有标记色）；
##       无目标 → 直接打出。
## 弃置：直接弃。
## **两条路都不再有确认条**：防误触已经由「必须双击」承担，
## 原先的确认拍（定案③打出 / 定案②弃置）是给单击配的，随单击一起去掉。
## 打不出的卡（效果未实现 / 此刻不可用）给出解释，并允许就地弃置腾位。
## 返回：选项下标；"cancel" 回按钮栏；Array = 中途改点了另一张卡；null = 放弃对局。
func _pick_hand(options: Array, gesture: Array) -> Variant:
	var card: String = gesture[1]
	var discard_i := -1
	var plays: Array = []
	for i in options.size():
		var d: Dictionary = options[i]["data"]
		if d.get("card", "") != card:
			continue
		if d["act"] == "discard":
			discard_i = i
		elif d["act"] == "play":
			plays.append(i)
	if hand != null:
		hand.set_selected(card)
	## 标题一律用短语，卡名放进副标题行——底条要给手牌区让位（HAND_INSET），
	## 剩下的宽度装不下「选择【九字卡名】的目标」这种长标题（试玩第一轮的重叠教训）
	var got: Variant
	if gesture[0] == "discard":
		## 直接弃，不再补确认条（团队 2026-09-01）：右键双击已经是强意图。
		## 误触的口子被两道东西堵着——要双击，而且只在主按钮栏那一问才算弃置。
		got = "cancel" if discard_i < 0 else discard_i   ## <0：这张此刻不能弃（正常流程到不了）
	elif plays.is_empty():
		var buttons: Array = []
		var values: Array = []
		if discard_i >= 0:
			buttons.append({ "title": "弃置它", "cost": "" })
			## 走和右键弃置**同一条路**（试玩第四轮要求）——那条路 2026-09-01 起是直接弃，
			## 所以这里也变成直接弃了。值是一个手势 Array，外层循环会把它当
			## 「又点了一次手牌」重新分派；这里已经是玩家的第二次确认，不欠一拍。
			values.append(["discard", card])
		buttons.append({ "title": "返回", "cost": "右键 / Esc" })
		values.append("cancel")
		got = await _prompt("还打不出", "【%s】%s" % [card, _unplayable_why(card)],
			buttons, values, {}, null, values.size() - 1, true, HAND_INSET)
	else:
		var tiles := {}
		for i in plays:
			var d: Dictionary = options[i]["data"]
			if d.has("to"):
				tiles[d["to"]] = i
			elif d.has("cid"):
				tiles[mirror.cells[int(d["cid"])]["pos"]] = i
		if tiles.is_empty():
			## 无目标卡直接打出。「确认打出」那一拍（定案③）**随单击一起取消了**：
			## 它防的是单击误触，而现在单击根本不发信号，留着就成了双重收费。
			got = plays[0]
		else:
			got = await _prompt("选择目标", "打出【%s】· 高亮 %d 格可选 · 右键或 Esc 退出" % [card, tiles.size()],
				[{ "title": "取消", "cost": "右键 / Esc" }], ["cancel"], tiles, null, 0, true, HAND_INSET)
	if hand != null:
		hand.set_selected("")
	return got


## 建行动栏时一次问完所有技能的「当前影响」：{ act: effects[] }。
## InProc 同步就有；Remote 第一次问只发出 RPC、当场返回 null —— 那一帧详情框写「当前影响：无」，
## **不写一个凑出来的数**，结果随下一次建栏从缓存补上（规格 A-5.1 / E-1 (a)）。
func _cost_effects_batch(cell: Dictionary, acts: Array) -> Dictionary:
	if kernel == null or acts.is_empty():
		return {}
	var got: Variant = kernel.query("cost_effects_for", { "cid": int(cell["id"]), "acts": acts })
	return got if got is Dictionary else {}


## 手牌几问的底条左侧让位宽度 = 手牌区的横向占位（LEFT + SPAN）。
## 卡再多（8 张压叠后右缘 312）、悬停抬起也到不了这条线右边。
const HAND_INSET := CWHand.LEFT + CWHand.SPAN


## 这张卡为什么打不出：66 张效果都实现了，走到这里只剩「此刻不可用」
## （带目标的卡没有合法目标、TNF 范围内没东西之类）
func _unplayable_why(_card: String) -> String:
	return "此刻不可用（没有合法目标）；可先弃置腾位"



## 技能的第二段：同一个 act 有多个选项时，让玩家挑一个。
##
## 为什么会有第二段：引擎那边为了让 AI 能把一个行动当成原子来推演，
## 把「分化成哪种」「裂解要不要顺带净化」「转移到哪一格」全摊成了顶层选项。
## 行动栏容不下那么多按钮，所以界面这边再把它们收回一个按钮 + 一次追问 ——
## 和「迁移」的两段式是同一套语汇。
##
## 带 `to` 的走棋盘点选，其余走按钮栏。返回选项下标；退出返回 "cancel"；放弃对局返回 null。
func _pick_sub(act: String, options: Array, picks: Array) -> Variant:
	var title: String = ACT_TITLE.get(act, act)
	var tiles := {}
	var buttons: Array = []
	var values: Array = []
	for i in picks:
		var data: Dictionary = options[i]["data"]
		if data.has("to"):
			tiles[data["to"]] = i
		else:
			buttons.append(_sub_entry(act, options[i]))
			values.append(i)
	buttons.append({ "title": "取消", "cost": "右键 / Esc" })
	values.append("cancel")
	var hint := "" if tiles.is_empty() else "高亮 %d 格可选 · 右键或 Esc 退出" % tiles.size()
	return await _prompt("选择%s的目标" % title, hint, buttons, values, tiles,
		null, buttons.size() - 1)


## 单打法要不要先问一声：带 `to` = 要在棋盘上选（看清落点、能反悔）→ 问；其余直接执行。**纯函数**。
static func confirm_single(data: Dictionary) -> bool:
	return data.has("to")


## 子选项的按钮条目：{ title, cost[, info] }。分化的条目带 info = 该细胞种类的详情（PRD 原文），
## 鼠标停上去时由 _prompt 转给详情框（2026-09-03 Kevin 要的「分化时悬停显示细胞详情」）
func _sub_entry(act: String, opt: Dictionary) -> Dictionary:
	var entry := { "title": _sub_label(act, opt), "cost": "" }
	if act == "differentiate":
		entry["info"] = CWCardInfo.describe_type(opt["data"]["type"])
	return entry


## 子选项的按钮标题。分化给种类名，其余退回**引擎给的 label**
## （从前兜底是 `str(data)`，那条路 #14 之前根本走不到，一走到就是一串 JSON 打在按钮上）。**纯函数**。
##
## 2026-09-19 批 1 步 8：裂解那一支读的 `data["purge"]` 删了 —— 全仓只此一行、`game/scripts/core/` 从来
## 没往选项里写过这个键，真走到就是当场 KeyError。裂解现在和别的技能一样吃 label（批 0 规格 §F#10 已授权）。
static func _sub_label(act: String, opt: Dictionary) -> String:
	var data: Dictionary = opt.get("data", {})
	match act:
		"differentiate":
			return CWData.IMMUNE_TYPE_NAMES[data["type"]]
	var label := String(opt.get("label", ""))
	if label != "":
		return label
	## 连 label 都没有（不该发生）：退到动作名，再退到 act 键 —— 反正不打字典
	var act_key := String(data.get("act", ""))
	return String(ACT_TITLE.get(act_key, act_key if act_key != "" else "？"))


## 目标选择态：高亮可达格，等玩家点一格或退出。
## 返回格子对应的选项下标；退出则返回 "cancel"；对局被放弃返回 null。
func _pick_move(cell: Dictionary, options: Array, moves: Array) -> Variant:
	var tiles := {}
	for i in moves:
		tiles[options[i]["data"]["to"]] = i
	var verb := _move_title(cell)
	## 每格多少钱**直接抄选项里引擎算好的 `cost`**，不在表现层重算一遍
	## （架构约定 #11）。悬停格子详情靠它显示耗能——尤其是穿过友军那种
	## 「收两格之和」的走法，不给数字玩家根本推不出来为什么这格贵一倍。
	move_costs.clear()
	## 教程的 `ui_layers.cost = false`（PRD:107/151/197「迁移不显示消耗」）：价目表整张不填 ——
	## 悬停详情那行「迁移耗能 x」是从这张表来的（`tile_info.gd:87`），空表 = 那一行不出现。正式局照常填
	if CWTutorLayers.on("cost"):
		for i in moves:
			move_costs[options[i]["data"]["to"]] = int(options[i]["data"]["cost"])
	move_verb = verb
	## 规划器交出来的路还没走完 → 接着走下一步，不再问。
	## 每一步都在这里重新查一次当前选项：中途盘面变了（联机、卡牌效果）就走不成，
	## 那时说明原因、回到普通选目标态，而不是按旧价钱硬走
	if not _plan.is_empty():
		var step: Variant = _plan_take_step(options, moves)
		if step != null:
			move_costs.clear()
			return step
	## 规划器开关只在这一问**内部**切换：它不是答案，点了不该把这一问结束掉
	## （上一版直接 `ans.fire("plan_on")`，于是一点「规划路径」就退出了迁移态）
	_planning = false
	_plan_drag = false
	## 规划器整体由**能力位**开关（规格 A-5.1）：句柄不能同步回答纯查询（联机那条）时整个不进规划态，
	## 按钮与提示行一起不出现 —— 降级要**看得见**，不能让玩家拖出一条按空报价配色的线
	## 教程的 `ui_layers.move_path = false`（PRD:107/151/197「迁移不显示路径」）：
	## 直接走已有的那条**降级可见**的路 —— 规划按钮与提示行一起不出现、拖不出线，一处开关两处生效
	_plan_ok = kernel != null and CWTutorLayers.on("move_path")   ## 联机也开：同步答不了的那几帧由 plan_tick 补画（E-1 (a)）
	_plan_cell = cell
	while not _aborted:
		var got: Variant = await _prompt("选择要%s到的组织" % verb, _plan_hint(cell, tiles.size()),
			_move_buttons(cell, verb), _move_values(), tiles, null,
			_move_buttons(cell, verb).size() - 1,
			true, 0.0, func(c: Vector2i) -> String: return _move_block_reason(cell, c), true)
		## 选目标态下手牌照样能打 / 弃（Kevin 2026-09-06）：手势走和主按钮栏同一条路（_pick_hand）。
		## 打出去的卡由引擎结算后重新询问，_sticky_move 还开着，于是自动回到选目标态（迁移是切换式的）；
		## 从卡的流程退回（"cancel"）则留在选目标态，不算「结束迁移」。规划中的路线作废——盘面可能已经变了
		if got is Array:
			while got is Array:
				got = await _pick_hand(options, got)
			if got == null:
				break
			if got is String:
				continue
			move_costs.clear()
			_plan_reset()
			return got
		if got is String and got == "plan_on":
			_planning = true
			continue
		if got is String and got == "plan_off":
			_plan.clear()
			_plan_quote = {}
			_planning = false
			_plan_drag = false
			continue
		## 这一问结束就把价目表收掉：留着的话，退出迁移后悬停还会显示上一轮的价钱
		move_costs.clear()
		## 「按此路径走」：交出**第一步**作为答案，余下几步留在 `_plan` 里，
		## 由「迁移是切换式的」那条既有逻辑把这一问再问回来（见本函数开头）
		if got is String and got == "plan_go":
			_planning = false
			_plan_drag = false
			var first: Variant = _plan_take_step(options, moves)
			return first if first != null else "cancel"
		_plan_reset()
		return got
	move_costs.clear()
	_plan_reset()
	return null


## 选目标态的按钮：规划器开关 + （开着时）「按此路径走」+ 结束迁移。
## 「结束迁移」永远是最后一个 —— `_prompt` 的 cancel 下标按它算。
## 点了一格却走不成，为什么。**规则问句柄**，界面不复算（决策 9）。
## 拿不到（Remote 第一次问只发出 RPC）就返回空串 = 这一下不弹，退回「点不动就是没反应」——
## 落子 / 复活那几问今天本来就是这样（规格 A-5.1）。
func _move_block_reason(cell: Dictionary, c: Vector2i) -> String:
	if kernel == null:
		return ""
	var why: Variant = kernel.query("move_block_reason", { "cid": int(cell["id"]), "to": c })
	if why == null:
		_block_want = c   ## 联机第一次问只发了 RPC：理由回来之后 plan_tick 补弹这一下，玩家不用点第二次
		_plan_cell = cell
		return ""
	return String(why)


func _move_buttons(cell: Dictionary, verb: String) -> Array:
	var out: Array = []
	if not _plan_ok:
		out.append({ "title": "结束%s" % verb, "cost": "右键 / Esc" })
		return out          ## 句柄答不了报价：规划按钮整条不出（降级可见）
	if _planning:
		var total: int = int(_plan_quote.get("total", 0))
		out.append({ "title": "按此路径走", "cost": "%s 能量 · %d 步" % [
			CWData.fmt(total), _plan.size()],
			"disabled": _plan.is_empty() or not _plan_quote.get("ok", false) })
		out.append({ "title": "退出规划", "cost": "" })
	else:
		out.append({ "title": "规划路径", "cost": "拖动画线" })
	out.append({ "title": "结束%s" % verb, "cost": "右键 / Esc" })
	return out


func _move_values() -> Array:
	if not _plan_ok:
		return ["cancel"]
	return ["plan_go", "plan_off", "cancel"] if _planning else ["plan_on", "cancel"]


## 规划态的提示行：把账写在玩家眼前（几步、多少钱、还剩多少、哪一步走不通）。
##
## ⚠ `n_reach` 必须由调用方传进来，**不能读 `_tiles`** —— 第一次进这一问时
## `_tiles` 要等 `_prompt()` 开头才赋值，而提示文案是 `_prompt()` 的**入参**，
## 那时读到的还是上一问的（或空的），界面上就会写「高亮 0 格可达」（2026-09-04 真机截图抓到）。
func _plan_hint(cell: Dictionary, n_reach: int) -> String:
	if not _planning:
		return "高亮 %d 格可达 · 可以连着走 · 右键或 Esc 退出" % n_reach
	if _plan.is_empty():
		return "从高亮格按下左键、划过想走的路线 · 再点「按此路径走」"
	if _plan_pending and _plan_quote.is_empty():
		return "%d 步 · 报价中…" % _plan.size()   ## 联机：RPC 还没回来（回来后 plan_tick 重排这一行）
	var q: Dictionary = _plan_quote
	## 途中从【代谢核心】收到的能量单独列一项（2026-09-08）：不写的话玩家会看到
	## 「合计 2.0 · 走完剩 3.5」这种对不上的账 —— 剩下的不等于「现有 − 合计」。
	## `total` 保持纯花费、不与收入相抵，因为玩家问的是「这条路要花多少」。
	var gained := int(q.get("gained", 0))
	var head := "%d 步 · 合计 %s%s · 走完剩 %s" % [_plan.size(),
		CWData.fmt(int(q.get("total", 0))),
		" · 途中核心 +%s" % CWData.fmt(gained) if gained > 0 else "",
		CWTutorLayers.energy_text(int(q.get("left", cell["energy"])))]   ## 无限能量的渲染点三处之三（方案 §3.2(b)）
	if not q.get("ok", false):
		var steps: Array = q.get("steps", [])
		var why: String = steps[-1]["blocked"] if not steps.is_empty() else ""
		return "%s ·（第 %d 步走不通：%s）" % [head, steps.size(), why]
	return head


func _plan_reset() -> void:
	_plan.clear()
	_planning = false
	_plan_drag = false
	_plan_quote = {}
	_plan_pending = false
	_plan_want = null
	_block_want = null


## 联机（E-1 (a)）：`kernel.query` 在 RPC 回来之前返回 null，这里每帧补一次 —— 报价、拖动时的可达表、灰格理由三样。
## 本地 InProc 同步答得了，pending 永远不会置上，这个函数就是空转。CWMatch._process 每帧调
func plan_tick() -> void:
	if kernel == null or _plan_cell.is_empty():
		return
	if _planning and _plan_pending:
		_plan_pending = false
		if _plan_want != null:
			var want: Vector2i = _plan_want
			_plan_want = null
			_plan_extend(_plan_cell, want)   ## 接不上就再等：它会重新置 pending
		else:
			_plan_requote(_plan_cell)
	if _block_want != null:
		var c: Vector2i = _block_want
		var why: Variant = kernel.query("move_block_reason", { "cid": int(_plan_cell["id"]), "to": c })
		if why != null:
			_block_want = null
			if String(why) != "":
				show_result(String(why), c)


## 拖到某一格：能接就接上，往回划就砍掉后面几步（拖过头了不用重来）
func _plan_extend(cell: Dictionary, c: Vector2i) -> void:
	if c == cell["pos"]:
		_plan.clear()
		_plan_requote(cell)
		return
	var at: int = _plan.find(c)
	if at >= 0:
		_plan.resize(at + 1)      ## 划回已经在路线上的格 → 砍掉它之后的
		_plan_requote(cell)
		return
	## **第一步认这一问自己的高亮格**：那是引擎给的移动选项（已经算过合法与付得起），
	## 与棋盘上亮着的格子严格一致 —— 玩家看得见什么就能拖到什么。
	## 之后几步棋盘上没有现成选项（细胞还没走过去），才去问 `plan_next_dests`
	if _plan.is_empty():
		if not _tiles.has(c):
			return
	else:
		var dests: Variant = kernel.query("plan_next_dests",
			{ "cid": int(cell["id"]), "from": _plan[-1] }) if kernel != null else null
		if dests == null and kernel != null:
			_plan_want = c        ## 联机：可达表还在路上，回来后 plan_tick 补接这一格
			_plan_pending = true
			_plan_cell = cell
			return
		if not (dests is Array) or not (c in (dests as Array)):
			return                ## 接不上（不相邻 / 有人占着）—— 忽略，别打断拖动
	_plan.append(c)
	_plan_requote(cell)


func _plan_requote(cell: Dictionary) -> void:
	_plan_cell = cell
	var quote: Variant = kernel.query("quote_path",
		{ "cid": int(cell["id"]), "path": _plan }) if kernel != null and not _plan.is_empty() else null
	_plan_quote = quote if quote is Dictionary else {}
	_plan_pending = quote == null and not _plan.is_empty() and kernel != null   ## 联机：RPC 在飞，plan_tick 下一帧再问
	if bar != null:
		bar.show_bar("选择要%s到的组织" % _move_title(cell), _plan_hint(cell, _tiles.size()),
			_move_buttons(cell, _move_title(cell)), _move_values().size() - 1)
	_repaint_marks()


## 从规划好的路里取下一步，返回它对应的选项下标；取不到返回 null。
##
## 「取不到」= 这一步此刻不在合法选项里（钱不够了、有人挡住了、盘面变了）。
## 那就把整条路作废并说明原因 —— 按旧价钱硬走是最不能接受的一种错。
func _plan_take_step(options: Array, moves: Array) -> Variant:
	if _plan.is_empty():
		return null
	var next: Vector2i = _plan[0]
	for i in moves:
		if options[i]["data"]["to"] == next:
			_plan.remove_at(0)
			_plan_quote = {}
			return i
	_plan.clear()
	_plan_quote = {}
	show_result("路线走不下去了（%s 这一步已不可行），请重新规划" % str(next), next)
	return null


# ============ 其余询问：有 to 的进棋盘，没 to 的进按钮 ============
# setup_place / revive / remodel_target 的选项带坐标 → 点棋盘；
# attack_target / differentiate / confirm 不带 → 全是按钮。
# 这条规则一写，六种询问就都覆盖到了，不必各写一套。

func _ask_generic(req: Dictionary) -> int:
	var options: Array = req["options"]
	var tiles := {}
	var buttons: Array = []
	var values: Array = []
	for i in options.size():
		var data: Dictionary = options[i]["data"]
		if data.has("to"):
			tiles[data["to"]] = i
		else:
			buttons.append({ "title": options[i]["label"], "cost": "" })
			values.append(i)
	var hint := "" if tiles.is_empty() else "高亮 %d 格可选" % tiles.size()
	var mine := self_type_text(mirror, req)
	if mine != "":
		hint = mine if hint == "" else "%s · %s" % [mine, hint]
	var got: Variant = await _prompt(req["prompt"], hint, buttons, values, tiles)
	return 0 if got == null else int(got)


## 开局落子那一问，提示里加一句「你是什么癌」（Kevin 2026-09-10）。**纯函数**，好直接测。
##
## **为什么值得多这一句**：癌种是开局随机发的，而落子点该选哪儿正取决于它 ——
## 黑色素瘤要贴着边扩、骨肉瘤指望固化、小细胞靠【转移】。右栏确实列着每个人的种类，
## 但落子那一刻玩家的眼睛在棋盘和这条提示上，而且那时他还不知道哪一行是自己。
##
## **只给癌方**：免疫开局一律是【免疫细胞】，分化在后头，报了也是废话。
## 只在 `setup_place` 这一问出 —— 之后种类已经在棋盘上、在右栏、在详情框里了。
## ⚠ 读的是 **player 上的 `cancer_type`**，不是细胞上的 `ctype`：
## 落子这一问跑在细胞**出生之前**（`setup.begin()` 发种类 → 问落点 → `setup.place()` 才造细胞），
## 那时 `cell_of()` 会当场越界。种类是 `_assign_cancer_types()` 记在玩家身上的。
static func self_type_text(g: CWMirror, req: Dictionary) -> String:
	if g == null or String(req.get("kind", "")) != "setup_place":
		return ""
	var pid := int(req.get("pid", -1))
	if pid < 0 or pid >= g.players.size():
		return ""
	var p := g.player(pid)
	if int(p.get("faction", -1)) != CWData.Faction.CANCER:
		return ""
	var ctype := int(p.get("cancer_type", -1))
	if not CWData.CANCER_TYPE_NAMES.has(ctype):
		return ""
	return "你是【%s】" % CWData.CANCER_TYPE_NAMES[ctype]


## 摆出一栏按钮 + 一组可点的格子，等玩家二选一，返回被选中那项的值。
## title 为空 = 技能栏形态（靠右一条）；否则 = 目标选择态（整条横过来，左边带提示）。
## end_value 非 null 时，右侧竖条底部的「结束回合」也算这一问的一个答案，
## 按下它就返回该值。选目标格时传 null，那个按钮会一起收掉。
## cancel 指出 buttons 里哪一个是「取消」（右键 / Esc 的快捷方式）；-1 = 不能取消。
## blocked：点到**不在选项里**的格子时问一句「为什么」，非空就弹出来。
## 不给这个回调的询问（落子、复活…）沿用老行为：点不动就是没反应。
## hand_discard：有「取消」按钮的那一问里，右键双击卡默认 = 取消（团队 2026-09-01 复核保留）；
## 只有迁移选目标态开着它（Kevin 2026-09-06：选目标态下要能直接对卡牌操作），右键双击卡 = 弃置，
## 右键点空处 / Esc 照旧 = 结束迁移。
func _prompt(title: String, hint: String, buttons: Array, values: Array,
		tiles: Dictionary, end_value: Variant = null, cancel := -1,
		hand_play := false, inset := 0.0, blocked := Callable(), hand_discard := false) -> Variant:
	_tiles = tiles
	_repaint_marks()
	bar.show_bar(title, hint, buttons, cancel, inset)
	var ans := Answer.new()
	_pending = ans
	var on_button := func(i: int) -> void: ans.fire(values[i])
	var on_end := func() -> void: ans.fire(end_value)
	## 行动询问期间手牌可点（方案甲）；其余询问（落子/复活等）不收手牌手势
	var on_play := func(n: String) -> void: ans.fire(["play", n])
	## 右键的归属只看这一问有没有「取消」：有（目标态/各确认条）→ 右键一律=取消，
	## 哪怕点在卡上——按钮上就标着「右键 / Esc」，卡不该抢走它（试玩第三轮报的）。
	## 团队 2026-09-01 复核过这条并保留：弃置只在**主按钮栏**（没有取消的那一问）生效。
	var on_discard := func(n: String) -> void:
		if cancel >= 0 and not hand_discard:
			ans.fire(values[cancel])
		else:
			ans.fire(["discard", n])
	if hand_play and hand != null:
		hand.play_requested.connect(on_play)
		hand.discard_requested.connect(on_discard)
	if panel != null:
		panel.show_end_turn(end_value != null)
		if end_value != null:
			panel.end_turn_pressed.connect(on_end)
	var on_tile := func(c: Vector2i) -> void:
		## 规划态：棋盘的点击不作答，改成「按下开始拖」
		if _planning:
			_plan_drag = true
			_plan_extend(mirror.cell_of(_sticky_pid), c)
			return
		if tiles.has(c):
			ans.fire(tiles[c])
			return
		## 点了一格却没反应，是界面最难受的一种沉默 —— 有理由就说出来
		## （攻击次数用尽是团队 2026-09-01 点名要的那一条）
		if blocked.is_valid():
			var why: String = blocked.call(c)
			if why != "":
				if has_meta("tutorial_guide"):
					var guide = get_meta("tutorial_guide")
					if guide != null and is_instance_valid(guide):
						guide.record_mistake()
				show_result(why, c)
	var on_hover := func(c: Vector2i) -> void:
		if _planning and _plan_drag and c != board.NO_TILE:
			_plan_extend(mirror.cell_of(_sticky_pid), c)
			return          ## _plan_extend 里已经重画过
		_repaint_marks()
	var on_release := func() -> void: _plan_drag = false
	## 按钮悬停 → 带 info 的条目浮详情（行动栏的每个技能、分化提问的种类按钮都带），离开就收起
	var on_bar_hover := func(i: int) -> void:
		if info == null:
			return
		if i >= 0 and i < buttons.size() and buttons[i].has("info"):
			info.on_hover_info(buttons[i]["info"], bar.button_x(i))
		else:
			info.on_hover_info({}, 0.0)
	bar.chosen.connect(on_button)
	bar.hovered.connect(on_bar_hover)
	board.tile_clicked.connect(on_tile)
	board.tile_hovered.connect(on_hover)
	board.drag_ended.connect(on_release)
	var got: Variant = await ans.done
	_pending = null
	if hand_play and hand != null:
		hand.play_requested.disconnect(on_play)
		hand.discard_requested.disconnect(on_discard)
	if panel != null and end_value != null:
		panel.end_turn_pressed.disconnect(on_end)
	bar.chosen.disconnect(on_button)
	bar.hovered.disconnect(on_bar_hover)
	if info != null:
		info.on_hover_info({}, 0.0)   ## 这一问结束就收：按钮都没了，详情不能还挂着
	board.tile_clicked.disconnect(on_tile)
	board.tile_hovered.disconnect(on_hover)
	board.drag_ended.disconnect(on_release)
	return got


## 候选格用免疫青；落着敌人的那一格用癌方橙 —— 那一下是攻击，不是迁移，
## 颜色得先说出来。鼠标停着的那格再提亮一档。
##
## 候选格里**癌性组织（含固化）换红**（issue #47）：青色色标一盖，红底的癌组织和
## 青底的健康组织混完就是一个色，可「这一步会不会净化」恰恰是选落点时要看的。
## 判据走 `mirror.is_cancerous`（内核的同名查询），界面不自己数格子。
func _repaint_marks() -> void:
	if mirror == null:
		marks = {}
		return              ## 对局已经拆了；防的是「信号还没断干净」那一瞬
	var m := {}
	for c: Vector2i in _tiles:
		if board.hovered == c:
			m[c] = board.MARK_HOVER
		elif _enemy >= 0 and not mirror.cells_at(c, _enemy).is_empty():
			m[c] = board.MARK_ATTACK
		else:
			m[c] = board.MARK_MOVE_SICK if mirror.is_cancerous(c) else board.MARK_MOVE
	## 规划出来的路线压在可达高亮之上：这几格是玩家自己选的，得比「可以去」更实。
	## 走不通的那一步标橙，配上提示行里的原因
	var steps: Array = _plan_quote.get("steps", [])
	for i in steps.size():
		var s: Dictionary = steps[i]
		m[s["to"]] = board.MARK_PLAN if s["afford"] else board.MARK_PLAN_BAD
	marks = m


func _clear_ui() -> void:
	marks = {}
	_tiles = {}
	if bar != null:
		bar.clear()
	if panel != null:
		panel.show_end_turn(false)
	if hand != null:
		hand.set_selected("")


# ---- 按钮文案 ----

func _move_title(cell: Dictionary) -> String:
	## 规则里免疫叫「迁移」、癌症叫「移动」，是两个词，别混用
	return "迁移" if cell["faction"] == CWData.Faction.IMMUNE else "移动"


## ⚠ **批 2 欠账**（规格 B-5 豁免④）：draw / differentiate / effector / toxin / lyse / mutate / mucus 七种
## 仍直读 `CWData` 常量 —— 这几种今天没有任何修饰会改价。受修饰的四种（antibody / homing / jump / ossify）
## 已经改读内核算好的**真报价**：价签与「点不点得动」不同源就会复发 Kevin 2026-09-08 报的
## 「按钮写着 1.0、我有 6.9、却点不动」。
func _cost_text(cell: Dictionary, act: String) -> String:
	match act:
		"draw":
			var c: int = CWData.IMMUNE_DRAW_COST if cell["faction"] == CWData.Faction.IMMUNE \
				else CWData.CANCER_DRAW_COST
			return "%s 抽卡" % CWData.fmt(c)
		"differentiate":
			return "免费"
		"effector":
			## 【效应应答】收的是**效应记忆**不是能量 —— 价签必须把单位写出来，
			## 否则玩家会以为是 15 点能量（那是全场没人付得起的数）
			return "%d 效应记忆" % CWData.EFFECTOR_COST
		"antibody":
			## 【抗体亲和力成熟】把抗体费降到 0.5——价签跟着技能走
			return _cost_d(cell, "antibody_cost")
		"toxin":
			return CWData.fmt(CWData.TOXIN_COST)
		"lyse":
			return CWData.fmt(CWData.LYSE_COST)
		"mutate":
			return CWData.fmt(CWData.MUTATE_COST)
		## 技能移动这两个**必须走真报价**，不能打常量：
		## 卡牌的全局修饰会把它们抬上去，而「能不能用」判的是抬完的数。
		## 两边不同源的话就会出现「按钮写着 1.0、我有 6.9、却点不动」（Kevin 2026-09-08）。
		"homing":
			return _cost_d(cell, "homing_cost_real")
		"jump":
			return _cost_d(cell, "metastasis_cost_real")
		"ossify":
			## 2026-09-07 Kevin 报「骨样硬化按钮没有费用」—— 09-05 重做这个技能时漏了这一格。
			## 同 jump：读的是内核算好的**真报价**（旋钮 + 全局修饰都算进去了），不是旋钮原值
			return _cost_d(cell, "ossify_cost_real")
		"mucus":
			return "耗尽能量"
	return ""


## 价签读**内核算好的真报价**（tier B）。这一档缺席（C# 生产者批 0 只交 tier A）就**不写价签** ——
## 打一个 0 上去比空着更坏：玩家会照着 0 去点一个点不动的按钮。
func _cost_d(cell: Dictionary, key: String) -> String:
	var d: Dictionary = cell.get("d", {})
	return CWData.fmt(int(d[key])) if d.has(key) else ""


# ============ 演出：播放时长 ≠ 阻塞时长（Kevin 2026-09-19）============
# 拍板 2：客户端按条目顺序播，有时长的演出播完再放下一条。但**队列等的只是下面这张表** ——
# `show_*` 协程 await 完这一段就返回，动画自己继续演完（小细胞那种波浪形长位移不该把整条队列堵住）。
# 数值按「看清这一下发生了什么」定，**全部可调**：调小 = 节奏更紧、同格演出更容易叠；调大 = 更像逐步演示。
# **骰子不在表里**：它是 barrier 条目、引擎在等 ack，必须整只演完（今天的行为，不动）。
const BLOCK_CARD_MS := 350      ## 头顶飞卡总长约 0.97 s（窜 0.16 + 停 0.30+0.08 + 收 0.36）：到「停」那一拍放手
const BLOCK_BEAM_MS := 900      ## CWBeamFx.TOTAL 2.2 s；蓄力 0.65 + 推到底 0.55，打到了就放手
const BLOCK_FX_DEFAULT_MS := 300
## 按 fx 种类给的阻塞毫秒，缺省走 BLOCK_FX_DEFAULT_MS。括号里是这只演出自己的总长（CWSkillFx.DURATION 等）。
const BLOCK_FX_MS := {
	"immune_attack": 450,   ## 0.66：接触 0.22 与收势 0.29 之间放手
	"chomp": 450,           ## 0.70：咬合完成在 0.61
	"homing": 500,          ## 2.9 —— 归巢是长位移，全等等不起
	"card_cascade": 500,    ## 2.8
	"anaerobic": 500,       ## 2.1
	"card_teleport": 500,   ## 2.1
	"card_clone": 500,      ## 2.1
	"lyse": 500,            ## 2.05
	"pseudopod": 400,       ## 1.0；后半程是把细胞拉过来，定殖过场自己会等 arrival_in（issue #29）
}
## 队列把四类演出喂给这四个回调（CWMatch._wire_bridge 注入）。
## **今天靠 CWGame 的四个信号驱动，信号在步 8 一起删掉** —— 不接的话头顶飞卡静默失效（规格 A-5.2 / D-3）。
var fx_card_played: Callable    ## → CWMatch._on_card_played(cell_id, pid, pos, faction, card, {})
var fx_event_drawn: Callable    ## → CWMatch._on_event_drawn(cell_id, pid, pos, faction, card)
var fx_card_drawn: Callable     ## → CWMatch._on_card_drawn(cell_id, pid, pos, source)


func _block_ms(kind: String) -> int:
	return int(BLOCK_FX_MS.get(kind, BLOCK_FX_DEFAULT_MS))


## 只等「阻塞那一段」。没有场景树（无头测试 / 纯数据桥）立即返回 —— 队列照样顺序播，只是不等。
func _block(ms: int) -> void:
	var node: Node = delay_node if delay_node != null else board
	if ms <= 0 or node == null or not node.is_inside_tree():
		return
	await node.get_tree().create_timer(ms / 1000.0).timeout


## 把骰子摆到目标格旁边演一次，同时在它上方标出这次掷的是什么（"攻击"/"突变"/"抗体"）。
## **AI 和人类同一档速度**（团队 2026-08-27 定）：原先 AI 走快档，
## 结果同一件事在不同回合有两种节奏，反而显得乱。
## `CWDice.play()` 的快档参数保留着，将来做「加速观战」时直接接上。
func show_roll(reason: String, value: int, sides: int, _pid: int, at: Vector2i) -> void:
	if not CWSettings.dice_anim:
		return   ## 设置「掷骰动画：跳过」：不演，结算说明（show_result）照常弹
	if dice == null or board == null:
		return
	var ground: Vector2 = board.tile_center(at)
	if toast != null and camera != null:
		## hold=0：一直留着，等骰子停稳后被结算说明顶掉
		toast.show_at(reason, _dice_rect(ground), 0.0)
	## 深度走 Z_DICE_TOP 这一整层，不再按排排（见 board.gd 那条注释）
	dice.place_at(ground, board.Z_DICE_TOP)
	await dice.play(value, sides)


## 掷骰的结算说明。文字是引擎给的，这里只负责把它摆到那一格上方。
## linger（非骰子的说明）走独立气泡、停 TEXT_HOLD：停得久就不能被下一条顶掉，也不能把骰子那行字挤走。
## 此刻仍被【中和抗体】压住的癌细胞在哪几格。**判据问镜像**（`mirror.neutralized`，值由内核算好）——
## 「谁挨着健康组织」是规则，表现层不许照着再判一遍。
func _sealed_centers() -> Array[Vector2]:
	var out: Array[Vector2] = []
	if mirror == null or board == null:
		return out
	for c in mirror.living_cells(CWData.Faction.CANCER):
		if mirror.neutralized(c):
			out.append(board.tile_center(c["pos"]))
	return out


## 此刻正在连锁的那只巨噬。`chain_running` 是引擎的再入闸，**全场至多一只**——
## 拿它认人比猜 `cell_of(current_pid)` 稳（分化之后一个玩家不止一只细胞）。
## 返回 {} 表示没找到（通报来自影子对局之类）。
func _chaining_cell() -> Dictionary:
	if mirror == null:
		return {}
	for c in mirror.cells:
		if c.get("chain_running", false) and c["alive"]:
			return c
	return {}


func show_result(text: String, at: Vector2i, linger := false) -> void:
	## 通报文案当分派键是没办法的事：准星是一次性演出，没有可以每帧去读的状态
	## （趋化源和标记光环都是读 game 的常驻状态）。名字至少引正本，别在这儿再抄一份。
	if text == CWData.EFFECTOR_NAMES[CWData.ImmuneType.DENDRITIC] \
			and hunt_fx != null and board != null:
		## 第二个点是搜索起点 —— 盘心。选稿里方框先在全图上摆，再收到目标身上
		hunt_fx.play(board.tile_center(at), board.tile_center(Vector2i.ZERO))
	## 【连续吞噬】：起点是那只巨噬**此刻**站的格（通报在它挪过去之前发），
	## 层数现读引擎的 chain_left，都不在表现层另记一份
	if text == CWData.EFFECTOR_NAMES[CWData.ImmuneType.MACRO] \
			and chain_fx != null and board != null and mirror != null:
		var eater := _chaining_cell()
		if not eater.is_empty():
			chain_fx.play(board.tile_center(eater["pos"]), board.tile_center(at),
				CWData.CHAIN_PHAGO_MAX - int(eater.get("chain_left", CWData.CHAIN_PHAGO_MAX)),
				int(eater["id"]))
	if text == "黏液破裂" and mucus_fx != null and board != null:
		mucus_fx.play(board.tile_center(at))
	## 【中和抗体】封住了谁**问镜像**（mirror.neutralized），不在这儿重算「谁挨着健康组织」
	if text == CWData.EFFECTOR_NAMES[CWData.ImmuneType.B_CELL] \
			and seal_fx != null and board != null and mirror != null:
		seal_fx.play(board.tile_center(at), _sealed_centers())
	if toast == null or board == null or camera == null:
		return
	if linger:
		toast.bubble_at(text, _dice_rect(board.tile_center(at)), TEXT_HOLD)
		return
	## 沿用掷骰时那个位置：骰子这会儿已经收了，但玩家的视线还在那儿，
	## 让「攻击」和「攻击大成功」出现在同一个地方比各自找最优位置更好读。
	## 先收掉掷骰时那行「攻击」，结果另起一只气泡停 RESULT_HOLD（各自一只：停久了才不会被下一次攻击的结果顶掉）
	toast.hide_box()
	toast.bubble_at(text, _dice_rect(board.tile_center(at)), RESULT_HOLD)


## Excalibur 的光束过场：把轴坐标换成棋盘像素，交给演出层。
## 队列会 await 它，但只等 BLOCK_BEAM_MS（蓄力 + 推到底）—— 余下那 1.3 s 的波及与散场自己演完。
##
## issue #53 ⑧「Excalibur 应该从细胞表面上下中心表面发出」：起点由格顶面中心改成**胞体中心**
## （脚底再往上半个贴图高，同 FX_BODY_CENTER 那几种），光束的起手偏移改成**胞体半径** ——
## 光芯于是正好从细胞轮廓上离开，而不是从脚底往外 16px 凭空冒出来。
## 落点与侧向波及仍是格位：它们打的是地面上的组织。
func show_beam(from: Vector2i, to: Vector2i, splash: Array) -> void:
	if beam_fx == null or board == null:
		return
	var pts: Array[Vector2] = []
	for c in splash:
		pts.append(board.tile_center(c))
	var half := _half_h(from)
	var body: Vector2 = board.tile_center(from) + Vector2(0, CWMatch.CELL_FOOT_DY - half)
	beam_fx.play(body, board.tile_center(to), pts, half)
	await _block(BLOCK_BEAM_MS)


## issue #29：伪足穿透正把细胞往这一格拉的话，过场等细胞到了再演（CWSkillFx.arrival_in），
## 等的那段 CWMatch._sync_tiles 把这一格照健康组织画 —— 先移动、再定殖。没伪足在拉的格 delay = 0，老路不变。
func show_erosion(at: Vector2i, dir: int) -> void:
	if erosion == null:
		return
	var wait: float = skill_fx.arrival_in(at) if skill_fx != null else -1.0
	erosion.play(at, dir, maxf(wait, 0.0))


## 演出数据里哪些键指的是**细胞**（落在细胞位 = 格顶面中心 + CELL_FOOT_DY）；其余 Vector2i 一律当格位
const FX_BODY_KEYS := {
	"antibody": ["from", "targets"], "toxin": ["from"], "lyse": ["from"], "adhesion": ["from", "to"],
	"differentiate": ["at"], "respire": ["at"], "mutate": ["at"], "anaerobic": ["at"],
}
## 要对准**胞体中心**的那几种（issue #26，HXR-I：有氧 / 无氧的粒子对着脚底收拢看着错位、堆在细胞贴图上一点很诡异；
## 伪足要抓的也是胞体）：另给一份 `<键>_body`（脚底再往上半个贴图高）和 `r`（半个贴图高，当胞体半径用）。
## 原键照旧是脚底 —— 演出层没拿到 `_body` 就退回选稿的脚底老画法，一个像素不动。
##
## 2026-09-19（issue #53 ①②⑤⑦）再添六种：抗体 / 裂解从**细胞中心**发出（原来从脚底，
## 看着是从肚子底下射出来的）、分化与突变的粒子中心对胞体（突变原来整束落在细胞下半身）、
## 复活那两条同理。数组键（抗体的 `targets`）给的是一串 `_body`，各按自己那格的贴图高算。
const FX_BODY_CENTER := {
	"respire": ["at"], "anaerobic": ["at"], "pseudopod": ["from"],
	"antibody": ["from", "targets"], "lyse": ["from"], "differentiate": ["at"],
	"mutate": ["at"], "revive_immune": ["at"], "revive_cancer": ["at"],
}
## 那一格上站着的细胞贴图有多高（半高）。由 CWMatch 注入 —— 只有它认得细胞节点；
## 没注入（无界面跑测试）按 24px 贴图算。
var cell_half_height: Callable


func _half_h(c: Vector2i) -> float:
	return float(cell_half_height.call(c)) if cell_half_height.is_valid() else 12.0


## 技能演出（issue #15）：把引擎给的轴坐标换成棋盘像素再交给演出层。
## 巨噬扑咬走 CWChainFx（它要代画胞体，和连锁那一口是同一副嘴）。
func show_fx(kind: String, data: Dictionary) -> void:
	if board == null:
		return
	if kind == "immune_attack":
		if attack_animation.is_valid():
			attack_animation.call(data)
			await _block(_block_ms(kind))   ## 触发即返回的 Callable，阻塞由这里给（拍板 2）
		return
	if kind == "chomp":
		if chain_fx != null:
			chain_fx.play_bite(board.tile_center(data["from"]), board.tile_center(data["to"]), int(data.get("cid", -1)))
			await _block(_block_ms(kind))
		return
	if skill_fx == null:
		return
	var body_keys: Array = FX_BODY_KEYS.get(kind, [])
	var out := {}
	for key in data:
		var v: Variant = data[key]
		var dy: float = CWMatch.CELL_FOOT_DY if body_keys.has(key) else 0.0
		if v is Vector2i:
			out[key] = board.tile_center(v) + Vector2(0, dy)
		elif v is Array:
			var pts: Array = []
			for c in v:
				if c is Vector2i:
					pts.append(board.tile_center(c) + Vector2(0, dy))
			out[key] = pts
		else:
			out[key] = v
	for key in FX_BODY_CENTER.get(kind, []):
		var c: Variant = data.get(key)
		if c is Vector2i:
			var half: float = _half_h(c)
			out[key + "_body"] = board.tile_center(c) + Vector2(0, CWMatch.CELL_FOOT_DY - half)
			out["r"] = half
		elif c is Array:
			## 一串细胞（抗体的 targets）：各按自己那格的贴图高算，不共用一个 r
			var pts: Array = []
			for e in c:
				if e is Vector2i:
					pts.append(board.tile_center(e) + Vector2(0, CWMatch.CELL_FOOT_DY - _half_h(e)))
			out[key + "_body"] = pts
	## 细胞毒素走地面贴花（issue #53 ③）：一格一个节点，各拿自己那格的 z（比自己那格高、比细胞低）
	if kind == "toxin" and data.get("tiles") is Array:
		var zs: Array = []
		for c in data["tiles"]:
			if c is Vector2i:
				zs.append(board.tile_z(c, board.Z_MARK))
		out["tiles_z"] = zs
	## 伪足穿透另留新格的轴坐标：定殖过场（show_erosion）要问「细胞几秒到这一格」（issue #29）
	if kind == "pseudopod" and data.get("to") is Vector2i:
		out["to_tile"] = data["to"]
	## 【克隆增殖】同理（issue #28）：那几格的定殖过场各等自己那道感染流
	if kind == "card_clone" and data.get("tiles") is Array:
		out["tiles_axial"] = data["tiles"]
	skill_fx.play(kind, out)
	await _block(_block_ms(kind))


## ---- 队列喂进来的四类演出（规格 A-5.2）----
## 今天这四样由 `CWMatch` 直接连 `CWGame` 的同名信号；步 8 把信号删了、改由播放队列调这里，
## 桥再转给 `CWMatch` 原来那四个处理函数（**函数体一行不动**）。**不接就是静默失效**：
## 不报错、不崩，只是头顶再也不飞卡（规格 D-3）。
## `info` 的键与 `cw_net_bridge.gd` 的报文键逐字相同，所以本地与联机走同一份代码。
func show_card_played(pid: int, text: String, info := {}) -> void:
	super.show_card_played(pid, text, info)
	if not fx_card_played.is_valid() or not info.has("card"):
		return          ## 今天 `_net_loop` 的同款 guard：没有牌名就不是「谁打出了卡」
	fx_card_played.call(int(info["cell_id"]), pid, info["pos"], int(info["faction"]), String(info["card"]), {})
	await _block(BLOCK_CARD_MS)


func show_event_drawn(pid: int, info := {}) -> void:
	if fx_event_drawn.is_valid() and info.has("card"):
		fx_event_drawn.call(int(info["cell_id"]), pid, info["pos"], int(info["faction"]), String(info["card"]))


## 抽到一张卡：倒放的头顶飞卡。**队列不 await 这一条**（归在便宜档），所以这里也不阻塞。
func show_card_drawn(pid: int, info := {}) -> void:
	if fx_card_drawn.is_valid() and info.has("pos"):
		fx_card_drawn.call(int(info["cell_id"]), pid, info["pos"], String(info.get("source", "")))



## 全局通报（`show_notice`）2026-09-07 起界面上没有位置了：抽到的那张事件卡
## 以卡面进棋盘左侧的出牌列（CWMatch._on_event_drawn），其余通报都写进日志。
## 基类的空实现留着 —— 联机那条 notice 报文照收不误，只是不再弹任何东西。


## 屏幕前这位真人是哪一席：热座 = 当前露牌的那位（换手期间 -1），单人局 = 那一席，观战 = -1
func viewing_pid() -> int:
	if hotseat:
		return current_human
	return human_pids[0] if not human_pids.is_empty() else -1


## 骰子落在某格时，它在**屏幕**上占的那块矩形。提示靠它避让。
func _dice_rect(ground: Vector2) -> Rect2:
	var span: Vector2 = dice.size * camera.zoom.x
	var origin: Vector2 = CWView.board_to_screen(camera, ground) - Vector2(
		span.x * 0.5, CWDice.contact_y(dice.size.y) * camera.zoom.y)
	return Rect2(origin, span)
