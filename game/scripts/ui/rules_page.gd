## rules_page.gd —— 规则速查：主菜单「规则速查」打开的一页式总览
##
## **数字一律现读 CWData / CWTuning 默认值，这里不写第二份**（ui_bridge 的
## 费用同一条纪律）——调平衡旋钮或改规则原文后，速查页自动跟上。
## 内容只收录引擎已实现且判定点明确的条目；细则以 PRD 为准，
## 这页是「打着打着忘了数」时看一眼的东西，不是规则书。
##
## 交互只有一件事：看完关掉（Esc / 右键）。内容 sections() 是纯函数，
## 无头测试核对关键数字有没有跟着常量走。
class_name CWRulesPage
extends Control

const W := 660
const H := 470
const PAD := 20
const COL_W := 300     ## 两栏，各 300，中缝 20
const TITLE_LINE := 24 ## 小节标题行高（20px 字）
const LINE := 15       ## 正文行高（10px 字）
const SECTION_GAP := 10


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	## 右键关闭必须接在 gui_input：本层是 STOP，鼠标事件在这儿就被吃掉了，
	## 永远到不了菜单路由的 _unhandled_input（Kevin 试玩当场抓到「右键关不掉」）。
	## Esc 是键盘事件不受 STOP 影响，走下面的 handle_input。
	gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed \
				and e.button_index == MOUSE_BUTTON_RIGHT:
			accept_event()
			visible = false)
	_build()


func open() -> void:
	visible = true


## 由 CWMainMenu 路由（覆盖层统一走菜单路由，同配置面板）
func handle_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		visible = false


## 速查内容：[{ title, lines }]。纯函数，数字全部现算。
## `tune` 可传入本局实际用的旋钮；不传则用默认值。
## ⚠ 默认值**不等于 PRD** —— 口径 #82 起，癌方占地单价等四项为平衡刻意偏离 PRD。
## 速查页显示的一律是**引擎实际在跑的数**，这正是它存在的意义（别让玩家看 PRD 对不上）。
static func sections(tune: CWTuning = null) -> Array:
	if tune == null:
		tune = CWTuning.new()
	return [
		{ "title": "怎么赢", "lines": [
			## 点阵字库没有 ≥ - 这类数学符号（字形覆盖测试盯着），中文说法代替
			"癌方：加权占地达到 %d（癌组织记 1、固化记 2）" % tune.cancer_win_weighted
				+ ("，且连续 %d 个世界回合末都达标（首次达标只是警报）" % tune.cancer_win_hold_rounds
				if tune.cancer_win_hold_rounds > 1 else ""),
			"免疫方：癌细胞全灭且无可复活的固化癌组织",
			"两条都在世界回合 E 的最后判；上限 %d 个世界回合" % CWData.LIMIT_ROUND,
		] },
		{ "title": "一个世界回合", "lines": [
			"S 阶段：复活 → 免疫方【有氧呼吸】收入",
			"玩家回合：按顺序行动，可连续行动到「结束回合」",
			"E 阶段：癌方【无氧呼吸】→ 增殖/侵蚀/压迫 → 固化衰减 → 判胜负",
		] },
		{ "title": "攻击判定（d6）", "lines": [
			## PRD：失败时自身 -0.5 能量（口径 #84）。写成条件式是因为它是平衡旋钮，
			## 平衡实验把它关掉时这半句要跟着消失——速查页不许出现和引擎不符的数
			"1-2 失败：弹回原格（费用不退）" + ("" if tune.counter_dmg_on_fail == 0
				else "，受反击 %s" % CWData.fmt(tune.counter_dmg_on_fail)),
			"3-5 成功（-%s） · 6 大成功（-%s）" % [
				CWData.fmt(tune.attack_dmg_success), CWData.fmt(tune.attack_dmg_crit)],
			"目标带【标记】：本次损失翻倍，随后消耗一层标记",
			## 上限是旋钮（口径 #88 定为 3）。0 = 不限时这一行要消失——
			## 速查页不许出现和引擎不符的数
			"每个行动回合最多攻击 %d 次" % tune.attack_max_per_turn
				if tune.attack_max_per_turn > 0 else "攻击次数不限（只受能量约束）",
		] },
		{ "title": "常用费用（能量）", "lines": [
			"迁移（免疫 I 级）：健康 %s / 癌性 %s，随等级降" % [
				CWData.fmt(tune.immune_move_healthy[0]),
				CWData.fmt(tune.immune_move_cancerous[0])],
			"抽卡：免疫 %s / 癌症 %s，每回合至多 %d 次" % [
				CWData.fmt(CWData.IMMUNE_DRAW_COST), CWData.fmt(CWData.CANCER_DRAW_COST),
				CWData.DRAW_MAX_PER_TURN],
			"突变 %s · 细胞毒素 %s · 裂解 %s" % [CWData.fmt(CWData.MUTATE_COST),
				CWData.fmt(CWData.TOXIN_COST), CWData.fmt(CWData.LYSE_COST)],
		] },
		{ "title": "能量即生命", "lines": [
			"能量归零死亡；支付费用不能让能量降到 0",
			"免疫死亡下个 S 阶段在骨髓复活；癌死亡需固化据点才能复活",
		] },
		{ "title": "固化癌组织", "lines": [
			## ⚠ 门槛存的是**十分整数**（30 = 3.0），而这句话说的是「几个回合」——
			## 一回合停留加 `SOLIDIFY_STEP`（10），所以要除一下。
			## 直接打门槛会变成「蹲满 30 回合」，而玩家正是照这一页学规则的
			## （2026-09-01 连同格子详情那处一起发现）
			"癌细胞停在癌组织上蹲满 %d 回合 → 固化（复活据点+高供能）" \
				% (tune.solidify_threshold / CWData.SOLIDIFY_STEP),
			"固化格不可净化，免疫要先用 T 细胞【裂解】破除",
		] },
		{ "title": "卡牌", "lines": [
			"【事件】抽到立即结算并弃置，不进手牌",
			"【技能】进手牌（上限 %d 张），随时可弃置" % CWData.HAND_MAX,
			"【永久技能】打出即装备：持续生效、死亡不掉、同名限一",
		] },
		{ "title": "对局中", "lines": [
			"L 键：对局日志 · 悬停格子 %ss：地形详情" % str(CWTileInfo.DELAY),
			"悬停右栏玩家行：查看其已装备的永久技能",
		] },
	]


func _build() -> void:
	var scrim := ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.55)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(scrim)

	var screen := CWView.screen_size()
	var panel := Control.new()
	panel.position = Vector2((screen.x - W) / 2.0, (screen.y - H) / 2.0)
	panel.size = Vector2(W, H)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(panel)

	var bg := Panel.new()
	bg.add_theme_stylebox_override("panel", CWStyle.box(0.45, CWStyle.PANEL))
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(bg)

	var title := CWStyle.label("规则速查", CWStyle.SIZE_BIG, CWStyle.TEXT_HI)
	title.position = Vector2(PAD, PAD - 4)
	panel.add_child(title)
	var src := CWStyle.label("细则以规则原文为准", CWStyle.SIZE_LABEL, CWStyle.TEXT_OFF)
	src.size = Vector2(W - PAD * 2, 14)
	src.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	src.position = Vector2(PAD, PAD + 12)
	panel.add_child(src)

	## 两栏铺小节：塞满左栏再起右栏（内容量是手工配平过的，正好两栏放下）
	var top := PAD + 44.0
	var limit := H - PAD - 20.0
	var x := float(PAD)
	var y := top
	for s in sections():
		var need: float = TITLE_LINE + s["lines"].size() * LINE + SECTION_GAP
		if y + need > limit and x < COL_W:
			x = PAD + COL_W + 20.0
			y = top
		var st := CWStyle.label(s["title"], CWStyle.SIZE_BODY, CWStyle.IMMUNE)
		st.position = Vector2(x, y)
		panel.add_child(st)
		y += TITLE_LINE
		for line in s["lines"]:
			var l := CWStyle.label(line, CWStyle.SIZE_LABEL, CWStyle.TEXT)
			l.position = Vector2(x, y + 2)
			l.size = Vector2(COL_W, LINE)
			l.clip_text = true
			l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			panel.add_child(l)
			y += LINE
		y += SECTION_GAP

	var hint := CWStyle.label("ESC / 右键 返回", CWStyle.SIZE_LABEL, CWStyle.TEXT_OFF)
	hint.size = Vector2(W - PAD * 2, 14)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.position = Vector2(PAD, H - PAD - 10)
	panel.add_child(hint)
