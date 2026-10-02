extends CWUIBridge
## 测试用界面桥（t_bridge_stale_ask / t_serve_ask_resend）：`_ask_human` 走到出行动栏那一步就记一次 —— 不建界面。
## 测的是「这一问还活着吗」那几处判断，不是行动栏本身。
## `hold` = 假：当场答 0；真：像 `_prompt` 那样挂一只 Answer 在 `_pending` 上等「点击」（测试 `_pending.fire(i)`；abort() 发 null → 答 0）
var acted := 0
var hold := false
var views: Array = []   ## 每次出行动栏时那一问的选项（只记 data.act）


func _ask_action(req: Dictionary) -> int:
	return await _held(req)


func _ask_generic(req: Dictionary) -> int:
	return await _held(req)


func _held(req: Dictionary) -> int:
	acted += 1
	views.append((req["options"] as Array).map(func(o: Dictionary) -> String: return str(o["data"].get("act", ""))))
	if not hold:
		return 0
	var ans := CWUIBridge.Answer.new()
	_pending = ans
	var got: Variant = await ans.done
	if _pending == ans:
		_pending = null
	return 0 if got == null else int(got)
