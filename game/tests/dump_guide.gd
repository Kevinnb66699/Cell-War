extends SceneTree
## 把现行教程剧本**原样导出成 Markdown** —— 给人读的工具，不是测试。
##
## 为什么要有：剧本散在 `CWGuideData` 的 16 个 `_stage_*()` 里，正文还带着从
## `CWTuning` / `CWData` 现算的数字（费用、伤害、门槛…）。想通读一遍、或者要和团队
## 逐句对文案，翻源码既费劲又容易漏掉「这句里的数其实是算出来的」。
## 这里直接问引擎要，导出来的就是**玩家真会看到的那几行字**。
##
## 跑（可以加 --headless）：
##   godot --headless --path game --script res://tests/dump_guide.gd -- <输出.md>
## 不给路径就打到标准输出。
##
## **导出的稿子按天存档**：`docs/教程剧本_<YYYY-MM-DD>.md`（2026-09-14 起的规矩）——
## 文案是队友在改的东西，留下每一版才对得起「改完再导一份」这句话；
## 不要覆盖同一个文件名，那样改了什么就再也看不出来了。

var _out := ""


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	var md := PackedStringArray()
	md.append("# 教程剧本（现行）")
	md.append("")
	md.append("由 `game/tests/dump_guide.gd` 从引擎导出 —— **这就是玩家真会看到的字**，")
	md.append("正文里的数字是 `CWTuning` / `CWData` 现算的，不是写死的。")
	md.append("")
	md.append("- 共 %d 关；`渐进 UI` 档位：0 只看棋盘 · 1 目标高亮 · 2 规则/资源提示 · 3 预测与解释"
		% CWGuideData.CHAPTER_COUNT)
	md.append("- 每步的字段：**正文**（最多两行）`高亮`（提亮层目标）`动作`（可由「继续」代做）`完成`（真实状态判据）")
	md.append("")
	var titles := CWGuideData.chapter_titles()
	var subs := CWGuideData.chapter_subtitles()
	var total := 0
	for i in CWGuideData.CHAPTER_COUNT:
		var steps: Array = CWGuideData.steps(i)
		total += steps.size()
		md.append("---")
		md.append("")
		md.append("## 第 %d 关 · %s" % [i + 1, titles[i]])
		md.append("")
		md.append("> %s" % subs[i])
		md.append("")
		md.append("`棋盘半径 %d` `视角 %s` `实验区 %d` `渐进 UI %d` `知识之书第 %d 章` `%d 步`"
			% [CWGuideLevels.radius(i),
				"癌症方" if CWGuideLevels.player_faction(i) == CWData.Faction.CANCER else "免疫方",
				CWGuideLevels.zones(i), CWGuideData.ui_stage(i),
				int(CWGuideData.CODEX_PAGE[i]) + 1, steps.size()])
		md.append("")
		for k in steps.size():
			var s: Dictionary = steps[k]
			md.append("**%d.%d %s**" % [i + 1, k + 1, str(s.get("t", ""))])
			md.append("")
			for line in s.get("b", []):
				md.append("> %s" % str(line))
			md.append("")
			var tags := PackedStringArray()
			if str(s.get("flag", "")) != "":
				tags.append("高亮 `%s`" % str(s["flag"]))
			if str(s.get("act", "")) != "":
				tags.append("动作 `%s`" % str(s["act"]))
			if str(s.get("watch", "")) != "":
				tags.append("完成 `%s`" % str(s["watch"]))
			if not tags.is_empty():
				md.append("　　%s" % " · ".join(tags))
				md.append("")
	md.append("---")
	md.append("")
	md.append("合计 %d 步。" % total)
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
			print("已导出 %s（%d 关 / %d 步）" % [_out, CWGuideData.CHAPTER_COUNT, total])
	quit()
