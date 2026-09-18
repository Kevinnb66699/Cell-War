#!/usr/bin/env bash
# L0「契约靶场」两侧同跑（测试迁移规格 A-8 闸一 / C-1 步 14）：
#   同一份 game/tests/l0/*.json，GD runner（tests/l0_runner.gd）与 C# runner（L0RunnerTests）都要绿，
#   外加闸二 2b 装载自证（PreParityTests：两侧装出来的世界逐字段相同）。
#   任一侧红、或 GD 侧有运行时报错，整体就红。tools/run_tests.sh 末尾会调这里；也可以单独跑。
#
# 提醒：pre_envelopes.jsonl.gz 是 GD 侧装载结果的夹具 —— 用例一动就要重录：
#   godot --headless --path game --script res://tests/l0_pre_dump.gd -- out=<临时>.jsonl && gzip -9 -c <临时>.jsonl > game/tests/l0/pre_envelopes.jsonl.gz
set -u
GODOT="${GODOT:-D:/Godot/Godot_v4.5-stable_win64.exe/Godot_v4.5-stable_win64_console.exe}"
TIMEOUT="${TIMEOUT:-300}"
cd "$(dirname "$0")/.."
RUNNER=""
if [ "$TIMEOUT" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
	RUNNER="timeout -k 10 $TIMEOUT"
fi
CODE=0

for f in game/tests/l0/*.json; do
	if [ "$f" -nt game/tests/l0/pre_envelopes.jsonl.gz ]; then
		echo "⚠ L0：$f 比 pre_envelopes.jsonl.gz 新 —— 用例改过就得重录 GD 侧装载夹具（见本脚本头部）"
	fi
done

GD_OUT="$($RUNNER "$GODOT" --headless --path game --script res://tests/l0_runner.gd 2>&1)"
GD_CODE=$?
echo "$GD_OUT" | grep -E "FAIL|L0-RESULT|L0（GD 侧）"
if echo "$GD_OUT" | grep -qE "SCRIPT ERROR|Parse Error|Failed to load script"; then
	echo "✘ L0（GD 侧）有运行时报错："
	echo "$GD_OUT" | grep -E "SCRIPT ERROR|Parse Error|Failed to load script" -A 3
	CODE=1
fi
if [ "$GD_CODE" -ne 0 ]; then
	CODE=1
fi

CS_OUT="$(dotnet test core/CellWar.Core.Tests --nologo -v q --filter "FullyQualifiedName~L0RunnerTests|FullyQualifiedName~PreParityTests" 2>&1)"
CS_CODE=$?
echo "$CS_OUT" | grep -E "\[FAIL\]|Passed!|Failed!| error " | sed 's/^/L0（C# 侧）：/'
if [ "$CS_CODE" -ne 0 ]; then
	CODE=1
fi

if [ "$CODE" -eq 0 ]; then
	echo "✔ L0 两侧同跑全绿"
else
	echo "✘ L0 有红（GD 退出码 $GD_CODE / C# 退出码 $CS_CODE）"
fi
exit $CODE
