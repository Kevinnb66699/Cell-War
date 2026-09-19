extends SceneTree
## 把现行教程剧本**原样导出成 Markdown** —— 给人读的工具，不是测试。
##
## 为什么要有：正文里的数字是从 `CWTuning` / `CWData` 现算的（`{{tune.*}}` 占位，费用、伤害、门槛…）。
## 想通读一遍、或者要和团队逐句对文案，翻数据既费劲又容易漏掉「这句里的数其实是算出来的」。
##
## **2026-09-19 改读 `cwtut/2`**（新手教程 v2 · S1）：老 `CWGuideData` 随老教程一起删了，
## 数据门面换成 `scripts/kernel/cw_tutor_script.gd`，逐关按 `index.json` 的关表走，
## 每条 `flow[]` 按九个动词原样列出来。**这一片是桩**：占位符替换与按皮排版由 S12 重写。
##
## 跑（可以加 --headless）：
##   godot --headless --path game --script res://tests/dump_guide.gd -- <输出.md>
## 不给路径就打到标准输出。
##
## **导出的稿子按天存档**：`docs/教程剧本_<YYYY-MM-DD>.md`（2026-09-14 起的规矩）——
## 文案是队友在改的东西，留下每一版才对得起「改完再导一份」这句话；
## 不要覆盖同一个文件名，那样改了什么就再也看不出来了。

const SCRIPT_DATA := preload("res://scripts/kernel/cw_tutor_script.gd")

var _out := ""


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	var d = SCRIPT_DATA.new()
	var rows: Array = d.load_index().get("levels", [])
	var md := PackedStringArray()
	md.append("# 教程剧本（现行 · cwtut/2）")
	md.append("")
	md.append("由 `game/tests/dump_guide.gd` 从数据导出 —— **这就是玩家真会看到的字**。")
	md.append("")
	md.append("- 共 %d 关；每条 `flow[]` 带 `do`（九个动词之一）与 `prd`（剧本行号，对账闸用）" % rows.size())
	md.append("")
	var total := 0
	for row: Dictionary in rows:
		var lv: Dictionary = d.load_level(str(row.get("id", "")))
		if lv.is_empty():
			md.append("> ⚠ 关「%s」读不出来（关表里的 file 指错了？）" % str(row.get("id", "")))
			continue
		var flow: Array = lv.get("flow", [])
		total += flow.size()
		md.append("---")
		md.append("")
		md.append("## %s · %s" % [str(lv.get("title", "")), str(lv.get("chapter_title", ""))])
		md.append("")
		md.append("> %s" % str(lv.get("subtitle", "")))
		md.append("")
		md.append("`%s` `活跃格 %d` `席位 %d（人类坐第 %d 席）` `带子 %d 颗` `%d 条`"
			% [str(lv.get("chapter_kind", "main")), (lv.get("active_tiles", []) as Array).size(),
				int(lv.get("seats", 0)), int(lv.get("human_seat", 0)) + 1,
				(lv.get("rolls", []) as Array).size(), flow.size()])
		md.append("")
		for k in flow.size():
			var e: Dictionary = flow[k]
			md.append("**%d. `%s`**%s" % [k + 1, str(e.get("do", "")),
				"（PRD:%d）" % int(e["prd"]) if e.has("prd") else ""])
			md.append("")
			for line in e.get("lines", []):
				md.append("> %s" % str(line))
			for field in ["hint", "advise", "tip"]:
				if str(e.get(field, "")) != "":
					md.append("　　%s `%s`" % [field, str(e[field])])
			md.append("")
	md.append("---")
	md.append("")
	md.append("合计 %d 条。" % total)
	md.append("")
	var text := "\n".join(md)
	if _out == "":
		print(text)
	else:
		var f := FileAccess.open(_out, FileAccess.WRITE)
		if f == null:
			printerr("写不出去：%s" % _out)
		else:
			f.store_string(text)
			f.close()
			print("已导出 %s（%d 关 / %d 条）" % [_out, rows.size(), total])
	quit()
