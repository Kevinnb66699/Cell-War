#!/usr/bin/env bash
# agent_turn.sh —— 把 play.gd 的文件协议包成「一次调用 = 一个决策」
#
# **为什么要有它。** `tests/play.gd` 让场外的人通过 ask.txt / reply.txt 坐一个席位。
# 一个人坐一席时直接 cat / echo 就够了；但 2026-09-05 起我们让**几个互不通气的智能体
# 各坐一席**对弈（比启发式更像真人，用来验平衡），这时每个决策都要「先写上一问的答案 →
# 再等到下一个问到我的问题」。让每个智能体自己写轮询循环，等于同一段逻辑抄四份，
# 而且轮询写错只会表现成「某一席莫名其妙不动了」，很难查。包成一个脚本就只有一份。
#
# 用法：
#   agent_turn.sh <通信目录> <席位号> [上一问的选项下标] [给队友的话]
#
#   第一次调用不带下标（还没有问题要答）；之后每次都带上——
#   脚本会先把它写成 `问号:下标` 交上去（问号防串台，见 play.gd 头注），
#   再阻塞等到**下一个问到本席位的问题**，把整段问题打到标准输出。
#
#   第四个参数是**队内喊话**（真人坐一桌是会商量的，尤其「我占住这格给你蹲个固化」
#   这种配合——不给队友说话的口子，四个人就是四个各打各的独狼，比真人更差）。
#   喊话写进 `$AGENT_TEAM_DIR/chat.txt`，只有同队看得到；
#   队友的新发言会跟在每一问后面一起打印出来。
#
# 退出码：0 = 打印了新的一问｜3 = 对局已结束（打印终局）｜
#         5 = **还没轮到你**（别的席位还在行动），直接不带下标再调一次｜1 = 用法/状态错
#
# 为什么要有 5：调用方的工具调用本身有超时上限，而「等到轮到我」可能要好几分钟
# （另外三席各自要走完一整个回合）。一直阻塞下去会被外面掐断，调用方还会以为对局卡死了。
# 所以等一小会儿就先回来说一声「还没轮到」，让它再问一次 —— 一局里这会发生几十次，是正常的。
# 答案在**进入等待之前**就已经交上去了，所以重调**不要**再带下标。
#
# 状态：`<通信目录>/.seat<席位号>.seq`（上一次看到的问号）、`.seat<席位号>.chat`
#       （队内频道读到第几行）。所以每次调用都是无状态的，智能体不用自己记。
set -u

DIR=${1:-}
SEAT=${2:-}
PICK=${3:-}
SAY=${4:-}
TEAM_DIR=${AGENT_TEAM_DIR:-}
[ -n "$DIR" ] && [ -n "$SEAT" ] || { echo "用法: agent_turn.sh <通信目录> <席位号> [下标] [给队友的话]" >&2; exit 1; }
[ -d "$DIR" ] || { echo "通信目录不存在：$DIR" >&2; exit 1; }

ASK="$DIR/ask.txt"
REPLY="$DIR/reply.txt"
SEQF="$DIR/.seat$SEAT.seq"
CHATN="$DIR/.seat$SEAT.chat"
# 默认 100 秒：要短于调用方工具调用的默认超时，否则会被外面掐断而不是自己回来
TIMEOUT=${AGENT_TURN_TIMEOUT:-100}
POLL=0.25

last=$(cat "$SEQF" 2>/dev/null || echo "")

# ---- 队内喊话 ----
if [ -n "$SAY" ] && [ -n "$TEAM_DIR" ]; then
	printf 'P%s: %s\n' "$SEAT" "$SAY" >> "$TEAM_DIR/chat.txt"
fi

# 机器循环检测。**这不是洁癖，是数据完整性**：2026-09-04 有一席写了个 100 次的
# shell 循环、每问盲答固定下标，连答 74 问（正常一个回合十来问），整局对照数据作废。
# 会思考的调用方每个决策至少要几秒，所以「60 秒内交了 20 个以上答案」几乎必然是机器在刷。
# 只警告不拦截：真有人手速快不该被误伤，而警告会连同问题一起打给调用方，它自己能看见。
rate_check() {
	local f="$DIR/.seat$SEAT.rate" now cnt
	now=$(date +%s)
	echo "$now" >> "$f"
	cnt=$(awk -v t="$((now - 60))" '$1 > t' "$f" | wc -l)
	if [ "$cnt" -gt 20 ]; then
		echo "$(date +%H:%M:%S) 席位 $SEAT 60 秒内交了 $cnt 个答案" >> "$DIR/WARN.txt"
		printf '
!!! 你在 60 秒内交了 %s 个答案 —— 这是机器循环的速度，不是思考的速度。
' "$cnt"
		printf '!!! 如果你在用脚本循环作答，**立刻停下**：这样打出来的局是废数据，整轮评测都要作废。
'
		printf '!!! 一次工具调用 = 一个决策，每步都要看局面。

'
	fi
}

# ---- 先交上一问的答案 ----
if [ -n "$PICK" ]; then
	[ -n "$last" ] || { echo "本席位还没有被问过，不能作答" >&2; exit 1; }
	case "$PICK" in (*[!0-9]*) echo "下标必须是非负整数：$PICK" >&2; exit 1;; esac
	# 先写临时文件再改名：引擎是轮询读的，直接覆写会有一瞬间读到半截
	printf '%s:%s\n' "$last" "$PICK" > "$REPLY.tmp.$SEAT"
	mv -f "$REPLY.tmp.$SEAT" "$REPLY"
	rate_check
fi

# 队友说了什么（只打没看过的那几行）
team_news() {
	[ -n "$TEAM_DIR" ] && [ -f "$TEAM_DIR/chat.txt" ] || return 0
	local seen total
	seen=$(cat "$CHATN" 2>/dev/null || echo 0)
	total=$(wc -l < "$TEAM_DIR/chat.txt")
	[ "$total" -gt "$seen" ] || return 0
	echo "—— 队内频道 ——"
	tail -n +$((seen + 1)) "$TEAM_DIR/chat.txt"
	printf '%s' "$total" > "$CHATN"
}

# ---- 等到下一个问到我的问题 ----
waited=0
while :; do
	head=$(head -n 1 "$ASK" 2>/dev/null || echo "")
	case "$head" in
		'#END'*)
			cat "$ASK"; team_news
			exit 3
			;;
		'#'*)
			seq=${head#\#}
			seq=${seq%% *}
			pid=${head##*P}
			# 没带下标 = 「把当前问到我的那一问再给我看一次」：
			# 首次调用是这样，某一席的智能体中途换人接手也是这样
			# （引擎正卡在等它作答，此时要的是重看，不是等下一问，否则双方对着死等）
			if [ "$pid" = "$SEAT" ] && { [ -z "$PICK" ] || [ "$seq" != "$last" ]; }; then
				printf '%s' "$seq" > "$SEQF"
				cat "$ASK"; team_news
				exit 0
			fi
			;;
	esac
	sleep "$POLL"
	waited=$(awk -v w="$waited" -v p="$POLL" 'BEGIN{print w+p}')
	case $(awk -v w="$waited" -v t="$TIMEOUT" 'BEGIN{print (w>t)}') in
		1) echo "还没轮到席位 $SEAT（其余席位还在行动）。不带下标再调一次即可 —— 这很正常。"; exit 5;;
	esac
done
