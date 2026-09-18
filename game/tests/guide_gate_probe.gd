extends CWGuideBridge
## 决策闸（方案 §1.5）的探针：把 `CWGuideBridge._ask_ui` 换成「记下过滤后的 view、按 pick 答一个 view 下标」。
## 这样就能在无头、无界面、无引擎的条件下验三件事 ——
## 闸的三态、**下标只映射一次**（答 view 下标 0，返回的却是原表里那一条），以及「全禁 / 全落空时一次也不答」。
##
## 单独一个文件而不是测试里的内部类：内部类 extends 全局类在测试脚本解析时解析不到父类
## （2026-09-11 撞到「Could not resolve super class inheritance」），用 load() 现取就没这问题。
var seen: Array = []      ## 每次被问到时那一份 view 的 options（原样存）
var answered := 0         ## 一共答了几次（全禁 / 全落空时必须是 0）
var pick := 0             ## 每次答哪个 **view** 下标


func _ask_ui(req: Dictionary) -> int:
	seen.append((req["options"] as Array).duplicate())
	answered += 1
	return pick
