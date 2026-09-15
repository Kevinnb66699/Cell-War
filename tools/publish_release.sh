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
# 发之前拦五件事，任一不满足直接退出 —— 这几条都是真踩过的坑：
#   ① 工作树干净        —— 否则发出去的包和仓库里的代码对不上
#   ② HEAD == origin/main —— 发的必须是已经推上去的那一版
#   ③ 两个包都在，且**比 HEAD 那次提交新** —— 防止改完代码忘了重导，把旧包发出去
#   ④ tag 还不存在      —— 免得覆盖历史版本
#   ⑤ BASE_BUILD 比上一次发版大 —— 热更的跨版本闸全靠它，不改就等于没有闸
#
# ⚠ **别把这个脚本接管道**（`tools/publish_release.sh | tail -7` 之类）。
# 脚本自己 `set -eu`、失败时老老实实退 1；但接了管道之后，`$?` 是**管道最后一段**的
# 退出码 —— `tail` 永远成功，于是发布失败会被读成成功。2026-09-09 就这么误判过一次：
# 网络抖动让 `gh` 报了 `error checking for existing release: ... EOF`，
# 退出码却是 0，靠事后 `gh release list` 交叉核对才发现包根本没发上去。
# 要截断输出就先落文件（`… >/tmp/pub.log 2>&1; rc=$?`），或者 `set -o pipefail`。
set -eu

cd "$(dirname "$0")/.."
DRY="${DRY:-0}"
WIN="dist/win/CellWar.exe"
MAC="dist/mac/CellWar.zip"

die() { echo "✘ $1" >&2; exit 1; }

# ---- ⓪ 卡面数据与 PRD 一致 ----
# 2026-09-09 三次撞上同一件事：PRD 里同一张卡按池子重复出现，团队改一处漏两处，
# `gen_card_data.py` 的一致性断言当场红 —— 而它**只在有人跑的时候才报错**，
# 于是卡面文案停更了两天没人发现。现在把它挂进发版守卫：生成不出来就不许发。
if command -v python >/dev/null 2>&1 && [ -f tools/gen_card_data.py ]; then
	# 2026-09-14（issue #41）由「生成得出来」改成 `--check` 逐字比对：
	# 生成得出来**不等于**仓库里那份是最新的 —— PRD 改了没重跑，照样一路绿灯发出去。
	python tools/gen_card_data.py --check 		|| die "卡面数据和 PRD 对不上（上面写了差在哪一行）：跑 python tools/gen_card_data.py 重新生成并提交"
fi

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

# ---- ⑤ 基线号必须比上一次发版大 ----
# `PatchState.BASE_BUILD` 是热更的**唯一**跨版本闸：manifest 的 min_base 拿它比，
# 比它老的客户端才会被 boot.gd 拦下来。
# 它的注释从第一天就写着「全量发版时往上改」，但那是句口头纪律 ——
# 2026-09-09 一天发了九个包，九个包的 BASE_BUILD 全是同一个 20260909，
# 于是 min_base 谁也拦不住：给 -9 打的补丁会照样装进 -7 的客户端，
# 而 -7 里没有 -9 新加的那五个类，玩家当场 `Identifier not declared`。
# 所以把这条纪律变成闸。**日期粒度不够**（同一天发九次），用到分钟。
base_build_at() {   # $1 = git ref（空 = 工作树）
	if [ -z "${1:-}" ]; then
		grep -oE '^const BASE_BUILD := [0-9]+' game/scripts/patch_state.gd
	else
		git show "$1:game/scripts/patch_state.gd" 2>/dev/null 			| grep -oE '^const BASE_BUILD := [0-9]+'
	fi | grep -oE '[0-9]+$'
}
NOW_BASE="$(base_build_at || true)"
[ -n "$NOW_BASE" ] || die "读不出 game/scripts/patch_state.gd 的 BASE_BUILD"
PREV_TAG="$(git tag -l 'client-*' --sort=-creatordate | head -1)"
if [ -n "$PREV_TAG" ]; then
	PREV_BASE="$(base_build_at "$PREV_TAG" || true)"
	if [ -n "$PREV_BASE" ] && [ "$NOW_BASE" -le "$PREV_BASE" ]; then
		die "BASE_BUILD 没往上改（$PREV_TAG 是 $PREV_BASE，现在还是 $NOW_BASE）——
   热更的跨版本闸全靠它：不改的话，给这一版打的补丁会装进上一版的客户端。
   改 game/scripts/patch_state.gd 的 BASE_BUILD 到 $(date +%Y%m%d%H%M) 再发。"
	fi
fi

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

# ---- 挂账提醒：全量发版是还它的**唯一**时机 ----
#
# 2026-09-15：网页版上有一个**发版侧的猴补丁**（tools/web/same_origin_shim.js），
# 用来把游戏里写死的 http://124.221.78.13/cellwar/ 改写成同源路径 —— 否则 https 页面上
# 那些请求会被当混合内容拦掉，整页被标成「不安全」。
#
# 之所以当时没根治，是因为根治要改 boot.gd 的 SELF_HOST，而**改 boot.gd 必须全量发版**
# （启动器在挂载补丁之前就被读了，热更不了；而且一改，补丁打包器就整个拒绝出包，
# 直到下一次全量发版为止）。
#
# **你现在正在做的就是全量发版。** 所以这里提醒 —— 不在这儿提，就没有别的地方会提了：
# 文档是被动的，只有这个脚本是「真要发版时一定会跑」的那一个。
#
# 提醒随 shim 文件自动消失：改完删掉它，这段就不再打印。
if [ -f "tools/web/same_origin_shim.js" ]; then
	cat >&2 <<'NOTE'

⚠ 挂账未还：网页版还挂着一个发版侧猴补丁（tools/web/same_origin_shim.js）
   它赌 Godot 的 web 版 HTTPRequest 走 fetch/XHR。引擎换实现就会**静默失效** ——
   页面变回「不安全」，而且不报任何错。

   **全量发版是还这笔账的唯一时机**，就是现在：
     1. boot.gd：SELF_HOST 改成 https://cellwar.jiling.chat/cellwar/
        （顺手 `if OS.has_feature("web")` 跳过查更新 —— 网页版根本不需要热更）
     2. nginx：cellwar 那块的 /cellwar/latest.json(.sig) 那两条 404 可以撤了
     3. 删掉 tools/web/same_origin_shim.js 与 deploy_web.sh 里注入它的那一段
     4. 重新 tools/deploy_web.sh
   细节见 docs/网页导出.md 的「①」。不做也能发，但这笔账会一直挂着。

NOTE
fi

if [ "$DRY" = "1" ]; then
	echo "✔ 五项检查通过（DRY=1，没真发）"
	exit 0
fi
command -v gh >/dev/null 2>&1 || die "没装 gh：装好并 gh auth login 之后再跑（登录那步要你自己来）"

gh release create "$TAG" "$WIN" "$MAC" --title "$TAG" --notes "$NOTES"
echo "✔ 已发布 $TAG"
