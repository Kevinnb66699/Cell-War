#!/usr/bin/env bash
# build_patch.sh —— 从 git 差异打出一个热更补丁包
#
# 用法（仓库根目录）：
#   tools/build_patch.sh <上一次发版的 tag>
#   例：tools/build_patch.sh client-2026-09-09-3
#
# 干的事：算出「那次发版之后 game/ 里改了哪些能进包的文件」→ 交给
# game/tests/build_patch.gd 用 PCKPacker 按 res:// 路径打包 →
# 连 manifest 一起放到 dist/patch/，并打印怎么上传。
#
# 发出去（tag 固定用 patch-latest，--clobber 覆盖同名资产）：
#   gh release create patch-latest -t "热更补丁" -n "" 2>/dev/null || true
#   gh release upload patch-latest dist/patch/<补丁包名> dist/patch/latest.json --clobber
#
# **补丁包名带版本号**，manifest 的地址却固定 —— 这样客户端拿 manifest 时加时间戳
# 绕开 CDN 缓存即可，补丁包本身不会被缓存串味。
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
BASE="${1:?用法：tools/build_patch.sh <上一次发版的 tag>}"
BUILD="$(date +%Y%m%d%H%M)"          # 版本号：客户端只比大小，只要单调递增就行
OUTDIR="dist/patch"
OUT="$OUTDIR/patch-$BUILD.pck"
GODOT="${GODOT:-/d/Godot/Godot_v4.5-stable_win64.exe/Godot_v4.5-stable_win64_console.exe}"

die() { echo "✘ $1" >&2; exit 1; }

git rev-parse -q --verify "$BASE^{commit}" >/dev/null || die "找不到 $BASE（发版 tag 见 git tag -l 'client-*'）"
[ -x "$GODOT" ] || die "找不到 Godot：$GODOT（用 GODOT=... 指定）"

# 只要 game/ 下**还存在**的文件；tests/ 不进客户端包，删掉的文件补丁也表达不了。
# .import / .uid 是编辑器的簿记，进不进包都一样，别让补丁白白变大。
mapfile -t CHANGED < <(git diff --name-only --diff-filter=d "$BASE"..HEAD -- game/ \
	| grep -v '^game/tests/' | grep -vE '\.(import|uid)$' || true)

[ "${#CHANGED[@]}" -gt 0 ] || die "$BASE..HEAD 之间 game/ 没有可打包的改动"

# 磁盘路径必须给**绝对**的：打包器跑在 `--path game` 底下，Godot 会把相对路径
# 当成 res:// 里的，于是每个文件都被报成「不存在」（2026-09-09 第一次跑就这么翻车）。
ARGS=()
echo "相对 $BASE 改动的文件："
for f in "${CHANGED[@]}"; do
	echo "  $f"
	ARGS+=("res://${f#game/}" "$PWD/$f")
done

mkdir -p "$OUTDIR"
# 输出路径同样得给绝对的 —— 理由和上面那段一样（打包器跑在 `--path game` 底下，
# 相对路径会被当成 res:// 里的）。2026-09-09 第一次真打补丁时就是漏了这一处。
"$GODOT" --headless --path game --script res://tests/build_patch.gd -- "$PWD/$OUT" "${ARGS[@]}"

# min_base 取当前的基线号：补丁是照着 HEAD 打的，就只保证能装在这一档基线上。
# 比它老的客户端会被 boot.gd 拦下来，提示去下完整包，而不是硬套一个可能用不了的补丁。
# 基线号从 patch_state.gd 的常量读（放 .txt 里的第一版没进导出包，见那边的注释）。
# ⚠ **2026-09-09 的过渡期**：已发出去的 client-2026-09-09-4 读不到自己的基线（读成 0），
#   而它那版 decide() 会把 0 判成「太老」→ 一个补丁都收不到。所以在**下一个全量版发出去之前**，
#   手工把 latest.json 的 min_base 改成 0 再上传。之后这个注释可以删。
MIN_BASE="$(grep -oE '^const BASE_BUILD := [0-9]+' game/scripts/patch_state.gd | grep -oE '[0-9]+$')"
SHA="$(sha256sum "$OUT" | cut -d' ' -f1)"
HOST="https://github.com/Kevinnb66699/Cell-War/releases/download/patch-latest"
cat > "$OUTDIR/latest.json" <<JSON
{
  "build": $BUILD,
  "min_base": $MIN_BASE,
  "pck": "$HOST/$(basename "$OUT")",
  "sha256": "$SHA",
  "notes": "$(git log -1 --format=%s)"
}
JSON
echo
echo "manifest → $OUTDIR/latest.json"
cat "$OUTDIR/latest.json"
echo
echo "上传："
echo "  export PATH=\"/c/Program Files/GitHub CLI:\$PATH\""
echo "  gh release create patch-latest -t '热更补丁' -n '' 2>/dev/null || true"
echo "  gh release upload patch-latest $OUT $OUTDIR/latest.json --clobber"
