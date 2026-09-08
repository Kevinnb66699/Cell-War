#!/usr/bin/env bash
# publish_release.sh —— 把 dist/ 里的两个客户端包发到 GitHub Release
#
# 用法（仓库根目录）：
#   tools/publish_release.sh              # tag = client-YYYY-MM-DD（当天重发自动加 -2、-3…）
#   tools/publish_release.sh client-x     # 自己给 tag
#   DRY=1 tools/publish_release.sh        # 只跑检查、不真发（没装 gh 也能验）
#
# 前置：`gh` 已安装并登录。**登录那一步要你自己做**（`gh auth login`）——
# 它要输凭据，脚本不碰、也不该碰。
#
# 为什么要有这个脚本：客户端包此前只躺在本机 dist/（`.gitignore` 里，不入库），
# 谁要谁问、也说不清哪个包对应哪次提交。放进 Release 之后，包和 commit 绑死。
#
# 发之前拦四件事，任一不满足直接退出 —— 这四条都是真踩过的坑：
#   ① 工作树干净        —— 否则发出去的包和仓库里的代码对不上
#   ② HEAD == origin/main —— 发的必须是已经推上去的那一版
#   ③ 两个包都在，且**比 HEAD 那次提交新** —— 防止改完代码忘了重导，把旧包发出去
#   ④ tag 还不存在      —— 免得覆盖历史版本
set -eu

cd "$(dirname "$0")/.."
DRY="${DRY:-0}"
WIN="dist/win/CellWar.exe"
MAC="dist/mac/CellWar.zip"

die() { echo "✘ $1" >&2; exit 1; }

# ---- ① 工作树干净（.png.import 那类导出脏数据不算）----
if [ -n "$(git status --porcelain | grep -v '\.png\.import$' || true)" ]; then
	git status --short | grep -v '\.png\.import$' || true
	die "工作树不干净：先提交或还原，否则发出去的包和仓库对不上"
fi

# ---- ② 与 origin/main 一致 ----
git fetch -q origin
HEAD_SHA="$(git rev-parse HEAD)"
[ "$HEAD_SHA" = "$(git rev-parse origin/main)" ] \
	|| die "HEAD 不是 origin/main：先 push（发的必须是推上去的那一版）"

# ---- ③ 两个包都在，且比 HEAD 那次提交新 ----
for f in "$WIN" "$MAC"; do
	[ -f "$f" ] || die "找不到 $f —— 先导出（见 docs/架构说明书.md 的发版一节）"
done
COMMIT_AT="$(git log -1 --format=%ct)"
for f in "$WIN" "$MAC"; do
	BUILT_AT="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f")"
	[ "$BUILT_AT" -ge "$COMMIT_AT" ] \
		|| die "$f 比 HEAD 那次提交还旧：重导一遍，别把上一版的包发出去"
done

# ---- ④ tag ----
TAG="${1:-}"
if [ -z "$TAG" ]; then
	BASE="client-$(date +%Y-%m-%d)"
	TAG="$BASE"
	N=2
	while git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
		|| git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1; do
		TAG="$BASE-$N"
		N=$((N + 1))
	done
fi
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG 本地已存在"
git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1 && die "tag $TAG 远端已存在"

SHORT="$(git rev-parse --short HEAD)"
NOTES="$(printf '客户端包，对应提交 %s。\n\n- Windows：CellWar.exe\n- macOS：CellWar.zip（已签名）\n\n服务器同版由 tools/deploy_server.sh 发布。' "$SHORT")"

echo "tag        $TAG"
echo "commit     $SHORT"
echo "win        $(du -h "$WIN" | cut -f1)"
echo "mac        $(du -h "$MAC" | cut -f1)"

if [ "$DRY" = "1" ]; then
	echo "✔ 四项检查通过（DRY=1，没真发）"
	exit 0
fi
command -v gh >/dev/null 2>&1 || die "没装 gh：装好并 gh auth login 之后再跑（登录那步要你自己来）"

gh release create "$TAG" "$WIN" "$MAC" --title "$TAG" --notes "$NOTES"
echo "✔ 已发布 $TAG"
