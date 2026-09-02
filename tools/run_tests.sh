#!/usr/bin/env bash
# 跑无头测试，并把 Godot 的运行时报错也当作失败。
#
# 为什么需要这个壳：headless_test.gd 只统计**断言**，断言全过就打印「全部测试通过」
# 并以 0 退出。但 GDScript 的运行时错误（空引用、数组越界、调用不存在的函数）
# 只会打印一行 SCRIPT ERROR，**不影响退出码**——2026-08-31 就真踩到两次：
# 一次是重构中途忘了删的 _after_damage 调用，一次是测试自己写错的 pid 越界，
# 两次都显示「全部测试通过」。只看最后那行是不够的。
set -u
GODOT="${GODOT:-D:/Godot/Godot_v4.5-stable_win64.exe/Godot_v4.5-stable_win64_console.exe}"
cd "$(dirname "$0")/.."
OUT="$("$GODOT" --headless --path game --script res://tests/headless_test.gd 2>&1)"
CODE=$?
echo "$OUT" | grep -E "FAIL|✔|✘"
ERRS="$(echo "$OUT" | grep -Ec "SCRIPT ERROR|Parse Error|Failed to load script")"
if [ "$ERRS" -gt 0 ]; then
	echo ""
	echo "✘ 另有 $ERRS 处运行时报错或测试脚本未加载（断言没红，也不能算通过）："
	echo "$OUT" | grep -E "SCRIPT ERROR|Parse Error|Failed to load script" -A 3
	exit 1
fi
exit $CODE
