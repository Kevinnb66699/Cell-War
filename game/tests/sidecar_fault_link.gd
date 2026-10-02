## sidecar_fault_link.gd —— 测试用的 sidecar 链路：真进程、真连接，只在点名的那条报文上当场「断掉」
##（t_sidecar_fault_before_view：open() 成了之后、头一份镜像落地之前 sidecar 没了 —— 真 sidecar 没有「第几条报文上崩」的开关，
## core/ 也不为测试加口子）。产品代码不用改：句柄从 cw_sidecar_link.gd 的 `_links` 里拿同一份产物的活链路，
## 测试先把这一条起好、塞进去（见 `install`），句柄就用上它了。
## 断法照真的来：`_die` 杀进程、从 `_links` 里摘掉，挂在上面的句柄下一次报文就看见故障 —— 与进程真崩了走同一条路
extends "res://scripts/kernel/cw_sidecar_link.gd"

var fail_op := ""                       ## 在哪一种报文上断（"" = 不断）
var fail_skip := 0                      ## 这种报文先放过去几次
var fail_fault := CWKernel.Fault.CRASHED


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
	if op == fail_op:
		if fail_skip <= 0:
			fail_op = ""
			_die(fail_fault, "测试：在 %s 上断掉" % op)
			return {}
		fail_skip -= 1
	return super.request(op, args)
