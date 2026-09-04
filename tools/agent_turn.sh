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
# 退出码：0 = 打印了新的一问｜3 = 对局已结束（打印终局）｜4 = 等超时｜1 = 用法/状态错
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
TIMEOUT=${AGENT_TURN_TIMEOUT:-1500}   # 秒；对手是人类速度的智能体，给足
POLL=0.25

last=$(cat "$SEQF" 2>/dev/null || echo "")

# ---- 队内喊话 ----
if [ -n "$SAY" ] && [ -n "$TEAM_DIR" ]; then
	printf 'P%s: %s\n' "$SEAT" "$SAY" >> "$TEAM_DIR/chat.txt"
fi

# ---- 先交上一问的答案 ----
if [ -n "$PICK" ]; then
	[ -n "$last" ] || { echo "本席位还没有被问过，不能作答" >&2; exit 1; }
	case "$PICK" in (*[!0-9]*) echo "下标必须是非负整数：$PICK" >&2; exit 1;; esac
	# 先写临时文件再改名：引擎是轮询读的，直接覆写会有一瞬间读到半截
	printf '%s:%s\n' "$last" "$PICK" > "$REPLY.tmp.$SEAT"
	mv -f "$REPLY.tmp.$SEAT" "$REPLY"
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
		1) echo "等了 ${TIMEOUT}s 没等到问到席位 $SEAT 的问题（对局可能已经卡住或结束）" >&2; exit 4;;
	esac
done
