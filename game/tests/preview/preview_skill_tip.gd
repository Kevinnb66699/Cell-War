extends SceneTree
## 右栏技能框：【癌症干性】的限次额度归到它自己那一行 —— 给人看的工具，不是测试。
##
## **为什么要出图**：这张卡是永久技能，可它复活时发的「本世界回合前两次向癌性组织移动免费」
## 额度住在 `cell["mods"]` 里，而 mods 那一段的标题写着「即时 · …」——
## 改之前同一张卡在同一个框里出现两次，一次永久一次即时（Kevin 2026-09-13）。
## 改完之后额度写在它自己那一行「余2次」，即时段里只剩真正的即时卡。
##
## 两块右栏并排，各浮一只技能框：左边照旧版行文摆的**示意**（那份行文已经没了，只能手摆），
## 右边是现在**真渲染**出来的。两边的排版参数都取自 `_update_tip`（8 / 15 / 24 / x=12），
## 所以行距、字号、底板是一致的，看的就是内容差别。
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview/preview_skill_tip.gd -- <输出.png>
const WARMUP := 12
const TIP_W := 200.0
## 框浮在面板左侧 8px 处；纵向就是 `_update_tip` 里那条 row_top（pid = 1 那一行）
const PANEL_X_LEFT := 216.0   ## 两块「框 200 + 缝 8 + 面板 264」正好铺满 960，左右不打架
const PANEL_X_RIGHT := 696.0
const TIP_X_LEFT := PANEL_X_LEFT - TIP_W - 8.0
const TIP_X_RIGHT := PANEL_X_RIGHT - TIP_W - 8.0
const TIP_Y := 188.0   ## PAD 16 + ROUND_H 52 + GAP 10 + SCORE_H 56 + GAP 10 + 1×ROW_H 44

## 改之前那只框里的行：[是不是小标题, 文字]
const BEFORE_ROWS: Array = [
	[true, "已装备 · 持续生效"], [false, "癌症干性"],
	[true, "即时 · 本世界回合"], [false, "癌症干性 ×2"],
	[true, "即时 · 待触发"], [false, "DNA损伤修复"],
]

var _out := "user://skill_tip.png"
var _frames := 0
var _panels: Array = []
var _before: Control


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	var bg := ColorRect.new()
	bg.color = CWStyle.GROUND
	bg.size = Vector2(960, 540)
	root.add_child(bg)

	var g := CWGame.new()
	g.init(CWData.FACTION_ORDER[2], 1)
	g.setup.build_board()
	g.round_no = 9
	g.cells.append(CWSetup.make_cell(0, 0, CWData.Faction.IMMUNE, Vector2i(5, 0),
		CWData.ImmuneType.BASIC, -1, 100))
	## 癌细胞：装备【癌症干性】（永久），身上挂着它复活时发的 2 次额度 + 一张真正的即时卡
	var can := CWSetup.make_cell(1, 1, CWData.Faction.CANCER, Vector2i(0, 0), -1,
		CWData.CancerType.MELANOMA, 100)
	g.cells.append(can)
	can["equipped"].append("癌症干性")
	g.add_mod(can, "癌症干性", 2, "round")
	g.add_mod(can, "DNA损伤修复", 1, "")

	## 批 1 步 6：面板吃 CWMirror。这张图只看**悬停**态的技能框（_tip_pid，full=false），
	## 那一档不问「当前影响」，所以纯查询句柄给个空 Callable
	var m := CWMirror.new()
	var merr := m.sync_from(g)
	if merr != "":
		push_error("preview_skill_tip：镜像装载失败 —— %s" % merr)
	## 两块真面板：左边只做背景（框自己手摆），右边连框一起真渲染
	for i in 2:
		var p := CWMatchPanel.new()
		root.add_child(p)
		p.refresh(m, Callable())          ## 先刷一次把玩家行搭出来，框才有行可挂
		if i == 1:
			p._tip_pid = 1
			p.refresh(m, Callable())
		_panels.append(p)
	_before = _mock_before()
	root.add_child(_before)
	_caption("改之前：同一张卡出现两次", Vector2(TIP_X_LEFT, TIP_Y - 20), CWStyle.CANCER)
	_caption("改之后：额度归到技能那一行", Vector2(TIP_X_RIGHT, TIP_Y - 20), CWStyle.IMMUNE)
	## 长话写在底下的空地上，别压着面板
	_caption("【癌症干性】是永久技能，可它复活时发的「前两次向癌性组织移动免费」额度住在 cell[\"mods\"] 里，",
		Vector2(16, 486), CWStyle.TEXT_DIM)
	_caption("而那一段的标题写着「即时 · …」—— 于是同一张卡被算了两次。现在额度写在技能自己那一行「余2次」。",
		Vector2(16, 504), CWStyle.TEXT_DIM)


## 照 `_update_tip` 的排版手摆一只「改之前」的框：底板 + 小标题 15px + 条目 24px，左边距 12
func _mock_before() -> Control:
	var box := Control.new()
	var h := 16.0
	for r in BEFORE_ROWS:
		h += 15.0 if bool(r[0]) else 24.0
	box.size = Vector2(TIP_W, h)
	var bg := Panel.new()
	bg.add_theme_stylebox_override("panel", CWStyle.box(0.45, CWStyle.BTN_BG))
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.add_child(bg)
	var y := 8.0
	for r in BEFORE_ROWS:
		var head: bool = bool(r[0])
		var l := CWStyle.label(str(r[1]), CWStyle.SIZE_LABEL if head else CWStyle.SIZE_BODY,
			CWStyle.TEXT_DIM if head else CWStyle.TEXT)
		l.position = Vector2(12, y)
		box.add_child(l)
		y += 15.0 if head else 24.0
	return box


func _caption(text: String, at: Vector2, color: Color) -> void:
	var l := CWStyle.label(text, CWStyle.SIZE_LABEL, color)
	l.position = at
	root.add_child(l)


func _process(_d: float) -> bool:
	_frames += 1
	## 位置每帧摆：`_ready` 会把面板钉回 RECT(696,0)，而这儿要两块并排
	for i in _panels.size():
		(_panels[i] as Control).position = Vector2(PANEL_X_LEFT + i * (PANEL_X_RIGHT - PANEL_X_LEFT), 0)
	## 「改之前」那只框对齐到右边真框的高度（拿不到就按 row_top 自己算）
	var real_tip: Control = (_panels[1] as CWMatchPanel)._tip
	_before.position = Vector2(TIP_X_LEFT, real_tip.position.y if real_tip != null else TIP_Y)
	if _frames < WARMUP:
		return false
	var err := root.get_texture().get_image().save_png(_out)
	print("已保存 %s (err=%d)" % [_out, err])
	return true
