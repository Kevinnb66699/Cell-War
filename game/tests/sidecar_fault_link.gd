## sidecar_fault_link.gd —— 测试用的 sidecar 链路：真进程、真连接，只在点名的那条报文上当场「断掉」
##（t_sidecar_fault_before_view：open() 成了之后、头一份镜像落地之前 sidecar 没了 —— 真 sidecar 没有「第几条报文上崩」的开关，
## core/ 也不为测试加口子）。产品代码不用改：句柄从 cw_sidecar_link.gd 的 `_links` 里拿同一份产物的活链路，
## 测试先把这一条起好、塞进去（见 `install`），句柄就用上它了。
## 断法照真的来：`_die` 杀进程、从 `_links` 里摘掉，挂在上面的句柄下一次报文就看见故障 —— 与进程真崩了走同一条路
extends "res://scripts/kernel/cw_sidecar_link.gd"

var fail_op := ""                       ## 在哪一种报文上断（"" = 不断）
var fail_skip := 0                      ## 这种报文先放过去几次
var fail_fault := CWKernel.Fault.CRASHED
## true = 不杀进程，只把这一条回成「这一局内部出错」（`broken:true`，同 C# Dispatcher 接住异常时的回应）：会话级故障、链路照常
var fail_broken := false
## 非空 = 先看见一条这种报文才「上膛」，下一条 fail_op 才断（例：arm_on = "answer"、fail_op = "save" —— 答案收下之后、存检查点那一下坏）
var arm_on := ""
var fail_repeat := false               ## true = 断完不撤，每次上膛都再断
var _armed := false
## 更多规则（10-01 二轮复核加）：每条 {op, args?（子集相等才算）, skip?, after?（先见过这种报文才生效）, reply?（回这一条；没有 = 断链路）, repeat?}
var rules: Array = []
var _seen_ops := {}


## 起一条真链路、登记成这份产物的共用链路。之前同一份产物要是还有一条闲着的，先关掉（不然 acquire 会复用那一条）
static func install(dotnet_path: String, dll_path: String, op: String, skip := 0) -> RefCounted:
	var key := dotnet_path + "|" + dll_path
	if _links.has(key):
		_links[key].shutdown()
	var link = new()
	link.dotnet = dotnet_path
	link.dll = dll_path
	link.fail_op = op
	link.fail_skip = skip
	if link._spawn():
		_links[key] = link   ## users 留 0：第一个 acquire 的句柄把它加到 1；测试收尾 shutdown_idle 关得掉
	return link


func request(op: String, args := {}) -> Dictionary:
	_seen_ops[op] = true
	for r: Dictionary in rules.duplicate():
		if String(r["op"]) != op or (r.has("after") and not _seen_ops.has(String(r["after"]))):
			continue
		var want: Dictionary = r.get("args", {})
		if not want.keys().all(func(k) -> bool: return args.has(k) and args[k] == want[k]):
			continue
		if int(r.get("skip", 0)) > 0:
			r["skip"] = int(r["skip"]) - 1
			continue
		if not bool(r.get("repeat", false)):
			rules.erase(r)
		if r.has("reply"):
			return (r["reply"] as Dictionary).duplicate()
		_die(fail_fault, "测试：在 %s 上断掉" % op)
		return {}
	if arm_on != "" and op == arm_on:
		_armed = true
	if op == fail_op and (arm_on == "" or _armed):
		if fail_skip <= 0:
			_armed = false
			if not fail_repeat:
				fail_op = ""
			if fail_broken:
				return { "ok": false, "broken": true, "error": "测试：%s 时这一局内部出错" % op }
			_die(fail_fault, "测试：在 %s 上断掉" % op)
			return {}
		fail_skip -= 1
	return super.request(op, args)
