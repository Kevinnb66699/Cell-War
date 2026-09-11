extends CWHeuristicBridge
## 记下引擎报的每一条技能演出（t_skill_fx 用）：ask 照启发式桥答，只多记 show_fx。
## 单独一个文件而不是测试里的内部类：内部类 extends 全局类在测试脚本解析时解析不到父类
## （2026-09-11 撞到「Could not resolve super class inheritance」），用 load() 现取就没这问题。
var got: Array = []


func show_fx(kind: String, data: Dictionary) -> void:
	got.append([kind, data])
