#!/usr/bin/env bash
# agent_smoke.sh —— 四席分别作答的**管道自检**（不是平衡测试，是查线路）
#
# 四个「永远选 0」的假智能体各坐一席打一局，只验三件事：
#   ① 没有两席认领同一问（串台会让整局静默错位，事后极难查）
#   ② 问号连续无缺口（有缺口 = 有一问被别人吃掉了）
#   ③ hide=1 下别席的手牌只剩张数（不然四方明牌，打出来的平衡数没有意义）
# 真智能体对弈之前先跑它；改过 play.gd 的文件协议之后也先跑它。
#
# 用法：agent_smoke.sh <工作目录> [godot 可执行文件]
set -u
D=${1:-}
GODOT=${2:-"D:/Godot/Godot_v4.5-stable_win64.exe/Godot_v4.5-stable_win64_console.exe"}
[ -n "$D" ] || { echo "用法: agent_smoke.sh <工作目录> [godot]" >&2; exit 1; }
REPO=$(cd "$(dirname "$0")/.." && pwd)

rm -rf "$D"; mkdir -p "$D/comm" "$D/log"
"$GODOT" --headless --path "$REPO/game" --script res://tests/play.gd -- \
	dir="$D/comm" logdir="$D/log" me=0,1,2,3 order=ICIC seed=90501 hide=1 \
	> "$D/engine.txt" 2>&1 &
ENGINE=$!

fake() {
	local seat=$1 pick="" n=0 out rc
	while :; do
		out=$(bash "$REPO/tools/agent_turn.sh" "$D/comm" "$seat" $pick 2>/dev/null); rc=$?
		[ $rc -eq 0 ] || return
		n=$((n + 1)); pick=0
		echo "$out" > "$D/last$seat.txt"
		echo "$(head -n1 <<<"$out")" >> "$D/trace$seat.txt"
		[ $n -gt 300 ] && return
	done
}
pids=""
for s in 0 1 2 3; do fake $s & pids="$pids $!"; done
wait $pids 2>/dev/null          # 假智能体自己会在打满上限或对局结束时收工
kill $ENGINE 2>/dev/null        # 引擎多半正卡在等某一席作答，直接收
pkill -f agent_turn.sh 2>/dev/null

fail=0
dup=$(cat "$D"/trace?.txt | awk '{print $1}' | sort -n | uniq -d)
[ -z "$dup" ] || { echo "✗ 两席认领了同一问：$dup"; fail=1; }
gap=$(cat "$D"/trace?.txt | awk '{print substr($1,2)}' | sort -n \
	| awk 'NR>1 && $1!=p+1{print p"->"$1} {p=$1}')
[ -z "$gap" ] || { echo "✗ 问号有缺口：$gap"; fail=1; }
grep -q '手牌 [0-9]* 张' "$D/last3.txt" || { echo "✗ hide=1 没生效：别席手牌不是只给张数"; fail=1; }
grep -q '➤' "$D/last3.txt" || { echo "✗ 本席位没有 ➤ 标记"; fail=1; }

echo "问数：$(cat "$D"/trace?.txt | wc -l)（$(for s in 0 1 2 3; do
	printf 'P%s=%s ' $s "$(wc -l < "$D/trace$s.txt")"; done))"
[ $fail -eq 0 ] && echo "✓ 管道自检通过" || echo "✗ 管道自检失败"
exit $fail
