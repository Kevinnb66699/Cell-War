extends Node
## 启动器 —— 查更新、挂补丁包，再进主场景。这是 `run/main_scene`。
##
## ## 为什么非得有这一层
##
## 客户端包 94 MB，其中约 88 MB 是 Godot 运行时，几乎从不变；每天真正改的
## 只有几十 KB 的脚本。`ProjectSettings.load_resource_pack()` 能用一个补丁包
## **按 res:// 路径覆盖**原包里的文件，于是发版不必再重传整个运行时。
##
## ## 两条硬约束（都是实测出来的，不是查文档来的）
##
## ① **挂载必须早于游戏代码的首次 load。** GDScript 一旦 load 过就进缓存，
##    之后再挂包也换不掉 —— 实测「先 load 再挂」拿到的仍是旧版。
## ② **本文件与它引用的一切，都不许碰游戏里的类**（`CWData` / `CWStyle` / …）。
##    引用谁，谁就在挂载前被解析进缓存，等于把游戏本体钉死在旧版上。
##    第一次做实验时启动脚本引用了被补丁覆盖的类，Godot 直接**挂死**。
##    所以这里只 preload 一个同样自包含的 `patch_state.gd`，别的一律不碰。
##    护栏 `t_hot_patch` 会直接扫这两个文件的源码，出现游戏类名就红。
##
## ## 补丁改不动什么（要动就得全量发版）
##
## · **新增 `class_name`** —— 全局类表在导出时就烘死了，补丁里新加的类名
##   会报 `Identifier "X" not declared`。新脚本想热更就别给 class_name，
##   改用 `preload("res://…gd")` 按路径引用。打包器（`tests/build_patch.gd`）会拦。
## · `project.godot` 的设置（自动加载、输入映射、窗口）—— 引擎启动时就读完了。
## · Godot 版本 / 导出模板 / 删除文件。
##
## ## 安全：这是在下发**可执行代码**
##
## **全链路都在自家服务器上，信任不靠 TLS 而靠一把钥匙**
## （Kevin 2026-09-09：国内比 GitHub 快一个量级，而且不受 GitHub 连不上影响）。
##
## · **manifest 带一份 RSA 签名**，公钥烧在 `PatchState.PUBLIC_KEY_PEM` 里。
##   manifest 是信任锚 —— 它说「装哪个包、哈希多少」，被换掉就等于任意代码执行。
##   签名之后传输层随便中间人怎么看怎么改：没有私钥就伪造不出能过验的一份。
## · **补丁包只走明文** —— 完整性靠 manifest 里那个 SHA-256（挂载前必校验），
##   换不成旧包：manifest 同时钉死 `build`，只有比本地新的才装。
##
## **为什么不上 HTTPS**：那台机器上的证书老是过期 ——
## 2026-09-09 查的时候四个站已经死了两个，剩一个 10 天后到期。
## 热更不该因为谁忘了续证就静默失效，而签名给的保证比 TLS 更贴题（要的是真伪不是保密）。
##
## 四条纪律，缺一条整套就不成立：
## ① **地址写死在常量里**（`MANIFEST` / `PCK_HOSTS`），不许来自配置文件或命令行，
##    manifest 里给的下载地址也要再过一遍 `PCK_HOSTS`。
## ② **manifest 验不过签名一律当没看见** —— 宁可收不到更新，也不装来路不明的代码。
## ③ **挂载前必校验补丁包的 SHA-256**，对不上就当它被换过。
## ④ 只走写死的那几个前缀，别的一律不请求。

const PatchState := preload("res://scripts/patch_state.gd")
const MAIN_SCENE := "res://scenes/Main.tscn"

## ⚠ 全部写死。明文没关系 —— manifest 靠签名验真伪，补丁包靠 manifest 里的 SHA-256。
const SELF_HOST := "http://124.221.78.13/cellwar/"
const MANIFEST := SELF_HOST + "latest.json"
const MANIFEST_SIG := MANIFEST + ".sig"
## 补丁包允许来自哪儿。manifest 里给的地址必须落在其中之一 ——
## 就算私钥泄漏了，攻击者也只能从这几个前缀发东西，多一道门槛。
const PCK_HOSTS := [SELF_HOST]
## 查更新最多等这么久。**查不到就照原样进游戏** —— 联网是锦上添花，
## 不该让一个断网的人打不开单机（Kevin 的队友常在手机热点下玩）。
const NET_TIMEOUT := 6.0

var _note: Label
var _http: HTTPRequest


func _ready() -> void:
	_build_note()
	_http = HTTPRequest.new()
	add_child(_http)
	## 顺序要紧：**先把新补丁落到盘上，再统一走挂载那一步**。
	## 挂载之后任何 load 都会进缓存，那时再下载已经晚了。
	var fetched := await _fetch_update()
	var msg := _apply_patch()
	var say: String = msg if msg != "" else fetched
	if say != "":
		_note.text = say
		await get_tree().create_timer(2.0).timeout
	## 自己把那层字收掉，别指望 change_scene 顺手释放本节点 ——
	## 只有「本节点就是 current_scene」时它才会。真机是这样（Boot 就是 main_scene），
	## 但 tests/screenshot.gd 是 `root.add_child()` 挂的，那时字会一直浮在主菜单上。
	_note.get_parent().queue_free()
	get_tree().change_scene_to_file(MAIN_SCENE)


# ---- 查更新 / 下载（挂载之前）----

## 「这份 manifest 该不该装」——**纯函数**，无头测试直接核对。
##
## 抽出来是因为这一段最容易判错，而判错的后果分两种：漏装（没人发现）、
## 错装（玩家那边崩，或者更糟：无限重下同一个坏包）。返回
## `{ act: "skip"|"install"|"too_old", url, sha, build }`。
static func decide(m: Dictionary, installed: int, blocked: int, base: int) -> Dictionary:
	var skip := { "act": "skip", "url": "", "sha": "", "build": 0 }
	if m.is_empty():
		return skip                       ## 断网 / 超时 / 没发过补丁
	var build := int(m.get("build", 0))
	if build <= 0 or build <= installed:
		return skip                       ## 已经是最新的
	if build == blocked:
		return skip                       ## 这一版装崩过，别再下（不挡就会无限重下）
	## 基线太老：补丁可能引用了老包里没有的东西。**base 必须在挂载前读**，
	## 否则等于让补丁自己说自己能装（见 PatchState.BASE_BUILD 的注释）。
	##
	## `base <= 0` = **读不出自己的基线**，一律放行。理由是两种失败模式的代价不对称：
	## 拦错了 = 热更整个系统看着在跑、其实一个补丁都收不到（2026-09-09 真踩过：
	## 基线放在 .txt 里没进导出包，线上读出来是 0，每次都判「太老」）；
	## 放行错了 = 装上一个不合适的补丁，而那有 SHA 校验、启动证明期与拉黑名单兜着。
	if base > 0 and int(m.get("min_base", 0)) > base:
		return { "act": "too_old", "url": "", "sha": "", "build": build }
	var url := str(m.get("pck", ""))
	var sha := str(m.get("sha256", ""))
	## manifest 自己不干净就当没看见：地址必须落在写死的前缀底下，指纹必须是 64 位十六进制
	if not pinned(url) or not sha.is_valid_hex_number() or sha.length() != 64:
		return skip
	return { "act": "install", "url": url, "sha": sha, "build": build }


## 这个地址是不是写死的那几个前缀之一。**唯一的放行口** ——
## 除了 manifest 本身，什么都要过这一关，包括 manifest 自己报出来的下载地址。
static func pinned(url: String) -> bool:
	if url == MANIFEST or url.begins_with(MANIFEST + "?"):
		return true
	if url == MANIFEST_SIG or url.begins_with(MANIFEST_SIG + "?"):
		return true
	for h in PCK_HOSTS:
		if url.begins_with(h):
			return true
	return false


## 返回要给玩家看的话；空串 = 没事发生（正常启动不该多一屏「正在检查更新」）。
func _fetch_update() -> String:
	var plan := decide(await _get_manifest(), PatchState.installed_build(),
		PatchState.blocked_build(), PatchState.base_build())
	if plan["act"] == "too_old":
		return "有新版本需要完整更新，请到 GitHub Releases 下载新客户端"
	if plan["act"] != "install":
		return ""
	var url: String = plan["url"]
	var want: String = plan["sha"]
	var build: int = plan["build"]
	_note.text = "正在更新…"
	if not await _download(url, PatchState.INCOMING):
		return ""
	## **校验在改名之前**：没过就不该有机会变成 current.pck
	if PatchState.sha256_of(PatchState.INCOMING) != want:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PatchState.INCOMING))
		return "更新文件校验失败，本次跳过更新"
	if FileAccess.file_exists(PatchState.PCK):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PatchState.PCK))
	DirAccess.rename_absolute(ProjectSettings.globalize_path(PatchState.INCOMING),
		ProjectSettings.globalize_path(PatchState.PCK))
	PatchState.record(build, want)
	return "已更新到 %d" % build


## 取 manifest 并**验签**。验不过、取不到、签名缺一样，一律返回空 = 什么都不做。
##
## 时间戳是为了绕开中间缓存 —— manifest 的地址固定，内容每次发补丁都变。
## **签名要连着一起取**：只有 manifest 没有签名，就是没法证明来路，直接放弃。
func _get_manifest() -> Dictionary:
	var stamp := "?t=%d" % Time.get_unix_time_from_system()
	var body := await _request(MANIFEST + stamp, "")
	if body.is_empty():
		return {}
	var sig := await _request(MANIFEST_SIG + stamp, "")
	if sig.is_empty():
		return {}
	if not PatchState.verify_manifest(body, sig.get_string_from_utf8()):
		return {}                        ## 见文件头纪律 ②
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	return parsed if parsed is Dictionary else {}


func _download(url: String, to: String) -> bool:
	DirAccess.make_dir_recursive_absolute(PatchState.DIR)
	return not (await _request(url, to)).is_empty()


## 一次 HTTP GET。`to` 非空则直接写文件（补丁包不必整个读进内存）。
## 失败一律返回空 —— 调用方据此「什么都不做」，绝不半途而废地改盘上的东西。
##
## ⚠⚠ **绝对不能写成 `await _http.request_completed`。**
## `cancel_request()` **不会**发那个信号，于是网络连不上时 await 永远醒不过来 ——
## 主场景永远不切，玩家看到的是启动器那块深色底：**黑屏**。
## 2026-09-09 队友就这么中招了（国内连 GitHub 本来就时好时坏），
## 而我这边网络通、怎么试都正常，是他报上来才发现的。
##
## 改成**自己轮询**：拿到结果、或者到点，两条路都必然走得出去。
## 这也顺手解决了上一版那个「两次请求共用一口超时钟、第一口把第二次掐掉」的问题 ——
## 每次请求自己数自己的表，没有跨请求的状态。
func _request(url: String, to: String) -> PackedByteArray:
	if not pinned(url):
		return PackedByteArray()          ## 见文件头安全第 ③ 条：只走写死的那几个前缀
	_http.download_file = to
	if _http.request(url) != OK:
		return PackedByteArray()
	var got: Array = []
	_http.request_completed.connect(
		func(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
			got.append([result, code, body]),
		CONNECT_ONE_SHOT)
	var deadline := Time.get_ticks_msec() + int(NET_TIMEOUT * 1000.0)
	while got.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if got.is_empty():
		_http.cancel_request()
		return PackedByteArray()          ## 超时：什么都不做，照原样进游戏
	var res: Array = got[0]
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS or int(res[1]) != 200:
		return PackedByteArray()
	## 写文件模式下 body 是空的，用一个非空标记表示成功
	return res[2] if to == "" else PackedByteArray([1])


# ---- 挂载（这之后任何 load 都会进缓存，补丁再也盖不上）----

func _apply_patch() -> String:
	## 上次带着补丁启动却没活到 mark_good：那个补丁有问题（坏补丁会让 Godot **挂死**，
	## 不是抛异常，所以只能靠这面「上次没放下的旗子」认出来）。挪开跑原版。
	if PatchState.boot_failed():
		PatchState.quarantine()
		return "上次的更新没能正常启动，已回退到原版"
	if not FileAccess.file_exists(PatchState.PCK):
		return ""
	## 补丁是**可执行代码**：挂之前必须核对指纹，对不上就当它被换过
	var want := PatchState.installed_sha()
	var got := PatchState.sha256_of(PatchState.PCK)
	if want == "" or got != want:
		PatchState.quarantine()
		return "更新文件校验失败，已回退到原版"
	if not ProjectSettings.load_resource_pack(PatchState.PCK, true):
		PatchState.quarantine()
		return "更新包无法加载，已回退到原版"
	## 立旗 → 换场景 → 活过 PROVE_SEC 才由**静态**回调放下。
	## 不能绑在本节点上：换场景之后它就被释放了，实例回调不会触发。
	PatchState.mark_pending()
	get_tree().create_timer(PatchState.PROVE_SEC).timeout.connect(PatchState.mark_good)
	return ""


## 一行字，居中。**不用 CWStyle** —— 那是游戏里的类，见文件头第 ② 条。
func _build_note() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var bg := ColorRect.new()
	bg.color = Color("141f2e")
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(bg)
	_note = Label.new()
	_note.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_note.add_theme_font_override("font",
		load("res://assets/fonts/fusion_pixel_10px.ttf") as Font)
	_note.add_theme_font_size_override("font_size", 20)
	_note.add_theme_color_override("font_color", Color("eaf8fc"))
	layer.add_child(_note)
