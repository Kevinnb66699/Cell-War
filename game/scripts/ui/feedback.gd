## feedback.gd —— 局内「反馈 bug」（issue #19）：截图 + 对局快照 + 一句说明，POST 到自家服务器存档
##
## 地址写死（同 boot.gd 的纪律：不许来自配置）：nginx 把 /cellwar/feedback 反代到服务器进程里的
## CWFeedbackHTTP（127.0.0.1:8612）。正文 = CWNet.encode(pack(...))，服务器原样落盘。
## 截图由暂停菜单在**自己隐藏之后**抓（Kevin：截图不含 Esc 菜单），缩到设计分辨率再压 PNG ——
## 真机窗口常是 2.5K，一张原尺寸的 PNG 好几百 KB；像素画按整数倍缩回 1× 一个像素都不丢。
##
## 这里只有纯函数与一个「发出去」的帮手，界面在 CWPauseMenu（反馈页）。
class_name CWFeedback
extends RefCounted

const PatchState := preload("res://scripts/patch_state.gd")
const URL := "http://124.221.78.13/cellwar/feedback"
const TEXT_MAX := 200            ## 说明最多多少字；LineEdit 的 max_length 也是它
const TIMEOUT_SEC := 20.0


## 打包成服务器落盘的那份报文。**纯函数**：说明、快照、截图各是什么由调用方给，这里只负责装箱。
## extra 让调用方带上「联机 / 回放」这类只有界面知道的事。
static func pack(text: String, snapshot: Dictionary, png: PackedByteArray, extra := {}) -> PackedByteArray:
	var msg := {
		"t": "feedback", "v": 1,
		"nick": CWSettings.nick,
		"version": str(ProjectSettings.get_setting("application/config/version", "0.0.0")),
		"base": PatchState.base_build(), "patch": PatchState.installed_build(),
		"time": Time.get_datetime_string_from_system(true, true),
		"text": text.strip_edges().substr(0, TEXT_MAX),
		"round": int(snapshot.get("round_no", 0)), "phase": str(snapshot.get("phase", "")),
		"snapshot": snapshot, "png": png,
	}
	msg.merge(extra, true)
	return CWNet.encode(msg)


## 把视口截图缩到设计分辨率再压成 PNG。宽比设计宽大就按整数倍缩（最近邻，像素画无损）；
## 空图返回空字节 —— 无头环境抓不到画面，反馈照发、只是没图。
static func png_from(img: Image) -> PackedByteArray:
	if img == null or img.is_empty():
		return PackedByteArray()
	var design := CWView.screen_size()
	if img.get_width() > int(design.x):
		var k: float = design.x / float(img.get_width())
		img.resize(int(design.x), maxi(int(round(img.get_height() * k)), 1), Image.INTERPOLATE_NEAREST)
	return img.save_png_to_buffer()


## 发出去：host 下挂一个 HTTPRequest，完事回调 done(ok: bool, detail: String) 并自毁。
## 暂停菜单是 PROCESS_MODE_ALWAYS，挂在它下面的请求在树暂停时照常跑。
static func post(host: Node, body: PackedByteArray, done: Callable) -> void:
	var http := HTTPRequest.new()
	http.timeout = TIMEOUT_SEC
	host.add_child(http)
	http.request_completed.connect(func(result: int, code: int, _h: PackedStringArray, _b: PackedByteArray) -> void:
		http.queue_free()
		if result != HTTPRequest.RESULT_SUCCESS:
			done.call(false, "网络 %d" % result)
		elif code != 200:
			done.call(false, "HTTP %d" % code)
		else:
			done.call(true, ""))
	var err := http.request_raw(URL, ["Content-Type: application/octet-stream"], HTTPClient.METHOD_POST, body)
	if err != OK:
		http.queue_free()
		done.call(false, "发不出去 %d" % err)
