extends SceneTree
## 事件卡的预览图 —— 给人看的工具，不是测试（Kevin 2026-09-06 要的）。
##
## 事件卡「抽取后立即生效」，对局里不会停在手牌上，所以它有三种露面方式，这里摆在一张图上：
##   ① 若在手牌里的卡面（悬停抬起的样子，卡面只有名字 + 类别 + 操作提示）
##   ② 悬停详情框（PRD 原文，当前分期那一档高亮）
##   ③ 抽到时棋盘上的通报气泡（引擎给的原文，停 CWUIBridge.TEXT_HOLD 秒）
##
## 跑（**不能加 --headless**，要真渲染）：
##   godot --path game --script res://tests/preview/preview_event_card.gd -- <输出.png> [卡名] [分期 0/1/2]
const WARMUP := 30

## 几张事件卡抽到时的通报原文（照 cw_card_fx 的写法，数字按中期）；没列的卡用占位句
const NOTICE := {
	"肿瘤血管生成": "事件【肿瘤血管生成】全体癌细胞 +2.0 · 自身另 +0.5",
	"糖酵解爆发": "事件【糖酵解爆发】+2.6 能量",
	"基因组不稳定": "事件【基因组不稳定】免费【突变】",
	"急性炎症反应": "事件【急性炎症反应】+1.5 能量",
}

var _out := "user://event_card.png"
var _card := "肿瘤血管生成"
var _phase := 1
var _frames := 0
var _hand: CWHand
var _box: CWCardInfo
var _toast: CWToast


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	if args.size() > 1:
		_card = args[1]
	if args.size() > 2:
		_phase = int(args[2])
	var bg := ColorRect.new()
	bg.color = CWStyle.GROUND
	bg.size = Vector2(960, 540)
	root.add_child(bg)

	## ① 手牌：目标卡放第一张并抬起，后面再摆两张同阵营的事件卡当邻居
	_hand = CWHand.new()
	root.add_child(_hand)
	var names := PackedStringArray([_card])
	for n in ["糖酵解爆发", "基因组不稳定", "急性炎症反应"]:
		if n != _card and names.size() < 3:
			names.append(n)
	_hand.sync(names.size(), Vector2.INF, names)
	_hand._hover(0)

	## ② 详情框：和对局里一样贴着抬起后的卡顶往上长
	_box = CWCardInfo.new()
	root.add_child(_box)
	_box.on_hover(_card)

	## ③ 通报气泡
	_toast = CWToast.new()
	root.add_child(_toast)

	_caption(Vector2(200, 468), "① 手牌里的卡面（悬停抬起）")
	_caption(Vector2(200, 484), "　 事件卡抽到即生效，实战不会停在手上；卡面只有名字、类别与操作提示")
	_caption(Vector2(344, 380), "② 悬停详情：PRD 原文，当前分期（%s）那一档高亮" % ["前期", "中期", "后期"][_phase])
	_caption(Vector2(520, 300), "③ 抽到时棋盘上的通报（引擎原文，停 %.0f 秒，各自一只气泡）" % CWUIBridge.TEXT_HOLD)


func _caption(at: Vector2, text: String) -> void:
	var l := CWStyle.label(text, CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	l.position = at
	root.add_child(l)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		var faction := CWData.Faction.CANCER if int(CWCardData.CARDS[_card]["immune"].max()) == 0 else CWData.Faction.IMMUNE
		_box.sync(CWCardInfo.DELAY + 0.1, faction, false, _phase)
		_toast.bubble_at(NOTICE.get(_card, "事件【%s】（抽到时的通报）" % _card), Rect2(560, 250, 40, 40), 100.0)
		return false
	if _frames < WARMUP:
		return false
	var err := root.get_texture().get_image().save_png(_out)
	print("已保存 %s (err=%d)" % [_out, err])
	return true
