#!/usr/bin/env bash
# build_patch.sh —— 从 git 差异打出一个热更补丁包
#
# 用法（仓库根目录）：
#   tools/build_patch.sh <上一次发版的 tag>
#   例：tools/build_patch.sh client-2026-09-09-3
#   DRY=1 tools/build_patch.sh <tag>   # 打包 + 签名照跑，**就是不上传**
#
# 干的事：算出「那次发版之后 game/ 里改了哪些能进包的文件」→ 交给
# game/tests/build_patch.gd 用 PCKPacker 按 res:// 路径打包 →
# 连 manifest 一起放到 dist/patch/，并打印怎么上传。
#
# **全自动**：打包 → 签 manifest → scp 到自家服务器。跑完就生效，不用再手工上传。
# 正因为跑完就生效，`DRY=1` 存在：打包、跨基线闸、签名全都真跑一遍，只把两次 scp 跳掉。
# 想先看看「包多大、闸过不过、manifest 长什么样」时用它 ——
# 这条流水线第一次真发东西是 2026-09-10，之前从没上过线，值得先空跑一次。
#
# 补丁包名带版本号，manifest 的地址固定 —— 客户端取 manifest 时带时间戳绕缓存，
# 补丁包本身因为文件名唯一，不会被缓存串味。
#
# 为什么客户端包能这么省：94 MB 里约 88 MB 是 Godot 运行时，几乎从不变；
# 每天真正改的只有几十 KB 脚本。补丁包按 res:// 路径覆盖原包里的文件即可。
#
# ⚠ **这些改动打不进补丁，必须走 tools/publish_release.sh 全量发版**：
#   · 新增 class_name，**以及引用了目标基线没有的类**（全局类表导出时烘死）——
#     判据是 $BASE 那次发版的 git 树，不是本机项目；build_patch.gd 会拦住
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
DRY="${DRY:-0}"                      # 1 = 只打包与签名，不上传

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

# 目标基线的全局类表：从 **$BASE 那次发版的 git 树**里扒（不是本机项目）。
# 本次新加的类在本机也已注册，拿本机对照等于让补丁自己给自己开绿灯 ——
# 2026-09-09 加五只演出（CWHuntFx 等）之后，任何碰 match.gd 的补丁都会引用它们，
# 而还停在更旧包上的玩家装了就是当场 `Identifier not declared`。
CLASSES="$(mktemp)"
trap 'rm -f "$CLASSES"' EXIT
# ⚠ 这条流水线 2026-09-09 写出来时就是坏的，2026-09-10 才发现。
# sed 的替换串本该是「第一个捕获组」，但本文件当初是用 heredoc 落盘的，
# 反斜杠被吃掉 → 替换成了控制字符 0x01，于是每个类名都变成一个 0x01，
# sort -u 再并成一行。文件非空、旧的 `[ -s ]` 检查照样放行，
# 打包器读到零个类名就**静默退回本机类表** —— 这道闸从写出来那天起一天都没生效过。
#
# 现在不再只判「文件非空」：数**长得像类名的行**，再拿一个必然存在的类当探针。
# 判据坏掉时要当场停，不能像上一版那样降级成一句警告接着跑。
git grep -h -E '^class_name [A-Za-z_]' "$BASE" -- 'game/*.gd' |
	sed -E 's/^class_name +([A-Za-z_][A-Za-z0-9_]*).*/\1/' | sort -u > "$CLASSES"
N_CLASSES="$(grep -cE '^[A-Za-z_][A-Za-z0-9_]*$' "$CLASSES" || true)"
if [ "$N_CLASSES" -lt 20 ]; then
	die "从 $BASE 只扈出 $N_CLASSES 个像样的类名（这工程有七十多个）——
   多半是上面那条流水线又坏了。空表当判据 = 这道闸等于没有。"
fi
if ! grep -qx CWData "$CLASSES"; then
	die "扈出来的类表里没有 CWData —— 它从第一天就在，扈不到就是扈错了。"
fi
echo "目标基线 $BASE 的全局类表：$N_CLASSES 个类"

mkdir -p "$OUTDIR"
# 输出路径同样得给绝对的 —— 理由和上面那段一样（打包器跑在 `--path game` 底下，
# 相对路径会被当成 res:// 里的）。2026-09-09 第一次真打补丁时就是漏了这一处。
"$GODOT" --headless --path game --script res://tests/build_patch.gd -- 	"--base-classes=$CLASSES" "$PWD/$OUT" "${ARGS[@]}"

# min_base 取当前的基线号：补丁是照着 HEAD 打的，就只保证能装在这一档基线上。
# 比它老的客户端会被 boot.gd 拦下来，提示去下完整包，而不是硬套一个可能用不了的补丁。
# 基线号从 patch_state.gd 的常量读（放 .txt 里的第一版没进导出包，见那边的注释）。
MIN_BASE="$(grep -oE '^const BASE_BUILD := [0-9]+' game/scripts/patch_state.gd | grep -oE '[0-9]+$')"
SHA="$(sha256sum "$OUT" | cut -d' ' -f1)"
# 补丁包放**自家服务器**（Kevin 2026-09-09：国内比 GitHub 快一个量级）。
# 明文 HTTP 没关系：完整性由下面写进 manifest 的 SHA-256 保证，
# 客户端挂载前必校验 —— 中间人改一个字节就装不上。见 boot.gd 文件头「两段路」。
HOST="http://124.221.78.13/cellwar"
if [ "$DRY" = "1" ]; then
	echo "补丁包已打好（DRY=1，没上传）：$OUT（$(du -h "$OUT" | cut -f1)）"
else
	echo "上传补丁包到服务器 …"
	scp -o BatchMode=yes -o ConnectTimeout=15 "$OUT" cellwar:/var/www/cellwar/ >/dev/null
	echo "  http://124.221.78.13/cellwar/$(basename "$OUT")"
fi
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
# manifest 是信任锚 —— 必须**签名**，客户端拿烧在包里的公钥验（见 boot.gd 文件头）。
# 私钥在 ~/.cellwar/patch_key.pem，不进仓库；没有它就发不了补丁，这是有意的。
echo
echo "给 manifest 签名 …"
"$GODOT" --headless --path game --script res://tests/patch_key.gd -- 	sign "$PWD/$OUTDIR/latest.json" "$PWD/$OUTDIR/latest.json.sig" | tail -1
if [ "$DRY" = "1" ]; then
	echo
	echo "✔ 打包与签名都过了（DRY=1，**没有上传**，线上没有任何变化）"
	echo "   包：$OUT"
	echo "   去掉 DRY=1 再跑一遍就是真发。"
	exit 0
fi
scp -o BatchMode=yes -o ConnectTimeout=15 	"$OUTDIR/latest.json" "$OUTDIR/latest.json.sig" cellwar:/var/www/cellwar/ >/dev/null
echo
echo "✔ 全部就位，客户端下次启动就能收到："
echo "   $HOST/$(basename "$OUT")"
echo "   $HOST/latest.json（+ .sig）"
