#!/usr/bin/env bash
# build_patch.sh —— 从 git 差异打出一个热更补丁包
#
# 用法（仓库根目录）：
#   tools/build_patch.sh <上一次发版的 tag> [输出.pck]
#   例：tools/build_patch.sh client-2026-09-09-3 dist/patch.pck
#
# 干的事：算出「那次发版之后 game/ 里改了哪些能进包的文件」→ 交给
# game/tests/build_patch.gd 用 PCKPacker 按 res:// 路径打包 → 打印 SHA-256。
#
# 为什么客户端包能这么省：94 MB 里约 88 MB 是 Godot 运行时，几乎从不变；
# 每天真正改的只有几十 KB 脚本。补丁包按 res:// 路径覆盖原包里的文件即可。
#
# ⚠ **这些改动打不进补丁，必须走 tools/publish_release.sh 全量发版**：
#   · 新增 class_name（全局类表导出时烘死；build_patch.gd 会拦住）
#   · project.godot 的设置、Godot 版本、导出模板
#   · 删除文件（补丁只能覆盖，表达不了「删掉」）
#
# ⚠ 碰了规则就**必须同时升 NET_VERSION 并重新部署服务器** —— 打了补丁和没打的人
#   规则不一样的话，联机状态哈希会对不上。这条纪律和全量发版时一模一样。
set -eu

cd "$(dirname "$0")/.."
BASE="${1:?用法：tools/build_patch.sh <上一次发版的 tag> [输出.pck]}"
OUT="${2:-dist/patch.pck}"
GODOT="${GODOT:-/d/Godot/Godot_v4.5-stable_win64.exe/Godot_v4.5-stable_win64_console.exe}"

die() { echo "✘ $1" >&2; exit 1; }

git rev-parse -q --verify "$BASE^{commit}" >/dev/null || die "找不到 $BASE（发版 tag 见 git tag -l 'client-*'）"
[ -x "$GODOT" ] || die "找不到 Godot：$GODOT（用 GODOT=... 指定）"

# 只要 game/ 下**还存在**的文件；tests/ 不进客户端包，删掉的文件补丁也表达不了
mapfile -t CHANGED < <(git diff --name-only --diff-filter=d "$BASE"..HEAD -- game/ \
	| grep -v '^game/tests/' | grep -v '\.import$' || true)

[ "${#CHANGED[@]}" -gt 0 ] || die "$BASE..HEAD 之间 game/ 没有可打包的改动"

ARGS=()
echo "相对 $BASE 改动的文件："
for f in "${CHANGED[@]}"; do
	echo "  $f"
	ARGS+=("res://${f#game/}" "$f")
done

mkdir -p "$(dirname "$OUT")"
"$GODOT" --headless --path game --script res://tests/build_patch.gd -- "$OUT" "${ARGS[@]}"
