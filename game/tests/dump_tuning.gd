## dump_tuning.gd —— 把**当前生效的全部规则旋钮默认值**原样打出来
##
## **为什么要有它。** 改平衡之前得先有一份「改之前长什么样」的底稿，
## 而底稿绝不能手抄 —— `CWTuning` 有四十来个字段、还有一半是从 `CWData` 常量取的，
## 手抄一定会漏或抄错，然后拿一份错的底稿去比对，比没有底稿更糟。
## 这里直接 new 一个默认 `CWTuning` 把 `RULE_FIELDS` 逐条打出来，
## 打出来的就是引擎此刻真正在用的值。
##
## 运行：
##   godot --headless --path game --script res://tests/dump_tuning.gd
##
## 输出是 Markdown 表格，可以直接贴进 docs/。数组字段（如按等级分档的迁移费）
## 原样打印，不做展开 —— 展开就得知道每一档是什么意思，那属于文档的活，不属于转储的活。
extends SceneTree


func _initialize() -> void:
	var t := CWTuning.new()
	print("| 字段 | 当前默认值 |")
	print("|---|---|")
	for name in CWTuning.RULE_FIELDS:
		print("| `%s` | `%s` |" % [name, str(t.get(name))])
	print("")
	print("字段数：%d" % CWTuning.RULE_FIELDS.size())
	quit(0)
