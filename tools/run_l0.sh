#!/usr/bin/env bash
# L0「契约靶场」两侧同跑（测试迁移规格 A-8 闸一 / C-1 步 14、步 15）：
#   同一份 game/tests/l0/*.json，GD runner（tests/l0_runner.gd）与 C# runner（L0RunnerTests）都要绿，
#   外加闸二 2b 装载自证（PreParityTests：两侧装出来的世界逐字段相同）、
#   闸二 2a/2d 往返自证（GD `l0_runner.gd --selfcheck` + C# RoundTripTests）、
#   契约表三条启动断言（ContractGateTests）。闸三计数 2026-09-20 退役。
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
elif [ "$TIMEOUT" -gt 0 ] && command -v gtimeout >/dev/null 2>&1; then   # macOS：brew install coreutils 装的是 gtimeout
	RUNNER="gtimeout -k 10 $TIMEOUT"
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

# 闸二 2a/2d 的 GD 半边（规格 §0.6.5 第 1 条）：dump(load(spec)) ≡ minify(spec) 逐条，外加世界往返。
# 参数形式按 l0_runner.gd 的约定 —— 从 OS.get_cmdline_user_args() 里认 --selfcheck。
SC_OUT="$($RUNNER "$GODOT" --headless --path game --script res://tests/l0_runner.gd -- --selfcheck 2>&1)"
SC_CODE=$?
echo "$SC_OUT" | grep -E "L0-RESULT|L0（GD 侧" | sed "s/^/L0 自检（GD 侧）：/"
if [ "$SC_CODE" -ne 0 ] || echo "$SC_OUT" | grep -qE "SCRIPT ERROR|Parse Error|Failed to load script"; then
	echo "✘ L0 自检（GD 侧 --selfcheck，闸二 2a/2d）没过："
	echo "$SC_OUT" | tail -40
	CODE=1
fi

# C# 侧（L0RunnerTests / PreParityTests / RoundTripTests …）：**Kevin 2026-09-19「后续不再需要维护 C# 核心，C# 的测试也不用跑了」**
# —— 默认跳过；要临时看一眼老的对拍就 CW_L0_CS=1 跑（core/ 不再随规则改动更新，红了不算数）。
CS_CODE=0
if [ "${CW_L0_CS:-0}" = "1" ]; then
	CS_OUT="$(dotnet test core/CellWar.Core.Tests --nologo -v q --filter "FullyQualifiedName~L0RunnerTests|FullyQualifiedName~PreParityTests|FullyQualifiedName~RoundTripTests|FullyQualifiedName~ContractGateTests|FullyQualifiedName~KeyTableTests|FullyQualifiedName~SetupOpsTests|FullyQualifiedName~SubsetTextTests" 2>&1)"
	CS_CODE=$?
	echo "$CS_OUT" | grep -E "\[FAIL\]|Passed!|Failed!| error " | sed 's/^/L0（C# 侧）：/'
	if [ "$CS_CODE" -ne 0 ]; then
		CODE=1
	fi
else
	echo "L0（C# 侧）：跳过（Kevin 2026-09-19：不再维护 C# 核心；CW_L0_CS=1 可临时跑）"
fi

# 闸三（covers ∩ 真实 check 名、covered_sites 单调不减、xcheck/COUNT）2026-09-20 退役（Kevin：测试整理口径 A）：
# 它是 C# 对拍时期「分子不许造」的记账，C# 已冻结；L0 用例照跑，用例里的 covers 字段只当出处注记、不再校验。

if [ "$CODE" -eq 0 ]; then
	echo "✔ L0（GD 侧）全绿"
else
	echo "✘ L0 有红（GD 退出码 $GD_CODE / GD 自检 $SC_CODE / C# 退出码 ${CS_CODE}）"
fi
exit $CODE
