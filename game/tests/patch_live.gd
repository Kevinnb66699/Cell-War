extends SceneTree
## patch_live.gd —— 热更补丁的**线上验收**：拿真从服务器下下来的 manifest + 签名，
## 走一遍客户端 `boot.gd` 的判定，回答「这个补丁玩家到底会不会装」。
##
## `build_patch.sh` 发完会自己回读线上那份跑这个，不用人记得。单独跑：
##   godot --headless --path game --script res://tests/patch_live.gd -- <json> <sig> <基线号>
##
## **为什么非要有**：签名验不过、地址不在白名单、min_base 写错 —— 这几样
## 客户端一律**安静地当没看见**（宁可收不到更新，也不装来路不明的代码，
## 见 boot.gd 文件头纪律 ②）。所以「文件传上去了」离「玩家会装」还差得远，
## 而中间的失败**一声不响**。2026-09-10 第一次真发补丁前才补上这一环 ——
## 同一天刚发现跨基线闸因为一个被吃掉的反斜杠，一天都没生效过。
##
## 只读不写：不碰 user:// 里的补丁状态。
const PatchState := preload("res://scripts/patch_state.gd")
const Boot := preload("res://scripts/boot.gd")

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	var body := FileAccess.get_file_as_bytes(a[0])
	var sig := FileAccess.get_file_as_string(a[1]).strip_edges()
	var base := int(a[2])
	print("manifest %d 字节 / 签名 %d 字符 / 本机基线 %d" % [body.size(), sig.length(), base])

	var ok_sig := PatchState.verify_manifest(body, sig)
	print("① 验签（用包里烧死的公钥）：", "过" if ok_sig else "**没过 —— 客户端会当没看见**")

	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	var m: Dictionary = parsed if parsed is Dictionary else {}
	print("② manifest 解析：", "过（build %d）" % int(m.get("build", 0)) if not m.is_empty() else "**解析不出来**")

	## 地址必须落在写死的前缀底下（boot.gd 安全第 ③ 条）
	print("③ 下载地址在白名单里：", "是" if Boot.pinned(String(m.get("pck", ""))) else "**否**")

	## 刚装好新包的玩家：installed=0、没拉黑、基线 = 本机这一版
	var plan: Dictionary = Boot.decide(m, 0, 0, base)
	print("④ 全新客户端的判定：", plan["act"])
	## 已经装过这一版的：应当 skip，不该反复重下
	var again: Dictionary = Boot.decide(m, int(m.get("build", 0)), 0, base)
	print("⑤ 装过之后再启动：", again["act"], "（该是 skip）")
	## 停在更老全量包上的（基线比 min_base 老）：该让他去下完整包
	var old: Dictionary = Boot.decide(m, 0, 0, int(m.get("min_base", 0)) - 1)
	print("⑥ 停在更老包上的玩家：", old["act"], "（该是 too_old）")

	var all_ok: bool = ok_sig and not m.is_empty() and Boot.pinned(String(m.get("pck", ""))) \
		and String(plan["act"]) == "install" and String(again["act"]) == "skip" \
		and String(old["act"]) == "too_old"
	print("")
	print("✔ 六条全过，这个补丁客户端会装" if all_ok else "✘ 有不对的，见上面")
	quit(0 if all_ok else 1)
