## guide_bridge.gd —— 教程局的引导桥：包一层 CWUIBridge，只加两件事
##
## ① 每步动作预先指定（落子 / 迁移 / 攻击 / 抽卡 / 结束回合），轮到人类时若该步
##    可自动演示则先演示一遍，再由玩家照着做；做错继续提示，绝不硬锁。
## ② 把「现在做什么」的一句话喂给 CWGuide.set_hint（经 guide 面板的实时提示行）。
##
## **不是硬锁步的教程**：引擎、询问桥、行动栏照常跑。演示就是「从引擎生成的合法
## 选项里挑一个满足条件的下标直接返回」——选项全由引擎生成，所以演示的每一步
## 都是合法行动；挑不出来（比如这一步在真实局面里不可用）就退回人类界面、只留提示。
##
## 这是**新桥**而不是改 CWUIBridge：正式对局和教程共用同一套引擎与界面，
## 教程的演示逻辑单独隔离在这里，出问题不会影响正常对局。
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
var _last_lesson_hint := ""  ## 上一次喂给面板的提示（去重用）
var _demoed := {}      ## (chapter, step) -> 已自动演示过（每步只演示一次）
## 只对「一步到位」的动作自动演示：place/end/draw 一旦返回下标就完成一次行动，
## 没有后续回环。move/attack 是「选完格还会留在选格态」的两段式，自动下标会
## 让地面局一路连走停不下来，所以只给提示、让玩家亲手点（2026-09-03 定稿）。
const AUTO_ACTS := { "place": true, "end": true, "draw": true }


## 在轮到人类玩家的某一次询问里：
##  - setup_place / 作用 action 时，找到向导当前步骤对应的演示动作；
##  - 如果该步设置了 auto 且能在合法选项里挑出演示下标，就直接替玩家走一步；
##  - 否则把提示喂给 guide，让玩家自己操作。
func ask(req: Dictionary) -> int:
	if req["pid"] in human_pids:
		var key := _guide_key(req)
		if key != "":
			var hint: String = STEP_HINTS[key].get("hint", FREE_HINT)
			if guide != null and is_instance_valid(guide) and guide.active and guide.chapter() >= 0:
				## 演示只对「当前正在教的这一关的这一个动作」生效；其他时刻只提示。
				var teach_act := CWGuideData.act_of(guide.chapter(), guide.step_no())
				if key == teach_act and _may_demo(key, guide.chapter(), guide.step_no()):
					var idx := _pick(req, key)
					if idx >= 0:
						guide.set_hint(hint + "（我已演示一遍，你可以照着做）")
						return idx
			if guide != null and is_instance_valid(guide):
				guide.set_hint(hint)
	return await super.ask(req)

## 把 req 归类到 STEP_HINTS 里的一个键。落子 / 顶层行动都走这里。
## 顶层 action 里我们只关心「正在学的动作」，但如果它不属于当前关卡，
## 仍给一个通用提示（避免新手面对一整排按钮愣住）。
func _guide_key(req: Dictionary) -> String:
	if req["kind"] == "setup_place":
		return "place"
	if req["kind"] != "action":
		return ""
	for opt in req["options"]:
		var a: String = opt["data"].get("act", "")
		if a == "move":
			## 优化：如果这一步同时在教攻击，优先显示攻击提示
			if guide != null and is_instance_valid(guide) and CWGuideData.act_of(guide.chapter(), guide.step_no()) == "attack":
				return "attack"
			return "move"
		if a in STEP_HINTS:
			return a
	return ""


## 这一步能不能自动演示：只对「一步到位」的动作演示一次。
## setup_place 的演示键是 place（guide_data 的 act 也是 place），
## 其余动作（move/attack）是两段式选格，留给玩家亲手点。
func _may_demo(key: String, chapter: int, step: int) -> bool:
	if not AUTO_ACTS.has(key):
		return false
	var k := "%d:%d" % [chapter, step]
	if _demoed.get(k, false):
		return false
	_demoed[k] = true
	return true

## 从引擎给的合法选项里挑一个满足当前动作的，返回下标；挑不到返回 -1。
func _pick(req: Dictionary, key: String) -> int:
	var opts: Array = req["options"]
	if opts.is_empty():
		return -1
	if key == "place":
		return 0 if req["kind"] == "setup_place" else -1
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
