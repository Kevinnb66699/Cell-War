## cw_kernel_sidecar.gd —— 本地 C# 进程内核的句柄（口径二 · 批 0 步 9 / 11：**stub，只钉接口面**）
##
## 真正的实现在 sidecar 那一批：OS.create_process 起 CellWar.Sidecar、loopback + token、/version /selftest /observe /pull /submit /query /save /restore，
## 退出码 64/65/66，换内核 = 换目录再 spawn（路线A §八点四）。批 0 这里 open() 一律失败 → UNAVAILABLE + SPAWN_FAILED，
## 每个方法在该态下继承基类的「定义良好的返回」（不抛不崩），一致性套件按它验不可用分支。
## ⚠ 硬不变量：sidecar 起不来**绝不能计进补丁系统的 STRIKES**（patch_state.gd 的永久本地拉黑）—— UNAVAILABLE 与补丁系统完全隔离。
class_name CWKernelSidecar
extends CWKernel


func open(_cfg: Dictionary) -> bool:
	_set_fault(Fault.SPAWN_FAILED, "sidecar 尚未实现：批 0 只钉接口面，真实现随 sidecar 那一批")
	_set_state(State.UNAVAILABLE)
	return false


func version() -> Dictionary:
	return { "host_abi": 0, "rules_build": "", "ruleset_digest": "" }


func caps() -> Dictionary:
	return { "stream_sync": true, "step_drive": false, "rollout": false, "save": true, "authority": true }
