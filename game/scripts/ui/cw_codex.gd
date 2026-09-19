## cw_codex.gd —— 知识之书：机制图鉴（主菜单 / 暂停菜单可达的一页式翻阅面板）
##
## 定位是「图鉴」，不是「规则书」：规则速查页（CWRulesPage）管「怎么赢 / 回合 /
## 判定」那一张硬数字总览，这里管「每个东西是什么、怎么用」，把新手引导每一课的
## 要点沉淀成随时能回看的条目。两者可以同时存在，不互相替代。
##
## 数字一律现读 CWData / CWTuning 默认值，不写第二份 —— 调平衡旋钮后本页自动跟上
## （和 CWRulesPage.sections() 是同一条纪律）。行文只解释机制，不复制 PRD 原文。
##
## 交互：左右箭头 / 方向键 / 滚轮翻页（一章一页），页内装不下时滚轮先滚页内、
## 到顶底再翻章；Esc 或右键关闭。内容 chapters() 是纯函数，无头测试直接核对。
##
## 搜索（Kevin 2026-09-06）：右上角一只输入框，边打字边把结果页铺出来 —— 每条「章 > 条目」+ 命中的那一行，
## 命中的字用阵营色标出；回车跳到第一条，点某条跳到那一章并滚到那个条目。找档是纯函数 search()，
## 只搜书里现有的内容（chapters()），不搜 PRD 原文（放不放进来另议）。输入框有焦点时 Esc 先收起搜索
## （清词、回到原来那一页），再按一次才关书；方向键那会儿归输入框（挪光标），不翻页。
##
## 正文渲染沿用规则速查页的做法：10px 点阵字、固定 15px 行高、预先手工折行，
## 不做运行时自动换行测量 —— 点阵字非整数行高会糊，测量又依赖字体排版细节，
## 固定行高最简单也最稳。chapters() 里每行的 b 就是折好的一行。
##
## **图鉴解锁（新手引导 S6 / S6b，2026-09-19）**：每条都有一个稳定 `id`（`{id, t, b}`，形如「章键/条目键」）——
## 正文按旋钮现算、整句会消失，所以下标不能当 id。`game/data/tutorial/codex_map.json` 把 PRD 的
## 「图鉴解锁：【X】」对到条目 id 上；**只有出现在那张表里的条目才受闸**，其余常驻可见，
## 于是那个文件不在 = 一个条目都不受闸 = 全解锁 = 退化成 09-19 之前的行为（回滚友好）。
##
## **⚠ 2026-09-19（新手教程 v2 · S6）：图鉴「去闸只留通知」**（方案 §3.8，Kevin 拍板）。
## PRD 全文只写「图鉴解锁：【X】」，**一句「没解锁就看不到」都没有** —— 于是：
##   · **全书常驻可读**：`_gate` 恒 `null`（:119），面板永远不往 `chapters()` 里传解锁集，
##     一个条目都不灰、一条都不拦；`CWGuideProgress.codex_gated()` 与 `skipped` 键当天退役。
##   · 解锁时留下的只有两件：导演发一条 `codex_unlocked(ids)`（通知小卡归皮，S3 画），
##     与**图鉴里那一条标题慢闪一轮**（`_fresh` / `_glow`，下面那套一个字没动）。
##   · `_mark_locked` 与 `chapters(unlocked)` / `search(query, unlocked)` 的可选参数
##     **留着不删**（方案 §3.8 明令）：老判据靠它们，而且将来要重新上闸就是把 :119 改回去一行。
##     不传 = 一条都不打标；传了照旧打 `locked: true`，只是产品侧再没有人传了。
## **章一个不少、条目一条不少** —— 章下标是 `open_to()` 的口径（教程直达哪一章由剧本点名）。
class_name CWCodex
extends Control

## 界面音效（游戏外按钮的点击）。**preload 不给 class_name**：新类走不了热更，见那个文件的头注
const SFX := preload("res://scripts/ui/cw_sfx.gd")

const W := 580
const H := 470
const PAD := 20
const HEADER_H := 52
const FOOTER_H := 34
const LINE := 15
const TITLE_LINE := 24
const GAP := 8

var _page := 0
var _scroll := 0.0
var _max_scroll := 0.0
var _panel: Control
var _body: Control
var _content: Control
var _title: Label
var _page_label: Label
var _prev: Label
var _next: Label
var _search: LineEdit
var _query := ""
var _hits: Array = []
var _in_results := false
var _hot_arrow: Label = null   ## 正被鼠标悬停的翻页箭头；null = 没有（同 CWConfigPanel）
var _n_pages := 0              ## 章数，_rebuild_page 时记下 —— 免得每次悬停都重建整本书

const SEARCH_W := 220
const HIT_H := LINE * 2 + GAP   ## 结果页每条两行：章 › 条目 / 命中行
const MAX_HITS := 40

## 解锁点 → 条目 id 的对照表（新手引导 S6）。**文件不在 = 一个条目都不受闸 = 全解锁**
const MAP_PATH := "res://data/tutorial/codex_map.json"
## 解锁动效的闪烁参数**取 CWStyle 那三个常数**（PRD 通用规则 8：闪烁参数收敛到一处）。
## 2026-09-19 老教程整套推倒，这三个常数从 `guide.gd` 搬进 `cw_style.gd`，取法不变
const HALO_PERIOD := CWStyle.HALO_PERIOD
const HALO_ALPHA_LO := CWStyle.HALO_ALPHA_LO
const HALO_ALPHA_HI := CWStyle.HALO_ALPHA_HI

static var _map_cache: Dictionary = {}
static var _map_read := false

var _unlocked := PackedStringArray()   ## 这次打开时玩家已解锁的**解锁点** id（不是条目 id）
## 往 chapters() / search() 里传的那一份。**S6 起恒 `null`**（去闸只留通知）⇒ 一条都不打标；
## 留着这个成员是因为它是「闸」的唯一开关，删了将来要上闸得重铺三处调用
var _gate: Variant = null
var _seen := {}                        ## 本实例已经闪过的条目 id —— 闪一次就够，别每次开书都闪一遍
var _fresh := {}                       ## 这次翻到就要闪的条目 id
var _glow: Array[Label] = []           ## 本页正在闪的条目标题
var _pulse_t := 0.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_build()


func open() -> void:
	_ensure_built()
	open_to(0)


## 直接翻到指定章（引导面板「翻到知识之书」用）。页码会被钳到合法范围。
func open_to(page: int) -> void:
	_ensure_built()
	visible = true
	_refresh_unlocked()
	_page = clampi(page, 0, chapters().size() - 1)
	_scroll = 0.0
	_rebuild_page()


## 每次开书重读一次解锁集（书是覆盖层、活得比一次解锁久，缓存会让刚解锁的那一条下次才闪）。
## 算的是「这次要闪的」：已解锁、且本实例还没让它闪过的条目
func _refresh_unlocked() -> void:
	_unlocked = PackedStringArray(CWGuideProgress.read()["unlocked"])
	## **恒 null**（S6：去闸只留通知，方案 §3.8）——解锁集只喂慢闪，不再决定哪条看得见。
	## 这一行就是那个闸的全部开关：要重新上闸，改回 `_unlocked if 某谓词 else null` 即可
	_gate = null
	_fresh.clear()
	var map := unlock_map()
	for point in _unlocked:
		for eid in map.get(str(point), []):
			if not _seen.has(str(eid)):
				_fresh[str(eid)] = true
	_pulse_t = 0.0


## 兜底：程序化建出来的实例在 _ready 之前就可能被 open/open_to 调用，
## 这里保证控件树先建好（已建过就是空操作）。
func _ensure_built() -> void:
	if _title == null:
		_build()


## 由 CWMainMenu / CWPauseMenu 路由（覆盖层统一走菜单路由）。
## 输入框有焦点时：Esc = 收起搜索（有词先清词回原页），不关书；方向键归输入框，这里不接。
## （被输入框吃掉的按键本来到不了这里，这段是给「输入框有焦点但事件漏过来」和无头测试走的同一条路）
func handle_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		if _search != null and (_search.has_focus() or _in_results):
			_dismiss_search()
			return
		visible = false
	elif _search != null and _search.has_focus():
		return
	elif event.is_action_pressed("ui_right") or event.is_action_pressed("ui_down"):
		get_viewport().set_input_as_handled()
		_next_page()
	elif event.is_action_pressed("ui_left") or event.is_action_pressed("ui_up"):
		get_viewport().set_input_as_handled()
		_prev_page()


## 收起搜索：清词、放掉焦点、回到原来那一页
func _dismiss_search() -> void:
	if _search.has_focus():
		_search.release_focus()
	if _search.text != "":
		_search.text = ""
	_on_query("")


## 右键 / 空白处点击关闭接在 gui_input：本层是 STOP，鼠标事件到不了菜单路由
## （同规则速查页）。点面板外的空白处（scrim 那层）左键也关，见 log_panel 同套路。
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			accept_event()
			visible = false
		elif event.button_index == MOUSE_BUTTON_LEFT \
				and not _panel.get_global_rect().has_point(event.position):
			## 点在面板矩形之外 = 空白处，收起。面板内的点击各有去处
			## （翻页箭头 / 搜索结果 / 输入框），不会走到这里。
			accept_event()
			visible = false
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			accept_event()
			_scroll_by(-40.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			accept_event()
			_scroll_by(40.0)


func _scroll_by(delta: float) -> void:
	if _max_scroll > 0.0:
		_scroll = clampf(_scroll + delta, 0.0, _max_scroll)
		_layout()
		return
	if delta < 0.0:
		_next_page()
	else:
		_prev_page()


func _prev_page() -> void:
	if _in_results:
		return   ## 结果页不翻章：先 Esc 收起搜索
	_page = posmod(_page - 1, chapters().size())   ## 绕回最后一章
	_scroll = 0.0
	_rebuild_page()


func _next_page() -> void:
	if _in_results:
		return
	_page = posmod(_page + 1, chapters().size())   ## 绕回第一章
	_scroll = 0.0
	_rebuild_page()


## 解锁点 → 条目 id 的对照表：`{ 解锁点 id: [条目 id…] }`。读一次缓存（一局之内不变）。
## 文件不在 / 读不出来 → 空表 → 一个条目都不受闸（回滚口径）
static func unlock_map() -> Dictionary:
	return _read_map().get("unlocks", {})


## 整份 `codex_map.json`（`unlocks` + `names`）。读一次缓存（一局之内不变）
static func _read_map() -> Dictionary:
	if _map_read:
		return _map_cache
	_map_read = true
	if FileAccess.file_exists(MAP_PATH):
		var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(MAP_PATH))
		if raw is Dictionary:
			_map_cache = raw as Dictionary
	return _map_cache


## 解锁点 → PRD 里那个【X】（`codex_map.json` 的 `names` 段）。
## **通知小卡上写的是这个名字，不是条目标题**：PRD:279 写的是「图鉴解锁：【攻击】」一条，
## 而它落到「怎么打」「攻击骰」两个条目上（一对二），拿条目标题拼会当场多出一行。
## 表里没有这个点 → 返回它自己的 id（宁可露出 id 也别静默吞掉一条通知）
static func unlock_name(point: String) -> String:
	var names: Dictionary = _read_map().get("names", {})
	return str(names.get(point, point))


## 一串解锁点的名字，**按传进来的次序、去重**（同一拍解锁两条的话通知要一次说完）
static func unlock_names(points) -> PackedStringArray:
	var out := PackedStringArray()
	for p in points:
		var n := unlock_name(str(p))
		if not out.has(n):
			out.append(n)
	return out


## 反向表：`{ 条目 id: [解锁点 id…] }`。**在这张表里的条目才受闸** —— S6 起产品侧没有人上闸了，
## 留着给判据与将来重新上闸用（方案 §3.8：`_mark_locked` 那一套一并留着）
static func gated_entries() -> Dictionary:
	var out := {}
	var map := unlock_map()
	for point in map:
		for eid in map[point]:
			var k := str(eid)
			if not out.has(k):
				out[k] = []
			(out[k] as Array).append(str(point))
	return out


## 给**受闸而还没解锁**的条目打上 `locked: true`（S6b：灰显不隐藏，见文件头注）。
## `unlocked == null` = 一条都不打标；**章一个不少、条目一条不少、位置一格不挪** ——
## 页面与搜索都照原位置排，locked 的只是画成灰的、不收点击。
##
## 就地打标（不另建一份）：唯一的调用方是 `chapters()`，而它每次现建整本书 ——
## 这些字典没有第二个持有者，改不脏任何共享状态
static func _mark_locked(all: Array, unlocked: Variant) -> Array:
	if unlocked == null:
		return all
	var gated := gated_entries()
	if gated.is_empty():
		return all
	var have := {}
	for x in unlocked:
		have[str(x)] = true
	for ch in all:
		for e in (ch as Dictionary)["entries"]:
			var eid := str((e as Dictionary).get("id", ""))
			if not gated.has(eid):
				continue
			var open_now := false
			for point in gated[eid]:
				if have.has(point):
					open_now = true
					break
			if not open_now:
				(e as Dictionary)["locked"] = true
	return all


## 章节目录。纯函数：{ title, entries:[{id, t, b:[行...], locked?}] }。数字现算、正文预折行。
## `unlocked` = 已解锁的解锁点 id 集合；**不传（null）= 一条都不打标**。
## 条目从不因为没解锁而消失（S6b）—— 没解锁的多一个 `locked: true`，渲染那头据此灰显。
## 会随旋钮变的句子（能量上限、有氧公式、无氧时机、反击、攻击上限、占地胜连续回合……）
## 按旋钮现值拼，关掉的机制整句消失 —— 和规则速查页同一条纪律：图鉴里不许出现和引擎不符的数
## （2026-09-05 按当日落地的九条规则逐条核对过，见开发日志）。点阵字库没有 √ ≥ − 这类符号，
## 公式一律写成汉字（「平方根」）和 ASCII 的 - / ×。
static func chapters(unlocked: Variant = null) -> Array:
	var tune := CWTuning.new()
	var lv: Array = CWData.LEVEL_NAMES
	## 【S-有氧呼吸】现行等级式：基数 + 等级 × 步长（-1 = 基数按人数分档）；0 = 退回旧的盘面公式
	var aerobic: Array = []
	if tune.aerobic_level_base != 0:
		aerobic.append("每个世界回合 S 阶段【有氧呼吸】，每个免疫细胞各拿一份：")
		## PRD 2026-09-09 云端版改回线性：(等级系数 − 1) × 步长 + 基数
		aerobic.append("（抗原记忆等级 - 1）× %s + 基数，等级 I/II/III/X 记 1/2/3/4。"
			% CWData.fmt(tune.aerobic_level_step))
		if tune.aerobic_level_base < 0:
			var parts: Array[String] = []
			var ns: Array = CWData.AEROBIC_LEVEL_BASE_BY_PLAYERS.keys()
			ns.sort()
			for n in ns:
				parts.append("%d 人局 %s" % [n, CWData.fmt(CWData.aerobic_level_base(n))])
			aerobic.append("基数按人数：" + "、".join(parts) + "。多净化、升等级，收入就涨。")
		else:
			aerobic.append("基数 %s，四档就是 %s。每升一级涨得一样多。" % [
				CWData.fmt(tune.aerobic_level_base),
				" / ".join(PackedStringArray([
					CWData.fmt(tune.aerobic_level_base),
					CWData.fmt(tune.aerobic_level_base + tune.aerobic_level_step),
					CWData.fmt(tune.aerobic_level_base + tune.aerobic_level_step * 2),
					CWData.fmt(tune.aerobic_level_base + tune.aerobic_level_step * 3)]))])
	else:
		aerobic.append("每个世界回合 S 阶段【有氧呼吸】：按全盘健康组织占比 × %s 结算，"
			% CWData.fmt(tune.aerobic_mult))
		aerobic.append("每个免疫细胞各拿一份。")
	if tune.aerobic_floor > 0:
		aerobic.append("每人至少拿 %s（低保）。" % CWData.fmt(tune.aerobic_floor))
	## 【E-无氧呼吸】：开方公式（0 = 退回线性求和）；时机看 anaerobic_on_turn_end（各癌细胞回合末 / E 阶段）
	var when := "每个癌细胞在自己的行动回合末" if tune.anaerobic_on_turn_end else "每个世界回合 E 阶段"
	var split := "，块内癌细胞均分。" if tune.anaerobic_split else "。"
	var anaerobic: Array = [when + "结算【无氧呼吸】："]
	if tune.anaerobic_block_coef != 0:
		## 系数与指数都可能按人数分档（-1：系数 Kevin 2026-09-07、指数 PRD 2026-09-12）——
		## 同有氧基数那条的写法：把每档都列出来，别只写一个数骗人
		## 一行放不下三档（正文栏 540px，护栏钉着），拆成「公式一行 + 各档一行」
		if tune.anaerobic_block_coef < 0 or tune.anaerobic_block_exp < 0:
			var cs: Array[String] = []
			var cns: Array = CWData.ANAEROBIC_BLOCK_COEF_BY_PLAYERS.keys()
			cns.sort()
			for n in cns:
				var e: int = tune.anaerobic_block_exp if tune.anaerobic_block_exp > 0 else CWData.anaerobic_block_exp(n)
				var k: int = tune.anaerobic_block_coef if tune.anaerobic_block_coef > 0 else CWData.anaerobic_block_coef(n)
				cs.append("%d 人 %.2f / %s" % [n, e / 100.0, CWData.fmt(k)])
			anaerobic.append("块内癌组织个数的 指数 次方 × 系数，再加全图每格固化 %s" % CWData.fmt(tune.anaerobic_solid_bonus) + split)
			anaerobic.append("指数 / 系数按人数：" + "，".join(cs) + "。")
		else:
			anaerobic.append("块内癌组织个数的 %.2f 次方 × %s，再加全图每格固化 %s" % [
				tune.anaerobic_block_exp / 100.0, CWData.fmt(tune.anaerobic_block_coef),
				CWData.fmt(tune.anaerobic_solid_bonus)] + split)
		## 人数系数 k（PRD 2026-09-14，issue #43）：乘在整条分式上，排在下限之前
		var ks: Array[String] = []
		for i in CWData.ANAEROBIC_CELLS_K.size():
			ks.append("%d 个 %d%%" % [i + 1, CWData.ANAEROBIC_CELLS_K[i]])
		anaerobic.append("再乘人数系数：块内活着 " + "、".join(ks) + "。")
		if tune.anaerobic_floor > 0:
			anaerobic.append("每个癌细胞至少拿 %s（下限）。" % CWData.fmt(tune.anaerobic_floor))
		anaerobic.append("铺地的边际收益很平，固化则是全场一起吃 —— 攒固化比摊大饼划算。")
	else:
		anaerobic.append("所在连通块每格癌组织 %s、每格固化 %s" % [
			CWData.fmt(tune.anaerobic_per_cancer), CWData.fmt(tune.anaerobic_per_solid)] + split)
		anaerobic.append("癌组织铺得越开，进账越多。")
	## 能量存量上限：0 = 不封（团队 2026-09-05 取消了 15.0 的封顶）
	var energy: Array = ["免疫细胞开局 %s 能量，癌细胞开局 %s 能量。" % [
		CWData.fmt(tune.init_energy_immune), CWData.fmt(tune.init_energy_cancer)]]
	if tune.energy_cap > 0:
		energy.append("每格账户最多存 %s，多出的部分在世界回合末消失。" % CWData.fmt(tune.energy_cap))
	else:
		energy.append("能量没有存量上限，攒多少都留得住。")
	## 癌方占地胜：达标后要不要连续几个回合末都达标（默认 2：首次达标只是警报）
	var cancer_win: Array = ["让「癌组织 + 2 × 固化癌组织」的加权占地达到 %d，" % tune.cancer_win_weighted]
	if tune.cancer_win_hold_rounds > 1:
		cancer_win.append("且连续 %d 个世界回合末都达标（首次达标只是警报）。" % tune.cancer_win_hold_rounds)
	else:
		cancer_win.append("E 阶段结算时立即获胜。")
	## 攻击判定里随旋钮出没的两句
	var fail_line := "1-2 无效：弹回原格（费用不退）"
	if tune.counter_dmg_on_fail > 0:
		fail_line += "，自身再 -%s" % CWData.fmt(tune.counter_dmg_on_fail)
	fail_line += "；"
	var atk_limit: Array = ["攻击次数不限，只受能量约束。"]
	if tune.attack_max_per_turn > 0:
		atk_limit = ["每个行动回合最多攻击 %d 次，" % tune.attack_max_per_turn,
			"用完后攻击选项从行动栏消失，普通迁移不受影响。"]
	## 玩家回合 / E 阶段：无氧呼吸写在它实际发生的那一段
	var turn_lines: Array = [
		"按行动顺序轮流行动，每个人可以连续行动多次，",
		"直到自己按下「结束回合」。右侧竖条标明回合数与轮到谁。"]
	var e_phase := "微环境压迫、增生、侵蚀、"
	if tune.anaerobic_on_turn_end:
		turn_lines.append("癌细胞按下「结束回合」那一刻，结算自己的【无氧呼吸】。")
	else:
		e_phase = "癌方结算【无氧呼吸】，随后" + e_phase
	## 分化细胞里随旋钮出没的句子
	var b_lines: Array = [
		"【抗体】：范围内与健康组织邻接的癌细胞各受 %s 伤害；" % CWData.fmt(CWData.ANTIBODY_DAMAGE),
		"没有目标时改为转化癌组织。"]
	if tune.antibody_halve:
		b_lines.append("同一世界回合内再放一次，伤害减半、再减半。")
	var t_lines: Array = [
		"【细胞毒素】把相邻癌组织转健康并留下坏死；",
		"【裂解】破除相邻的固化癌组织。主攻手。"]
	if tune.necrosis_aerobic_pct < 100:
		t_lines.append("站在坏死格上的免疫细胞那一回合的有氧收入只有 %d%%，放完毒记得走开。" % tune.necrosis_aerobic_pct)
	var macro_line := "【吞噬】：攻击造成能量损失后，回复目标损失量的一半。"
	var macro_codex := "免疫续航型分化：【吞噬】攻击造成损失后回血一半，"
	if tune.macro_heal_purify > 0:
		macro_line = "【吞噬】：每次净化恢复 %s 能量，攻击造成损失后再回血一半。" % CWData.fmt(tune.macro_heal_purify)
		macro_codex = "免疫续航型分化：【吞噬】每次净化回 %s 能量、攻击后再回血一半，" % CWData.fmt(tune.macro_heal_purify)
	## 癌细胞里随旋钮出没的句子
	var mucus_tail := "；"
	if tune.mucus_move_surcharge > 0:
		mucus_tail = "，留下的黏液让免疫踏入时多付 %s；" % CWData.fmt(tune.mucus_move_surcharge)
	var jump_limit := ""
	if tune.metastasis_max_per_round > 0:
		jump_limit = "（每世界回合最多 %d 次）" % tune.metastasis_max_per_round
	var solid_rounds: int = int(tune.solidify_threshold[0]) / CWData.SOLIDIFY_STEP
	return _mark_locked([
		{ "title": "目标与胜负", "entries": [
			{ "id": "goal/what", "t": "你要做什么", "b": [
				"免疫方与癌方轮流行动：免疫要清剿癌细胞、守住身体，",
				"癌方要扩张癌组织、挤占整片棋盘。每一格组织、每一点能量",
				"都在此消彼长。",
			] },
			{ "id": "goal/immune_win", "t": "免疫怎么赢", "b": [
				"把场上所有癌细胞消灭，并且没有可供癌方复活的固化癌组织，",
				"在世界回合 E 阶段结算时立即获胜。",
			] },
			{ "id": "goal/cancer_win", "t": "癌方怎么赢", "b": cancer_win },
			{ "id": "goal/round_limit", "t": "回合打满怎么办", "b": [
				"最多 %d 个世界回合。" % tune.limit_round,
				"到点后癌性组织达到 %d 格判癌方胜，否则免疫胜。" % tune.limit_cancerous,
			] },
		] },
		{ "title": "棋盘与地形", "entries": [
			{ "id": "board/grid", "t": "一块蜂窝棋盘", "b": [
				"半径 6 的六边形网格，共 %d 格。" % CWData.TOTAL_TILES,
				"细胞站在组织格上，一格最多一个细胞。",
				"悬停任意格稍候，会弹出那一格的地形详情。",
			] },
			{ "id": "board/healthy", "t": "健康组织", "b": [
				"青绿色，是双方争夺的本体。免疫走进癌组织会把它净化回健康，",
				"癌细胞走进健康组织会把它定殖成癌组织。",
			] },
			{ "id": "board/cancer", "t": "癌组织", "b": [
				"红色，癌方的地盘。癌细胞在上面蹲满 %d 个世界回合，" % solid_rounds,
				"这一格就变成固化癌组织。",
			] },
			{ "id": "board/solid", "t": "固化癌组织", "b": [
				"更深一档的癌组织，是癌方复活据点、加权占地记 2 分。",
				"它不能被普通净化，得用 T 细胞的【裂解】破除。",
			] },
			{ "id": "board/special", "t": "三种特殊组织", "b": [
				"代谢核心储能量、骨髓储卡牌，踩上去当场收取；",
				"血管会把踩上去的细胞传送到另一根血管，且不会固化。",
				"它们的产出一格一格记，悬停就能看到储量。",
			] },
		] },
		{ "title": "能量与费用", "entries": [
			{ "id": "energy/life", "t": "能量就是生命", "b": [
				"所有行动都要花能量，能量归零即死亡。",
				"支付费用不能让能量降到 0，总要留一点底。",
			] },
			{ "id": "energy/init", "t": "初始与上限", "b": energy },
			{ "id": "energy/aerobic", "t": "免疫的收入", "b": aerobic },
			{ "id": "energy/anaerobic", "t": "癌方的收入", "b": anaerobic },
			{ "id": "energy/costs", "t": "常用费用", "b": [
				"免疫迁移健康 %s / 癌性按等级；" % CWData.fmt(tune.immune_move_healthy[0]),
				"抽卡免疫 %s、癌方 %s；突变 %s；" % [CWData.fmt(CWData.IMMUNE_DRAW_COST), CWData.fmt(CWData.CANCER_DRAW_COST), CWData.fmt(CWData.MUTATE_COST)],
				"细胞毒素 %s、裂解 %s。行动栏按钮上都会标价。" % [CWData.fmt(CWData.TOXIN_COST), CWData.fmt(CWData.LYSE_COST)],
			] },
		] },
		{ "title": "一个世界回合", "entries": [
			{ "id": "round/s_phase", "t": "S 阶段", "b": [
				"先按顺序结算特殊组织产出、血管传送，",
				"再轮到复活（免疫在骨髓、癌方在固化组织），",
				"最后免疫结算【有氧呼吸】收入。",
			] },
			{ "id": "round/turn", "t": "玩家回合", "b": turn_lines },
			{ "id": "round/e_phase", "t": "E 阶段", "b": [
				e_phase,
				"固化与衰减依次发生，最后统一判定胜负。",
			] },
			{ "id": "round/stage", "t": "环境恶化", "b": [
				"第 6 回合起肿瘤 II 期、第 11 回合起 III 期：",
				"压迫 ×1.5 / ×2，增生与侵蚀更凶；",
				"II 期起固化格每回合再给相邻癌组织加 1.0 固化计数，",
				"III 期固化门槛降到 %s。" % CWData.fmt(int(tune.solidify_threshold[2])),
			] },
			{ "id": "round/count", "t": "回合计数", "b": [
				"越往后局势越不受控制，别把决战拖到太晚。",
			] },
		] },
		{ "title": "移动与净化", "entries": [
			{ "id": "move/immune", "t": "免疫迁移", "b": [
				"点「迁移」再点高亮的相邻格。走进癌组织会自动【净化】",
				"并 +1 抗原记忆；走进有癌细胞的一格则触发攻击而不是净化。",
			] },
			{ "id": "move/cancer", "t": "癌方移动", "b": [
				"点「移动」再点相邻格。走进健康组织会【定殖】成癌组织，",
				"这就是癌方扩张地盘的基本方式。",
			] },
			{ "id": "move/step", "t": "一格一格走", "b": [
				"「迁移 / 移动」是切换式：走完一步仍停在选目标格上，",
				"可以连续走，右键或 Esc 结束。",
			] },
			## 门槛按人数分档（Kevin 2026-09-09），而图鉴是**静态**的、拿不到当前人数，
			## 所以两档都写出来。写死一档的话有一半的局看到的是错的。
			{ "id": "move/purify_memory", "t": "净化与记忆", "b": [
				"免疫每净化一格 +1 抗原记忆。四人局记忆到 %d / %d 升 II / III 级，" % [
					CWData.LEVEL_MIN_MEMORY_BY_PLAYERS[4][1], CWData.LEVEL_MIN_MEMORY_BY_PLAYERS[4][2]],
				"六人局 %d / %d；X 级四人 %d、六人 %d。" % [
					CWData.LEVEL_MIN_MEMORY[1], CWData.LEVEL_MIN_MEMORY[2],
					CWData.LEVEL_MIN_MEMORY_BY_PLAYERS[4][3], CWData.LEVEL_MIN_MEMORY[3]],
				"迁入癌组织的费用随等级下降。",
			] },
		] },
		{ "title": "攻击与判定", "entries": [
			{ "id": "attack/how", "t": "怎么发起攻击", "b": [
				"免疫迁移时，目标格上站着癌细胞就是一次攻击。",
				"骰子会落在那一格上方演一遍，结算说明由引擎给出。",
			] },
			{ "id": "attack/d6", "t": "d6 判定", "b": [
				fail_line,
				"3-5 成功（目标 -%s）；6 大成功（目标 -%s）。" % [CWData.fmt(tune.attack_dmg_success), CWData.fmt(tune.attack_dmg_crit)],
			] },
			{ "id": "attack/mark", "t": "标记翻倍", "b": [
				"树突细胞给 %d 格内的癌细胞挂【标记】，带标记的目标受到的下一次" % CWData.MARK_RANGE,
				"伤害翻倍，随后消耗一层标记。",
			] },
			{ "id": "attack/limit", "t": "攻击次数", "b": atk_limit },
		] },
		{ "title": "免疫分化", "entries": [
			{ "id": "diff/rule", "t": "分化规则", "b": [
				"免疫等级升到 %s 后可以分化，每个细胞一辈子一次，" % lv[tune.differentiate_min_level],
				"每种分化全阵营限一个。分化免费。",
			] },
			{ "id": "diff/b_cell", "t": "B 细胞", "b": b_lines },
			{ "id": "diff/t_cell", "t": "T 细胞", "b": t_lines },
			{ "id": "diff/macrophage", "t": "巨噬细胞", "b": [
				macro_line,
				"续航型，越打越有钱，适合反复净化。",
			] },
			{ "id": "diff/effector", "t": "效应应答", "b": [
				"免疫等级到 %s 之后，抗原记忆改叫【效应记忆】并从零重数；" % lv[3],
				"已分化的免疫细胞各解锁一个大招，每次花 %d 效应记忆。" % CWData.EFFECTOR_COST,
				"每个细胞一辈子一次，整个免疫方每个世界回合也只放得了一次。",
				"B【中和抗体】：贴着健康组织的癌细胞，种类技能与永久卡失效两回合。",
				"T【Excalibur】：选一个方向扫到棋盘边，癌组织转健康并坏死，",
				"　射线上的癌细胞 -%s、被溅到的 -%s；固化癌组织不转。"
					% [CWData.fmt(CWData.EXCALIBUR_RAY_DMG), CWData.fmt(CWData.EXCALIBUR_SPLASH_DMG)],
				"巨噬【连续吞噬】：这一回合净化之后可以接着免费走，最多连 %d 格，" % CWData.CHAIN_PHAGO_MAX,
				"　每连一格下一击多 %s 伤害。" % CWData.fmt(CWData.CHAIN_PHAGO_BONUS),
				"树突【免疫猎杀】：给全场任意一个癌细胞挂上标记，外加一个跟着它跑的趋化源——",
				"　它自己怎么走都算「远离」，也就是怎么走都要多付钱。",
			] },
			{ "id": "diff/dendritic", "t": "树突状细胞", "b": [
				"【趋化源】：花 %s 在任意格立源、持续 %d 个完整回合（到自己下个回合前），" % [
					CWData.fmt(CWData.CHEMO_COST), CWData.CHEMO_FULL_TURNS],
				"消失后本人冷却 %d 个世界回合才能再立；场上至多一个。" % CWData.CHEMO_COOLDOWN_ROUNDS,
				"免疫朝它走的迁移费 ×%d%%，癌细胞背它走的移动费 ×%d%%。" % [CWData.CHEMO_IMMUNE_PCT, CWData.CHEMO_CANCER_PCT],
				"%d 格内的癌细胞自动带【标记】，下一次受伤翻倍；同一个癌细胞一回合只标得上一次。" % CWData.MARK_RANGE,
				"【组织黏连】：世界回合末，带标记的癌细胞把标记传染给 %d 格内的同伴（不连锁）。" % CWData.ADHESION_RANGE,
				"自身不能攻击，纯辅助。",
			] },
		] },
		{ "title": "四种癌细胞", "entries": [
			{ "id": "cancer/melanoma", "t": "恶性黑色素瘤", "b": [
				"【早期血行转移】从血管传送到任意空地并扩散癌组织，每世界回合一次；",
				"【伪足穿透】目标邻接 %d 格以上癌性组织时移动只花 %s。" % [CWData.PSEUDOPOD_MIN_ADJ, CWData.fmt(tune.pseudopod_cost)],
				"机动性极强。",
			] },
			{ "id": "cancer/signet", "t": "印戒细胞癌", "b": [
				"【黏液破裂】耗尽能量自爆、范围转化癌组织" + mucus_tail,
				"【囊性护甲】每世界回合第一次能量损失减 %s。肉盾型。" % CWData.fmt(CWData.ARMOR_REDUCTION),
			] },
			{ "id": "cancer/osteo", "t": "骨肉瘤", "b": [
				"【骨样硬化】花 %s 标记脚下的癌组织，%d 个世界回合后直接固化；" % [CWData.fmt(tune.osteo_ossify_cost), tune.osteo_ossify_rounds],
				"免疫踏进标记格得蹲满一回合才能净化。站在固化组织上受伤只剩 %d%%。阵地型。" % CWData.OSTEO_BARRIER_PERCENT,
			] },
			{ "id": "cancer/sclc", "t": "小细胞肺癌", "b": [
				"【转移】向某方向跃进 %d 格" % CWData.METASTASIS_RANGE + jump_limit + "；【瓦伯格】无氧呼吸 %d%%；" % CWData.WARBURG_PERCENT,
				"移动至健康组织只花 %s。爆发型。" % CWData.fmt(tune.sclc_move_healthy),
			] },
		] },
		{ "title": "细胞图鉴", "entries": [
			{ "id": "cells/immune_basic", "t": "原生免疫细胞", "b": [
				"免疫方的移动单位：走进癌组织自动【净化】并 +1 抗原记忆，",
				"走进站有癌细胞的格子则触发攻击。能量花完或血被打空就死亡。",
			] },
			{ "id": "cells/b_cell", "t": "B 细胞", "b": [
				"免疫输出型分化：【抗体】花 %s 能量，范围内邻接健康组织" % CWData.fmt(CWData.ANTIBODY_COST),
				"的癌细胞各受 %s 伤害；没有目标时改为转化癌组织。" % CWData.fmt(CWData.ANTIBODY_DAMAGE),
			] },
			{ "id": "cells/t_cell", "t": "T 细胞", "b": [
				"免疫攻坚型分化：【细胞毒素】花 %s 能量，把相邻癌组织转健康" % CWData.fmt(CWData.TOXIN_COST),
				"并留下坏死；【裂解】花 %s 能量破除固化癌组织。" % CWData.fmt(CWData.LYSE_COST),
				"克制骨肉瘤的骨壳，也能拆掉癌方的复活点。",
			] },
			{ "id": "cells/macrophage", "t": "巨噬细胞", "b": [
				macro_codex,
				"配合反复净化能一直走下去，适合清扫大片癌组织。",
			] },
			{ "id": "cells/dendritic", "t": "树突状细胞", "b": [
				"免疫辅助型分化：【趋化源】花 %s 立源，免疫朝它走打折、癌细胞背它走加价；" % CWData.fmt(CWData.CHEMO_COST),
				"%d 格内的癌细胞自动带【标记】，下一次受伤翻倍。自身不能攻击。" % CWData.MARK_RANGE,
			] },
			{ "id": "cells/melanoma", "t": "恶性黑色素瘤", "b": [
				"癌方游击手：【早期血行转移】花 %s 能量，每世界回合一次，" % CWData.fmt(CWData.MELANOMA_HOMING_COST),
				"从血管传送到任意空地并扩散癌组织；【伪足穿透】贴着癌区走只花 %s。" % CWData.fmt(tune.pseudopod_cost),
				"盯紧血管口。",
			] },
			{ "id": "cells/signet", "t": "印戒细胞癌", "b": [
				"癌方肉盾：【黏液破裂】耗尽能量自爆、范围转化最多 %d 格癌组织" % CWData.MUCUS_MAX_CONVERT + mucus_tail,
				"【囊性护甲】每世界回合第一次能量损失减 %s。别让它扎进健康区。" % CWData.fmt(CWData.ARMOR_REDUCTION),
			] },
			{ "id": "cells/osteo", "t": "骨肉瘤", "b": [
				"癌方阵地：【骨样硬化】花 %s 标记脚下癌组织，%d 回合后直接固化，" % [CWData.fmt(tune.osteo_ossify_cost), tune.osteo_ossify_rounds],
				"免疫踏进标记格得蹲一回合才能净化；站在固化组织上受伤只剩 %d%%。" % CWData.OSTEO_BARRIER_PERCENT,
				"用 T 细胞【裂解】拆壳最稳。",
			] },
			{ "id": "cells/sclc", "t": "小细胞肺癌", "b": [
				"癌方爆发：【转移】向某方向跃进 %d 格" % CWData.METASTASIS_RANGE + jump_limit + "；【瓦伯格】无氧呼吸 %d%%；" % CWData.WARBURG_PERCENT,
				"移动至健康组织仅 %s。贴脸就能打乱免疫阵型。" % CWData.fmt(tune.sclc_move_healthy),
			] },
		] },

		{ "title": "卡牌", "entries": [
			{ "id": "cards/kinds", "t": "三类卡", "b": [
				"事件卡抽到立即结算并弃置；技能卡进手牌（上限 %d 张）；" % CWData.HAND_MAX,
				"永久技能打出即装备，持续生效、死亡不掉。",
			] },
			{ "id": "cards/draw", "t": "怎么抽卡", "b": [
				"【基因表达】付费抽卡，每个行动回合最多 %d 次；" % CWData.DRAW_MAX_PER_TURN,
				"踩骨髓也能拿卡。免疫按记忆等级抽池，癌方按回合分期抽池。",
			] },
			{ "id": "cards/play", "t": "怎么出牌", "b": [
				"轮到人类玩家时，点左下角手牌即可打出或弃置。",
				"带目标的卡会高亮可点格子；双击免确认直接打出。",
			] },
		] },
		{ "title": "界面与快捷键", "entries": [
			{ "id": "ui/sidebar", "t": "右侧竖条", "b": [
				"回合数、胜负进度、每位玩家的能量与手牌、免疫等级都在这里。",
				"悬停玩家行可查看其已装备的永久技能。",
			] },
			{ "id": "ui/action_bar", "t": "行动栏", "b": [
				"底部一排按钮，数字键 1-9 对应从左到右。",
				"按钮不消失、只变暗，位置和编号始终稳定。",
			] },
			{ "id": "ui/keys", "t": "常用按键", "b": [
				"空格 = 结束回合；L = 对局日志；Esc = 取消 / 打开暂停菜单；",
				"右键 = 取消选目标。主菜单里方向键 + 回车即可全程操作。",
			] },
			{ "id": "ui/hover", "t": "悬停与提示", "b": [
				"悬停格子看地形、悬停玩家行看装备、悬停按钮看费用。",
				"点不动的时候，界面上一般会直接告诉你为什么。",
			] },
		] },
		{ "title": "给新手的三个提醒", "entries": [
			{ "id": "tips/income", "t": "先扩张收入", "b": [
				"免疫多净化攒记忆、升等级，癌方多定殖把连通块做大，",
				"收入才滚得起来。开局别只盯着一个细胞对砍。",
			] },
			{ "id": "tips/respawn", "t": "守住复活点", "b": [
				"癌方的命根子是固化癌组织，免疫的命根子是骨髓。",
				"被对面占住复活位，往往比死一个细胞更伤。",
			] },
			{ "id": "tips/energy", "t": "能量别见底", "b": [
				"付钱不能降到 0，攒不出足够费用就会卡手。",
				"留一两步移动的余量，关键时刻才进退自如。",
			] },
		] },
	], unlocked)


## 在图鉴里找一个词（大小写不分，子串匹配）：返回 [{ page, chapter, t, line, locked }]，
## line 为空 = 命中在条目标题上。一个条目里命中多行各算一条；最多 MAX_HITS 条。纯函数，无头测试直接核对。
## `unlocked` 与 `chapters()` 同义（不传 = 一条都不打标）——**面板照旧传**：
## 没解锁的条目**命中但灰显**（S6b 起不再从结果里剔除），`locked` 就是结果页画哪一档色的依据。
static func search(query: String, unlocked: Variant = null) -> Array:
	var q := query.strip_edges().to_lower()
	var out: Array = []
	if q == "":
		return out
	var all := chapters(unlocked)
	for p in all.size():
		var ch: Dictionary = all[p]
		for entry in ch["entries"]:
			var locked: bool = bool((entry as Dictionary).get("locked", false))
			if String(entry["t"]).to_lower().contains(q):
				out.append({ "page": p, "chapter": ch["title"], "t": entry["t"], "line": "", "locked": locked })
				if out.size() >= MAX_HITS:
					return out
			for line in entry["b"]:
				if String(line).to_lower().contains(q):
					out.append({ "page": p, "chapter": ch["title"], "t": entry["t"], "line": line,
						"locked": locked })
					## 上限**逐条**判，不能等整个条目铺完再判：
					## 那样一个多行条目能一次冲过 40（2026-09-07 加【效应应答】那条时正好撞上）
					if out.size() >= MAX_HITS:
						return out
	return out


## 输入框里的词变了：有词铺结果页，没词回到原来那一页
func _on_query(q: String) -> void:
	_query = q.strip_edges()
	if _query == "":
		_in_results = false
		_hits.clear()
		_rebuild_page()
		return
	_hits = search(_query, _gate)
	_in_results = true
	_rebuild_results()


## 回车：跳到第一条**点得动的**。灰显的那些不响应点击（S6b），回车也不该绕过这一条
func _on_submit(_q: String) -> void:
	for hit in _hits:
		if not bool((hit as Dictionary).get("locked", false)):
			_goto(hit)
			return


## 跳到某条：翻到那一章，把那个条目滚到正文顶部；搜索词留在框里（Esc 可清）
func _goto(hit: Dictionary) -> void:
	_in_results = false
	if _search != null and _search.has_focus():
		_search.release_focus()
	open_to(int(hit["page"]))
	var y := 0.0
	## 滚到那个条目：逐条累行高。条目不再因为没解锁而消失（S6b），所以这一页和整本书同形 ——
	## 仍走 `_gate` 只是为了和别处同一条路，换成 `chapters()` 结果一样
	for entry in chapters(_gate)[_page]["entries"]:
		if entry["t"] == hit["t"]:
			break
		y += TITLE_LINE + entry["b"].size() * LINE + GAP
	_scroll = clampf(y, 0.0, _max_scroll)
	_layout()


## 结果页：标题「搜索」、页码换成条数；每条两行（章 > 条目 / 命中行，命中的字用阵营色），整条可点。
## **灰显的那些（S6b）**：整条降一档暗色、命中的字**不**标阵营色（标了就是这一行唯一的亮点，
## 等于反过来替玩家指路），不收点击、不换鼠标形状、悬停也不提色
func _rebuild_results() -> void:
	for child in _content.get_children():
		child.queue_free()
	_glow.clear()   ## 结果页没有条目标题可闪
	_title.text = "搜索「%s」" % _query
	_page_label.text = "%d 条" % _hits.size()
	_paint_arrows()   ## 结果页两枚都翻不动，_paint_arrows 自己会把它们压暗、不发光
	var y := 0.0
	if _hits.is_empty():
		var none := CWStyle.label("没有找到「%s」" % _query, CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
		none.position = Vector2(0, 4)
		_content.add_child(none)
		y = LINE + GAP
	for hit in _hits:
		var locked: bool = bool((hit as Dictionary).get("locked", false))
		var row := Control.new()
		row.position = Vector2(0, y)
		row.size = Vector2(_body.size.x, HIT_H)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE if locked else Control.MOUSE_FILTER_STOP
		if not locked:
			row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		## 分隔用 ASCII 的 > —— 点阵字库没有「›」，画出来是个方块（预览图里看见的）
		var head := CWStyle.label("%s > %s" % [hit["chapter"], hit["t"]], CWStyle.SIZE_LABEL,
			CWStyle.TEXT_OFF if locked else CWStyle.IMMUNE)
		head.position = Vector2(0, 0)
		row.add_child(head)
		var line_text := String(hit["line"]) if hit["line"] != "" else String(hit["t"])
		if locked:
			var dim := CWStyle.label(line_text, CWStyle.SIZE_LABEL, CWStyle.TEXT_OFF_DIM)
			dim.position = Vector2(0, LINE)
			row.add_child(dim)
		else:
			_put_marked(row, line_text, Vector2(0, LINE))
			row.gui_input.connect(func(e: InputEvent) -> void:
				if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
					get_viewport().set_input_as_handled()
					SFX.click()
					_goto(hit))
			row.mouse_entered.connect(func() -> void: head.add_theme_color_override("font_color", CWStyle.TEXT_HI))
			row.mouse_exited.connect(func() -> void: head.add_theme_color_override("font_color", CWStyle.IMMUNE))
		_content.add_child(row)
		y += HIT_H
		_content.add_child(_rule(y - GAP / 2.0))
	_content.size = Vector2(_body.size.x, y)
	_scroll = 0.0
	_layout()


## 一行正文，命中的字换成阵营色：前文 / 命中 / 后文三个标签按实测字宽接排（同 CWCardInfo 的分档高亮画法）
func _put_marked(parent: Control, line: String, at: Vector2) -> void:
	var i := line.to_lower().find(_query.to_lower())
	if i < 0:
		var l := CWStyle.label(line, CWStyle.SIZE_LABEL, CWStyle.TEXT)
		l.position = at
		parent.add_child(l)
		return
	var x := at.x
	for seg in [[line.substr(0, i), CWStyle.TEXT], [line.substr(i, _query.length()), CWStyle.CANCER], [line.substr(i + _query.length()), CWStyle.TEXT]]:
		if String(seg[0]) == "":
			continue
		var l := CWStyle.label(seg[0], CWStyle.SIZE_LABEL, seg[1])
		l.position = Vector2(x, at.y)
		parent.add_child(l)
		x += CWStyle.FONT.get_string_size(seg[0], HORIZONTAL_ALIGNMENT_LEFT, -1, CWStyle.SIZE_LABEL).x


func _build() -> void:
	var scrim := ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.55)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(scrim)

	var screen := CWView.screen_size()
	_panel = Control.new()
	_panel.position = Vector2((screen.x - W) / 2.0, (screen.y - H) / 2.0)
	_panel.size = Vector2(W, H)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)
	var panel := _panel   ## 下方代码仍按局部名 panel 引用（改造成本最低）

	var bg := Panel.new()
	bg.add_theme_stylebox_override("panel", CWStyle.box(0.45, CWStyle.PANEL))
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(bg)

	var head := CWStyle.label("知识之书", CWStyle.SIZE_BIG, CWStyle.TEXT_HI)
	head.position = Vector2(PAD, PAD - 4)
	panel.add_child(head)

	## 搜索框（Kevin 2026-09-06）占了原来副标题的位置；副标题那句挪进页脚
	_search = LineEdit.new()
	_search.placeholder_text = "搜索图鉴… 回车跳到第一条"
	_search.max_length = 24
	_search.context_menu_enabled = false
	_search.add_theme_font_override("font", CWStyle.FONT)
	_search.add_theme_font_size_override("font_size", CWStyle.SIZE_LABEL)
	_search.add_theme_color_override("font_color", CWStyle.TEXT_HI)
	_search.add_theme_color_override("font_placeholder_color", CWStyle.TEXT_OFF)
	_search.add_theme_color_override("caret_color", CWStyle.IMMUNE)
	_search.add_theme_stylebox_override("normal", CWStyle.box(0.45, CWStyle.BTN_BG, 2, 6))
	_search.add_theme_stylebox_override("focus", CWStyle.box(1.0, CWStyle.BTN_BG, 2, 6))
	_search.text_changed.connect(_on_query)
	_search.text_submitted.connect(_on_submit)
	## 框里按 Esc：只收起搜索，不让事件漏到菜单路由去关书
	_search.gui_input.connect(func(e: InputEvent) -> void:
		if e.is_action_pressed("ui_cancel"):
			_search.accept_event()
			_dismiss_search())
	panel.add_child(_search)
	## 尺寸在**进树之后**设（同 CWChatBox 那条，2026-09-17）：进树前主题缓存还是默认主题，
	## set_size 会被默认的最小高 31 钳住、之后不缩回 —— 这只框此前就真的是 31 高，比设计多探下 9 px
	_search.position = Vector2(W - PAD - SEARCH_W, PAD + 2)
	_search.size = Vector2(SEARCH_W, 22)

	## 章标题行与页码（点阵字没有箭头，用 ASCII < > 做翻页按钮，同配置面板语汇）
	_title = CWStyle.label("", CWStyle.SIZE_BODY, CWStyle.IMMUNE)
	_title.position = Vector2(PAD, PAD + HEADER_H - 24)
	panel.add_child(_title)

	_page_label = CWStyle.label("", CWStyle.SIZE_LABEL, CWStyle.TEXT_DIM)
	_page_label.position = Vector2(W - PAD - 78, PAD + HEADER_H - 22)
	_page_label.size = Vector2(40, 14)
	_page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(_page_label)

	_prev = _clicky("<", Vector2(W - PAD - 40, PAD + HEADER_H - 24), _prev_page, panel)
	_next = _clicky(">", Vector2(W - PAD - 20, PAD + HEADER_H - 24), _next_page, panel)
	## 悬停亮起白光 —— 和 CWConfigPanel / CWOnlinePanel 的拨值箭头同一套语言
	## （Kevin 2026-09-09 报「换页箭头没有加辉光」：这两枚此前只换字色，光是漏的）
	for arrow: Label in [_prev, _next]:
		arrow.mouse_entered.connect(func() -> void:
			_hot_arrow = arrow
			_paint_arrows())
		arrow.mouse_exited.connect(func() -> void:
			if _hot_arrow == arrow:
				_hot_arrow = null
			_paint_arrows())

	## 正文滚动区：clip 裁掉越界部分，_content 随 _scroll 上下移动
	_body = Control.new()
	_body.position = Vector2(PAD, PAD + HEADER_H)
	_body.size = Vector2(W - PAD * 2, H - PAD - HEADER_H - FOOTER_H)
	_body.clip_contents = true
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(_body)

	_content = Control.new()
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.add_child(_content)

	var hint := CWStyle.label("ESC / 右键 返回 · ←→ 翻页 · 滚轮阅读 · 细则以规则原文为准",
		CWStyle.SIZE_LABEL, CWStyle.TEXT_OFF)
	hint.size = Vector2(W - PAD * 2, 14)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.position = Vector2(PAD, H - PAD - 10)
	panel.add_child(hint)


## 两枚翻页箭头的配色与辉光。
##
## **翻不动的那枚不发光**：首末页各有一枚到头，搜索结果页两枚都翻不动
## （`_prev_page` / `_next_page` 见 `_in_results` 直接 return）。
## 让死箭头亮起来等于许一个做不到的承诺 —— 玩家会以为自己点漏了。
func _paint_arrows() -> void:
	_paint_arrow(_prev, not _in_results and _page > 0)
	_paint_arrow(_next, not _in_results and _page < _n_pages - 1)


## 描边参数（白、0.5、8px）**和 CWConfigPanel / CWOnlinePanel 的拨值箭头逐字相同**；
## 三处要改一起改，否则同一个手势在不同面板上会亮出不一样的光。
func _paint_arrow(arrow: Label, live: bool) -> void:
	var hot: bool = live and arrow == _hot_arrow
	arrow.add_theme_color_override("font_color",
		Color.WHITE if hot else (CWStyle.TEXT_HI if live else CWStyle.TEXT_OFF))
	arrow.add_theme_color_override("font_outline_color", Color(1, 1, 1, 0.5))
	arrow.add_theme_constant_override("outline_size", 8 if hot else 0)


## 可点击文字（同 config_panel._clicky——覆盖层里收点击都要标记已处理）
func _clicky(text: String, at: Vector2, on_click: Callable, parent: Node = null) -> Label:
	var label := CWStyle.label(text, CWStyle.SIZE_BODY, CWStyle.TEXT_HI)
	label.position = at
	label.mouse_filter = Control.MOUSE_FILTER_STOP
	label.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	label.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			get_viewport().set_input_as_handled()
			SFX.click()
			on_click.call())
	(parent if parent != null else self).add_child(label)
	return label


func _rebuild_page() -> void:
	for child in _content.get_children():
		child.queue_free()
	_glow.clear()
	_title.text = ""
	_page_label.text = ""
	var all := chapters(_gate)
	if all.is_empty():
		return
	var ch: Dictionary = all[_page]
	_title.text = ch["title"]
	_page_label.text = "%d / %d" % [_page + 1, all.size()]
	_n_pages = all.size()
	_paint_arrows()

	var y := 0.0
	for entry in ch["entries"]:
		## 灰显（S6b）：没解锁的条目**照样出现、位置一格不挪**，只把标题与正文降两档色。
		## 色值一律取 CWStyle 现成的「灰掉」那一对，不新造 —— 同 `_paint_arrow` 压暗箭头的写法
		var locked: bool = bool((entry as Dictionary).get("locked", false))
		var t := CWStyle.label(entry["t"], CWStyle.SIZE_BODY,
			CWStyle.TEXT_OFF if locked else CWStyle.TEXT_HI)
		t.position = Vector2(0, y)
		_content.add_child(t)
		## 解锁动效：刚解锁、本实例还没让它闪过的条目，标题慢闪一轮。
		## 翻到才记「闪过」—— 解锁的条目在别的章时，这次没翻过去就留到下次。
		## （`_fresh` 只收**已解锁**的点，所以 locked 的条目永远进不来，不必另判）
		var eid := str((entry as Dictionary).get("id", ""))
		if _fresh.has(eid):
			_seen[eid] = true
			_glow.append(t)
		y += TITLE_LINE
		for line in entry["b"]:
			var l := CWStyle.label(line, CWStyle.SIZE_LABEL,
				CWStyle.TEXT_OFF_DIM if locked else CWStyle.TEXT)
			l.position = Vector2(0, y)
			l.size = Vector2(_body.size.x, LINE)
			l.clip_text = true
			l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			_content.add_child(l)
			y += LINE
		y += GAP
		_content.add_child(_rule(y - GAP))
	_content.size = Vector2(_body.size.x, y)
	_scroll = 0.0
	_layout()


func _rule(at_y: float) -> ColorRect:
	var r := ColorRect.new()
	r.color = Color(CWStyle.LINE, 0.18)
	r.position = Vector2(0, at_y)
	r.size = Vector2(_body.size.x, 1)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


func _layout() -> void:
	_content.position = Vector2(0, -_scroll)
	_max_scroll = maxf(_content.size.y - _body.size.y, 0.0)


## 解锁动效的心跳。**无头视口不跑这一支**（书通常不进树），所以判据直接摆 `_pulse_t` 再调 `_apply_pulse()`
func _process(delta: float) -> void:
	if not visible or _glow.is_empty():
		return
	_pulse_t += delta
	_apply_pulse()


## 慢闪 = 标题整体透明度在 HALO_ALPHA_LO..HI 之间呼吸（同教程提亮层的柔光，PRD 通用规则 8）。
## 用 modulate 而不是换字色：点阵字换色会让字重看起来在变，透明度不会
func _apply_pulse() -> void:
	var k := 0.5 + 0.5 * sin(_pulse_t * TAU / HALO_PERIOD)
	var a := lerpf(HALO_ALPHA_LO, HALO_ALPHA_HI, k)
	for l in _glow:
		l.modulate.a = a
