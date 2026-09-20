#!/usr/bin/env bash
# 跑无头测试，并把 Godot 的运行时报错也当作失败。
#
# 为什么需要这个壳：headless_test.gd 只统计**断言**，断言全过就打印「全部测试通过」
# 并以 0 退出。但 GDScript 的运行时错误（空引用、数组越界、调用不存在的函数）
# 只会打印一行 SCRIPT ERROR，**不影响退出码**——2026-08-31 就真踩到两次：
# 一次是重构中途忘了删的 _after_damage 调用，一次是测试自己写错的 pid 越界，
# 两次都显示「全部测试通过」。只看最后那行是不够的。
#
# 分片并行（Kevin 2026-09-05 提的）：套件 1900 项、单进程要 2.5 分钟，而 Godot 无头是单线程。
# 默认开 SHARDS=2 个进程各跑一半（headless_test.gd 的 `-- --shard=i/n`，每片各自的 user://），
# 各片输出先落到临时文件，跑完按片打印摘要；任一片红、或任一片有运行时报错，整体就算失败。
# SHARDS=1 退回串行。
set -u
GODOT="${GODOT:-D:/Godot/Godot_v4.5-stable_win64.exe/Godot_v4.5-stable_win64_console.exe}"
SHARDS="${SHARDS:-2}"
# 每片的墙钟上限（秒）。0 = 不设。
# 为什么要有：headless_test.gd 自己那只看门狗按「当前测试跑了多久」判，
# 但**单帧里的死循环**根本轮不到 _process —— 2026-09-07 的 _next_event_round 无上界 while
# 就把套件挂死过一次。只有外面这一刀杀得掉。
TIMEOUT="${TIMEOUT:-900}"
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
RUNNER=""
if [ "$TIMEOUT" -gt 0 ]; then
	if command -v timeout >/dev/null 2>&1; then
		RUNNER="timeout -k 10 $TIMEOUT"
	else
		echo "⚠ 找不到 timeout，跳过墙钟上限（单帧死循环将无人兜底）"
	fi
fi
trap 'rm -rf "$TMP"' EXIT

i=0
while [ "$i" -lt "$SHARDS" ]; do
	(
		$RUNNER "$GODOT" --headless --path game --script res://tests/headless_test.gd -- "--shard=$i/$SHARDS" \
			> "$TMP/shard$i.log" 2>&1
		echo $? > "$TMP/shard$i.code"
	) &
	i=$((i + 1))
done
wait

CODE=0
ALL=""
i=0
while [ "$i" -lt "$SHARDS" ]; do
	OUT="$(cat "$TMP/shard$i.log")"
	ALL="$ALL
$OUT"
	echo "$OUT" | grep -E "FAIL|✔|✘"
	SC="$(cat "$TMP/shard$i.code")"
	if [ "$SC" -eq 124 ] || [ "$SC" -eq 137 ]; then
		echo "✘ 分片 $((i + 1))/$SHARDS 超过 ${TIMEOUT}s 被杀（挂死；日志末尾就是卡住的地方）"
		tail -n 5 "$TMP/shard$i.log"
	fi
	if [ "$SC" -ne 0 ]; then
		CODE=1
	fi
	i=$((i + 1))
done

ERRS="$(echo "$ALL" | grep -Ec "SCRIPT ERROR|Parse Error|Failed to load script")"
if [ "$ERRS" -gt 0 ]; then
	echo ""
	echo "✘ 另有 $ERRS 处运行时报错或测试脚本未加载（断言没红，也不能算通过）："
	echo "$ALL" | grep -E "SCRIPT ERROR|Parse Error|Failed to load script" -A 3
	exit 1
fi
if [ "$SHARDS" -gt 1 ]; then
	# 通过的片写「（N 项检查」，红的片写「（共 N 项」，两种都算进合计
	TOTAL="$(echo "$ALL" | grep -oE "（(共 )?[0-9]+ 项" | grep -oE "[0-9]+" | awk '{ s += $1 } END { print s + 0 }')"
	if [ "$CODE" -eq 0 ]; then
		echo "✔ ${SHARDS} 片合计 ${TOTAL} 项检查全部通过"
	else
		echo "✘ ${SHARDS} 片里有红（合计 ${TOTAL} 项检查）"
	fi
fi
exit $CODE
