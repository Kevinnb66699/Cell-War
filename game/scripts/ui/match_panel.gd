## match_panel.gd —— 右侧竖条：常驻信息全在这儿
##
## 尺寸全部照搬定稿的「右侧竖条 · 尺寸与字号」标注稿，**一个数都别改**：
## 面板 264×540，内边距 16，块间距 10，各块高度写死
## 52（回合）/ 56（胜负进度）/ 44×人数（玩家列表）/ 44（免疫等级）/ 52（结束回合，钉底）。
## 6 人局合计 530，只余 10px —— 这套高度是按最挤的情况配平的，
## 随手把哪一块调高一点，6 人局就会溢出。
##
## **唯一的例外是教程**（新手引导 S8）：`ui_layers.round_no` 关着时，回合块那 52 + 10 px
## 真让给下面的行（`_layer_round` / `rows_top()`）。第五关 Step2 场上 9 席，不让位免疫等级
## 那一块整块掉出 540，而 PRD:417 要的就是「显示……的状态、免疫等级」。
## 正式对局 `round_no` 恒 true ⇒ 一个像素不动。
##
## 为什么是右侧竖条而不是底部横条：见 [CWView] 的对局机位注释。
##
## 刷新方式和棋盘一致：每帧全量刷（refresh），只改 Label 的 text。
## Godot 的 Label.text 在没变化时会直接返回，所以代价接近零，
## 而画面不可能和状态对不上。节点结构只在第一次 refresh 时按人数建一遍。
class_name CWMatchPanel
extends Control

## 「结束回合」被按下（面板底部那个按钮，或空格）
signal end_turn_pressed
## 固定详情里停在某一条技能上：把它的 PRD 原文（CWCardInfo 的 { name, kind, lines }）
## 和详情框该贴的横坐标交出去，由 CWMatch 转给同一只 CWCardInfo。
## 离开时发空字典 —— 和行动栏那条悬停路径同一套约定
## anchor_y = 被悬停那一行的画布 y，详情框把框顶对齐到它（2026-09-07 之前没带 y，框被摆到窗口底部）；离开时发 -1
signal skill_hovered(rows: Dictionary, anchor_x: float, anchor_y: float)

const RECT := Rect2(696, 0, 264, 540)
const PAD := 16
const GAP := 10
const ROUND_H := 52
const SCORE_H := 56
const ROW_H := 44
const LEVEL_H := 44
const END_H := 52
## 升级进度条：贴免疫等级那一块的底边。**不许加高那一块**（见文件头），
## 所以它只能长在文字墨迹底下那道缝里 —— 38 起、4 高，块高 44，还留 2px 到下边。
##
## 第一版摆在 34，Kevin 一眼看出来「距离罗马数字太近了」：等级那个字是
## SIZE_BODY 20，行框到 y+35，34 等于**贴着它的下沿**。往下挪 4px 之后
## 字与条之间空出一行的呼吸。护栏钉的就是「条顶不高于等级字的行框底」——
## 那条关系比「34 还是 38」耐改（换字号时会自己跟着走）。
const BAR_DY := 38.0
const BAR_H := 4.0
## 「免疫等级」那四个字。数字要居中到它和记忆行之间，所以宽度得量它 ——
## 写成常量是为了**只有一处**：量的字和摆的字必须是同一串（见 _layout_level）
const LEVEL_CAPTION := "免疫等级"
## 数字离两边各留多少才不算贴脸。**只有护栏在用** —— 版面本身是居中算的，
## 这个数是「最挤的一档也得留出这么多」的下限（见 t_match_panel）
const LEVEL_GAP := 8.0

const W := 232          ## 内容宽 = 264 - 16×2
const ROW_PAD := 6      ## 玩家行自己的左右内边距
const ICON := 32

## 手牌用小方块表示（团队 2026-08-28 定）：**总是画满 CWData.HAND_MAX 格**，
## 持有的填成阵营色、其余只留描边 —— 满没满一眼可见，比一个数字直观。
## 永久技能则**没有上限**（X 级免疫池光永久技能就有 9 张），所以只能用数字，不能也方块化。
const PIP := 6            ## 方块边长
const PIP_GAP := 2
const INCOME_RESERVE := 30  ## 预计收入小字「+x.x」贴行右缘，预留的宽度（Kevin 2026-09-06：「能量往左、+ 多少放右边」）
const ENERGY_RESERVE := 52  ## 能量数字预留的宽度，右对齐到预计收入左边；「技 N」再右对齐到它左边
## 玩家名的裁剪宽度：原 110，给预计收入让位后 64。本地对局的「免疫A」52px 不受影响；
## 联机长昵称本来就要裁（2026-09-03 排版体检），只是裁得更早一点
const NAME_W := 64
## 技能详情框的宽度。固定态要放下「停在技能上看详情 · 再点该行取消固定」这行小字（10px×18 字 = 180）
const TIP_W := 200.0
## 规则浮窗（#49 升级规则 / #50 当期效果）的宽度与行距。比技能详情框宽一点：
## 那只列的是技能名，这只要把「门槛 + 收益」并排写在一行里。
## 行距取 10px 小字那一档（同技能框的小标题行），六七行也只有一百来像素高。
const INFO_W := 252.0
const INFO_ROW := 15.0

## 玩家行里的种类图标。和棋盘上是同一批贴图，但棋盘那份要对齐脚底、这份是居中摆，
## 用途不同所以各留各的表（棋盘那份见 CWMatch.IMMUNE_ART / CANCER_ART）。
const IMMUNE_ICON := {
	CWData.ImmuneType.BASIC: preload("res://assets/art/cells/immune.png"),
	CWData.ImmuneType.B_CELL: preload("res://assets/art/cells/bcell.png"),
	CWData.ImmuneType.T_CELL: preload("res://assets/art/cells/tcell.png"),
	CWData.ImmuneType.MACRO: preload("res://assets/art/cells/macrophage.png"),
	CWData.ImmuneType.DENDRITIC: preload("res://assets/art/cells/dendritic.png"),
}
const CANCER_ICON := {
	CWData.CancerType.MELANOMA: preload("res://assets/art/cells/melanoma.png"),
	CWData.CancerType.SIGNET: preload("res://assets/art/cells/signet.png"),
	CWData.CancerType.OSTEO: preload("res://assets/art/cells/osteo.png"),
	CWData.CancerType.SCLC: preload("res://assets/art/cells/sclc.png"),
}

var _round: Label
var _phase: Label
var _weighted: Label
var _weighted_max: Label
var _weighted_caption: Label   ## 平时写「癌性加权」，警报期换成「★ 警报 1/2」
var _bar_fill: ColorRect
var _level: Label
var _memory: Label
var _lv_bar_bg: ColorRect    ## 升级进度条的槽（胜负那条叫 _bar_fill，别混）
var _lv_bar_fill: ColorRect  ## 已攒到的那一段
var _bg: Panel
var _end: PanelContainer
var _rows: Array = []      ## 每项 { bg, fac, icon, name, type, energy, pips, skills }
var _built := 0            ## 已按几人局建好（0 = 还没建）
var _level_y := 0.0        ## 免疫等级那一块的顶边；测试靠它核对 6 人局没溢出
var _tip: Control = null   ## 技能详情框（悬停玩家行时列出已装备 + 即时修饰；**点一下固定**后列全套技能）
var _tip_pid := -1         ## 正悬停哪一行；-1 = 收起
var _tip_pinned := -1      ## 被点住固定的那一行；-1 = 没固定。固定后框不随鼠标收起、条目可悬停
var _tip_key := ""         ## 上次搭悬浮框用的键，没变不重搭
var _info: Control = null      ## 规则浮窗（#49 升级规则 / #50 当期效果），和 _tip 各管各的
var _info_key := ""            ## 上次搭它用的键，没变不重搭
var _info_hover := ""          ## "level" / "stage" / ""：指针正停在哪一块上
var _stage_zone: Control = null  ## 「肿瘤 n 期」那一行的感应区（回合块关掉时跟着收）
## 悬停探针，**只给无头测试**。无头视口不跟踪悬停控件 —— mouse_entered 一次都不会发，
## 注入一个返回 "level" / "stage" / "" 的 Callable 就能在无头里驱动这两块浮窗。
## 真机一个字也不碰它，照旧走 mouse_entered / mouse_exited。
var info_hover_probe := Callable()
## 联机：房间视图里的席位表（下标 = pid）。AI 席 / 离线席在种类后面加个角标；本地对局留空
var net_seats: Array = []
## 教程的 `ui_layers.end_turn`（默认开）。正式局永远是 true
var _layer_end := true
## 教程的 `ui_layers.round_no`（默认开）。正式局永远是 true。
## **关掉时那一块的 52 + 10 px 真让出来**（新手引导 S8）：第五关 Step2 场上有 9 席
## （五种免疫各一 + 玩家 + 三只癌，Kevin 2026-09-19 Q-18），按原来的排版免疫等级那一块
## 整块掉到 540 之外 —— 而 PRD:417 要的正是「显示……的状态、免疫等级」。
## 只在**这一块本来就不显示**的时候让位，所以正式局一个像素不动（那边 round_no 恒 true）
var _layer_round := true


func _ready() -> void:
	position = RECT.position
	size = RECT.size
	mouse_filter = Control.MOUSE_FILTER_STOP   ## 面板要挡住底下的棋盘点击
	_chrome()


## 底板和「结束回合」按钮：都跟人数无关，所以和玩家列表分开建，
## 而且是**懒建**——程序化创建本面板时 _ready 要等到下一帧才跑，
## 而调用方（CWUIBridge）当帧就可能来调 show_end_turn()。
func _chrome() -> void:
	if _bg == null:
		_bg = Panel.new()
		## 只有左边一道描边（设计稿 border-left），所以不能用 set_border_width_all
		var box := CWStyle.box(0.45, CWStyle.PANEL)
		box.set_border_width_all(0)
		box.border_width_left = 2
		_bg.add_theme_stylebox_override("panel", box)
		_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_bg)
	if _end == null:
		_end = _build_end_button()
		_end.position = Vector2(PAD, RECT.size.y - PAD - END_H)
		_end.size = Vector2(W, END_H)
		_end.visible = false
		add_child(_end)


## 点面板外面 → 取消固定的细胞信息栏（Kevin 2026-09-07）。点在面板 / 详情框自己身上的鼠标事件
## 走不到这里（那两处都是 MOUSE_FILTER_STOP），所以能到这儿的就是「点了外面」。
## **不吃这一下**：它只是个信息框，玩家点棋盘多半是要走子或选目标，顺手收起就好，别把那一下也吞了
## —— 日志面板那边相反（它盖着大半个棋盘，点外面就是想关它）。
func _unhandled_input(event: InputEvent) -> void:
	if _tip_pinned < 0:
		return
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	_tip_pinned = -1
	_tip_key = ""        ## 固定与否决定列什么，键作废、强制重搭
	skill_hovered.emit({}, 0.0, -1.0)   ## 连带收掉浮在旁边的那张卡面


func _unhandled_key_input(event: InputEvent) -> void:
	## 设计稿把空格标成「结束回合」的快捷键。
	## 聊天框里打字时让路（拼音选字就是按空格）—— 判据同 L 键，见 CWChatBox.typing
	if CWChatBox.typing(get_viewport()):
		return
	if CWPauseMenu.modal():
		return   ## 暂停菜单压在上面（联机局不冻树）：空格归菜单的「确定」，不结束回合，issue #45
	if _end != null and _end.visible and event.is_action_pressed("ui_accept"):
		get_viewport().set_input_as_handled()
		end_turn_pressed.emit()


## 每帧调用。第一次会按人数把节点建出来，之后只改文字。
func refresh(m: CWMirror, q: Callable) -> void:
	if m == null or m.players.is_empty():
		return
	if _built != m.players.size():
		_build(m.players.size())
	_round.text = "第 %d 回合" % m.round_no
	## 环境恶化（2026-09-11）：肿瘤分期直接改压迫/增生/侵蚀/固化门槛的数，玩家得看得见现在是第几期。
	var stage_name: String = CWData.STAGE_NAMES[m.tumor_stage()]
	## 阶段文字取 d.phase_text（中文串「世界回合 E」）——
	## m.phase 是协议的机器词 setup/s/turn/e/finished，直接打出来顶栏就变成英文小写（规格 D-6）
	var phase_text := str(m.g["d"]["phase_text"])
	_phase.text = "%s · %s" % [phase_text, stage_name]

	var w := m.cancer_weighted()
	var goal: int = int(m.tune["cancer_win_weighted"])
	_weighted.text = str(w)
	_weighted_max.text = " / %d" % goal
	## 定案 B（2026-09-01）：首次达标只拉警报。引擎的 cancer_win_streak > 0 就是「警报期」，
	## 界面只负责把它显示出来（架构约定 #10），不自己数。
	var alarm: Dictionary = m.g["cancer_alarm"]
	if int(alarm["streak"]) > 0:
		_weighted_caption.text = "★ 警报 %d/%d" % [int(alarm["streak"]), int(alarm["hold_rounds"])]
		_weighted_caption.add_theme_color_override("font_color", CWStyle.CANCER)
	else:
		_weighted_caption.text = "癌性加权"
		_weighted_caption.add_theme_color_override("font_color", CWStyle.TEXT_DIM)
	_bar_fill.size.x = W * clampf(float(w) / float(goal), 0.0, 1.0)

	for pid in m.players.size():
		_refresh_row(m, pid)
	_update_tip(m, q)

	_level.text = CWData.LEVEL_NAMES[m.immune_level]
	## 门槛**按人数分档**（四人 6/16/30、六人 10/20/30）——
	## 别读 CWData.LEVEL_MIN_MEMORY 那张常量表，那是六人档兼缺省（同 CWGame.gain_memory）——
	## 内核已按人数算好放进 d.level_thresholds；tier B 缺席时给空表，
	## memory_text / level_progress 自会退成「只报数、不画条」（t_tier_b_absent 的「空但不崩」）
	var tiers: Array = Array(m.g["d"].get("level_thresholds", []))
	_memory.text = memory_text(m.memory, m.immune_level, tiers)
	_layout_level()      ## 记忆行的宽度变了，数字要重新居中（见 _layout_level）
	var p := level_progress(m.memory, m.immune_level, tiers)
	## X 级没有「下一级」，条整个收起来 —— 画一根永远满的条等于骗人
	_lv_bar_bg.visible = p >= 0.0
	_lv_bar_fill.visible = p >= 0.0
	_lv_bar_fill.size = Vector2(W * maxf(p, 0.0), BAR_H)
	_update_info_tip(m, tiers)


## 回到主菜单时清空：下一局人数可能不同，节点结构要按新人数重建。
func reset() -> void:
	_chrome()
	_end.visible = false
	for c in get_children():
		if c == _bg or c == _end:
			continue
		remove_child(c)
		c.queue_free()
	_rows.clear()
	_built = 0
	net_seats = []
	_tip = null       ## 悬浮框也在刚才那波清掉了，别留野引用
	_tip_pid = -1
	_tip_pinned = -1
	_tip_key = ""
	_info = null
	_info_key = ""
	_info_hover = ""
	_stage_zone = null


func show_end_turn(on: bool) -> void:
	_chrome()
	_end.visible = on and _layer_end


## 教程的 UI 层开关（`ui_layers.end_turn` / `round_no`，只有 `CWMatch` 教程局每帧喂）。
## 「结束回合」是**闸**不是显隐：`show_end_turn(true)` 也得按它再关一道 ——
## 否则轮到玩家时询问桥会把它重新亮出来，而第一 ~ 五关整关不许结束回合（方案 §2.3）
func guide_layers(end_turn: bool, round_no: bool) -> void:
	_layer_end = end_turn
	_chrome()
	if not end_turn and _end != null:
		_end.visible = false
	## 回合块关掉 = 它那 62px 让给下面的行（见 _layer_round）。**位置是 _build 时算死的**，
	## 所以开关一变就得重搭一次；`refresh` 每帧全量刷，重搭之后下一帧内容自己回来
	if round_no != _layer_round:
		_layer_round = round_no
		if _built > 0:
			_build(_built)
	if _round != null:
		_round.visible = round_no
	if _phase != null:
		_phase.visible = round_no
	if _stage_zone != null:
		_stage_zone.visible = round_no   ## 那一行都不显示了，感应区也不该还在那儿等人


## 教程提亮层用（scripts/tutor/cw_tutor_spot.gd，S2）：某块区域的屏幕矩形。"round" 回合 / 阶段 / 事件块，"row:<pid>" 玩家行，
## "pips:<pid>" 该行的手牌方块，"level" 免疫等级块，"end" 结束回合按钮。没建好 / 此刻不显示 → 零矩形（提亮就不画）
func rect_of(what: String) -> Rect2:
	if _built == 0:
		return Rect2()
	var at := global_position
	if what == "round":
		return Rect2(at + Vector2(PAD, PAD), Vector2(W, ROUND_H))
	if what == "level":
		return Rect2(at + Vector2(PAD, _level_y), Vector2(W, LEVEL_H))
	if what == "end":
		return _end.get_global_rect() if _end != null and _end.visible else Rect2()
	var parts := what.split(":")
	if parts.size() != 2:
		return Rect2()
	var pid := int(parts[1])
	if pid < 0 or pid >= _rows.size():
		return Rect2()
	if parts[0] == "row":
		return (_rows[pid]["bg"] as Control).get_global_rect()
	if parts[0] == "pips":
		var pips: Array = _rows[pid]["pips"]
		var r: Rect2 = (pips[0] as Control).get_global_rect()
		for p in pips:
			r = r.merge((p as Control).get_global_rect())
		return r
	return Rect2()


## ---- 能量增损的行内提示（issue #48）----
## 棋盘上飘 ±数字的同一拍，右栏那一行的能量数字色闪一下（进账青绿、出账粉红，同 CWEnergyFx 的笔）——
## 两处同步，眼睛才把「棋盘上这只」和「右栏那一行」对上。
##
## **只闪色、不滚数字**：这一行每帧全量刷（见文件头），滚数字得另记一份「正在显示的值」，
## 而那份值一旦和引擎错开就是两套真相 —— 右栏是常驻信息，宁可朴素也不能骗人。
const ENERGY_FLASH := 0.55
var _energy_flash := {}   ## pid -> [开演的 ticks_msec, 是不是进账]


## 由 `CWMatch._sync_cells` 的镜像差分调（和棋盘那条飘字同一处）
func bump_energy(pid: int, up: bool) -> void:
	_energy_flash[pid] = [Time.get_ticks_msec(), up]


## 这一行的能量数字此刻什么色。`age` < 0 或已过 ENERGY_FLASH = 没在闪 → 常色。
## **纯函数**（时间从外面进来，无头测试直接核）
static func energy_color(dead: bool, age: float, up: bool) -> Color:
	if dead:
		return CWStyle.TEXT_OFF
	if age < 0.0 or age >= ENERGY_FLASH:
		return CWStyle.TEXT_HI
	## 缓出：起手就是满色，快收时才追上常色 —— 一眼看得见，又不会闪得刺眼
	var k := age / ENERGY_FLASH
	return (CWStyle.ENERGY_GAIN if up else CWStyle.ENERGY_LOSS).lerp(CWStyle.TEXT_HI, k * k)


## 这一席此刻闪了多久（秒）；没在闪 → -1
func _flash_age(pid: int) -> float:
	if not _energy_flash.has(pid):
		return -1.0
	var e: Array = _energy_flash[pid]
	return float(Time.get_ticks_msec() - int(e[0])) / 1000.0


## 底框标「轮到谁」（Kevin 2026-09-12：开局落子、复活阶段也要亮）：行动回合里是 current_pid；
## 回合之外（落子 / 复活 / 卡牌追问）是引擎正在问的那一席 asking_pid（本地由 CWGame.ask 记，
## 联机由 state 报文的 turn 记）；两者都没有（结算演出中）就谁都不亮。**纯函数**。
static func acting_pid(m: CWMirror) -> int:
	return m.current_pid if m.current_pid >= 0 else m.asking_pid


func _refresh_row(m: CWMirror, pid: int) -> void:
	var row: Dictionary = _rows[pid]
	var p: Dictionary = m.player(pid)
	var immune: bool = p["faction"] == CWData.Faction.IMMUNE
	var faction_color: Color = CWStyle.IMMUNE if immune else CWStyle.CANCER
	row["fac"].color = faction_color
	row["name"].text = p["name"]
	var on: bool = acting_pid(m) == pid

	## 开局布置阶段是一个一个落子的：玩家已经建好，细胞还没有。
	## 这一行先只显示名字和阵营色，别去问一个还不存在的细胞 —— 但轮到它落子时底框照亮
	if pid >= m.cells.size():
		row["bg"].color = Color(faction_color, 0.10 if on else 0.0)
		row["name"].add_theme_color_override("font_color", CWStyle.TEXT_HI if on else CWStyle.TEXT_OFF)
		row["type"].text = "待落子"
		row["energy"].text = ""
		row["income"].text = ""
		_set_pips(row, 0, CWStyle.TEXT_OFF_DIM)
		row["skills"].text = ""
		row["icon"].visible = false
		return

	var cell: Dictionary = m.cell_of(pid)
	var dead: bool = not cell["alive"]
	row["bg"].color = Color(faction_color, 0.10 if on else 0.0)
	row["name"].add_theme_color_override("font_color",
		CWStyle.TEXT_OFF if dead else (CWStyle.TEXT_HI if on else CWStyle.TEXT))
	## 种类名按阵营查表；死亡占位细胞（教程 fixture 的缺席方）种类为 -1，显示空串
	var tname := ""
	if immune:
		if cell["itype"] >= 0:
			tname = CWData.IMMUNE_TYPE_NAMES[cell["itype"]]
	elif cell["ctype"] >= 0:
		tname = CWData.CANCER_TYPE_NAMES[cell["ctype"]]
	row["type"].text = tname
	if pid < net_seats.size():
		var seat: Dictionary = net_seats[pid]
		if seat.get("kind", "") == "ai":
			row["type"].text += " · AI"
		elif seat.get("kind", "") == "human" and not seat.get("online", true):
			row["type"].text += " · 离线代打"
	## 教程的「无限能量」换成标志文字（渲染点三处之一，新手教程 v2 方案 §3.2(b) / CWTutorLayers）；正式局照常写数字
	row["energy"].text = CWTutorLayers.energy_text(maxi(cell["energy"], 0))
	var flash: Array = _energy_flash.get(pid, [0, true])
	row["energy"].add_theme_color_override("font_color",
		energy_color(dead, _flash_age(pid), bool(flash[1])))
	row["income"].text = "" if dead else income_text(m, cell)
	## 手牌方块：持有的填阵营色，其余留描边色
	_set_pips(row, cell["hand"].size(), CWStyle.TEXT_OFF if dead else faction_color)
	var n_skill: int = cell["equipped"].size()
	row["skills"].text = "技 %d" % n_skill
	row["skills"].add_theme_color_override("font_color",
		CWStyle.TEXT_HI if n_skill > 0 else CWStyle.TEXT_OFF)

	var icon: Sprite2D = row["icon"]
	var icon_ok: bool = cell["itype"] >= 0 if immune else cell["ctype"] >= 0
	icon.visible = icon_ok          ## 死亡占位（教程 fixture 缺席方）没有种类图标
	icon.modulate.a = 0.35 if dead else 1.0
	if icon_ok:
		icon.texture = IMMUNE_ICON[cell["itype"]] if immune else CANCER_ICON[cell["ctype"]]


# ============ 建节点（只跑一次）============

## 胜负进度块的顶边：回合块关着就顶上去（见 _layer_round）
func _score_top() -> float:
	return PAD + (ROUND_H + GAP if _layer_round else 0)


## 玩家列表第一行的顶边。**只有这一处算**（_build 摆行、_show_tip 对齐悬浮框，两边不许各算一遍）
func rows_top() -> float:
	return _score_top() + SCORE_H + GAP


## n 席时免疫等级那一块的底边（测试拿它核对「一行一席都放得下」，PRD:417）。**纯函数**
func level_bottom(n: int) -> float:
	return rows_top() + n * ROW_H + GAP + LEVEL_H


func _build(n: int) -> void:
	_chrome()
	for c in get_children():
		if c == _bg or c == _end:
			continue      ## 底板和结束回合按钮跟人数无关，留着
		remove_child(c)
		c.queue_free()
	_rows.clear()
	_built = n
	_tip = null
	_tip_pid = -1
	_tip_pinned = -1
	_tip_key = ""
	_info = null
	_info_key = ""
	_info_hover = ""      ## 感应区连同浮窗一起重建，旧的那份「正停在哪儿」作废

	# ① 回合 / 阶段
	_round = _put(CWStyle.label("", CWStyle.SIZE_BIG, CWStyle.TEXT_HI), PAD, PAD, W)
	_phase = _put(CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM), PAD, PAD + 36, W)
	## #50：悬停「肿瘤 n 期」浮出当期效果。感应区做**整条阶段行**（10px 小字行框 16 高），
	## 不是只框住「肿瘤II期」那四个字 —— 那点面积算不上一个命中目标（同玩家行那条的理由）
	_stage_zone = _put_hover(Vector2(PAD, PAD + 36), Vector2(W, 16), "stage")

	# ② 胜负进度：一行标签 + 一条进度条
	var y := _score_top()
	_weighted_caption = _put(CWStyle.label("癌性加权", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM), PAD, y + 10, 100)
	_weighted_max = _put(CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM),
		PAD, y + 10, W, HORIZONTAL_ALIGNMENT_RIGHT)
	_weighted = _put(CWStyle.label("", CWStyle.SIZE_BODY, CWStyle.CANCER),
		PAD, y, W - 36, HORIZONTAL_ALIGNMENT_RIGHT)
	var track := ColorRect.new()
	track.color = Color("0a0f16")
	track.position = Vector2(PAD, y + 28)
	track.size = Vector2(W, 8)
	add_child(track)
	_bar_fill = ColorRect.new()
	_bar_fill.color = CWStyle.CANCER
	_bar_fill.position = Vector2(PAD, y + 28)
	_bar_fill.size = Vector2(0, 8)
	add_child(_bar_fill)

	# ③ 玩家列表
	y = rows_top()
	for i in n:
		_rows.append(_build_row(y + i * ROW_H, i))

	# ④ 免疫等级（上面一道分隔线）
	y += n * ROW_H + GAP
	_level_y = y
	var rule := ColorRect.new()
	rule.color = Color(CWStyle.LINE, 0.25)
	rule.position = Vector2(PAD, y)
	rule.size = Vector2(W, 1)
	add_child(rule)
	var lv_cap := CWStyle.label(LEVEL_CAPTION, CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	_put(lv_cap, PAD, y + 20, 80)
	## 等级数字**居中在「免疫等级」和记忆行之间那道缝里**（Kevin 2026-09-10 定）。
	##
	## 位置**只能在 refresh() 里现算**（`_layout_level`）：缝的右边缘跟着记忆行的长短走，
	## 而那串会变 ——「抗原记忆 0 / 6」和「抗原记忆 18 / 20」差着 15px，
	## X 级还会换成「效应记忆 25」。在这儿算死就等于又埋一个要人记得同步的常数
	## （issue #6 就是这么来的：原来数字右对齐到 `W - 92`，那 92 是照旧文案量的，
	## 记忆行一加「/ 下一档」就顶到数字上了）。
	##
	## 纵向按**基线**对齐而不是按行框：两个字号的行框虚高不一样（10px 的 ascent 11、
	## 20px 的 22），照行框顶对齐会差 3px，并排时一眼就看得出来。
	var lv_y: float = y + 20 + CWStyle.FONT.get_ascent(CWStyle.SIZE_LABEL) \
		- CWStyle.FONT.get_ascent(CWStyle.SIZE_BODY)
	_level = _put(CWStyle.label("", CWStyle.SIZE_BODY, CWStyle.IMMUNE),
		PAD, lv_y, 0, HORIZONTAL_ALIGNMENT_CENTER)
	_memory = _put(CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM),
		PAD, y + 20, W, HORIZONTAL_ALIGNMENT_RIGHT)
	## 升级进度条（Kevin 2026-09-10：「方便玩家观察和计算」）。
	##
	## **摆在这一块的底边，而且只有 4px 高** —— 文件头那条「一个数都别改」是硬的：
	## 6 人局五块加起来 530，只余 10px，把哪一块调高一点就溢出。
	## 好在 44px 里文字的**墨迹**只到 y+31（点阵字的行框虚高 23px 而字形只有 10px），
	## y+34 起是空的，细条正好塞得进去，不占任何人的地方。
	_lv_bar_bg = ColorRect.new()
	_lv_bar_bg.color = Color(CWStyle.TEXT_OFF, 0.30)
	_lv_bar_bg.position = Vector2(PAD, y + BAR_DY)
	_lv_bar_bg.size = Vector2(W, BAR_H)
	_lv_bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_lv_bar_bg)
	_lv_bar_fill = ColorRect.new()
	_lv_bar_fill.color = CWStyle.IMMUNE
	_lv_bar_fill.position = _lv_bar_bg.position
	_lv_bar_fill.size = Vector2(0, BAR_H)
	_lv_bar_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_lv_bar_fill)
	## #49：悬停免疫等级那**一整块**浮出升级规则。范围同 `rect_of("level")`（引导提亮用的也是它）——
	## 这一块是四个标签加两条色带拼出来的，逐个挂 mouse_entered 等于把「这一块」散写六遍
	_put_hover(Vector2(PAD, _level_y), Vector2(W, LEVEL_H), "level")

	## ⑤「结束回合」钉在底部（设计稿 margin-top:auto），在 _chrome() 里建


func _build_row(y: float, pid: int) -> Dictionary:
	var bg := ColorRect.new()
	bg.position = Vector2(PAD, y)
	bg.size = Vector2(W, ROW_H)
	bg.color = Color(0, 0, 0, 0)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	## 悬停整行 → 浮出该玩家的已装备清单（设计稿：贴着「技 N」往左浮）。
	## 感应区做整行而不是只做「技 N」两个字：44px 的行才够格算命中目标。
	var hover := Control.new()
	hover.position = Vector2(PAD, y)
	hover.size = Vector2(W, ROW_H)
	hover.mouse_filter = Control.MOUSE_FILTER_PASS   ## 只感应悬停，不吃点击
	hover.mouse_entered.connect(func() -> void: _tip_pid = pid)
	hover.mouse_exited.connect(func() -> void:
		if _tip_pid == pid:
			_tip_pid = -1)
	## 点一下**固定**这一行的详情（2026-09-04 Kevin 要的）：不固定的话框会随鼠标一起消失，
	## 想读技能正文就永远够不着它。再点同一行取消，点别的行直接换过去。
	hover.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_tip_pinned = -1 if _tip_pinned == pid else pid
			_tip_key = ""      ## 固定与否决定列什么，键作废、强制重搭
			skill_hovered.emit({}, 0.0, -1.0))
	add_child(hover)

	var x: float = PAD + ROW_PAD
	var fac := ColorRect.new()            ## 阵营色条 4×30
	fac.position = Vector2(x, y + (ROW_H - 30) / 2.0)
	fac.size = Vector2(4, 30)
	add_child(fac)
	x += 4 + 8

	## 贴图有 16/24/32 三种尺寸，一律居中摆、不缩放 —— 非整数倍会糊。
	var icon := Sprite2D.new()
	icon.position = Vector2(x + ICON / 2.0, y + ROW_H / 2.0)
	add_child(icon)
	x += ICON + 8

	var nm := _put(CWStyle.label("", CWStyle.SIZE_BODY, CWStyle.TEXT), x, y + 4, NAME_W)
	## 联机昵称最长 12 字（20px 字 = 240px），不裁会压到同一行右对齐的能量数上；
	## 本地对局的「免疫A」只有 52px，不受影响（2026-09-03 排版体检）
	nm.clip_text = true
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	## **先开裁切再定尺寸**（架构约定；不裁的 Label 最小宽 = 全文宽，会把定下的宽度顶开）——
	## 2026-09-07 Kevin 拍到「图标重叠」：联机局的「恶性黑色素瘤 · 离线代打」正是这么压过去的。
	## 实际宽度等下面手牌方块定了位再收到方块左边
	var ty := CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	ty.clip_text = true
	ty.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_put(ty, x, y + 26, 110)
	var right: float = PAD + W - ROW_PAD
	## 能量数右对齐到预计收入左边（顶行从右往左：+x.x → 能量 → 技 N，Kevin 2026-09-06 定的顺序）
	var en := _put(CWStyle.label("", CWStyle.SIZE_BODY, CWStyle.TEXT_HI),
		x, y + 4, right - INCOME_RESERVE - x, HORIZONTAL_ALIGNMENT_RIGHT)
	## 手牌方块：右对齐贴到行的右缘，占行底那一行
	var pips: Array = []
	var total: float = CWData.HAND_MAX * (PIP + PIP_GAP) - PIP_GAP
	for k in CWData.HAND_MAX:
		var pip := ColorRect.new()
		pip.position = Vector2(right - total + k * (PIP + PIP_GAP), y + 30)
		pip.size = Vector2(PIP, PIP)
		pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(pip)
		pips.append(pip)
	## 种类小字铺到手牌方块左边为止（这一行原来还摆着本回合历史小卡，Kevin 2026-09-11 删了）
	ty.size.x = maxf(40.0, right - total - 4.0 - x)
	## 预计收入「+x.x」贴行右缘、能量数右边（Kevin 2026-09-06：每回合预计拿到的有氧 / 无氧呼吸，显示在能量边）
	var inc := _put(CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM),
		x, y + 10, right - x, HORIZONTAL_ALIGNMENT_RIGHT)
	## 「技 N」放**能量那一行**（团队 2026-08-28 选的右边那版），右对齐到能量左侧
	var sk := _put(CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM),
		x, y + 10, right - ENERGY_RESERVE - INCOME_RESERVE - x, HORIZONTAL_ALIGNMENT_RIGHT)
	return { "bg": bg, "fac": fac, "icon": icon,
		"name": nm, "type": ty, "energy": en, "income": inc, "pips": pips, "skills": sk }


func _build_end_button() -> PanelContainer:
	var p := PanelContainer.new()
	## 设计稿 .btn.go：底与描边同色，字反过来用深色
	var box := CWStyle.box(1.0, CWStyle.IMMUNE, 6, 8)
	box.border_color = CWStyle.IMMUNE
	p.add_theme_stylebox_override("panel", box)
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(v)
	var dark := Color("0d1620")
	for pair in [["结束回合", CWStyle.SIZE_BODY], ["空格", CWStyle.SIZE_LABEL]]:
		var l := CWStyle.label(pair[0], pair[1], dark)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(l)
	p.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			end_turn_pressed.emit())
	return p


# ============ 被动技能悬浮框 ============

## 悬停玩家行时，在面板左侧浮出该细胞的已装备清单。没装备就不浮（空框是噪音）。
## 每帧从 refresh() 进来：装备可以在悬停期间变（BCL-2 触发会弃掉自己），
## 键没变就不重搭。死亡不掉装备（口径 #65 批），所以死了照样能看。
## 详情框里列什么：**纯函数**，测试直接核对，不用真渲染。
##
## 两档内容，因为两种用法的诉求不同：
## · **悬停**（`full = false`）只列已装备的永久技能 —— 平时划过右栏时最少的打扰，
##   没装备就干脆不浮（这是 2026-08-30 定的老行为，别因为加了固定就把它变吵）；
## · **固定**（`full = true`，点了那一行）列全套：细胞种类的自带技能 → 主动技能 → 已装备。
##   被动技能（【伪足穿透】【囊性护甲】【I-各司其职】…）**永远不进行动栏**，
##   这里是玩家唯一读得到它们的地方（2026-09-04 Kevin 要的）。
##
## 每项是 { text, info }：`info` = 悬停时浮出的 PRD 原文；`head` 项是小标题，不可悬停。
## 主动技能那一段直接走 `CWActions.action_kinds()` —— 和行动栏同一份清单，两处对不上是迟早的事。
## **即时卡挂上的修饰条目**（本回合 / 本世界回合 / 待触发）两种形态都列在最后（`mod_rows`）——
## 之前只有日志里看得到它们（Kevin 2026-09-06：「现在看不到即时的 buff」）。
static func tip_rows(m: CWMirror, pid: int, full: bool, q: Callable) -> Array:
	if pid < 0 or pid >= m.cells.size():
		return []
	var cell: Dictionary = m.cell_of(pid)
	var immune: bool = cell["faction"] == CWData.Faction.IMMUNE
	var equipped: Array = cell["equipped"]
	var phase := CWCardData.cancer_phase(m.round_no)   ## 分档写法高亮当前档（Kevin 2026-09-06）
	var mods: Array = mod_rows(cell, phase)
	var out: Array = []
	if not full:
		if equipped.is_empty() and mods.is_empty():
			return []
		if not equipped.is_empty():
			out.append({ "head": "已装备 · 持续生效" })
			out.append_array(equip_rows(cell, phase))
		out.append_array(mods)
		return out
	var tinfo: Dictionary = CWCardInfo.describe_type(cell["itype"], "【细胞种类】") if immune \
		else CWCardInfo.describe_ctype(cell["ctype"])
	if not tinfo["lines"].is_empty():
		out.append({ "head": "细胞种类" })
		out.append({ "text": tinfo["name"], "info": tinfo })
	var acts: Array = []
	for act in m.action_kinds_of(cell):
		acts.append({ "text": CWData.act_name(act, cell["faction"]),
			"info": CWCardInfo.describe_act_for(q, cell, act) })
	if not acts.is_empty():
		out.append({ "head": "主动技能" })
		out.append_array(acts)
	if not equipped.is_empty():
		out.append({ "head": "已装备 · 持续生效" })
		out.append_array(equip_rows(cell, phase))
	out.append_array(mods)
	return out


## 已装备的永久技能那一段。带**限次额度**的在名字后面写「余 N 次」：
## 【癌症干性】是永久技能，可它复活时发的「前两次向癌性组织移动免费」额度住在 `cell["mods"]` 里，
## 而 mods 那一段的标题写的是「即时 · …」—— 照直列，同一张卡就在框里出现两次，
## 还被扣上「即时」的帽子（Kevin 2026-09-13：「『癌症干性』被同时视为即时和永久」）。
## 所以额度归到它自己这一行来，`mod_rows` 那边跳过已装备的同名条目。
static func equip_rows(cell: Dictionary, phase: int) -> Array:
	var out: Array = []
	for n: String in cell["equipped"]:
		var left: int = mod_uses(cell, n)
		out.append({ "text": n if left <= 0 else "%s 余%d次" % [n, left],
			"info": CWCardInfo.describe(n, cell["faction"], phase) })
	return out


## 这只细胞身上叫这个名字的修饰条目还剩几次（各时钟相加）。0 = 没有这条。**纯函数**
static func mod_uses(cell: Dictionary, mod_name: String) -> int:
	var n := 0
	for m in cell["mods"]:
		if String(m["name"]) == mod_name:
			n += int(m["uses"])
	return n


## 即时卡挂在细胞上的修饰条目（CWGame.add_mod）按时钟分三段：本回合 / 本世界回合 / 待触发（不过期，挂着等触发）。
## 同名合并、次数 >1 写「×N」；条目悬停浮出的是那张卡的 PRD 原文。
## 名字带「·待发」的是引擎内部标记（如【细胞因子网络】的待发计数），不是玩家打出的东西，不列。
## **和已装备永久技能同名的也不列**：那是那张永久技能自己的限次额度（【癌症干性】复活时发的
## 免费移动），归到「已装备」那一行写成「余 N 次」（见 `equip_rows`）——
## 列在这儿等于把一张永久技能又说成即时的（Kevin 2026-09-13）。
## phase = 癌症卡的分期，条目详情里的分档写法高亮这一档（-1 = 不高亮）
static func mod_rows(cell: Dictionary, phase := -1) -> Array:
	var uses_by := { "turn": {}, "round": {}, "": {} }
	for m in cell["mods"]:
		var mod_name: String = m["name"]
		if mod_name.contains("·待发") or cell["equipped"].has(mod_name):
			continue
		var clock: String = m["until"] if uses_by.has(m["until"]) else ""
		uses_by[clock][mod_name] = int(uses_by[clock].get(mod_name, 0)) + int(m["uses"])
	var out: Array = []
	for pair in [["turn", "即时 · 本回合"], ["round", "即时 · 本世界回合"], ["", "即时 · 待触发"]]:
		var group: Dictionary = uses_by[pair[0]]
		if group.is_empty():
			continue
		out.append({ "head": pair[1] })
		for mod_name in group:
			var uses: int = group[mod_name]
			out.append({ "text": mod_name if uses <= 1 else "%s ×%d" % [mod_name, uses],
				"info": CWCardInfo.describe(mod_name, cell["faction"], phase) })
	return out


## 框高：小标题 15、条目 24、上下内边距各 8；固定态底下多一行操作提示
static func tip_height(rows: Array, full: bool) -> float:
	var h := 16.0
	for r in rows:
		h += 15.0 if r.has("head") else 24.0
	return h + (15.0 if full else 0.0)


## #49：悬停「抗原 / 效应记忆」那一块浮出的升级规则。**纯函数**，一个数都不写死 ——
## 门槛取内核按人数算好的 `d.level_thresholds`（同 memory_text，四人 / 六人各一档），
## 每一级的收益取 CWData 的按等级表。门槛表或收益表哪天改了，这儿自己跟着变。
##
## tiers 不全（tier B 缺席时是空表）就返回空表、干脆不画 —— 同 memory_text 的退路：
## 半张门槛表比没有更糟，玩家会照着它算。
##
## ⚠ 收益读的是 `CWData` 常量而不是 `tune`：按等级的那两张表（aerobic_by_level /
## immune_move_cancerous）不在观测协议的 tune 里（CWObsProto.TUNE 只有八个键），
## 平衡扫描改旋钮时这儿会跟不上。正式局两者恒等。
static func level_rules_rows(tiers: Array, level: int) -> Array:
	var n: int = CWData.LEVEL_NAMES.size()
	if tiers.size() < n:
		return []
	var out: Array = [{ "text": "免疫等级 · 升级规则", "color": CWStyle.TEXT_DIM }]
	for lv in n:
		## 当前这一档用免疫青标出来：四行数字里得有一行是「我在这儿」
		out.append({ "text": "%s 级　记忆 %d 起　有氧 %s　净化 %s" % [CWData.LEVEL_NAMES[lv],
				int(tiers[lv]), CWData.fmt(CWData.AEROBIC_BY_LEVEL[lv]),
				CWData.fmt(CWData.IMMUNE_MOVE_CANCEROUS[lv])],
			"color": CWStyle.IMMUNE if lv == level else CWStyle.TEXT })
		if lv == CWData.DIFFERENTIATE_MIN_LEVEL:
			out.append({ "text": "　　解锁【分化】", "color": CWStyle.TEXT_DIM })
		if lv == n - 1:
			## X 级把计数器改名并从零重数（CWData.memory_name），不写清楚玩家会以为记忆丢了
			out.append({ "text": "　　解锁【效应应答】（%s从零重数）" % CWData.memory_name(lv),
				"color": CWStyle.TEXT_DIM })
	return out


## #50：悬停右上角「肿瘤 n 期」浮出的**当期**效果。**纯函数**。
##
## 固化门槛走内核算好的那一个数（`mirror.solidify_threshold()`，协议的 tune 里有这张三档表）；
## 其余四项协议没带，读 CWData 的同一张 `_BY_STAGE` 表 —— 界面不自己推分期，表一改这儿跟着变。
##
## ⚠ 无氧呼吸的分期增益（PRD 环境恶化那条 II +20% / III +50%）今天引擎里还没有，
## 所以这儿不写。哪天加了一张 `_BY_STAGE` 表，照下面的样子再补一行。
static func stage_rows(stage: int, solidify: int) -> Array:
	var s: int = clampi(stage, 0, CWData.STAGE_NAMES.size() - 1)
	var tiles: Vector2i = CWData.EROSION_TILES_BY_STAGE[s]
	var rooted: int = CWData.ROOTED_BY_STAGE[s]
	return [
		{ "text": "%s · 当前效果" % CWData.STAGE_NAMES[s], "color": CWStyle.TEXT_DIM },
		{ "text": "微环境压迫　能量损失 ×%s" % CWData.fmt(CWData.PRESSURE_MUL_BY_STAGE[s]),
			"color": CWStyle.TEXT },
		{ "text": "增生　每邻癌 %s%%，每固化 +%s%%" % [CWData.fmt(CWData.PROLIFERATE_BASE_BY_STAGE[s]),
			CWData.fmt(CWData.PROLIFERATE_SOLID_BY_STAGE[s])], "color": CWStyle.TEXT },
		{ "text": "侵蚀　2/3 概率 %d 格、1/3 概率 %d 格" % [tiles.x, tiles.y], "color": CWStyle.TEXT },
		{ "text": "固化　计数满 %s 转固化癌组织" % CWData.fmt(solidify), "color": CWStyle.TEXT },
		{ "text": "根深蒂固　%s" % ("未生效" if rooted <= 0
			else "每块固化每回合助推 %d 格" % rooted), "color": CWStyle.TEXT },
	]


## 一块只感应悬停的透明区（不吃点击，同玩家行那只）。kind 进 `_info_hover`，决定浮窗画哪一份。
func _put_hover(at: Vector2, sz: Vector2, kind: String) -> Control:
	var z := Control.new()
	z.position = at
	z.size = sz
	z.mouse_filter = Control.MOUSE_FILTER_PASS
	z.mouse_entered.connect(func() -> void: _info_hover = kind)
	z.mouse_exited.connect(func() -> void:
		if _info_hover == kind:
			_info_hover = "")
	add_child(z)
	return z


## 规则浮窗（#49 / #50）。和技能详情框同一套（键没变就不重搭），但**另起一只节点**：
## 那只按玩家行摆、这只按自己那一块摆，合成一只就得在里头再分两种锚点。
func _update_info_tip(m: CWMirror, tiers: Array) -> void:
	## 无头没有真鼠标，探针在时它说了算（见 info_hover_probe）
	if info_hover_probe.is_valid():
		_info_hover = String(info_hover_probe.call())
	var rows: Array = []
	var anchor := 0.0
	if _info_hover == "level":
		rows = level_rules_rows(tiers, m.immune_level)
		anchor = _level_y
	elif _info_hover == "stage":
		rows = stage_rows(m.tumor_stage(), m.solidify_threshold())
		anchor = PAD + 36.0
	if rows.is_empty():
		if _info != null:
			_info.visible = false
		_info_key = ""
		return
	var names := PackedStringArray()
	for r in rows:
		names.append(String(r["text"]))
	var key := "%s|%s" % [_info_hover, ",".join(names)]
	var h: float = 16.0 + rows.size() * INFO_ROW
	if key != _info_key or _info == null:
		_info_key = key
		if _info != null:
			remove_child(_info)
			_info.queue_free()
		_info = Control.new()
		_info.mouse_filter = Control.MOUSE_FILTER_IGNORE   ## 只是个牌子，别挡棋盘的悬停
		_info.size = Vector2(INFO_W, h)
		var bg := Panel.new()
		bg.add_theme_stylebox_override("panel", CWStyle.box(0.45, CWStyle.BTN_BG))
		bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_info.add_child(bg)
		var ry := 8.0
		for r in rows:
			var col: Color = r["color"]
			var l := CWStyle.label(String(r["text"]), CWStyle.SIZE_LABEL, col)
			l.position = Vector2(12, ry)
			_info.add_child(l)
			ry += INFO_ROW
		add_child(_info)
	_info.visible = true
	## 竖向对齐到自己那一块的顶边，够不着就往回挪。技能详情框正巧也在这条竖带上
	## （它按玩家行摆），钉住的时候真会撞上 —— Kevin 2026-09-06 报过「两个框叠在一起」。
	## 撞上就再往左让一格，不去抢它的位置。
	var top := clampf(anchor, 8.0, RECT.size.y - h - 8.0)
	var x := -(INFO_W + 8.0)
	if _tip != null and _tip.visible and top < _tip.position.y + _tip.size.y \
			and _tip.position.y < top + h:
		x -= TIP_W + 8.0
	_info.position = Vector2(x, top)


func _update_tip(m: CWMirror, q: Callable) -> void:
	var full: bool = _tip_pinned >= 0
	var pid: int = _tip_pinned if full else _tip_pid
	var rows: Array = tip_rows(m, pid, full, q)
	if rows.is_empty():
		if _tip != null:
			_tip.visible = false
		_tip_key = ""
		return
	var names := PackedStringArray()
	for r in rows:
		names.append(r.get("head", r.get("text", "")) + str(r.get("info", {}).get("lines", [])))
	## 分期进键：条目的详情（含分档高亮）是搭框时算好捏在闭包里的，跨期要重搭才会换档
	var key := "%d|%d|%d|%s" % [pid, int(full), CWCardData.cancer_phase(m.round_no), ",".join(names)]
	if key == _tip_key and _tip != null:
		_tip.visible = true
		return
	_tip_key = key
	if _tip != null:
		remove_child(_tip)
		_tip.queue_free()
	_tip = Control.new()
	_tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var h := tip_height(rows, full)
	_tip.size = Vector2(TIP_W, h)
	var row_top: float = rows_top() + pid * ROW_H
	_tip.position = Vector2(-(TIP_W + 8.0),
		clampf(row_top, 8.0, RECT.size.y - h - 8.0))
	var bg := Panel.new()
	bg.add_theme_stylebox_override("panel", CWStyle.box(0.45, CWStyle.BTN_BG))
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	## 固定态整块底板也收鼠标：指针在框内任何位置都算「被控件占着」，棋盘就不会把底下那一格的详情浮上来
	## （Kevin 2026-09-06 截图：技能详情和格子详情叠在一起）。不固定时照旧放行，理由同下面条目那段注释
	bg.mouse_filter = Control.MOUSE_FILTER_STOP if full else Control.MOUSE_FILTER_IGNORE
	_tip.add_child(bg)
	var y := 8.0
	for r in rows:
		if r.has("head"):
			var head := CWStyle.label(r["head"], CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
			head.position = Vector2(12, y)
			_tip.add_child(head)
			y += 15.0
			continue
		var item := CWStyle.label(r["text"], CWStyle.SIZE_BODY, CWStyle.TEXT)
		item.position = Vector2(12, y)
		if full:
			## 固定态才收鼠标：不固定时框会随鼠标离开玩家行而收起，
			## 让它挡事件只会把「移开就收」变成「移不开」
			item.size = Vector2(TIP_W - 24, 22)
			item.mouse_filter = Control.MOUSE_FILTER_STOP
			var info: Dictionary = r["info"]
			item.mouse_entered.connect(func() -> void:
				item.add_theme_color_override("font_color", Color.WHITE)
				skill_hovered.emit(info, _tip.global_position.x - CWCardInfo.W - 8.0, item.get_global_rect().position.y))
			item.mouse_exited.connect(func() -> void:
				item.add_theme_color_override("font_color", CWStyle.TEXT)
				skill_hovered.emit({}, 0.0, -1.0))
		_tip.add_child(item)
		y += 24.0
	if full:
		var hint := CWStyle.label("停在技能上看详情 · 再点该行取消固定",
			CWStyle.SIZE_LABEL, CWStyle.TEXT_OFF)
		hint.position = Vector2(12, y)
		_tip.add_child(hint)
	add_child(_tip)


## 能量旁的「预计收入」小字：免疫 = 下一次 S 阶段的【有氧呼吸】（CWWorld.aerobic_income），
## 癌症 = 回合末 / E 阶段的【无氧呼吸】份额（CWWorld.anaerobic_gain_for）。两个都是引擎的纯查询，
## 界面不抄算式（约定 #11）。纯函数，测试直接核对文案。
static func income_text(m: CWMirror, cell: Dictionary) -> String:
	## 有氧 / 无氧那一岔在内核里判（cw_obs_codec.gd:_cell_d 按阵营挑同一对函数），界面连岔路都不抄
	var v: int = m.income_of(cell)
	return "+%s" % CWData.fmt(v)


## 摆一个 Label 到面板内的绝对位置。
## 本面板全部绝对定位：各块高度是设计稿钉死的数，用容器反而要靠一堆 size_flags
## 才能复现同样的值，改起来还看不出跟标注稿的对应关系。
## 填 n 个方块。空格子不留白 —— 画成暗色描边，让「一共 8 格」这件事始终看得见。
func _set_pips(row: Dictionary, n: int, accent: Color) -> void:
	for k in row["pips"].size():
		var pip: ColorRect = row["pips"][k]
		pip.color = accent if k < n else CWStyle.TEXT_OFF_DIM
		pip.modulate.a = 1.0 if k < n else 0.45


## 把等级数字居中到「免疫等级」与记忆行之间那道缝里。
##
## **每次 refresh 都要重算**：缝的右边缘 = 记忆行的左缘，而记忆行右对齐、长度会变
## （「抗原记忆 0 / 6」比「抗原记忆 18 / 20」窄 15px，X 级又换成「效应记忆 25」）。
## 算死一个数就是又埋一个要人记得同步的常数 —— issue #6 正是那么来的。
##
## 做法是**把标签的盒子铺满整道缝、让它自己居中**，而不是算「中点减半个字宽」：
## 这样 I / II / III / X 宽度不同也各自居中，不必再去量字。
func _layout_level() -> void:
	if _level == null or _memory == null:
		return
	var f := CWStyle.FONT
	var cap_right: float = PAD + f.get_string_size(LEVEL_CAPTION,
		HORIZONTAL_ALIGNMENT_LEFT, -1, CWStyle.SIZE_LABEL).x
	var mem_left: float = PAD + W - f.get_string_size(_memory.text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, CWStyle.SIZE_LABEL).x
	_level.position.x = cap_right
	_level.size.x = maxf(mem_left - cap_right, 0.0)


## 当前这一档攒了多少（0..1）；**X 级返回 -1 = 没有下一级**，调用方据此把条收起来。
## **纯函数**，好直接测 —— 这一段有两个容易错的地方：
## ① 进度要按**本档区间**算（从 tiers[lv] 到 tiers[lv+1]），不是从 0 算，
##    否则 I→II 走到一半时条会显示 80%；
## ② 记忆**会被扣**（突变削 2），而等级只升不降 —— 于是 memory 可能掉到
##    tiers[lv] 以下，算出来是负的。钳住。
static func level_progress(memory: int, level: int, tiers: Array) -> float:
	if level >= tiers.size() - 1:
		return -1.0
	var lo := int(tiers[level])
	var hi := int(tiers[level + 1])
	if hi <= lo:
		return -1.0
	return clampf(float(memory - lo) / float(hi - lo), 0.0, 1.0)


## 右下角那行字。**升级前写成「8 / 10」**：光有当前值的话，「还差几次净化」
## 得玩家自己去记门槛（而门槛还按人数分档，记不住）。
## X 级之后没有门槛可写，回到只报数 —— 那时它管的是【效应应答】的费用，不是进度。
static func memory_text(memory: int, level: int, tiers: Array) -> String:
	var name := CWData.memory_name(level)
	if level >= tiers.size() - 1:
		return "%s %d" % [name, memory]
	return "%s %d / %d" % [name, memory, int(tiers[level + 1])]


func _put(l: Label, x: float, y: float, w: float,
		align := HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	l.position = Vector2(x, y)
	l.size = Vector2(w, 0)
	l.horizontal_alignment = align
	add_child(l)
	return l
