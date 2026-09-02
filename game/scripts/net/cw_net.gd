## cw_net.gd —— 联机协议：版本号、常量、报文编解码、视角快照（服务器与客户端共用）
##
## 拍板与全貌见 docs/联机设计_2026-09-02.md。要点：
##   · 服务器权威：规则、骰子、抽卡全在服务器的 CWGame 里跑；客户端只发「选第几项」。
##   · 报文 = 4 字节原长 + zstd(var_to_bytes(字典))。用 Godot 序列化而不是 JSON，
##     因为棋盘键是 Vector2i、演出坐标也是；解码禁对象（bytes_to_var 默认），报文里塞不进脚本。
##     压缩是因为整份快照 35~41 KB、压完约 2 KB（2026-09-02 实测，结构高度重复）。
##   · 视角快照 = snapshot() 去掉 rng、别人的手牌换成占位、别人的待决选项去掉 ——
##     客户端拿不到随机数状态与他人手牌，改客户端也算不出下一张牌。
##
## 报文一览（t = 类型；C→S 客户端发，S→C 服务器发）：
##   C→S  hello{ver, nick, room?, token?}   握手；带 room+token 即顺手重连
##        ping · list_rooms · create_room{players, timer, public, seed?} · join_room{code}
##        leave_room · reconnect{code, token} · sit{seat} · stand · ready{ready}
##        set_ai{seat, tier} · kick{seat} · start（后三个房主专用）· answer{ask_id, index}
##   S→C  welcome{client_id, ver, maintenance} · pong · lobby{rooms, maintenance}
##        room{...}（等待室全量视图，见 CWRoom.view_for）
##        state{view, logs, turn, hash, game}（视角快照 + 新增日志行 + 正在决策的席位）
##        ask{ask_id, req, left_ms}（只发给该席位）· roll · result · notice（三种演出）
##        game_over{winner, reason, kind, round} · left（离开房间的回执）· error{code, msg}
class_name CWNet
extends RefCounted

## 协议或规则一变就升号：服务器拒绝版本不符的客户端（error code=version）。
const NET_VERSION := 1
const DEFAULT_HOST := "124.221.78.13"
const DEFAULT_PORT := 8611
## 单条报文（压缩后）上限；超过即断开
const MAX_PACKET := 65536
## 解压后的上限（防解压炸弹）
const MAX_RAW := 4 * 1024 * 1024
## 房间码：6 位，字母表去掉 0/O/1/I
const CODE_ALPHABET := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
const CODE_LEN := 6
const PLAYER_CHOICES := [2, 4, 6]
## 每次决策的秒数（界面给的档位）；协议本身接受 0~TIMER_MAX 的任意整数，0 = 不限
const TIMER_CHOICES := [0, 30, 60, 90]
const TIMER_MAX := 600
const AI_TIERS := { "heur": "AI·新手", "mc": "AI·专家" }
const NICK_MAX := 12
const HEARTBEAT_MS := 5000            ## 客户端多久发一次 ping
const DEAD_MS := 20000                ## 服务器多久没收到任何报文就当掉线
const ROOM_IDLE_MS := 10 * 60 * 1000  ## 空房多久自动关
const RATE_PER_SEC := 30              ## 每连接每秒「非作答」报文上限（作答与 ping 不计）
const MAX_PER_IP := 8
const HIDDEN_CARD := "？"             ## 别人手牌的占位

## 错误码 → 给玩家看的话
const ERRORS := {
	"version": "客户端版本与服务器不符，请更新游戏",
	"bad_message": "报文格式错误",
	"maintenance": "服务器维护中，暂不能开新局",
	"no_room": "没有这个房间",
	"playing": "这个房间正在对局中",
	"not_in_room": "你不在房间里",
	"not_host": "只有房主能这么做",
	"not_waiting": "对局进行中不能这么做",
	"seat_taken": "这个席位已经有人了",
	"bad_seat": "没有这个席位",
	"seat_empty": "还有席位空着",
	"no_human": "至少要有一位真人",
	"not_ready": "还有人没准备",
	"not_seated": "你没有坐下",
	"stale": "这次询问已经过期",
	"bad_index": "选项不存在",
	"bad_token": "重连令牌无效",
	"bad_param": "参数不合法",
	"kicked": "你被房主请出了房间",
	"room_closed": "房间已关闭",
	"rate": "发送过于频繁",
}


static func encode(msg: Dictionary) -> PackedByteArray:
	var raw := var_to_bytes(msg)
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u32(0, raw.size())
	out.append_array(raw.compress(FileAccess.COMPRESSION_ZSTD))
	return out


## 解不出来返回空字典（调用方按坏报文处理）
static func decode(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 5:
		return {}
	var n := bytes.decode_u32(0)
	if n == 0 or n > MAX_RAW:
		return {}
	var raw := bytes.slice(4).decompress(n, FileAccess.COMPRESSION_ZSTD)
	if raw.size() != n:
		return {}
	var v: Variant = bytes_to_var(raw)
	if v is Dictionary and v.has("t") and v["t"] is String:
		return v
	return {}


static func make_code(rng: RandomNumberGenerator) -> String:
	var s := ""
	for i in CODE_LEN:
		s += CODE_ALPHABET[rng.randi_range(0, CODE_ALPHABET.length() - 1)]
	return s


static func make_token(rng: RandomNumberGenerator) -> String:
	return "%08x%08x%08x" % [rng.randi(), rng.randi(), rng.randi()]


static func clean_nick(n: Variant) -> String:
	var s := str(n).strip_edges().replace("\n", " ").replace("\r", " ")
	if s.length() > NICK_MAX:
		s = s.substr(0, NICK_MAX)
	return s if s != "" else "玩家"


static func error_text(code: String) -> String:
	return ERRORS.get(code, code)


## 某个席位看到的对局：rng 去掉、他人手牌占位、他人的待决选项去掉。pid=-1 = 没坐下的人。
static func view_for(game: CWGame, pid: int) -> Dictionary:
	var v := game.snapshot()
	v["rng"] = 0
	for c in v["cells"]:
		if c["pid"] != pid:
			var hidden: Array = []
			for i in c["hand"].size():
				hidden.append(HIDDEN_CARD)
			c["hand"] = hidden
	var p: Dictionary = v["pending"]
	if not p.is_empty() and p.get("pid", -1) != pid:
		v["pending"] = { "kind": p["kind"], "pid": p["pid"], "prompt": p.get("prompt", ""), "options": [] }
	return v


## 从第 from 行起的对局日志，秘密行（别人抽到什么牌）换成公开替身
static func logs_for(game: CWGame, pid: int, from: int) -> PackedStringArray:
	var out: PackedStringArray = []
	for i in range(from, game.logs.size()):
		var who: int = game.log_secret[i] if i < game.log_secret.size() else -1
		if who < 0 or who == pid:
			out.append(game.logs[i])
		else:
			out.append(game.log_public[i])
	return out
