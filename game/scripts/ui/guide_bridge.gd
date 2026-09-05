## guide_bridge.gd —— 教程局的引导桥：包一层 CWUIBridge，只加两件事
##
## ① 轮到人类时，把「现在做什么」的一句话喂给 CWGuide.set_hint（面板的实时提示行）。
## ② 「一步到位」的动作（落子 / 结束回合 / 抽卡）可以由面板的「继续」按钮**替玩家做**：
##    正在教的那一步与此刻等答的这一问对上号时，按「继续」= 从引擎给的合法选项里挑一个
##    下标直接作答。落子要么亲手点棋盘、要么点「继续」，两条路都留；不再有自动演示
##    （Kevin 2026-09-05 拍板：自动演示会在玩家没看剧本时替他放掉开局唯一一次落子）。
##
## **不是硬锁步的教程**：引擎、询问桥、行动栏照常跑。代做就是「从引擎生成的合法
## 选项里挑一个满足条件的下标返回」——选项全由引擎生成，所以代做的每一步都合法；
## 挑不出来（这一步在真实局面里不可用）「继续」就只翻页、不作答。
##
## 这是**新桥**而不是改 CWUIBridge：正式对局和教程共用同一套引擎与界面，
## 教程的代做逻辑单独隔离在这里，出问题不会影响正常对局。
class_name CWGuideBridge
extends CWUIBridge

## 操作步骤的「提示词」表。guide_data 每关步骤的 act 字段映射到这里；
## 关键字沿用在引擎 action 选项的 data["act"] 上，hint 是轮到你时的一句话。
const STEP_HINTS := {
	"place": { "act": "place", "hint": "把免疫细胞放到一个高亮的健康组织上" },
	"move": { "act": "move", "hint": "点底部「迁移」，再点一个相邻的健康组织" },
	"attack": { "act": "attack", "hint": "选一个站在癌组织上的癌细胞，迁过去攻击它" },
	"draw": { "act": "draw", "hint": "点「基因表达」抽一张卡" },
	"end": { "act": "end", "hint": "点右侧「结束回合」（或按空格）" },
}

## 关卡结束后、自由游玩阶段轮到你时的一句提示（不再推进步骤）。
const FREE_HINT := "自由行动：净化、抽卡、攻击或结束回合"

## guide 面板实例（由 CWMatch 在 _attach_guide 时注入）。
var guide: CWGuide
## on_prompt 由 CWMatch 注入，用于把提示转发出去（保持解耦）。
var on_prompt: Callable = Callable()
## 此刻正等这位真人作答的那一问（空 = 没在等人）。「继续」代做时据它挑下标
var _cur_req := {}
## 「继续」能替玩家做的动作：place/end/draw 一旦返回下标就完成一次行动，没有后续回环。
## move/attack 是「选完格还会留在选格态」的两段式，自动下标会让地面局一路连走停不下来，
## 所以只给提示、让玩家亲手点（2026-09-03 定稿）。
const AUTO_ACTS := { "place": true, "end": true, "draw": true }


## 轮到人类玩家的某一次询问：记下这一问（「继续」代做要用）、把提示喂给面板，然后照常交给界面。
func ask(req: Dictionary) -> int:
	if req["pid"] in human_pids and _guide_key(req) != "":
		_cur_req = req
		if guide != null and is_instance_valid(guide):
			guide.set_hint(current_hint())
	var got: int = await super.ask(req)
	_cur_req = {}
	return got


## 此刻该给玩家的一句提示：按正等的这一问 + 正在教的那一步算（没在等人 → 空串）。
## 面板每次翻页都会重新问一遍（CWGuide.hint_now），所以同一问里翻到「别忘了结束回合」，提示就从「迁移」换成「结束回合」
func current_hint() -> String:
	if _cur_req.is_empty():
		return ""
	var key := _guide_key(_cur_req)
	if key == "":
		return ""
	return STEP_HINTS[key].get("hint", FREE_HINT)


## 「继续」此刻会不会替玩家做这一步：正在教的动作是可代做的一种，且此刻正等的这一问里挑得出它
func can_demo() -> bool:
	return _demo_index() >= 0


## 「继续」按下：能代做就替玩家作答（唤醒卡在 _prompt 上的那一问），返回 true；否则 false，面板只翻页。
## 先把「正在等的这一问」清掉再唤醒：唤醒是同步展开的，展开途中引擎可能已经问出下一问、写进新的 _pending / _cur_req，
## 事后再清会把新的抹掉；而同一问也绝不能代做第二次（Answer 只认第一个答案，但这里的 true/false 得说真话）
func take_offer() -> bool:
	var idx := _demo_index()
	if idx < 0 or _pending == null:
		return false
	var p := _pending
	_pending = null
	_cur_req = {}
	p.fire(idx)
	return true


## 代做时该答哪个下标；-1 = 此刻不能代做（没在等人 / 面板没挂 / 教的不是一步到位的动作 / 局面里没这一项）
func _demo_index() -> int:
	if _cur_req.is_empty() or guide == null or not is_instance_valid(guide) or not guide.active:
		return -1
	var teach := CWGuideData.act_of(guide.chapter(), guide.step_no())
	if not AUTO_ACTS.has(teach):
		return -1
	return _pick(_cur_req, teach)


## 把 req 归类到 STEP_HINTS 里的一个键。落子 / 顶层行动都走这里。
## 顶层 action 里优先说「正在教的动作」（它得在这一问里做得了：攻击 = 迁进有癌细胞的格，选项里叫 move）；
## 教的不是这一问里的动作（或没在教动作）就给一句通用的迁移提示，避免新手面对一整排按钮愣住。
func _guide_key(req: Dictionary) -> String:
	if req["kind"] == "setup_place":
		return "place"
	if req["kind"] != "action":
		return ""
	var acts := {}
	for opt in req["options"]:
		acts[str(opt["data"].get("act", ""))] = true
	var teach := ""
	if guide != null and is_instance_valid(guide):
		teach = CWGuideData.act_of(guide.chapter(), guide.step_no())
	if teach == "attack" and acts.has("move"):
		return "attack"
	if teach != "" and STEP_HINTS.has(teach) and acts.has(teach):
		return teach
	if acts.has("move"):
		return "move"
	for a in acts:
		if a in STEP_HINTS:
			return a
	return ""


## 从引擎给的合法选项里挑一个满足当前动作的，返回下标；挑不到返回 -1。
## 落子优先挑**紧邻癌区**的健康格 —— 剧本建议的就是这种位置，提亮层描的也是它们。
func _pick(req: Dictionary, key: String) -> int:
	var opts: Array = req["options"]
	if opts.is_empty():
		return -1
	if key == "place":
		if req["kind"] != "setup_place":
			return -1
		for i in opts.size():
			var to: Vector2i = opts[i]["data"]["to"]
			for n in CWData.neighbors(to):
				if game != null and game.tiles.has(n) and game.is_cancerous(n):
					return i
		return 0
	for i in opts.size():
		var a: String = opts[i]["data"].get("act", "")
		match key:
			"move":
				if a == "move" and game.cells_at(opts[i]["data"]["to"]).is_empty():
					return i
			"attack":
				if a == "move" and not game.cells_at(opts[i]["data"]["to"], CWData.Faction.CANCER).is_empty():
					return i
			"draw":
				if a == "draw":
					return i
			"end":
				if a == "end":
					return i
	return -1
