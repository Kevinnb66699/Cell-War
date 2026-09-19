extends SceneTree
## 把现行教程剧本**原样导出成 Markdown** —— 给人读的工具，不是测试。
##
## 为什么要有：正文里的数字是从 `CWTuning` / `CWData` 现算的（`{{tune.旋钮名}}` 占位，数据纪律 6）。
## 想通读一遍、或者要和团队逐句对文案，翻 JSON 既费劲又容易漏掉「这句里的数其实是算出来的」。
##
## **2026-09-19 按新壳重写**（新手教程 v2 · S12 收口）。S1 那一版是桩：只会把 `lines` 抄一遍。
## 这一版补齐两件 ——
##   ① **占位符替换**：`{{tune.*}}` 按**这一关自己那份 world 的旋钮**现算（关卡可以改旋钮，
##      六关里的数因此不一定等于正式局的数；拿全局默认值替换会给出错的字）；
##   ② **按皮排版**：九个动词各自把「玩家真会看到 / 真要做的那件事」摊开 ——
##      台词前面标说话人、`player` 那条把 `allow` / `until` / 提示行列出来、`point` 标高亮的是谁。
##      逐字对文案的人要的是这个，不是 JSON。
##
## 跑（可以加 --headless）：
##   godot --headless --path game --script res://tests/dump_guide.gd -- <输出.md>
## 不给路径就打到标准输出。
##
## **导出的稿子按天存档**：`docs/教程剧本_<YYYY-MM-DD>.md`（2026-09-14 起的规矩）——
## 文案是队友在改的东西，留下每一版才对得起「改完再导一份」这句话；
## 不要覆盖同一个文件名，那样改了什么就再也看不出来了。

const SCRIPT_DATA := preload("res://scripts/kernel/cw_tutor_script.gd")

## 说话人（`who`）→ 给人读的名字。`seat:<n>` / `ui:<控件 id>` 另外按前缀翻
const WHO_NAMES := { "player": "玩家", "narrator": "旁白" }

var _out := ""
var _data                      ## SCRIPT_DATA 的实例
var _tune: CWTuning = null     ## 当前这一关的旋钮（`{{tune.*}}` 从它取）


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	_data = SCRIPT_DATA.new()
	var rows: Array = _data.load_index().get("levels", [])
	var md := PackedStringArray()
	md.append("# 教程剧本（现行 · cwtut/2）")
	md.append("")
	md.append("由 `game/tests/dump_guide.gd` 从 `game/data/tutorial/**` 导出 —— **这就是玩家真会看到的字**。")
	md.append("")
	md.append("- 共 %d 关（含间章）；每条 `flow[]` 带 `do`（九个动词之一）与 `prd`（剧本行号，对账闸用）" % rows.size())
	md.append("- 正文里的 `{{tune.旋钮名}}` 已按**这一关自己那份 world 的旋钮**现算替换")
	md.append("- 台词前面的名字是 `who`；`player` 那条列的是**玩家此刻能做什么**（`allow`）与**做到什么算过**（`until`）")
	md.append("")
	var total := 0
	for row: Dictionary in rows:
		var lv: Dictionary = _data.load_level(str(row.get("id", "")))
		if lv.is_empty():
			md.append("> ⚠ 关「%s」读不出来（关表里的 file 指错了？）" % str(row.get("id", "")))
			continue
		_tune = _tune_of(lv)
		total += _level_md(lv, md)
	md.append("---")
	md.append("")
	md.append("合计 %d 条。" % total)
	md.append("")
	_write("\n".join(md), rows.size(), total)
	quit()


## 一关的整段。返回这一关的条目数
func _level_md(lv: Dictionary, md: PackedStringArray) -> int:
	var flow: Array = lv.get("flow", [])
	md.append("---")
	md.append("")
	md.append("## %s · %s" % [str(lv.get("title", "")), str(lv.get("chapter_title", ""))])
	md.append("")
	md.append("> %s" % _fill(str(lv.get("subtitle", ""))))
	md.append("")
	md.append("`%s` `活跃格 %d` `席位 %d（人类坐第 %d 席）` `带子 %d 颗` `%d 条` `world %s`"
		% [str(lv.get("chapter_kind", "main")), (lv.get("active_tiles", []) as Array).size(),
			int(lv.get("seats", 0)), int(lv.get("human_seat", 0)) + 1,
			(lv.get("rolls", []) as Array).size(), flow.size(),
			", ".join(PackedStringArray((lv.get("worlds", {}) as Dictionary).keys()))])
	md.append("")
	for k in flow.size():
		var e: Dictionary = flow[k]
		var head := "**%d. `%s`**%s" % [k + 1, str(e.get("do", "")),
			"（PRD:%d）" % int(e["prd"]) if e.has("prd") else ""]
		var tail := _headline(e)
		md.append(head if tail == "" else "%s　%s" % [head, tail])
		md.append("")
		for line in e.get("lines", []):
			md.append("> %s" % _fill(str(line)))
		for field in ["hint", "advise", "tip"]:
			if str(e.get(field, "")) != "":
				md.append("　　%s `%s`" % [field, _fill(str(e[field]))])
		md.append("")
	return flow.size()


## 动词那一行的「摘要」：这一条**做了什么**，一句话。空串 = 这个动词没有额外要说的
func _headline(e: Dictionary) -> String:
	var bits := PackedStringArray()
	match str(e.get("do", "")):
		"state":
			if e.has("load"):
				bits.append("装盘 `%s`" % str(e["load"]))
			if e.has("reveal"):
				bits.append("浮现 %s" % _coords(e["reveal"]))
			if e.has("ui"):
				bits.append("界面 %s" % _ui_text(e["ui"]))
		"say":
			bits.append(_who(str(e.get("who", ""))))
			if bool(e.get("auto", false)):
				bits.append("自动过")
			if e.has("beats"):
				bits.append("停 %d 拍" % int(e["beats"]))
		"point":
			bits.append("高亮 %s" % _targets(e))
			bits.append("`%s`" % str(e.get("mode", "soft")))
		"unlock":
			bits.append("解锁图鉴 %s" % ", ".join(PackedStringArray(e.get("ids", []))))
		"player":
			bits.append("玩家能做：%s" % ("（不限）" if not e.has("allow")
				else "`%s`" % "` `".join(PackedStringArray(e.get("allow", [])))))
			if e.has("until"):
				bits.append("过关条件 `%s`" % _pred(e["until"]))
			if e.has("reset_when"):
				bits.append("自动重置 `%s`" % _pred(e["reset_when"]))
			if e.has("advise_when"):
				bits.append("劝重置 `%s`" % _pred(e["advise_when"]))
			if e.has("ui") or e.has("hex"):
				bits.append("高亮 %s" % _targets(e))
		"hook":
			bits.append("钩子 `%s`" % str(e.get("call", "")))
		"wait":
			bits.append("等 %s 秒" % str(e.get("secs", 0)))
		"play":
			bits.append("演出 `%s`" % str(e.get("fx", "")))
			if e.has("at"):
				bits.append("在 %s" % _coords(e["at"]))
			if e.has("secs"):
				bits.append("%s 秒" % str(e["secs"]))
			if bool(e.get("await", false)):
				bits.append("等它播完")
		"npc":
			bits.append("第 %d 席照剧本走 `%s`" % [int(e.get("seat", 0)) + 1, str(e.get("plan", ""))])
	return " ｜ ".join(bits)


## `who` → 给人读的名字
func _who(who: String) -> String:
	if WHO_NAMES.has(who):
		return str(WHO_NAMES[who])
	if who.begins_with("seat:"):
		return "第 %d 席" % (int(who.substr(5)) + 1)
	if who.begins_with("ui:"):
		return "界面「%s」" % who.substr(3)
	return who


## `point` / `player` 的高亮目标（`ui` 一组控件 id + `hex` 一组坐标）
func _targets(e: Dictionary) -> String:
	var bits := PackedStringArray()
	if e.has("ui"):
		bits.append("控件 %s" % ", ".join(PackedStringArray(e["ui"])))
	if e.has("hex"):
		bits.append("格 %s" % _coords(e["hex"]))
	return " + ".join(bits) if bits.size() > 0 else "（无）"


func _coords(v: Variant) -> String:
	return "(%s)" % ") (".join(PackedStringArray(v)) if v is Array else str(v)


## 三类谓词写回一行（`{"state":"…","arg":"…"}` / `{"delta":"…"}` / 字符串直写）
func _pred(v: Variant) -> String:
	if not (v is Dictionary):
		return str(v)
	var d: Dictionary = v
	var bits := PackedStringArray()
	for k in d:
		bits.append("%s=%s" % [str(k), str(d[k])])
	return " ".join(bits)


## `state.ui` 那一串开关：只列**开着的**与几个带值的，全列出来没人读得完
func _ui_text(v: Variant) -> String:
	if not (v is Dictionary):
		return str(v)
	var on := PackedStringArray()
	var off := PackedStringArray()
	for k in (v as Dictionary):
		var val: Variant = (v as Dictionary)[k]
		if val is bool:
			if bool(val):
				on.append(str(k))
			elif str(k) == "*":
				off.append("先全关")
		else:
			on.append("%s=%s" % [str(k), JSON.stringify(val)])
	var bits := PackedStringArray()
	if off.size() > 0:
		bits.append(", ".join(off))
	if on.size() > 0:
		bits.append(", ".join(on))
	return " → ".join(bits)


## 这一关自己那份旋钮：`worlds` 里关首那一份的 `tuning` 盖在默认值上。
## 拿全局默认值替换 `{{tune.*}}` 会给出错的字 —— 教程的关卡是**改过旋钮**的（攻击次数上限、
## 有氧档位…），而玩家看到的数就是这一关生效的那个
func _tune_of(lv: Dictionary) -> CWTuning:
	var t := CWTuning.new()
	var entry := "base"
	var flow: Array = lv.get("flow", [])
	if flow.size() > 0 and (flow[0] as Dictionary).has("load"):
		entry = str((flow[0] as Dictionary)["load"])
	var spec: Dictionary = _data.resolve(lv, entry)
	for k in (spec.get("tuning", {}) as Dictionary):
		if k in t:
			t.set(str(k), (spec["tuning"] as Dictionary)[k])
	return t


## `{{tune.旋钮名}}` → 这一关生效的那个数。认不出来的原样留着（留着才看得见哪里写错了）
func _fill(text: String) -> String:
	var out := text
	while true:
		var a := out.find("{{tune.")
		if a < 0:
			break
		var b := out.find("}}", a)
		if b < 0:
			break
		var key := out.substr(a + 7, b - a - 7).strip_edges()
		var shown := "{{tune.%s ← 没有这个旋钮}}" % key
		if _tune != null and key in _tune:
			shown = str(_tune.get(key))
		out = out.substr(0, a) + shown + out.substr(b + 2)
	return out


func _write(text: String, levels: int, total: int) -> void:
	if _out == "":
		print(text)
		return
	var f := FileAccess.open(_out, FileAccess.WRITE)
	if f == null:
		printerr("写不出去：%s" % _out)
		return
	f.store_string(text)
	f.close()
	print("已导出 %s（%d 关 / %d 条）" % [_out, levels, total])
